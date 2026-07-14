package app

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
