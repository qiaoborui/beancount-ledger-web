package app

import "context"

type LedgerReadOptions struct {
	ValuationCurrency string
	ComparisonDate    string
}

// LedgerQueryPort exposes application-level read results to transports.
type LedgerQueryPort interface {
	Version(context.Context) (LedgerVersion, error)
	Bootstrap(string, string, bool, LedgerReadOptions) (BootstrapResult, error)
	BootstrapLite(string, string, bool, LedgerReadOptions) (BootstrapResult, error)
	Summary(string, string, bool, LedgerReadOptions) (SummaryQueryResult, error)
	Transactions(string, string, bool, string) (TransactionQueryResult, error)
	Balances(context.Context) (map[string]int, []BalanceAssertion, error)
	IncomeStatement(string, string, bool, ...string) (IncomeStatementQueryResult, error)
	BQL(context.Context, string, string) (BQLResult, error)
}

// LedgerSnapshotPort isolates legacy consumers that still require raw snapshots.
type LedgerSnapshotPort interface {
	Snapshot(context.Context) (*LedgerSnapshot, error)
	SnapshotLite(context.Context) (*LedgerSnapshot, error)
}

var _ LedgerQueryPort = (*LedgerReadService)(nil)
var _ LedgerSnapshotPort = (*LedgerReadService)(nil)
