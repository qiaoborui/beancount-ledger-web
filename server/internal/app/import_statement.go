package app

type normalizedStatement struct {
	Provider        string
	Title           string
	StatementDate   string
	Cycle           string
	DueDate         string
	DefaultCurrency string
	Transactions    []normalizedTransaction
}

type normalizedTransaction struct {
	Date                string
	PostingDate         string
	AccountLast4        string
	Description         string
	TransactionCurrency string
	TransactionAmount   string
	SettlementCurrency  string
	SettlementAmount    string
	Amount              int
	RowNumber           int
	Source              string
}
