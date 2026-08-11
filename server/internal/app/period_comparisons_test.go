package app

import "testing"

func TestComparisonTodayUsesTheClientCalendarDate(t *testing.T) {
	if got := comparisonToday("2028-02-29"); got != "2028-02-29" {
		t.Fatalf("comparison today = %q, want browser-local leap day", got)
	}
}

func TestCalendarMonthComparisonRangesClampPartialAndCompletedMonths(t *testing.T) {
	partial, ok := calendarMonthComparisonRanges("2026-03-01", "2026-04-01", "2026-03-31")
	if !ok {
		t.Fatal("expected calendar month range")
	}
	if partial.current.End != "2026-03-31" || partial.month.End != "2026-02-28" || partial.year.End != "2025-03-31" {
		t.Fatalf("short-month clamp changed: %#v", partial)
	}

	leap, ok := calendarMonthComparisonRanges("2028-02-01", "2028-03-01", "2028-02-29")
	if !ok || leap.current.End != "2028-02-29" || leap.month.End != "2028-01-29" || leap.year.End != "2027-02-28" {
		t.Fatalf("leap-year clamp changed: %#v ok=%v", leap, ok)
	}

	completed, ok := calendarMonthComparisonRanges("2026-04-01", "2026-05-01", "2026-08-11")
	if !ok || completed.current.End != "2026-04-30" || completed.month.End != "2026-03-31" || completed.year.End != "2025-04-30" {
		t.Fatalf("completed calendar month should use its full day count: %#v ok=%v", completed, ok)
	}

	if _, ok := calendarMonthComparisonRanges("2026-03-02", "2026-04-02", "2026-03-31"); ok {
		t.Fatal("non-calendar range should not produce monthly comparisons")
	}
}

func TestBuildLedgerPeriodComparisonsPreservesZeroBaselineAndPrivacy(t *testing.T) {
	snapshot := &LedgerSnapshot{
		Transactions: []Transaction{
			{Date: "2025-08-05", Postings: []Posting{{Account: "Income:Salary", Amount: -800, Currency: "CNY"}, {Account: "Assets:Cash", Amount: 800, Currency: "CNY"}, {Account: "Expenses:Food", Amount: 400, Currency: "CNY"}}},
			{Date: "2026-07-05", Postings: []Posting{{Account: "Expenses:Food", Amount: 100, Currency: "CNY"}, {Account: "Assets:Cash", Amount: -100, Currency: "CNY"}}},
			{Date: "2026-08-05", Postings: []Posting{{Account: "Income:Salary", Amount: -1000, Currency: "CNY"}, {Account: "Assets:Cash", Amount: 700, Currency: "CNY"}, {Account: "Expenses:Food", Amount: 300, Currency: "CNY"}}},
		},
	}
	history := []NetWorthPoint{
		{Date: "2025-08-10", Assets: 8000, Liabilities: 3000, NetWorth: 5000},
		{Date: "2026-07-10", Assets: 10000, Liabilities: 9000, NetWorth: 1000},
		{Date: "2026-08-09", Assets: 12000, Liabilities: 11500, NetWorth: 500},
	}

	unlocked := buildLedgerPeriodComparisons(snapshot, "2026-08-01", "2026-09-01", true, "CNY", history, true, "2026-08-11")
	if unlocked == nil {
		t.Fatal("expected monthly comparisons")
	}
	incomeMoM := unlocked.Income.MonthOverMonth
	if incomeMoM.Current == nil || *incomeMoM.Current != 1000 || incomeMoM.Baseline == nil || *incomeMoM.Baseline != 0 || incomeMoM.Delta == nil || *incomeMoM.Delta != 1000 || incomeMoM.Percentage != nil {
		t.Fatalf("zero income baseline should keep absolute delta and omit percentage: %#v", incomeMoM)
	}
	if yoy := unlocked.Income.YearOverYear; yoy.Percentage == nil || *yoy.Percentage != 0.25 {
		t.Fatalf("income YoY comparison changed: %#v", yoy)
	}
	if unlocked.TotalAssets == nil {
		t.Fatal("full comparison should include total assets")
	}
	assetsMoM := unlocked.TotalAssets.MonthOverMonth
	if assetsMoM.Current == nil || *assetsMoM.Current != 12000 || assetsMoM.Baseline == nil || *assetsMoM.Baseline != 10000 || assetsMoM.Delta == nil || *assetsMoM.Delta != 2000 {
		t.Fatalf("total assets must use latest assets snapshots, not net worth: %#v", assetsMoM)
	}

	locked := buildLedgerPeriodComparisons(snapshot, "2026-08-01", "2026-09-01", false, "CNY", nil, true, "2026-08-11")
	if locked.TotalAssets == nil {
		t.Fatal("full locked comparison should preserve the total-assets range shape")
	}
	if locked.Income.MonthOverMonth.Current != nil || locked.Income.MonthOverMonth.Delta != nil || locked.TotalAssets.MonthOverMonth.Current != nil || locked.TotalAssets.MonthOverMonth.Delta != nil {
		t.Fatalf("locked comparisons leaked sensitive values: %#v", locked)
	}
	if locked.Expense.MonthOverMonth.Delta == nil || *locked.Expense.MonthOverMonth.Delta != 200 {
		t.Fatalf("locked expense comparison should remain available: %#v", locked.Expense.MonthOverMonth)
	}
	lite := buildLedgerPeriodComparisons(snapshot, "2026-08-01", "2026-09-01", true, "CNY", nil, false, "2026-08-11")
	if lite == nil || lite.TotalAssets != nil || lite.Income.MonthOverMonth.Delta == nil || lite.Expense.MonthOverMonth.Delta == nil {
		t.Fatalf("lite bootstrap should provide cash-flow comparisons without an incomplete asset placeholder: %#v", lite)
	}
}

func TestPeriodComparisonMissingAndNegativeValues(t *testing.T) {
	current := ComparisonDateRange{Start: "2026-08-01", End: "2026-08-11"}
	baseline := ComparisonDateRange{Start: "2026-07-01", End: "2026-07-11"}

	missing := comparisonValues(current, baseline, 100, 0, true, false)
	if missing.Current == nil || *missing.Current != 100 || missing.Baseline != nil || missing.Delta != nil || missing.Percentage != nil {
		t.Fatalf("missing baseline should make the comparison unavailable: %#v", missing)
	}

	negative := comparisonValues(current, baseline, -200, 100, true, true)
	if negative.Delta == nil || *negative.Delta != -300 || negative.Percentage == nil || *negative.Percentage != -3 {
		t.Fatalf("negative comparison should preserve mathematical signs: %#v", negative)
	}
}
