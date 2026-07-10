package app

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	pgxstdlib "github.com/jackc/pgx/v5/stdlib"
	"golang.org/x/sync/errgroup"
)

type LedgerIndexStore struct {
	db        *sql.DB
	sourceKey string
	closeDB   bool
}

type LedgerIndexRevision struct {
	ID            int64
	SourceKey     string
	GitSHA        string
	LedgerVersion LedgerVersion
	IndexedAt     time.Time
	beanEntries   []byte
	beanErrors    []byte
}

func NewLedgerIndexStore(cfg Config) (*LedgerIndexStore, error) {
	if cfg.DatabaseURL == "" {
		return nil, errors.New("DATABASE_URL is required when LEDGER_READ_MODEL=postgres")
	}
	db, err := openPostgres(cfg.DatabaseURL)
	if err != nil {
		return nil, err
	}
	store, err := NewLedgerIndexStoreWithDB(db, cfg)
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	store.closeDB = true
	return store, nil
}

func NewLedgerIndexStoreWithDB(db *sql.DB, cfg Config) (*LedgerIndexStore, error) {
	store := &LedgerIndexStore{db: db, sourceKey: ledgerIndexSourceKey(cfg)}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := store.EnsureSchema(ctx); err != nil {
		return nil, err
	}
	return store, nil
}

func ledgerReadModelEnabled(cfg Config) bool {
	value := strings.TrimSpace(strings.ToLower(cfg.LedgerReadModel))
	return value == "postgres" || value == "pg"
}

func ledgerIndexSourceKey(cfg Config) string {
	branch := strings.TrimSpace(cfg.LedgerGitBranch)
	if branch == "" {
		branch = "main"
	}
	return "ledger#" + branch
}

func (s *LedgerIndexStore) Close() error {
	if s == nil || s.db == nil || !s.closeDB {
		return nil
	}
	return s.db.Close()
}

func (s *LedgerIndexStore) EnsureSchema(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS ledger_index_revisions (
  id BIGSERIAL PRIMARY KEY,
  source_key TEXT NOT NULL,
  git_sha TEXT NOT NULL DEFAULT '',
  ledger_version TEXT NOT NULL,
  latest_mtime_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
  file_count INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  error TEXT NOT NULL DEFAULT '',
  bean_entries JSONB NOT NULL DEFAULT '[]'::jsonb,
  bean_errors JSONB NOT NULL DEFAULT '[]'::jsonb,
  indexed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  activated_at TIMESTAMPTZ,
  UNIQUE (source_key, ledger_version)
);


CREATE UNIQUE INDEX IF NOT EXISTS ledger_index_revisions_active
  ON ledger_index_revisions (source_key)
  WHERE status = 'active';

CREATE TABLE IF NOT EXISTS ledger_index_accounts (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  account TEXT NOT NULL,
  open_date TEXT NOT NULL,
  close_date TEXT,
  currency TEXT NOT NULL,
  alias TEXT,
  label TEXT NOT NULL,
  account_group TEXT NOT NULL,
  active BOOLEAN NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  payload JSONB NOT NULL,
  PRIMARY KEY (revision_id, account)
);

CREATE TABLE IF NOT EXISTS ledger_index_transactions (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  txn_date TEXT NOT NULL,
  payee TEXT NOT NULL,
  narration TEXT NOT NULL,
  source_file TEXT NOT NULL,
  source_line INTEGER NOT NULL,
  source_hash TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  tags TEXT[] NOT NULL DEFAULT '{}'::text[],
  links TEXT[] NOT NULL DEFAULT '{}'::text[],
  payload JSONB NOT NULL,
  PRIMARY KEY (revision_id, ordinal)
);

CREATE INDEX IF NOT EXISTS ledger_index_transactions_date
  ON ledger_index_transactions (revision_id, txn_date DESC, ordinal DESC);

CREATE INDEX IF NOT EXISTS ledger_index_transactions_range
  ON ledger_index_transactions (revision_id, txn_date DESC, source_line ASC, ordinal ASC);

CREATE TABLE IF NOT EXISTS ledger_index_postings (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  transaction_ordinal INTEGER NOT NULL,
  posting_ordinal INTEGER NOT NULL,
  account TEXT NOT NULL,
  amount BIGINT NOT NULL,
  currency TEXT NOT NULL,
  flag TEXT NOT NULL,
  payload JSONB NOT NULL,
  PRIMARY KEY (revision_id, transaction_ordinal, posting_ordinal)
);

CREATE INDEX IF NOT EXISTS ledger_index_postings_account
  ON ledger_index_postings (revision_id, account);

CREATE TABLE IF NOT EXISTS ledger_index_balance_assertions (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  assertion_date TEXT NOT NULL,
  account TEXT NOT NULL,
  amount BIGINT NOT NULL,
  currency TEXT NOT NULL,
  payload JSONB NOT NULL,
  PRIMARY KEY (revision_id, ordinal)
);

CREATE TABLE IF NOT EXISTS ledger_index_prices (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  price_date TEXT NOT NULL,
  currency TEXT NOT NULL,
  amount BIGINT NOT NULL,
  quote_currency TEXT NOT NULL,
  payload JSONB NOT NULL,
  PRIMARY KEY (revision_id, ordinal)
);

CREATE TABLE IF NOT EXISTS ledger_index_commodities (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  commodity TEXT NOT NULL,
  PRIMARY KEY (revision_id, commodity)
);`)
	return err
}

func (s *LedgerIndexStore) ActiveRevision(ctx context.Context) (LedgerIndexRevision, bool, error) {
	return s.activeRevision(ctx, false)
}

func (s *LedgerIndexStore) activeRevision(ctx context.Context, includeBeanPayloads bool) (LedgerIndexRevision, bool, error) {
	var revision LedgerIndexRevision
	query := `
SELECT id, source_key, git_sha, ledger_version, latest_mtime_ms, file_count, indexed_at
FROM ledger_index_revisions
WHERE source_key = $1 AND status = 'active'
ORDER BY activated_at DESC NULLS LAST, indexed_at DESC
LIMIT 1`
	args := []any{s.sourceKey}
	dest := []any{&revision.ID, &revision.SourceKey, &revision.GitSHA, &revision.LedgerVersion.Version, &revision.LedgerVersion.LatestMtime, &revision.LedgerVersion.FileCount, &revision.IndexedAt}
	if includeBeanPayloads {
		query = `
SELECT id, source_key, git_sha, ledger_version, latest_mtime_ms, file_count, indexed_at, bean_entries, bean_errors
FROM ledger_index_revisions
WHERE source_key = $1 AND status = 'active'
ORDER BY activated_at DESC NULLS LAST, indexed_at DESC
LIMIT 1`
		dest = append(dest, &revision.beanEntries, &revision.beanErrors)
	}
	err := s.db.QueryRowContext(ctx, query, args...).Scan(dest...)
	if errors.Is(err, sql.ErrNoRows) {
		return LedgerIndexRevision{}, false, nil
	}
	if err != nil {
		return LedgerIndexRevision{}, false, err
	}
	return revision, true, nil
}

func (s *LedgerIndexStore) ActiveSnapshot(ctx context.Context) (*LedgerSnapshot, bool, error) {
	return s.activeSnapshot(ctx, true)
}

func (s *LedgerIndexStore) ActiveSnapshotLite(ctx context.Context) (*LedgerSnapshot, bool, error) {
	return s.activeSnapshot(ctx, false)
}

func (s *LedgerIndexStore) activeSnapshot(ctx context.Context, includeBeanPayloads bool) (*LedgerSnapshot, bool, error) {
	revision, ok, err := s.activeRevision(ctx, includeBeanPayloads)
	if err != nil || !ok {
		return nil, ok, err
	}
	snapshot := &LedgerSnapshot{LedgerVersion: revision.LedgerVersion, ParsedAt: revision.IndexedAt.UnixMilli()}
	if includeBeanPayloads {
		if err := json.Unmarshal(revision.beanEntries, &snapshot.BeanEntries); err != nil {
			return nil, false, err
		}
		if err := json.Unmarshal(revision.beanErrors, &snapshot.BeanErrors); err != nil {
			return nil, false, err
		}
	}

	// Load indexed rows in parallel to amortise Neon round-trip latency.
	var g errgroup.Group
	g.Go(func() error {
		var loadErr error
		snapshot.Accounts, loadErr = loadIndexRows[Account](ctx, s.db, `SELECT payload FROM ledger_index_accounts WHERE revision_id = $1 ORDER BY account`, revision.ID)
		return loadErr
	})
	g.Go(func() error {
		var loadErr error
		snapshot.Transactions, loadErr = loadIndexRows[Transaction](ctx, s.db, `SELECT payload FROM ledger_index_transactions WHERE revision_id = $1 ORDER BY ordinal`, revision.ID)
		return loadErr
	})
	g.Go(func() error {
		var loadErr error
		snapshot.BalanceAssertions, loadErr = loadIndexRows[BalanceAssertion](ctx, s.db, `SELECT payload FROM ledger_index_balance_assertions WHERE revision_id = $1 ORDER BY ordinal`, revision.ID)
		return loadErr
	})
	g.Go(func() error {
		var loadErr error
		snapshot.Prices, loadErr = loadIndexRows[Price](ctx, s.db, `SELECT payload FROM ledger_index_prices WHERE revision_id = $1 ORDER BY ordinal`, revision.ID)
		return loadErr
	})
	g.Go(func() error {
		var loadErr error
		snapshot.Commodities, loadErr = loadIndexCommodities(ctx, s.db, revision.ID)
		return loadErr
	})
	if err := g.Wait(); err != nil {
		return nil, false, err
	}
	prepareLedgerSnapshot(snapshot)
	return snapshot, true, nil
}

func (s *LedgerIndexStore) TransactionsForRevision(ctx context.Context, revisionID int64, start, end string) ([]Transaction, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT payload
FROM ledger_index_transactions
WHERE revision_id = $1 AND txn_date >= $2 AND txn_date < $3
ORDER BY txn_date DESC, source_line ASC, ordinal ASC`, revisionID, start, end)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Transaction{}
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var txn Transaction
		if err := json.Unmarshal(raw, &txn); err != nil {
			return nil, err
		}
		out = append(out, txn)
	}
	return out, rows.Err()
}

func loadIndexRows[T any](ctx context.Context, db *sql.DB, query string, revisionID int64) ([]T, error) {
	rows, err := db.QueryContext(ctx, query, revisionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []T{}
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var item T
		if err := json.Unmarshal(raw, &item); err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func loadIndexCommodities(ctx context.Context, db *sql.DB, revisionID int64) ([]string, error) {
	rows, err := db.QueryContext(ctx, `SELECT commodity FROM ledger_index_commodities WHERE revision_id = $1 ORDER BY commodity`, revisionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var commodity string
		if err := rows.Scan(&commodity); err != nil {
			return nil, err
		}
		out = append(out, commodity)
	}
	return out, rows.Err()
}

func (s *LedgerIndexStore) ReplaceActiveSnapshot(ctx context.Context, snapshot *LedgerSnapshot, gitSHA string) (int64, error) {
	if snapshot == nil {
		return 0, errors.New("ledger snapshot is required")
	}
	previousRevisionID := int64(0)
	if revision, ok, err := s.ActiveRevision(ctx); err != nil {
		return 0, err
	} else if ok && revision.LedgerVersion.Version == snapshot.Version && (gitSHA == "" || revision.GitSHA == gitSHA) {
		return revision.ID, nil
	} else if ok {
		previousRevisionID = revision.ID
	}

	conn, err := s.db.Conn(ctx)
	if err != nil {
		return 0, err
	}
	defer conn.Close()

	var revisionID int64
	err = conn.Raw(func(driverConn any) error {
		stdlibConn, ok := driverConn.(*pgxstdlib.Conn)
		if !ok {
			return driver.ErrBadConn
		}
		pgxTx, err := stdlibConn.Conn().Begin(ctx)
		if err != nil {
			return err
		}
		defer pgxTx.Rollback(ctx)
		revisionID, err = replaceActiveSnapshotPGX(ctx, pgxTx, s.sourceKey, previousRevisionID, snapshot, gitSHA)
		if err != nil {
			return err
		}
		return pgxTx.Commit(ctx)
	})
	if err != nil {
		return 0, err
	}
	return revisionID, nil
}

func replaceActiveSnapshotPGX(ctx context.Context, tx pgx.Tx, sourceKey string, previousRevisionID int64, snapshot *LedgerSnapshot, gitSHA string) (int64, error) {
	beanEntries, err := json.Marshal(snapshot.BeanEntries)
	if err != nil {
		return 0, err
	}
	beanErrors, err := json.Marshal(snapshot.BeanErrors)
	if err != nil {
		return 0, err
	}
	var revisionID int64
	err = tx.QueryRow(ctx, `
INSERT INTO ledger_index_revisions (source_key, git_sha, ledger_version, latest_mtime_ms, file_count, status, error, bean_entries, bean_errors, indexed_at)
VALUES ($1, $2, $3, $4, $5, 'indexing', '', $6, $7, now())
ON CONFLICT (source_key, ledger_version)
DO UPDATE SET git_sha = EXCLUDED.git_sha, latest_mtime_ms = EXCLUDED.latest_mtime_ms, file_count = EXCLUDED.file_count, status = 'indexing', error = '', bean_entries = EXCLUDED.bean_entries, bean_errors = EXCLUDED.bean_errors, indexed_at = now()
RETURNING id`, sourceKey, gitSHA, snapshot.Version, snapshot.LatestMtime, snapshot.FileCount, beanEntries, beanErrors).Scan(&revisionID)
	if err != nil {
		return 0, err
	}
	if err := clearRevisionRowsPGX(ctx, tx, revisionID); err != nil {
		return 0, err
	}
	if err := copyAccounts(ctx, tx, revisionID, snapshot.Accounts); err != nil {
		return 0, err
	}
	if err := copyTransactions(ctx, tx, revisionID, previousRevisionID, snapshot.Transactions); err != nil {
		return 0, err
	}
	if err := copyBalanceAssertions(ctx, tx, revisionID, snapshot.BalanceAssertions); err != nil {
		return 0, err
	}
	if err := copyPrices(ctx, tx, revisionID, snapshot.Prices); err != nil {
		return 0, err
	}
	if err := copyCommodities(ctx, tx, revisionID, snapshot.Commodities); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `UPDATE ledger_index_revisions SET status = 'indexed', activated_at = NULL WHERE id = $1`, revisionID); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `UPDATE ledger_index_revisions SET status = 'superseded' WHERE source_key = $1 AND status = 'active' AND id <> $2`, sourceKey, revisionID); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `UPDATE ledger_index_revisions SET status = 'active', activated_at = now() WHERE id = $1`, revisionID); err != nil {
		return 0, err
	}
	return revisionID, nil
}

func clearRevisionRowsPGX(ctx context.Context, tx pgx.Tx, revisionID int64) error {
	for _, table := range []string{
		"ledger_index_postings",
		"ledger_index_transactions",
		"ledger_index_balance_assertions",
		"ledger_index_prices",
		"ledger_index_commodities",
		"ledger_index_accounts",
	} {
		if _, err := tx.Exec(ctx, fmt.Sprintf("DELETE FROM %s WHERE revision_id = $1", table), revisionID); err != nil {
			return err
		}
	}
	return nil
}

func copyAccounts(ctx context.Context, tx pgx.Tx, revisionID int64, accounts []Account) error {
	if len(accounts) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_accounts"}, []string{"revision_id", "account", "open_date", "close_date", "currency", "alias", "label", "account_group", "active", "metadata", "payload"}, pgx.CopyFromSlice(len(accounts), func(i int) ([]any, error) {
		account := accounts[i]
		payload, metadata, err := jsonPayloads(account, account.Metadata)
		if err != nil {
			return nil, err
		}
		return []any{revisionID, account.Account, account.OpenDate, nullableStringPtr(account.CloseDate), account.Currency, nullableStringPtr(account.Alias), account.Label, account.Group, account.Active, metadata, payload}, nil
	}))
	return err
}

type indexedTransaction struct {
	ordinal int
	txn     Transaction
}

type reusedTransaction struct {
	newOrdinal int
	oldOrdinal int
}

type transactionReuseKey struct {
	file string
	line int
	hash string
}

func copyTransactions(ctx context.Context, tx pgx.Tx, revisionID int64, previousRevisionID int64, txns []Transaction) error {
	if len(txns) == 0 {
		return nil
	}
	reused, fresh, err := partitionReusableTransactions(ctx, tx, previousRevisionID, txns)
	if err != nil {
		return err
	}
	if err := copyReusedTransactions(ctx, tx, revisionID, previousRevisionID, reused); err != nil {
		return err
	}
	if err := copyFreshTransactions(ctx, tx, revisionID, fresh); err != nil {
		return err
	}
	return copyFreshPostings(ctx, tx, revisionID, fresh)
}

func partitionReusableTransactions(ctx context.Context, tx pgx.Tx, previousRevisionID int64, txns []Transaction) ([]reusedTransaction, []indexedTransaction, error) {
	if previousRevisionID == 0 {
		return nil, indexedTransactions(txns), nil
	}
	rows, err := tx.Query(ctx, `
SELECT ordinal, source_file, source_line, source_hash
FROM ledger_index_transactions
WHERE revision_id = $1 AND source_hash <> ''`, previousRevisionID)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()

	oldByKey := map[transactionReuseKey]int{}
	for rows.Next() {
		var ordinal int
		var key transactionReuseKey
		if err := rows.Scan(&ordinal, &key.file, &key.line, &key.hash); err != nil {
			return nil, nil, err
		}
		if _, exists := oldByKey[key]; !exists {
			oldByKey[key] = ordinal
		}
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	reused, fresh := classifyReusableTransactions(txns, oldByKey)
	return reused, fresh, nil
}

func classifyReusableTransactions(txns []Transaction, oldByKey map[transactionReuseKey]int) ([]reusedTransaction, []indexedTransaction) {
	reused := []reusedTransaction{}
	fresh := []indexedTransaction{}
	for i, txn := range txns {
		key := transactionReuseKey{file: txn.Source.File, line: txn.Source.Line, hash: txn.Source.Hash}
		if key.hash != "" {
			if oldOrdinal, ok := oldByKey[key]; ok {
				reused = append(reused, reusedTransaction{newOrdinal: i, oldOrdinal: oldOrdinal})
				continue
			}
		}
		fresh = append(fresh, indexedTransaction{ordinal: i, txn: txn})
	}
	return reused, fresh
}

func indexedTransactions(txns []Transaction) []indexedTransaction {
	out := make([]indexedTransaction, len(txns))
	for i, txn := range txns {
		out[i] = indexedTransaction{ordinal: i, txn: txn}
	}
	return out
}

func copyReusedTransactions(ctx context.Context, tx pgx.Tx, revisionID int64, previousRevisionID int64, reused []reusedTransaction) error {
	if len(reused) == 0 {
		return nil
	}
	if _, err := tx.Exec(ctx, `CREATE TEMP TABLE ledger_index_txn_reuse_map (new_ordinal INTEGER NOT NULL, old_ordinal INTEGER NOT NULL) ON COMMIT DROP`); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_txn_reuse_map"}, []string{"new_ordinal", "old_ordinal"}, pgx.CopyFromSlice(len(reused), func(i int) ([]any, error) {
		row := reused[i]
		return []any{row.newOrdinal, row.oldOrdinal}, nil
	})); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
INSERT INTO ledger_index_transactions (revision_id, ordinal, txn_date, payee, narration, source_file, source_line, source_hash, metadata, tags, links, payload)
SELECT $1, m.new_ordinal, t.txn_date, t.payee, t.narration, t.source_file, t.source_line, t.source_hash, t.metadata, t.tags, t.links, t.payload
FROM ledger_index_txn_reuse_map m
JOIN ledger_index_transactions t ON t.revision_id = $2 AND t.ordinal = m.old_ordinal`, revisionID, previousRevisionID); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `
INSERT INTO ledger_index_postings (revision_id, transaction_ordinal, posting_ordinal, account, amount, currency, flag, payload)
SELECT $1, m.new_ordinal, p.posting_ordinal, p.account, p.amount, p.currency, p.flag, p.payload
FROM ledger_index_txn_reuse_map m
JOIN ledger_index_postings p ON p.revision_id = $2 AND p.transaction_ordinal = m.old_ordinal`, revisionID, previousRevisionID)
	return err
}

func copyFreshTransactions(ctx context.Context, tx pgx.Tx, revisionID int64, txns []indexedTransaction) error {
	if len(txns) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_transactions"}, []string{"revision_id", "ordinal", "txn_date", "payee", "narration", "source_file", "source_line", "source_hash", "metadata", "tags", "links", "payload"}, pgx.CopyFromSlice(len(txns), func(i int) ([]any, error) {
		indexed := txns[i]
		txn := indexed.txn
		payload, metadata, err := jsonPayloads(txn, txn.Metadata)
		if err != nil {
			return nil, err
		}
		return []any{revisionID, indexed.ordinal, txn.Date, txn.Payee, txn.Narration, txn.Source.File, txn.Source.Line, txn.Source.Hash, metadata, stringSlice(txn.Tags), stringSlice(txn.Links), payload}, nil
	}))
	return err
}

func copyFreshPostings(ctx context.Context, tx pgx.Tx, revisionID int64, txns []indexedTransaction) error {
	if len(txns) == 0 {
		return nil
	}
	txnIndex, postingIndex := 0, 0
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_postings"}, []string{"revision_id", "transaction_ordinal", "posting_ordinal", "account", "amount", "currency", "flag", "payload"}, pgx.CopyFromFunc(func() ([]any, error) {
		for txnIndex < len(txns) && postingIndex >= len(txns[txnIndex].txn.Postings) {
			txnIndex++
			postingIndex = 0
		}
		if txnIndex >= len(txns) {
			return nil, nil
		}
		indexed := txns[txnIndex]
		posting := indexed.txn.Postings[postingIndex]
		currentPostingIndex := postingIndex
		postingIndex++
		payload, err := json.Marshal(posting)
		if err != nil {
			return nil, err
		}
		return []any{revisionID, indexed.ordinal, currentPostingIndex, posting.Account, posting.Amount, posting.Currency, posting.Flag, payload}, nil
	}))
	return err
}

func copyBalanceAssertions(ctx context.Context, tx pgx.Tx, revisionID int64, assertions []BalanceAssertion) error {
	if len(assertions) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_balance_assertions"}, []string{"revision_id", "ordinal", "assertion_date", "account", "amount", "currency", "payload"}, pgx.CopyFromSlice(len(assertions), func(i int) ([]any, error) {
		assertion := assertions[i]
		payload, err := json.Marshal(assertion)
		if err != nil {
			return nil, err
		}
		return []any{revisionID, i, assertion.Date, assertion.Account, assertion.Amount, assertion.Currency, payload}, nil
	}))
	return err
}

func copyPrices(ctx context.Context, tx pgx.Tx, revisionID int64, prices []Price) error {
	if len(prices) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_prices"}, []string{"revision_id", "ordinal", "price_date", "currency", "amount", "quote_currency", "payload"}, pgx.CopyFromSlice(len(prices), func(i int) ([]any, error) {
		price := prices[i]
		payload, err := json.Marshal(price)
		if err != nil {
			return nil, err
		}
		return []any{revisionID, i, price.Date, price.Currency, price.Amount, price.QuoteCurrency, payload}, nil
	}))
	return err
}

func copyCommodities(ctx context.Context, tx pgx.Tx, revisionID int64, commodities []string) error {
	if len(commodities) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_commodities"}, []string{"revision_id", "commodity"}, pgx.CopyFromSlice(len(commodities), func(i int) ([]any, error) {
		return []any{revisionID, commodities[i]}, nil
	}))
	return err
}

func jsonPayloads(payloadValue any, metadataValue any) ([]byte, []byte, error) {
	payload, err := json.Marshal(payloadValue)
	if err != nil {
		return nil, nil, err
	}
	metadata, err := json.Marshal(metadataValue)
	if err != nil {
		return nil, nil, err
	}
	if string(metadata) == "null" {
		metadata = []byte("{}")
	}
	return payload, metadata, nil
}

func nullableStringPtr(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

func stringSlice(values []string) []string {
	if values == nil {
		return []string{}
	}
	return values
}
