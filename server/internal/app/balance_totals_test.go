package app

import "testing"

// An overpaid credit card (a positive Liabilities balance, e.g. a refund that
// landed after the bill was paid in full) is money owed to the user. It must
// reduce debt, not add to it, so net worth is not understated by twice the
// overpayment.
func TestBalanceTotalsTreatOverpaidLiabilitiesAsReducingDebt(t *testing.T) {
	rows := []AccountBalance{
		{Account: "Assets:Bank", Valuation: 1_000_000},
		{Account: "Liabilities:CreditCard:Visa", Valuation: -30_000},
		{Account: "Liabilities:CreditCard:Master", Valuation: 50_000},
		{Account: "Assets:Unpriced", Valuation: 999_999, ValuationMissing: true},
		{Account: "Expenses:Food", Valuation: 12_345},
	}
	assets, liabilities := balanceTotals(rows)
	if assets != 1_000_000 || liabilities != -20_000 || assets-liabilities != 1_020_000 {
		t.Fatalf("assets=%d liabilities=%d net=%d, want 1000000/-20000/1020000", assets, liabilities, assets-liabilities)
	}

	assets, liabilities = balanceTotals([]AccountBalance{
		{Account: "Assets:Bank", Valuation: 1_000_000},
		{Account: "Liabilities:CreditCard", Valuation: 50_000},
	})
	if liabilities != -50_000 || assets-liabilities != 1_050_000 {
		t.Fatalf("overpaid only: liabilities=%d net=%d, want -50000/1050000", liabilities, assets-liabilities)
	}
}

// The net worth history behind the trend charts must agree with balanceTotals.
func TestNetWorthHistoryTreatsOverpaidLiabilitiesAsReducingDebt(t *testing.T) {
	txns := []Transaction{
		{Date: "2026-09-01", Postings: []Posting{{Account: "Assets:Bank", Amount: 1_000_000, Currency: "CNY"}, {Account: "Equity:Opening", Amount: -1_000_000, Currency: "CNY"}}},
		{Date: "2026-09-02", Postings: []Posting{{Account: "Liabilities:CreditCard", Amount: 50_000, Currency: "CNY"}, {Account: "Income:Refund", Amount: -50_000, Currency: "CNY"}}},
	}
	rows := netWorthHistoryInCurrencyAsc(txns, nil, "CNY")
	if len(rows) != 2 {
		t.Fatalf("rows=%#v, want two dated points", rows)
	}
	last := rows[len(rows)-1]
	if last.Assets != 1_000_000 || last.Liabilities != -50_000 || last.NetWorth != 1_050_000 {
		t.Fatalf("last=%#v, want assets 1000000, liabilities -50000, net worth 1050000", last)
	}
}
