package app

import "testing"

func TestPaymentAccountsExcludeInvestmentsAndCapAtExpense(t *testing.T) {
	accounts := map[string]Account{
		"Assets:Cash":             {Account: "Assets:Cash", Group: "cash"},
		"Assets:Broker:Portfolio": {Account: "Assets:Broker:Portfolio", Group: "wealth"},
	}
	txns := []Transaction{
		{
			Date: "2026-07-10",
			Postings: []Posting{
				{Account: "Assets:Broker:Portfolio", Amount: 99900, Currency: "CNY"},
				{Account: "Expenses:Investment:Fee", Amount: 100, Currency: "CNY"},
				{Account: "Assets:Cash", Amount: -100000, Currency: "CNY"},
			},
			Source: TransactionSource{File: "transactions/2026/07.bean", Line: 10},
		},
		{
			Date: "2026-07-11",
			Postings: []Posting{
				{Account: "Assets:Broker:Portfolio", Amount: -100000, Currency: "CNY"},
				{Account: "Expenses:Investment:Fee", Amount: 100, Currency: "CNY"},
				{Account: "Assets:Cash", Amount: 99900, Currency: "CNY"},
			},
			Source: TransactionSource{File: "transactions/2026/07.bean", Line: 20},
		},
	}

	rows := summarizePaymentAccounts(txns, "2026-07-01", "2026-08-01", accounts, nil, "CNY")

	if len(rows) != 1 {
		t.Fatalf("payment sources should only contain the cash account, got %#v", rows)
	}
	if rows[0].Account != "Assets:Cash" || rows[0].Amount != 100 || rows[0].TxCount != 1 {
		t.Fatalf("payment source should reflect the actual fee instead of investment principal, got %#v", rows[0])
	}
}
