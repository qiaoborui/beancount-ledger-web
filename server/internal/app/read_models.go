package app

type ReconciliationRow struct {
	Account       string            `json:"account"`
	Alias         *string           `json:"alias"`
	Label         string            `json:"label"`
	Currency      string            `json:"currency"`
	LedgerBalance int               `json:"ledgerBalance"`
	Status        string            `json:"status"`
	LastAssertion *BalanceAssertion `json:"lastAssertion"`
}

type BootstrapResult struct {
	Start              string                `json:"start"`
	End                string                `json:"end"`
	Summary            Summary               `json:"summary"`
	Balances           map[string]int        `json:"balances"`
	AccountBalances    []AccountBalance      `json:"accountBalances"`
	NetWorthHistory    []NetWorthPoint       `json:"netWorthHistory"`
	MonthEndNetWorth   []NetWorthPoint       `json:"monthEndNetWorth"`
	NetWorthWindows    *NetWorthWindows      `json:"netWorthWindows"`
	CreditCards        []CreditCardAnalytics `json:"creditCards"`
	Investments        InvestmentSummary     `json:"investments"`
	Transactions       []Transaction         `json:"transactions"`
	ReconciliationRows []ReconciliationRow   `json:"reconciliationRows"`
	Accounts           []Account             `json:"accounts"`
	Commodities        []string              `json:"commodities"`
	Prices             []Price               `json:"prices"`
	ValuationCurrency  string                `json:"valuationCurrency"`
	IncomeStatement    IncomeStatementResult `json:"incomeStatement"`
	AccountStatuses    []AccountStatus       `json:"accountStatuses"`
	LedgerVersion      LedgerVersion         `json:"ledgerVersion"`
	SensitiveUnlocked  bool                  `json:"sensitiveUnlocked"`
}

type IncomeStatementResult struct {
	Income             []IncomeStatementNode      `json:"income"`
	Expense            []IncomeStatementNode      `json:"expense"`
	TotalIncome        int                        `json:"totalIncome"`
	TotalExpense       int                        `json:"totalExpense"`
	ExpenseAnalytics   []ExpenseCategoryAnalytics `json:"expenseAnalytics"`
	TopPayees          []PayeeAnalytics           `json:"topPayees"`
	TopPaymentAccounts []AccountAnalytics         `json:"topPaymentAccounts"`
	NetIncome          int                        `json:"netIncome"`
	ValuationCurrency  string                     `json:"valuationCurrency"`
}

type IncomeStatementQueryResult struct {
	Start string `json:"start"`
	End   string `json:"end"`
	IncomeStatementResult
	SensitiveUnlocked bool `json:"sensitiveUnlocked"`
}

type SummaryQueryResult struct {
	Start             string                `json:"start"`
	End               string                `json:"end"`
	Summary           Summary               `json:"summary"`
	Balances          map[string]int        `json:"balances"`
	AccountBalances   []AccountBalance      `json:"accountBalances"`
	NetWorthHistory   []NetWorthPoint       `json:"netWorthHistory"`
	MonthEndNetWorth  []NetWorthPoint       `json:"monthEndNetWorth"`
	NetWorthWindows   *NetWorthWindows      `json:"netWorthWindows"`
	CreditCards       []CreditCardAnalytics `json:"creditCards"`
	Commodities       []string              `json:"commodities"`
	Prices            []Price               `json:"prices"`
	ValuationCurrency string                `json:"valuationCurrency"`
	SensitiveUnlocked bool                  `json:"sensitiveUnlocked"`
}

type TransactionQueryResult struct {
	Start             string        `json:"start"`
	End               string        `json:"end"`
	Transactions      []Transaction `json:"transactions"`
	SensitiveUnlocked bool          `json:"sensitiveUnlocked"`
}
