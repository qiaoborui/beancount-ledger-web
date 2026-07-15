package app

import "context"

// LedgerIndexPort exposes indexed ledger reads to the application layer.
// LedgerIndexStore is the Postgres adapter currently wired by the composition root.
type LedgerIndexPort interface {
	ActiveRevision(context.Context) (LedgerIndexRevision, bool, error)
	ActiveSnapshot(context.Context) (*LedgerSnapshot, bool, error)
	ActiveSnapshotLite(context.Context) (*LedgerSnapshot, bool, error)
	TransactionsForRevision(context.Context, int64, string, string) ([]Transaction, error)
	BalancesForRevision(context.Context, int64) (map[string]int, []BalanceAssertion, error)
}

var _ LedgerIndexPort = (*LedgerIndexStore)(nil)
