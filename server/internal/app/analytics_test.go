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

func TestExpenseAnalyticsRefundsNetOut(t *testing.T) {
	accounts := []Account{
		{Account: "Assets:Cash", Group: "cash"},
		{Account: "Assets:Alipay", Group: "cash"},
		{Account: "Expenses:Clothing", Group: "expense"},
		{Account: "Expenses:Food", Group: "expense"},
	}
	txns := []Transaction{
		// Purchase 1: Clothing 500 CNY from Alipay (Payee: Taobao)
		{
			Date:  "2026-07-05",
			Payee: "淘宝",
			Postings: []Posting{
				{Account: "Expenses:Clothing", Amount: 50000, Currency: "CNY"},
				{Account: "Assets:Alipay", Amount: -50000, Currency: "CNY"},
			},
			Source: TransactionSource{File: "transactions/2026/07.bean", Line: 1},
		},
		// Purchase 2: Food 100 CNY from Alipay (Payee: Meituan)
		{
			Date:  "2026-07-06",
			Payee: "美团",
			Postings: []Posting{
				{Account: "Expenses:Food", Amount: 10000, Currency: "CNY"},
				{Account: "Assets:Alipay", Amount: -10000, Currency: "CNY"},
			},
			Source: TransactionSource{File: "transactions/2026/07.bean", Line: 2},
		},
		// Refund 1: Full refund for Food 100 CNY to Alipay (Payee: Meituan)
		{
			Date:  "2026-07-07",
			Payee: "美团",
			Postings: []Posting{
				{Account: "Expenses:Food", Amount: -10000, Currency: "CNY"},
				{Account: "Assets:Alipay", Amount: 10000, Currency: "CNY"},
			},
			Source: TransactionSource{File: "transactions/2026/07.bean", Line: 3},
		},
		// Refund 2: Partial refund for Clothing 200 CNY to Alipay (Payee: Taobao)
		{
			Date:  "2026-07-08",
			Payee: "淘宝",
			Postings: []Posting{
				{Account: "Expenses:Clothing", Amount: -20000, Currency: "CNY"},
				{Account: "Assets:Alipay", Amount: 20000, Currency: "CNY"},
			},
			Source: TransactionSource{File: "transactions/2026/07.bean", Line: 4},
		},
	}

	categories, topPayees, topAccounts := ExpenseAnalyticsInCurrency(txns, "2026-07-01", "2026-08-01", accounts, nil, "CNY")

	// 1. Food was fully refunded (100 - 100 = 0), so it should not be in expense categories
	if len(categories) != 1 {
		t.Fatalf("expected 1 positive expense category, got %#v", categories)
	}
	if categories[0].Account != "Expenses:Clothing" || categories[0].Amount != 30000 {
		t.Fatalf("expected Clothing to be 300.00 CNY, got %#v", categories[0])
	}

	// 2. Meituan was fully refunded, so only Taobao (500 - 200 = 300 CNY) should be in top payees
	if len(topPayees) != 1 {
		t.Fatalf("expected 1 top payee, got %#v", topPayees)
	}
	if topPayees[0].Payee != "淘宝" || topPayees[0].Amount != 30000 {
		t.Fatalf("expected Taobao to have 300.00 CNY, got %#v", topPayees[0])
	}

	// 3. Alipay net outflow should be 300 CNY (600 outflow - 300 refund)
	if len(topAccounts) != 1 {
		t.Fatalf("expected 1 payment account, got %#v", topAccounts)
	}
	if topAccounts[0].Account != "Assets:Alipay" || topAccounts[0].Amount != 30000 {
		t.Fatalf("expected Alipay to have net outflow 300.00 CNY, got %#v", topAccounts[0])
	}
}

