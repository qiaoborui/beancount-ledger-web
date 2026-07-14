package app

type TransactionQueryResult struct {
	Start             string        `json:"start"`
	End               string        `json:"end"`
	Transactions      []Transaction `json:"transactions"`
	SensitiveUnlocked bool          `json:"sensitiveUnlocked"`
}
