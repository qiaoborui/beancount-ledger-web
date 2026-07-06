package app

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

type LedgerIndexStore struct {
	db        *sql.DB
	sourceKey string
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
	db, err := sql.Open("pgx", cfg.DatabaseURL)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(4)
	db.SetConnMaxIdleTime(5 * time.Minute)
	store := &LedgerIndexStore{db: db, sourceKey: ledgerIndexSourceKey(cfg)}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := store.EnsureSchema(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

func ledgerReadModelEnabled(cfg Config) bool {
	value := strings.TrimSpace(strings.ToLower(cfg.LedgerReadModel))
	return value == "postgres" || value == "pg"
}

func ledgerIndexSourceKey(cfg Config) string {
	if sourceKey := strings.TrimSpace(env("LEDGER_INDEX_SOURCE_KEY", "")); sourceKey != "" {
		return sourceKey
	}
	remote := strings.TrimSpace(cfg.LedgerGitRemote)
	if remote == "" {
		remote = strings.TrimSpace(cfg.LedgerRoot)
	}
	branch := strings.TrimSpace(cfg.LedgerGitBranch)
	if branch == "" {
		branch = "main"
	}
	return remote + "#" + branch
}

func (s *LedgerIndexStore) Close() error {
	if s == nil || s.db == nil {
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

ALTER TABLE ledger_index_revisions ADD COLUMN IF NOT EXISTS bean_entries JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE ledger_index_revisions ADD COLUMN IF NOT EXISTS bean_errors JSONB NOT NULL DEFAULT '[]'::jsonb;

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
	var revision LedgerIndexRevision
	err := s.db.QueryRowContext(ctx, `
SELECT id, source_key, git_sha, ledger_version, latest_mtime_ms, file_count, indexed_at, bean_entries, bean_errors
FROM ledger_index_revisions
WHERE source_key = $1 AND status = 'active'
ORDER BY activated_at DESC NULLS LAST, indexed_at DESC
LIMIT 1`, s.sourceKey).Scan(&revision.ID, &revision.SourceKey, &revision.GitSHA, &revision.LedgerVersion.Version, &revision.LedgerVersion.LatestMtime, &revision.LedgerVersion.FileCount, &revision.IndexedAt, &revision.beanEntries, &revision.beanErrors)
	if errors.Is(err, sql.ErrNoRows) {
		return LedgerIndexRevision{}, false, nil
	}
	if err != nil {
		return LedgerIndexRevision{}, false, err
	}
	return revision, true, nil
}

func (s *LedgerIndexStore) ActiveSnapshot(ctx context.Context) (*LedgerSnapshot, bool, error) {
	revision, ok, err := s.ActiveRevision(ctx)
	if err != nil || !ok {
		return nil, ok, err
	}
	snapshot := &LedgerSnapshot{LedgerVersion: revision.LedgerVersion, ParsedAt: revision.IndexedAt.UnixMilli()}
	if err := json.Unmarshal(revision.beanEntries, &snapshot.BeanEntries); err != nil {
		return nil, false, err
	}
	if err := json.Unmarshal(revision.beanErrors, &snapshot.BeanErrors); err != nil {
		return nil, false, err
	}
	if snapshot.Accounts, err = loadIndexRows[Account](ctx, s.db, `SELECT payload FROM ledger_index_accounts WHERE revision_id = $1 ORDER BY account`, revision.ID); err != nil {
		return nil, false, err
	}
	if snapshot.Transactions, err = loadIndexRows[Transaction](ctx, s.db, `SELECT payload FROM ledger_index_transactions WHERE revision_id = $1 ORDER BY ordinal`, revision.ID); err != nil {
		return nil, false, err
	}
	if snapshot.BalanceAssertions, err = loadIndexRows[BalanceAssertion](ctx, s.db, `SELECT payload FROM ledger_index_balance_assertions WHERE revision_id = $1 ORDER BY ordinal`, revision.ID); err != nil {
		return nil, false, err
	}
	if snapshot.Prices, err = loadIndexRows[Price](ctx, s.db, `SELECT payload FROM ledger_index_prices WHERE revision_id = $1 ORDER BY ordinal`, revision.ID); err != nil {
		return nil, false, err
	}
	snapshot.Commodities, err = loadIndexCommodities(ctx, s.db, revision.ID)
	if err != nil {
		return nil, false, err
	}
	snapshot.RawBalances = CurrentBalances(snapshot.Transactions)
	snapshot.PriceIndex = NewPriceIndex(snapshot.Prices)
	snapshot.AccountMap = accountByName(snapshot.Accounts)
	snapshot.Balances = nativeAccountBalances(snapshot.RawBalances, snapshot.AccountMap)
	snapshot.AccountBalances = AccountBalanceRowsWithPriceIndex(snapshot.RawBalances, snapshot.PriceIndex, "")
	return snapshot, true, nil
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
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	var revisionID int64
	beanEntries, err := json.Marshal(snapshot.BeanEntries)
	if err != nil {
		return 0, err
	}
	beanErrors, err := json.Marshal(snapshot.BeanErrors)
	if err != nil {
		return 0, err
	}
	err = tx.QueryRowContext(ctx, `
INSERT INTO ledger_index_revisions (source_key, git_sha, ledger_version, latest_mtime_ms, file_count, status, error, bean_entries, bean_errors, indexed_at)
VALUES ($1, $2, $3, $4, $5, 'indexing', '', $6, $7, now())
ON CONFLICT (source_key, ledger_version)
DO UPDATE SET git_sha = EXCLUDED.git_sha, latest_mtime_ms = EXCLUDED.latest_mtime_ms, file_count = EXCLUDED.file_count, status = 'indexing', error = '', bean_entries = EXCLUDED.bean_entries, bean_errors = EXCLUDED.bean_errors, indexed_at = now()
RETURNING id`, s.sourceKey, gitSHA, snapshot.Version, snapshot.LatestMtime, snapshot.FileCount, beanEntries, beanErrors).Scan(&revisionID)
	if err != nil {
		return 0, err
	}
	if err := clearRevisionRows(ctx, tx, revisionID); err != nil {
		return 0, err
	}
	if err := insertAccounts(ctx, tx, revisionID, snapshot.Accounts); err != nil {
		return 0, err
	}
	if err := insertTransactions(ctx, tx, revisionID, snapshot.Transactions); err != nil {
		return 0, err
	}
	if err := insertBalanceAssertions(ctx, tx, revisionID, snapshot.BalanceAssertions); err != nil {
		return 0, err
	}
	if err := insertPrices(ctx, tx, revisionID, snapshot.Prices); err != nil {
		return 0, err
	}
	if err := insertCommodities(ctx, tx, revisionID, snapshot.Commodities); err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE ledger_index_revisions SET status = 'indexed', activated_at = NULL WHERE id = $1`, revisionID); err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE ledger_index_revisions SET status = 'superseded' WHERE source_key = $1 AND status = 'active' AND id <> $2`, s.sourceKey, revisionID); err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE ledger_index_revisions SET status = 'active', activated_at = now() WHERE id = $1`, revisionID); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return revisionID, nil
}

func clearRevisionRows(ctx context.Context, tx *sql.Tx, revisionID int64) error {
	for _, table := range []string{
		"ledger_index_postings",
		"ledger_index_transactions",
		"ledger_index_balance_assertions",
		"ledger_index_prices",
		"ledger_index_commodities",
		"ledger_index_accounts",
	} {
		if _, err := tx.ExecContext(ctx, fmt.Sprintf("DELETE FROM %s WHERE revision_id = $1", table), revisionID); err != nil {
			return err
		}
	}
	return nil
}

func insertAccounts(ctx context.Context, tx *sql.Tx, revisionID int64, accounts []Account) error {
	stmt, err := tx.PrepareContext(ctx, `
INSERT INTO ledger_index_accounts (revision_id, account, open_date, close_date, currency, alias, label, account_group, active, metadata, payload)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, account := range accounts {
		payload, metadata, err := jsonPayloads(account, account.Metadata)
		if err != nil {
			return err
		}
		if _, err := stmt.ExecContext(ctx, revisionID, account.Account, account.OpenDate, nullableStringPtr(account.CloseDate), account.Currency, nullableStringPtr(account.Alias), account.Label, account.Group, account.Active, metadata, payload); err != nil {
			return err
		}
	}
	return nil
}

func insertTransactions(ctx context.Context, tx *sql.Tx, revisionID int64, txns []Transaction) error {
	txnStmt, err := tx.PrepareContext(ctx, `
INSERT INTO ledger_index_transactions (revision_id, ordinal, txn_date, payee, narration, source_file, source_line, source_hash, metadata, tags, links, payload)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`)
	if err != nil {
		return err
	}
	defer txnStmt.Close()
	postingStmt, err := tx.PrepareContext(ctx, `
INSERT INTO ledger_index_postings (revision_id, transaction_ordinal, posting_ordinal, account, amount, currency, flag, payload)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`)
	if err != nil {
		return err
	}
	defer postingStmt.Close()
	for i, txn := range txns {
		payload, metadata, err := jsonPayloads(txn, txn.Metadata)
		if err != nil {
			return err
		}
		if _, err := txnStmt.ExecContext(ctx, revisionID, i, txn.Date, txn.Payee, txn.Narration, txn.Source.File, txn.Source.Line, txn.Source.Hash, metadata, stringSlice(txn.Tags), stringSlice(txn.Links), payload); err != nil {
			return err
		}
		for j, posting := range txn.Postings {
			postingPayload, err := json.Marshal(posting)
			if err != nil {
				return err
			}
			if _, err := postingStmt.ExecContext(ctx, revisionID, i, j, posting.Account, posting.Amount, posting.Currency, posting.Flag, postingPayload); err != nil {
				return err
			}
		}
	}
	return nil
}

func insertBalanceAssertions(ctx context.Context, tx *sql.Tx, revisionID int64, assertions []BalanceAssertion) error {
	stmt, err := tx.PrepareContext(ctx, `
INSERT INTO ledger_index_balance_assertions (revision_id, ordinal, assertion_date, account, amount, currency, payload)
VALUES ($1, $2, $3, $4, $5, $6, $7)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for i, assertion := range assertions {
		payload, err := json.Marshal(assertion)
		if err != nil {
			return err
		}
		if _, err := stmt.ExecContext(ctx, revisionID, i, assertion.Date, assertion.Account, assertion.Amount, assertion.Currency, payload); err != nil {
			return err
		}
	}
	return nil
}

func insertPrices(ctx context.Context, tx *sql.Tx, revisionID int64, prices []Price) error {
	stmt, err := tx.PrepareContext(ctx, `
INSERT INTO ledger_index_prices (revision_id, ordinal, price_date, currency, amount, quote_currency, payload)
VALUES ($1, $2, $3, $4, $5, $6, $7)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for i, price := range prices {
		payload, err := json.Marshal(price)
		if err != nil {
			return err
		}
		if _, err := stmt.ExecContext(ctx, revisionID, i, price.Date, price.Currency, price.Amount, price.QuoteCurrency, payload); err != nil {
			return err
		}
	}
	return nil
}

func insertCommodities(ctx context.Context, tx *sql.Tx, revisionID int64, commodities []string) error {
	stmt, err := tx.PrepareContext(ctx, `INSERT INTO ledger_index_commodities (revision_id, commodity) VALUES ($1, $2)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, commodity := range commodities {
		if _, err := stmt.ExecContext(ctx, revisionID, commodity); err != nil {
			return err
		}
	}
	return nil
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
