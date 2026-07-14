package app

import "context"

// LedgerQueryPort exposes application-level read results to transports.
type LedgerQueryPort interface {
	Version(context.Context) (LedgerVersion, error)
	Bootstrap(string, string, bool, ...string) (BootstrapResult, error)
	BootstrapLite(string, string, bool, ...string) (BootstrapResult, error)
	Summary(string, string, bool, ...string) (SummaryQueryResult, error)
	Transactions(string, string, bool) (TransactionQueryResult, error)
	Balances(context.Context) (map[string]int, []BalanceAssertion, error)
	IncomeStatement(string, string, bool, ...string) (IncomeStatementQueryResult, error)
}

// LedgerSnapshotPort isolates legacy consumers that still require raw snapshots.
type LedgerSnapshotPort interface {
	Snapshot(context.Context) (*LedgerSnapshot, error)
	SnapshotLite(context.Context) (*LedgerSnapshot, error)
}

var _ LedgerQueryPort = (*LedgerReadService)(nil)
var _ LedgerSnapshotPort = (*LedgerReadService)(nil)
