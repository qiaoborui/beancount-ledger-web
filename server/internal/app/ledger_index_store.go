package app

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/persistence"
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
}

const ledgerIndexSupersededRevisionGracePeriod = time.Minute

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
	if err := persistence.ApplyMigrations(ctx, db); err != nil {
		return nil, err
	}
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

func (s *LedgerIndexStore) SetConfig(cfg Config) {
	if s != nil {
		s.sourceKey = ledgerIndexSourceKey(cfg)
	}
}

func (s *LedgerIndexStore) withIndexLock(ctx context.Context, fn func() (LedgerIndexResult, error)) (LedgerIndexResult, error) {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return LedgerIndexResult{}, err
	}
	defer conn.Close()

	lockName := "ledger-index:" + s.sourceKey
	if _, err := conn.ExecContext(ctx, `SELECT pg_advisory_lock(hashtext($1))`, lockName); err != nil {
		return LedgerIndexResult{}, err
	}
	defer conn.ExecContext(context.Background(), `SELECT pg_advisory_unlock(hashtext($1))`, lockName)

	return fn()
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
  indexed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  activated_at TIMESTAMPTZ,
  UNIQUE (source_key, ledger_version)
);


CREATE UNIQUE INDEX IF NOT EXISTS ledger_index_revisions_active
  ON ledger_index_revisions (source_key)
  WHERE status = 'active';

CREATE TABLE IF NOT EXISTS ledger_index_bean_entries (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  entry_kind TEXT NOT NULL,
  entry_date TEXT NOT NULL DEFAULT '',
  source_file TEXT NOT NULL,
  source_line INTEGER NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  value TEXT NOT NULL DEFAULT '',
  filename TEXT NOT NULL DEFAULT '',
  flag TEXT NOT NULL DEFAULT '',
  payee TEXT NOT NULL DEFAULT '',
  narration TEXT NOT NULL DEFAULT '',
  account TEXT NOT NULL DEFAULT '',
  account2 TEXT NOT NULL DEFAULT '',
  currency TEXT NOT NULL DEFAULT '',
  amount BIGINT NOT NULL DEFAULT 0,
  amount_number TEXT NOT NULL DEFAULT '',
  amount_currency TEXT NOT NULL DEFAULT '',
  tolerance TEXT NOT NULL DEFAULT '',
  quote_currency TEXT NOT NULL DEFAULT '',
  custom_type TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (revision_id, ordinal)
);

CREATE INDEX IF NOT EXISTS ledger_index_bean_entries_kind_date
  ON ledger_index_bean_entries (revision_id, entry_kind, entry_date, ordinal);

CREATE TABLE IF NOT EXISTS ledger_index_bean_entry_lines (
  revision_id BIGINT NOT NULL,
  entry_ordinal INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  text TEXT NOT NULL,
  PRIMARY KEY (revision_id, entry_ordinal, ordinal),
  FOREIGN KEY (revision_id, entry_ordinal)
    REFERENCES ledger_index_bean_entries(revision_id, ordinal) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ledger_index_bean_entry_currencies (
  revision_id BIGINT NOT NULL,
  entry_ordinal INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  currency TEXT NOT NULL,
  PRIMARY KEY (revision_id, entry_ordinal, ordinal),
  FOREIGN KEY (revision_id, entry_ordinal)
    REFERENCES ledger_index_bean_entries(revision_id, ordinal) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ledger_index_bean_entry_tags (
  revision_id BIGINT NOT NULL,
  entry_ordinal INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  tag TEXT NOT NULL,
  PRIMARY KEY (revision_id, entry_ordinal, ordinal),
  FOREIGN KEY (revision_id, entry_ordinal)
    REFERENCES ledger_index_bean_entries(revision_id, ordinal) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ledger_index_bean_entry_links (
  revision_id BIGINT NOT NULL,
  entry_ordinal INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  link TEXT NOT NULL,
  PRIMARY KEY (revision_id, entry_ordinal, ordinal),
  FOREIGN KEY (revision_id, entry_ordinal)
    REFERENCES ledger_index_bean_entries(revision_id, ordinal) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ledger_index_bean_entry_metadata (
  revision_id BIGINT NOT NULL,
  entry_ordinal INTEGER NOT NULL,
  metadata_key TEXT NOT NULL,
  value_kind TEXT NOT NULL CHECK (value_kind IN ('null', 'string', 'number', 'boolean')),
  text_value TEXT,
  number_value DOUBLE PRECISION,
  boolean_value BOOLEAN,
  PRIMARY KEY (revision_id, entry_ordinal, metadata_key),
  FOREIGN KEY (revision_id, entry_ordinal)
    REFERENCES ledger_index_bean_entries(revision_id, ordinal) ON DELETE CASCADE,
  CHECK (
    (value_kind = 'null' AND text_value IS NULL AND number_value IS NULL AND boolean_value IS NULL) OR
    (value_kind = 'string' AND text_value IS NOT NULL AND number_value IS NULL AND boolean_value IS NULL) OR
    (value_kind = 'number' AND text_value IS NULL AND number_value IS NOT NULL AND boolean_value IS NULL) OR
    (value_kind = 'boolean' AND text_value IS NULL AND number_value IS NULL AND boolean_value IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS ledger_index_bean_entry_custom_values (
  revision_id BIGINT NOT NULL,
  entry_ordinal INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  value_kind TEXT NOT NULL CHECK (value_kind IN ('null', 'string', 'number', 'boolean')),
  text_value TEXT,
  number_value DOUBLE PRECISION,
  boolean_value BOOLEAN,
  PRIMARY KEY (revision_id, entry_ordinal, ordinal),
  FOREIGN KEY (revision_id, entry_ordinal)
    REFERENCES ledger_index_bean_entries(revision_id, ordinal) ON DELETE CASCADE,
  CHECK (
    (value_kind = 'null' AND text_value IS NULL AND number_value IS NULL AND boolean_value IS NULL) OR
    (value_kind = 'string' AND text_value IS NOT NULL AND number_value IS NULL AND boolean_value IS NULL) OR
    (value_kind = 'number' AND text_value IS NULL AND number_value IS NOT NULL AND boolean_value IS NULL) OR
    (value_kind = 'boolean' AND text_value IS NULL AND number_value IS NULL AND boolean_value IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS ledger_index_bean_entry_postings (
  revision_id BIGINT NOT NULL,
  entry_ordinal INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  account TEXT NOT NULL,
  amount BIGINT NOT NULL,
  currency TEXT NOT NULL,
  flag TEXT NOT NULL,
  blank BOOLEAN NOT NULL,
  quantity_number TEXT NOT NULL,
  quantity_currency TEXT NOT NULL,
  cost_amount BIGINT NOT NULL,
  cost_currency TEXT NOT NULL,
  cost_number TEXT NOT NULL,
  cost_value_currency TEXT NOT NULL,
  total_cost BOOLEAN NOT NULL,
  price_amount BIGINT NOT NULL,
  price_currency TEXT NOT NULL,
  price_number TEXT NOT NULL,
  price_value_currency TEXT NOT NULL,
  total_price BOOLEAN NOT NULL,
  PRIMARY KEY (revision_id, entry_ordinal, ordinal),
  FOREIGN KEY (revision_id, entry_ordinal)
    REFERENCES ledger_index_bean_entries(revision_id, ordinal) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ledger_index_bean_errors (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  source_file TEXT NOT NULL,
  source_line INTEGER NOT NULL,
  message TEXT NOT NULL,
  PRIMARY KEY (revision_id, ordinal)
);

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
  PRIMARY KEY (revision_id, account)
);

CREATE TABLE IF NOT EXISTS ledger_index_account_metadata (
  revision_id BIGINT NOT NULL,
  account TEXT NOT NULL,
  metadata_key TEXT NOT NULL,
  value_kind TEXT NOT NULL CHECK (value_kind IN ('null', 'string', 'number', 'boolean')),
  text_value TEXT,
  number_value DOUBLE PRECISION,
  boolean_value BOOLEAN,
  PRIMARY KEY (revision_id, account, metadata_key),
  FOREIGN KEY (revision_id, account)
    REFERENCES ledger_index_accounts(revision_id, account) ON DELETE CASCADE,
  CHECK (
    (value_kind = 'null' AND text_value IS NULL AND number_value IS NULL AND boolean_value IS NULL) OR
    (value_kind = 'string' AND text_value IS NOT NULL AND number_value IS NULL AND boolean_value IS NULL) OR
    (value_kind = 'number' AND text_value IS NULL AND number_value IS NOT NULL AND boolean_value IS NULL) OR
    (value_kind = 'boolean' AND text_value IS NULL AND number_value IS NULL AND boolean_value IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS ledger_index_account_metadata_key
  ON ledger_index_account_metadata (revision_id, metadata_key);

CREATE TABLE IF NOT EXISTS ledger_index_transactions (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  txn_date TEXT NOT NULL,
  payee TEXT NOT NULL,
  narration TEXT NOT NULL,
  source_file TEXT NOT NULL,
  source_line INTEGER NOT NULL,
  source_hash TEXT NOT NULL,
  PRIMARY KEY (revision_id, ordinal)
);

CREATE INDEX IF NOT EXISTS ledger_index_transactions_date
  ON ledger_index_transactions (revision_id, txn_date DESC, ordinal DESC);

CREATE INDEX IF NOT EXISTS ledger_index_transactions_range
  ON ledger_index_transactions (revision_id, txn_date DESC, source_line ASC, ordinal ASC);

CREATE TABLE IF NOT EXISTS ledger_index_transaction_metadata (
  revision_id BIGINT NOT NULL,
  transaction_ordinal INTEGER NOT NULL,
  metadata_key TEXT NOT NULL,
  value_kind TEXT NOT NULL CHECK (value_kind IN ('null', 'string', 'number', 'boolean')),
  text_value TEXT,
  number_value DOUBLE PRECISION,
  boolean_value BOOLEAN,
  PRIMARY KEY (revision_id, transaction_ordinal, metadata_key),
  FOREIGN KEY (revision_id, transaction_ordinal)
    REFERENCES ledger_index_transactions(revision_id, ordinal) ON DELETE CASCADE,
  CHECK (
    (value_kind = 'null' AND text_value IS NULL AND number_value IS NULL AND boolean_value IS NULL) OR
    (value_kind = 'string' AND text_value IS NOT NULL AND number_value IS NULL AND boolean_value IS NULL) OR
    (value_kind = 'number' AND text_value IS NULL AND number_value IS NOT NULL AND boolean_value IS NULL) OR
    (value_kind = 'boolean' AND text_value IS NULL AND number_value IS NULL AND boolean_value IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS ledger_index_transaction_metadata_key
  ON ledger_index_transaction_metadata (revision_id, metadata_key);

CREATE TABLE IF NOT EXISTS ledger_index_transaction_tags (
  revision_id BIGINT NOT NULL,
  transaction_ordinal INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  tag TEXT NOT NULL,
  PRIMARY KEY (revision_id, transaction_ordinal, ordinal),
  FOREIGN KEY (revision_id, transaction_ordinal)
    REFERENCES ledger_index_transactions(revision_id, ordinal) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ledger_index_transaction_tags_tag
  ON ledger_index_transaction_tags (revision_id, tag);

CREATE TABLE IF NOT EXISTS ledger_index_transaction_links (
  revision_id BIGINT NOT NULL,
  transaction_ordinal INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  link TEXT NOT NULL,
  PRIMARY KEY (revision_id, transaction_ordinal, ordinal),
  FOREIGN KEY (revision_id, transaction_ordinal)
    REFERENCES ledger_index_transactions(revision_id, ordinal) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ledger_index_transaction_links_link
  ON ledger_index_transaction_links (revision_id, link);

CREATE TABLE IF NOT EXISTS ledger_index_postings (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  transaction_ordinal INTEGER NOT NULL,
  posting_ordinal INTEGER NOT NULL,
  account TEXT NOT NULL,
  amount BIGINT NOT NULL,
  currency TEXT NOT NULL,
  flag TEXT NOT NULL,
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
  PRIMARY KEY (revision_id, ordinal)
);

CREATE TABLE IF NOT EXISTS ledger_index_prices (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  price_date TEXT NOT NULL,
  currency TEXT NOT NULL,
  amount BIGINT NOT NULL,
  quote_currency TEXT NOT NULL,
  PRIMARY KEY (revision_id, ordinal)
);

CREATE TABLE IF NOT EXISTS ledger_index_commodities (
  revision_id BIGINT NOT NULL REFERENCES ledger_index_revisions(id) ON DELETE CASCADE,
  commodity TEXT NOT NULL,
  PRIMARY KEY (revision_id, commodity)
);

CREATE TABLE IF NOT EXISTS ledger_index_requests (
  id BIGSERIAL PRIMARY KEY,
  source_key TEXT NOT NULL,
  git_sha TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  error TEXT NOT NULL DEFAULT '',
  requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  UNIQUE (source_key, git_sha)
);

CREATE INDEX IF NOT EXISTS ledger_index_requests_pending
  ON ledger_index_requests (source_key, requested_at)
  WHERE status = 'pending';`)
	return err
}

// EnqueueRequest durably records a Git revision that should be indexed and
// wakes local indexers listening on the shared database. The table is the
// source of truth; NOTIFY is only a low-latency hint and may be missed.
func (s *LedgerIndexStore) EnqueueRequest(ctx context.Context, gitSHA string) error {
	gitSHA = strings.TrimSpace(gitSHA)
	if gitSHA == "" {
		return nil
	}
	if _, err := s.db.ExecContext(ctx, `
INSERT INTO ledger_index_requests (source_key, git_sha, status, error, requested_at, completed_at)
VALUES ($1, $2, 'pending', '', now(), NULL)
ON CONFLICT (source_key, git_sha)
DO UPDATE SET status = 'pending', error = '', requested_at = now(), completed_at = NULL`, s.sourceKey, gitSHA); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `SELECT pg_notify('ledger_index_request', $1)`, s.sourceKey)
	return err
}

func (s *LedgerIndexStore) HasPendingRequest(ctx context.Context) (bool, error) {
	var exists bool
	err := s.db.QueryRowContext(ctx, `
SELECT EXISTS(SELECT 1 FROM ledger_index_requests WHERE source_key = $1 AND status = 'pending')`, s.sourceKey).Scan(&exists)
	return exists, err
}

func (s *LedgerIndexStore) PendingRequestBoundary(ctx context.Context) (int64, error) {
	var boundary int64
	err := s.db.QueryRowContext(ctx, `
SELECT COALESCE(MAX(id), 0) FROM ledger_index_requests WHERE source_key = $1 AND status = 'pending'`, s.sourceKey).Scan(&boundary)
	return boundary, err
}

func (s *LedgerIndexStore) CompletePendingRequestsThrough(ctx context.Context, boundary int64) error {
	if boundary <= 0 {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `
UPDATE ledger_index_requests
SET status = 'completed', error = '', completed_at = now()
WHERE source_key = $1 AND status = 'pending' AND id <= $2`, s.sourceKey, boundary)
	return err
}

func (s *LedgerIndexStore) IndexRequestStatus(ctx context.Context, gitSHA string) (string, bool, error) {
	gitSHA = strings.TrimSpace(gitSHA)
	if gitSHA == "" {
		return "", false, nil
	}
	var status string
	err := s.db.QueryRowContext(ctx, `
SELECT status
FROM ledger_index_requests
WHERE source_key = $1 AND git_sha = $2`, s.sourceKey, gitSHA).Scan(&status)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return status, err == nil, err
}

func (s *LedgerIndexStore) ActiveRevision(ctx context.Context) (LedgerIndexRevision, bool, error) {
	return s.activeRevision(ctx)
}

func (s *LedgerIndexStore) activeRevision(ctx context.Context) (LedgerIndexRevision, bool, error) {
	var revision LedgerIndexRevision
	query := `
SELECT id, source_key, git_sha, ledger_version, latest_mtime_ms, file_count, indexed_at
FROM ledger_index_revisions
WHERE source_key = $1 AND status = 'active'
ORDER BY activated_at DESC NULLS LAST, indexed_at DESC
LIMIT 1`
	err := s.db.QueryRowContext(ctx, query, s.sourceKey).Scan(&revision.ID, &revision.SourceKey, &revision.GitSHA, &revision.LedgerVersion.Version, &revision.LedgerVersion.LatestMtime, &revision.LedgerVersion.FileCount, &revision.IndexedAt)
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
	revision, ok, err := s.activeRevision(ctx)
	if err != nil || !ok {
		return nil, ok, err
	}
	snapshot := &LedgerSnapshot{LedgerVersion: revision.LedgerVersion, ParsedAt: revision.IndexedAt.UnixMilli()}
	if includeBeanPayloads {
		if err := loadBeanPayloads(ctx, s.db, revision.ID, snapshot); err != nil {
			return nil, false, err
		}
	}

	// Load indexed rows in parallel to amortise Neon round-trip latency.
	var g errgroup.Group
	g.Go(func() error {
		var loadErr error
		snapshot.Accounts, loadErr = loadIndexAccounts(ctx, s.db, revision.ID)
		return loadErr
	})
	g.Go(func() error {
		var loadErr error
		snapshot.Transactions, loadErr = loadIndexTransactions(ctx, s.db, revision.ID, `
SELECT ordinal, txn_date, payee, narration, source_file, source_line, source_hash
FROM ledger_index_transactions
WHERE revision_id = $1
ORDER BY ordinal`, `
SELECT transaction_ordinal, posting_ordinal, account, amount, currency, flag
FROM ledger_index_postings
WHERE revision_id = $1
ORDER BY transaction_ordinal, posting_ordinal`, `
SELECT 'tag', transaction_ordinal, ordinal, tag
FROM ledger_index_transaction_tags
WHERE revision_id = $1
UNION ALL
SELECT 'link', transaction_ordinal, ordinal, link
FROM ledger_index_transaction_links
WHERE revision_id = $1
ORDER BY 2, 1, 3`, `
SELECT transaction_ordinal, metadata_key, value_kind, text_value, number_value, boolean_value
FROM ledger_index_transaction_metadata
WHERE revision_id = $1
ORDER BY transaction_ordinal, metadata_key`, revision.ID)
		return loadErr
	})
	g.Go(func() error {
		var loadErr error
		snapshot.BalanceAssertions, loadErr = loadIndexBalanceAssertions(ctx, s.db, revision.ID)
		return loadErr
	})
	g.Go(func() error {
		var loadErr error
		snapshot.Prices, loadErr = loadIndexPrices(ctx, s.db, revision.ID)
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
	for index := range snapshot.Transactions {
		snapshot.Transactions[index].Source.GitSHA = revision.GitSHA
	}
	prepareLedgerSnapshot(snapshot)
	return snapshot, true, nil
}

func (s *LedgerIndexStore) TransactionsForRevision(ctx context.Context, revisionID int64, start, end string) ([]Transaction, error) {
	return loadIndexTransactions(ctx, s.db, revisionID, `
SELECT ordinal, txn_date, payee, narration, source_file, source_line, source_hash
FROM ledger_index_transactions
WHERE revision_id = $1 AND txn_date >= $2 AND txn_date < $3
ORDER BY txn_date DESC, source_line ASC, ordinal ASC`, `
SELECT p.transaction_ordinal, p.posting_ordinal, p.account, p.amount, p.currency, p.flag
FROM ledger_index_postings p
JOIN ledger_index_transactions t ON t.revision_id = p.revision_id AND t.ordinal = p.transaction_ordinal
WHERE p.revision_id = $1 AND t.txn_date >= $2 AND t.txn_date < $3
ORDER BY p.transaction_ordinal, p.posting_ordinal`, `
SELECT 'tag', tt.transaction_ordinal, tt.ordinal, tt.tag
FROM ledger_index_transaction_tags tt
JOIN ledger_index_transactions t ON t.revision_id = tt.revision_id AND t.ordinal = tt.transaction_ordinal
WHERE tt.revision_id = $1 AND t.txn_date >= $2 AND t.txn_date < $3
UNION ALL
SELECT 'link', tl.transaction_ordinal, tl.ordinal, tl.link
FROM ledger_index_transaction_links tl
JOIN ledger_index_transactions t ON t.revision_id = tl.revision_id AND t.ordinal = tl.transaction_ordinal
WHERE tl.revision_id = $1 AND t.txn_date >= $2 AND t.txn_date < $3
ORDER BY 2, 1, 3`, `
SELECT tm.transaction_ordinal, tm.metadata_key, tm.value_kind, tm.text_value, tm.number_value, tm.boolean_value
FROM ledger_index_transaction_metadata tm
JOIN ledger_index_transactions t ON t.revision_id = tm.revision_id AND t.ordinal = tm.transaction_ordinal
WHERE tm.revision_id = $1 AND t.txn_date >= $2 AND t.txn_date < $3
ORDER BY tm.transaction_ordinal, tm.metadata_key`, revisionID, start, end)
}

// BalancesForRevision returns each account's balance in its configured native
// currency. Accounts without a configured currency are included when all of
// their postings share one currency, matching nativeAccountBalances.
func (s *LedgerIndexStore) BalancesForRevision(ctx context.Context, revisionID int64) (map[string]int, []BalanceAssertion, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT p.account,
       COALESCE(NULLIF(a.currency, ''), ''),
       COALESCE(NULLIF(p.currency, ''), 'CNY'),
       SUM(p.amount)::BIGINT
FROM ledger_index_postings p
LEFT JOIN ledger_index_accounts a
  ON a.revision_id = p.revision_id AND a.account = p.account
WHERE p.revision_id = $1
GROUP BY p.account, a.currency, COALESCE(NULLIF(p.currency, ''), 'CNY')`, revisionID)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()

	type accountBalance struct {
		currency string
		amounts  map[string]int
	}
	byAccount := map[string]accountBalance{}
	for rows.Next() {
		var account, currency, postingCurrency string
		var amount int64
		if err := rows.Scan(&account, &currency, &postingCurrency, &amount); err != nil {
			return nil, nil, err
		}
		balance := byAccount[account]
		balance.currency = currency
		if balance.amounts == nil {
			balance.amounts = map[string]int{}
		}
		balance.amounts[postingCurrency] = int(amount)
		byAccount[account] = balance
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	balances := make(map[string]int, len(byAccount))
	for account, balance := range byAccount {
		if balance.currency != "" {
			balances[account] = balance.amounts[balance.currency]
			continue
		}
		if len(balance.amounts) == 1 {
			for _, amount := range balance.amounts {
				balances[account] = amount
			}
		}
	}
	assertions, err := loadIndexBalanceAssertions(ctx, s.db, revisionID)
	if err != nil {
		return nil, nil, err
	}
	return balances, assertions, nil
}

func loadIndexAccounts(ctx context.Context, db *sql.DB, revisionID int64) ([]Account, error) {
	rows, err := db.QueryContext(ctx, `
SELECT account, open_date, close_date, currency, alias, label, account_group, active
FROM ledger_index_accounts WHERE revision_id = $1 ORDER BY account`, revisionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	accounts := []Account{}
	for rows.Next() {
		var account Account
		var closeDate, alias sql.NullString
		if err := rows.Scan(&account.Account, &account.OpenDate, &closeDate, &account.Currency, &alias, &account.Label, &account.Group, &account.Active); err != nil {
			return nil, err
		}
		if closeDate.Valid {
			account.CloseDate = &closeDate.String
		}
		if alias.Valid {
			account.Alias = &alias.String
		}
		account.Metadata = map[string]MetadataValue{}
		accounts = append(accounts, account)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	metadataRows, err := db.QueryContext(ctx, `
SELECT account, metadata_key, value_kind, text_value, number_value, boolean_value
FROM ledger_index_account_metadata
WHERE revision_id = $1
ORDER BY account, metadata_key`, revisionID)
	if err != nil {
		return nil, err
	}
	defer metadataRows.Close()
	byAccount := make(map[string]int, len(accounts))
	for i, account := range accounts {
		byAccount[account.Account] = i
	}
	for metadataRows.Next() {
		var account, key, kind string
		var textValue sql.NullString
		var numberValue sql.NullFloat64
		var booleanValue sql.NullBool
		if err := metadataRows.Scan(&account, &key, &kind, &textValue, &numberValue, &booleanValue); err != nil {
			return nil, err
		}
		value, err := decodeLedgerMetadataValue(kind, textValue, numberValue, booleanValue)
		if err != nil {
			return nil, fmt.Errorf("decode account metadata %s.%s: %w", account, key, err)
		}
		if index, ok := byAccount[account]; ok {
			accounts[index].Metadata[key] = value
		}
	}
	if err := metadataRows.Err(); err != nil {
		return nil, err
	}
	return accounts, nil
}

func loadIndexTransactions(ctx context.Context, db *sql.DB, revisionID int64, transactionQuery, postingQuery, annotationQuery, metadataQuery string, args ...any) ([]Transaction, error) {
	rows, err := db.QueryContext(ctx, transactionQuery, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	type indexedTransactionRow struct {
		ordinal int
		txn     Transaction
	}
	indexed := []indexedTransactionRow{}
	byOrdinal := map[int]int{}
	for rows.Next() {
		var row indexedTransactionRow
		if err := rows.Scan(&row.ordinal, &row.txn.Date, &row.txn.Payee, &row.txn.Narration, &row.txn.Source.File, &row.txn.Source.Line, &row.txn.Source.Hash); err != nil {
			return nil, err
		}
		row.txn.Metadata = map[string]MetadataValue{}
		byOrdinal[row.ordinal] = len(indexed)
		indexed = append(indexed, row)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	postings, err := db.QueryContext(ctx, postingQuery, args...)
	if err != nil {
		return nil, err
	}
	defer postings.Close()
	for postings.Next() {
		var transactionOrdinal, postingOrdinal int
		var posting Posting
		if err := postings.Scan(&transactionOrdinal, &postingOrdinal, &posting.Account, &posting.Amount, &posting.Currency, &posting.Flag); err != nil {
			return nil, err
		}
		if index, ok := byOrdinal[transactionOrdinal]; ok {
			indexed[index].txn.Postings = append(indexed[index].txn.Postings, posting)
		}
	}
	if err := postings.Err(); err != nil {
		return nil, err
	}
	annotations, err := db.QueryContext(ctx, annotationQuery, args...)
	if err != nil {
		return nil, err
	}
	defer annotations.Close()
	for annotations.Next() {
		var kind, value string
		var transactionOrdinal, ordinal int
		if err := annotations.Scan(&kind, &transactionOrdinal, &ordinal, &value); err != nil {
			return nil, err
		}
		if index, ok := byOrdinal[transactionOrdinal]; ok {
			switch kind {
			case "tag":
				indexed[index].txn.Tags = append(indexed[index].txn.Tags, value)
			case "link":
				indexed[index].txn.Links = append(indexed[index].txn.Links, value)
			}
		}
	}
	if err := annotations.Err(); err != nil {
		return nil, err
	}
	metadataRows, err := db.QueryContext(ctx, metadataQuery, args...)
	if err != nil {
		return nil, err
	}
	defer metadataRows.Close()
	for metadataRows.Next() {
		var key, kind string
		var ordinal int
		var textValue sql.NullString
		var numberValue sql.NullFloat64
		var booleanValue sql.NullBool
		if err := metadataRows.Scan(&ordinal, &key, &kind, &textValue, &numberValue, &booleanValue); err != nil {
			return nil, err
		}
		value, err := decodeLedgerMetadataValue(kind, textValue, numberValue, booleanValue)
		if err != nil {
			return nil, fmt.Errorf("decode transaction metadata %d.%s: %w", ordinal, key, err)
		}
		if index, ok := byOrdinal[ordinal]; ok {
			indexed[index].txn.Metadata[key] = value
		}
	}
	if err := metadataRows.Err(); err != nil {
		return nil, err
	}
	out := make([]Transaction, 0, len(indexed))
	for _, row := range indexed {
		out = append(out, row.txn)
	}
	return out, nil
}

func loadIndexBalanceAssertions(ctx context.Context, db *sql.DB, revisionID int64) ([]BalanceAssertion, error) {
	rows, err := db.QueryContext(ctx, `
SELECT assertion_date, account, amount, currency
FROM ledger_index_balance_assertions WHERE revision_id = $1 ORDER BY ordinal`, revisionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	assertions := []BalanceAssertion{}
	for rows.Next() {
		var assertion BalanceAssertion
		if err := rows.Scan(&assertion.Date, &assertion.Account, &assertion.Amount, &assertion.Currency); err != nil {
			return nil, err
		}
		assertions = append(assertions, assertion)
	}
	return assertions, rows.Err()
}

func loadIndexPrices(ctx context.Context, db *sql.DB, revisionID int64) ([]Price, error) {
	rows, err := db.QueryContext(ctx, `
SELECT price_date, currency, amount, quote_currency
FROM ledger_index_prices WHERE revision_id = $1 ORDER BY ordinal`, revisionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	prices := []Price{}
	for rows.Next() {
		var price Price
		if err := rows.Scan(&price.Date, &price.Currency, &price.Amount, &price.QuoteCurrency); err != nil {
			return nil, err
		}
		prices = append(prices, price)
	}
	return prices, rows.Err()
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
	return s.replaceActiveSnapshot(ctx, snapshot, gitSHA, false)
}

func (s *LedgerIndexStore) ForceReplaceActiveSnapshot(ctx context.Context, snapshot *LedgerSnapshot, gitSHA string) (int64, error) {
	return s.replaceActiveSnapshot(ctx, snapshot, gitSHA, true)
}

func (s *LedgerIndexStore) replaceActiveSnapshot(ctx context.Context, snapshot *LedgerSnapshot, gitSHA string, force bool) (int64, error) {
	if snapshot == nil {
		return 0, errors.New("ledger snapshot is required")
	}
	previousRevisionID := int64(0)
	if revision, ok, err := s.ActiveRevision(ctx); err != nil {
		return 0, err
	} else if ok && !force && revision.LedgerVersion.Version == snapshot.Version && (gitSHA == "" || revision.GitSHA == gitSHA) {
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
	var revisionID int64
	err := tx.QueryRow(ctx, `
INSERT INTO ledger_index_revisions (source_key, git_sha, ledger_version, latest_mtime_ms, file_count, status, error, indexed_at)
VALUES ($1, $2, $3, $4, $5, 'indexing', '', now())
ON CONFLICT (source_key, ledger_version)
DO UPDATE SET git_sha = EXCLUDED.git_sha, latest_mtime_ms = EXCLUDED.latest_mtime_ms, file_count = EXCLUDED.file_count, status = 'indexing', error = '', indexed_at = now()
RETURNING id`, sourceKey, gitSHA, snapshot.Version, snapshot.LatestMtime, snapshot.FileCount).Scan(&revisionID)
	if err != nil {
		return 0, err
	}
	if err := clearRevisionRowsPGX(ctx, tx, revisionID); err != nil {
		return 0, err
	}
	if err := copyBeanPayloads(ctx, tx, revisionID, snapshot.BeanEntries, snapshot.BeanErrors); err != nil {
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
	if err := pruneSupersededRevisionsPGX(ctx, tx, sourceKey); err != nil {
		return 0, err
	}
	return revisionID, nil
}

func pruneSupersededRevisionsPGX(ctx context.Context, tx pgx.Tx, sourceKey string) error {
	// Keep the immediately previous revision for readers that cached its ID.
	// Delete at most two older snapshots per activation so legacy history
	// converges without turning one index update into a large cascade.
	_, err := tx.Exec(ctx, `
WITH newest_superseded AS (
  SELECT id
  FROM ledger_index_revisions
  WHERE source_key = $1 AND status = 'superseded'
  ORDER BY activated_at DESC NULLS LAST, indexed_at DESC, id DESC
  LIMIT 1
), stale_superseded AS (
  SELECT id
  FROM ledger_index_revisions
  WHERE source_key = $1
    AND status = 'superseded'
    AND id <> COALESCE((SELECT id FROM newest_superseded), 0)
    AND (activated_at IS NULL OR activated_at < now() - ($2 * INTERVAL '1 second'))
  ORDER BY activated_at ASC NULLS FIRST, indexed_at ASC, id ASC
  LIMIT 2
)
DELETE FROM ledger_index_revisions AS revisions
USING stale_superseded
WHERE revisions.id = stale_superseded.id`, sourceKey, int64(ledgerIndexSupersededRevisionGracePeriod/time.Second))
	return err
}

func clearRevisionRowsPGX(ctx context.Context, tx pgx.Tx, revisionID int64) error {
	for _, table := range []string{
		"ledger_index_bean_entry_lines",
		"ledger_index_bean_entry_currencies",
		"ledger_index_bean_entry_tags",
		"ledger_index_bean_entry_links",
		"ledger_index_bean_entry_metadata",
		"ledger_index_bean_entry_custom_values",
		"ledger_index_bean_entry_postings",
		"ledger_index_bean_entries",
		"ledger_index_bean_errors",
		"ledger_index_account_metadata",
		"ledger_index_transaction_metadata",
		"ledger_index_transaction_tags",
		"ledger_index_transaction_links",
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
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_accounts"}, []string{"revision_id", "account", "open_date", "close_date", "currency", "alias", "label", "account_group", "active"}, pgx.CopyFromSlice(len(accounts), func(i int) ([]any, error) {
		account := accounts[i]
		return []any{revisionID, account.Account, account.OpenDate, nullableStringPtr(account.CloseDate), account.Currency, nullableStringPtr(account.Alias), account.Label, account.Group, account.Active}, nil
	}))
	if err != nil {
		return err
	}
	return copyAccountMetadata(ctx, tx, revisionID, accounts)
}

type indexedAccountMetadata struct {
	account string
	key     string
	kind    string
	text    any
	number  any
	boolean any
}

func copyAccountMetadata(ctx context.Context, tx pgx.Tx, revisionID int64, accounts []Account) error {
	rows := make([]indexedAccountMetadata, 0)
	for _, account := range accounts {
		keys := make([]string, 0, len(account.Metadata))
		for key := range account.Metadata {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			kind, textValue, numberValue, booleanValue, err := encodeLedgerMetadataValue(account.Metadata[key])
			if err != nil {
				return fmt.Errorf("encode account metadata %s.%s: %w", account.Account, key, err)
			}
			rows = append(rows, indexedAccountMetadata{account: account.Account, key: key, kind: kind, text: textValue, number: numberValue, boolean: booleanValue})
		}
	}
	if len(rows) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_account_metadata"}, []string{"revision_id", "account", "metadata_key", "value_kind", "text_value", "number_value", "boolean_value"}, pgx.CopyFromSlice(len(rows), func(i int) ([]any, error) {
		row := rows[i]
		return []any{revisionID, row.account, row.key, row.kind, row.text, row.number, row.boolean}, nil
	}))
	return err
}

func encodeLedgerMetadataValue(value MetadataValue) (string, any, any, any, error) {
	switch typed := value.(type) {
	case nil:
		return "null", nil, nil, nil, nil
	case string:
		return "string", typed, nil, nil, nil
	case bool:
		return "boolean", nil, nil, typed, nil
	case float64:
		return "number", nil, typed, nil, nil
	case float32:
		return "number", nil, float64(typed), nil, nil
	case int:
		return "number", nil, float64(typed), nil, nil
	case int64:
		return "number", nil, float64(typed), nil, nil
	default:
		return "", nil, nil, nil, fmt.Errorf("unsupported value type %T", value)
	}
}

func decodeLedgerMetadataValue(kind string, textValue sql.NullString, numberValue sql.NullFloat64, booleanValue sql.NullBool) (MetadataValue, error) {
	switch kind {
	case "null":
		if textValue.Valid || numberValue.Valid || booleanValue.Valid {
			return nil, errors.New("null value has data")
		}
		return nil, nil
	case "string":
		if !textValue.Valid || numberValue.Valid || booleanValue.Valid {
			return nil, errors.New("invalid string value")
		}
		return textValue.String, nil
	case "number":
		if textValue.Valid || !numberValue.Valid || booleanValue.Valid {
			return nil, errors.New("invalid number value")
		}
		return numberValue.Float64, nil
	case "boolean":
		if textValue.Valid || numberValue.Valid || !booleanValue.Valid {
			return nil, errors.New("invalid boolean value")
		}
		return booleanValue.Bool, nil
	default:
		return nil, fmt.Errorf("unknown value kind %q", kind)
	}
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
	if err := copyFreshPostings(ctx, tx, revisionID, fresh); err != nil {
		return err
	}
	if err := copyReusedTransactionMetadata(ctx, tx, revisionID, previousRevisionID, reused); err != nil {
		return err
	}
	if err := copyReusedTransactionAnnotations(ctx, tx, revisionID, previousRevisionID, reused); err != nil {
		return err
	}
	if err := copyFreshTransactionMetadata(ctx, tx, revisionID, fresh); err != nil {
		return err
	}
	return copyFreshTransactionAnnotations(ctx, tx, revisionID, fresh)
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
INSERT INTO ledger_index_transactions (revision_id, ordinal, txn_date, payee, narration, source_file, source_line, source_hash)
SELECT $1, m.new_ordinal, t.txn_date, t.payee, t.narration, t.source_file, t.source_line, t.source_hash
FROM ledger_index_txn_reuse_map m
JOIN ledger_index_transactions t ON t.revision_id = $2 AND t.ordinal = m.old_ordinal`, revisionID, previousRevisionID); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `
INSERT INTO ledger_index_postings (revision_id, transaction_ordinal, posting_ordinal, account, amount, currency, flag)
SELECT $1, m.new_ordinal, p.posting_ordinal, p.account, p.amount, p.currency, p.flag
FROM ledger_index_txn_reuse_map m
JOIN ledger_index_postings p ON p.revision_id = $2 AND p.transaction_ordinal = m.old_ordinal`, revisionID, previousRevisionID)
	return err
}

func copyFreshTransactions(ctx context.Context, tx pgx.Tx, revisionID int64, txns []indexedTransaction) error {
	if len(txns) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_transactions"}, []string{"revision_id", "ordinal", "txn_date", "payee", "narration", "source_file", "source_line", "source_hash"}, pgx.CopyFromSlice(len(txns), func(i int) ([]any, error) {
		indexed := txns[i]
		txn := indexed.txn
		return []any{revisionID, indexed.ordinal, txn.Date, txn.Payee, txn.Narration, txn.Source.File, txn.Source.Line, txn.Source.Hash}, nil
	}))
	return err
}

func copyReusedTransactionMetadata(ctx context.Context, tx pgx.Tx, revisionID int64, previousRevisionID int64, reused []reusedTransaction) error {
	if len(reused) == 0 {
		return nil
	}
	_, err := tx.Exec(ctx, `
INSERT INTO ledger_index_transaction_metadata (revision_id, transaction_ordinal, metadata_key, value_kind, text_value, number_value, boolean_value)
SELECT $1, m.new_ordinal, metadata.metadata_key, metadata.value_kind, metadata.text_value, metadata.number_value, metadata.boolean_value
FROM ledger_index_txn_reuse_map m
JOIN ledger_index_transaction_metadata metadata
  ON metadata.revision_id = $2 AND metadata.transaction_ordinal = m.old_ordinal`, revisionID, previousRevisionID)
	return err
}

func copyFreshTransactionMetadata(ctx context.Context, tx pgx.Tx, revisionID int64, txns []indexedTransaction) error {
	rows := make([]indexedTransactionMetadata, 0)
	for _, indexed := range txns {
		keys := make([]string, 0, len(indexed.txn.Metadata))
		for key := range indexed.txn.Metadata {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			kind, textValue, numberValue, booleanValue, err := encodeLedgerMetadataValue(indexed.txn.Metadata[key])
			if err != nil {
				return fmt.Errorf("encode transaction metadata %d.%s: %w", indexed.ordinal, key, err)
			}
			rows = append(rows, indexedTransactionMetadata{transactionOrdinal: indexed.ordinal, key: key, kind: kind, text: textValue, number: numberValue, boolean: booleanValue})
		}
	}
	if len(rows) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_transaction_metadata"}, []string{"revision_id", "transaction_ordinal", "metadata_key", "value_kind", "text_value", "number_value", "boolean_value"}, pgx.CopyFromSlice(len(rows), func(i int) ([]any, error) {
		row := rows[i]
		return []any{revisionID, row.transactionOrdinal, row.key, row.kind, row.text, row.number, row.boolean}, nil
	}))
	return err
}

type indexedTransactionMetadata struct {
	transactionOrdinal int
	key                string
	kind               string
	text               any
	number             any
	boolean            any
}

func copyReusedTransactionAnnotations(ctx context.Context, tx pgx.Tx, revisionID int64, previousRevisionID int64, reused []reusedTransaction) error {
	if len(reused) == 0 {
		return nil
	}
	for _, annotation := range []struct {
		table  string
		column string
	}{
		{table: "ledger_index_transaction_tags", column: "tag"},
		{table: "ledger_index_transaction_links", column: "link"},
	} {
		query := fmt.Sprintf(`
INSERT INTO %s (revision_id, transaction_ordinal, ordinal, %s)
SELECT $1, m.new_ordinal, a.ordinal, a.%s
FROM ledger_index_txn_reuse_map m
JOIN %s a ON a.revision_id = $2 AND a.transaction_ordinal = m.old_ordinal`, annotation.table, annotation.column, annotation.column, annotation.table)
		if _, err := tx.Exec(ctx, query, revisionID, previousRevisionID); err != nil {
			return err
		}
	}
	return nil
}

func copyFreshTransactionAnnotations(ctx context.Context, tx pgx.Tx, revisionID int64, txns []indexedTransaction) error {
	for _, annotation := range []struct {
		table  string
		column string
		values func(Transaction) []string
	}{
		{table: "ledger_index_transaction_tags", column: "tag", values: func(txn Transaction) []string { return txn.Tags }},
		{table: "ledger_index_transaction_links", column: "link", values: func(txn Transaction) []string { return txn.Links }},
	} {
		txnIndex, valueIndex := 0, 0
		_, err := tx.CopyFrom(ctx, pgx.Identifier{annotation.table}, []string{"revision_id", "transaction_ordinal", "ordinal", annotation.column}, pgx.CopyFromFunc(func() ([]any, error) {
			for txnIndex < len(txns) && valueIndex >= len(annotation.values(txns[txnIndex].txn)) {
				txnIndex++
				valueIndex = 0
			}
			if txnIndex >= len(txns) {
				return nil, nil
			}
			indexed := txns[txnIndex]
			value := annotation.values(indexed.txn)[valueIndex]
			ordinal := valueIndex
			valueIndex++
			return []any{revisionID, indexed.ordinal, ordinal, value}, nil
		}))
		if err != nil {
			return err
		}
	}
	return nil
}

func copyFreshPostings(ctx context.Context, tx pgx.Tx, revisionID int64, txns []indexedTransaction) error {
	if len(txns) == 0 {
		return nil
	}
	txnIndex, postingIndex := 0, 0
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_postings"}, []string{"revision_id", "transaction_ordinal", "posting_ordinal", "account", "amount", "currency", "flag"}, pgx.CopyFromFunc(func() ([]any, error) {
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
		return []any{revisionID, indexed.ordinal, currentPostingIndex, posting.Account, posting.Amount, posting.Currency, posting.Flag}, nil
	}))
	return err
}

func copyBalanceAssertions(ctx context.Context, tx pgx.Tx, revisionID int64, assertions []BalanceAssertion) error {
	if len(assertions) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_balance_assertions"}, []string{"revision_id", "ordinal", "assertion_date", "account", "amount", "currency"}, pgx.CopyFromSlice(len(assertions), func(i int) ([]any, error) {
		assertion := assertions[i]
		return []any{revisionID, i, assertion.Date, assertion.Account, assertion.Amount, assertion.Currency}, nil
	}))
	return err
}

func copyPrices(ctx context.Context, tx pgx.Tx, revisionID int64, prices []Price) error {
	if len(prices) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_prices"}, []string{"revision_id", "ordinal", "price_date", "currency", "amount", "quote_currency"}, pgx.CopyFromSlice(len(prices), func(i int) ([]any, error) {
		price := prices[i]
		return []any{revisionID, i, price.Date, price.Currency, price.Amount, price.QuoteCurrency}, nil
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

func nullableStringPtr(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}
