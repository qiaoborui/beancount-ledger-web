package app

import (
	"slices"
	"testing"
)

func expenseTxn(date string, amount int) Transaction {
	return Transaction{Date: date, Postings: []Posting{
		{Account: "Expenses:Food", Amount: amount, Currency: "CNY"},
		{Account: "Assets:Cash", Amount: -amount, Currency: "CNY"},
	}}
}

func TestMonthlyExpenseTrendCoversTwelveMonthsEndingAtThePeriod(t *testing.T) {
	txns := []Transaction{
		expenseTxn("2024-12-31", 999), // before the window, still marks history
		expenseTxn("2025-01-03", 100),
		expenseTxn("2025-07-10", 200),
		expenseTxn("2025-07-28", 50),
		expenseTxn("2025-12-31", 300),
		expenseTxn("2026-01-01", 777), // after the window
		{Date: "2025-07-15", Postings: []Posting{
			{Account: "Assets:Cash", Amount: 1_000, Currency: "CNY"},
			{Account: "Income:Salary", Amount: -1_000, Currency: "CNY"},
		}},
	}
	trend := MonthlyExpenseTrend(txns, NewPriceIndex(nil), "2026-01-01", "2026-01-01", "CNY")
	if len(trend) != monthlyExpenseTrendMonths {
		t.Fatalf("trend has %d months, want %d: %v", len(trend), monthlyExpenseTrendMonths, trend)
	}
	if trend[0].Month != "2025-01" || trend[len(trend)-1].Month != "2025-12" {
		t.Fatalf("trend spans %s…%s, want 2025-01…2025-12", trend[0].Month, trend[len(trend)-1].Month)
	}
	want := map[string]int{"2025-01": 100, "2025-07": 250, "2025-12": 300}
	for _, point := range trend {
		if point.Expense != want[point.Month] {
			t.Fatalf("%s expense = %d, want %d", point.Month, point.Expense, want[point.Month])
		}
	}
}

// A mid-month period end still anchors the window on that month, and the
// final bucket is the whole calendar month.
func TestMonthlyExpenseTrendAnchorsOnTheMonthHoldingTheLastDay(t *testing.T) {
	txns := []Transaction{expenseTxn("2025-01-05", 10), expenseTxn("2026-03-02", 20), expenseTxn("2026-03-30", 30)}
	trend := MonthlyExpenseTrend(txns, NewPriceIndex(nil), "2026-03-11", "2026-03-11", "CNY")
	last := trend[len(trend)-1]
	if last != (MonthlyExpensePoint{Month: "2026-03", Expense: 50}) {
		t.Fatalf("last point = %v, want March with both expenses", last)
	}
	if trend[0].Month != "2025-04" {
		t.Fatalf("trend starts at %s, want 2025-04", trend[0].Month)
	}
}

// 本年 ends on next January 1st; the window stops at today's month instead of
// charting the empty months still to come.
func TestMonthlyExpenseTrendStopsAtToday(t *testing.T) {
	txns := []Transaction{expenseTxn("2026-01-04", 10), expenseTxn("2026-11-08", 20)}
	trend := MonthlyExpenseTrend(txns, NewPriceIndex(nil), "2027-01-01", "2026-11-10", "CNY")
	if last := trend[len(trend)-1]; last != (MonthlyExpensePoint{Month: "2026-11", Expense: 20}) {
		t.Fatalf("last point = %v, want November", last)
	}
	if trend[0].Month != "2026-01" || len(trend) != 11 {
		t.Fatalf("trend = %v, want January through November", trend)
	}
	// An unparsable today keeps the period's own end.
	if trend := MonthlyExpenseTrend(txns, NewPriceIndex(nil), "2027-01-01", "", "CNY"); trend[len(trend)-1].Month != "2026-12" {
		t.Fatalf("trend without today ends at %s, want 2026-12", trend[len(trend)-1].Month)
	}
}

func TestMonthlyExpenseTrendStartsAtTheLedgersFirstMonth(t *testing.T) {
	txns := []Transaction{expenseTxn("2026-09-20", 40), expenseTxn("2026-11-02", 60)}
	trend := MonthlyExpenseTrend(txns, NewPriceIndex(nil), "2026-12-01", "", "CNY")
	want := []MonthlyExpensePoint{{Month: "2026-09", Expense: 40}, {Month: "2026-10"}, {Month: "2026-11", Expense: 60}}
	if !slices.Equal(trend, want) {
		t.Fatalf("trend = %v, want %v", trend, want)
	}
}

func TestMonthlyExpenseTrendIsEmptyWithoutHistory(t *testing.T) {
	if trend := MonthlyExpenseTrend(nil, NewPriceIndex(nil), "2026-12-01", "", "CNY"); trend == nil || len(trend) != 0 {
		t.Fatalf("trend = %#v, want an empty non-nil slice", trend)
	}
	if trend := MonthlyExpenseTrend(nil, NewPriceIndex(nil), "bad", "", "CNY"); trend == nil || len(trend) != 0 {
		t.Fatalf("trend = %#v, want an empty non-nil slice", trend)
	}
}

// The overview highlights the selected month; its bar must equal the period
// total the page prints, and the trend must reach months outside the period.
func TestBootstrapMonthlyExpenseTrendMatchesThePeriodSummary(t *testing.T) {
	snapshot := &LedgerSnapshot{
		Transactions: []Transaction{expenseTxn("2026-06-12", 8_000), expenseTxn("2026-08-03", 1_200), expenseTxn("2026-08-29", 300)},
		Commodities:  []string{"CNY"},
	}
	for _, unlocked := range []bool{true, false} {
		payload := BuildLedgerBootstrap(snapshot, "2026-08-01", "2026-09-01", unlocked, "CNY", "2026-09-01")
		trend := payload.MonthlyExpenseTrend
		want := []MonthlyExpensePoint{{Month: "2026-06", Expense: 8_000}, {Month: "2026-07"}, {Month: "2026-08", Expense: 1_500}}
		if !slices.Equal(trend, want) {
			t.Fatalf("unlocked=%v trend = %v, want %v", unlocked, trend, want)
		}
		if trend[len(trend)-1].Expense != payload.Summary.Expense {
			t.Fatalf("last month %d differs from the period expense %d", trend[len(trend)-1].Expense, payload.Summary.Expense)
		}
		lite := BuildLedgerBootstrapLite(snapshot, "2026-08-01", "2026-09-01", unlocked, "CNY", "2026-09-01")
		if !slices.Equal(lite.MonthlyExpenseTrend, want) {
			t.Fatalf("lite trend = %v, want %v", lite.MonthlyExpenseTrend, want)
		}
	}
}
