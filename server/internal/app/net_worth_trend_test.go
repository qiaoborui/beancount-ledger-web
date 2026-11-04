package app

import (
	"slices"
	"testing"
	"time"
)

func dailyNetWorthPoints(t *testing.T, start, end string) []NetWorthPoint {
	t.Helper()
	first, err := time.Parse("2006-01-02", start)
	if err != nil {
		t.Fatal(err)
	}
	last, err := time.Parse("2006-01-02", end)
	if err != nil {
		t.Fatal(err)
	}
	if last.Before(first) {
		t.Fatalf("end %s is before start %s", end, start)
	}
	rows := []NetWorthPoint{}
	for day := first; !day.After(last); day = day.AddDate(0, 0, 1) {
		rows = append(rows, NetWorthPoint{Date: day.Format("2006-01-02"), NetWorth: len(rows)})
	}
	return rows
}

func assertAscendingDates(t *testing.T, rows []NetWorthPoint) {
	t.Helper()
	for i := 1; i < len(rows); i++ {
		if rows[i-1].Date >= rows[i].Date {
			t.Fatalf("trend is not strictly ascending at %d: %s then %s", i, rows[i-1].Date, rows[i].Date)
		}
	}
}

func TestNetWorthTrendPointsKeepsEveryPointInTheRecentWindow(t *testing.T) {
	// 2024-06-01 is the last point, so the daily window opens 92 days earlier.
	rows := dailyNetWorthPoints(t, "2023-06-01", "2024-06-01")
	trend := NetWorthTrendPoints(rows)
	assertAscendingDates(t, trend)

	if trend[0].Date != "2023-06-30" {
		t.Fatalf("trend starts at %s, want the June 2023 month end", trend[0].Date)
	}
	if trend[len(trend)-1].Date != "2024-06-01" {
		t.Fatalf("trend ends at %s, want the last net-worth point", trend[len(trend)-1].Date)
	}
	// 9 month ends (2023-06…2024-02) plus 93 daily points (2024-03-01…2024-06-01).
	if len(trend) != 102 {
		t.Fatalf("trend length = %d, want 102", len(trend))
	}
	dates := map[string]bool{}
	for _, row := range trend {
		dates[row.Date] = true
	}
	for _, want := range []string{"2024-02-29", "2024-03-01", "2024-04-15", "2024-05-31", "2024-06-01"} {
		if !dates[want] {
			t.Fatalf("trend is missing %s", want)
		}
	}
	for _, dropped := range []string{"2023-06-29", "2024-01-15", "2024-02-28"} {
		if dates[dropped] {
			t.Fatalf("trend kept %s, want only month ends before the recent window", dropped)
		}
	}
}

func TestNetWorthTrendPointsStaysBoundedAcrossDecades(t *testing.T) {
	rows := dailyNetWorthPoints(t, "2000-01-01", "2024-12-31")
	trend := NetWorthTrendPoints(rows)
	assertAscendingDates(t, trend)

	if len(trend) != netWorthTrendMaxPoints {
		t.Fatalf("trend length = %d, want %d", len(trend), netWorthTrendMaxPoints)
	}
	if trend[0].Date != "2000-01-31" {
		t.Fatalf("trend starts at %s, want the opening month end", trend[0].Date)
	}
	if trend[len(trend)-1].Date != "2024-12-31" {
		t.Fatalf("trend ends at %s, want the last net-worth point", trend[len(trend)-1].Date)
	}
}

func TestNetWorthTrendPointsPassesShortHistoriesThrough(t *testing.T) {
	short := dailyNetWorthPoints(t, "2024-05-01", "2024-05-03")
	if trend := NetWorthTrendPoints(short); !slices.Equal(trend, short) {
		t.Fatalf("short trend = %v, want the input unchanged: %v", trend, short)
	}
	for _, rows := range [][]NetWorthPoint{nil, {}, {{Date: "2024-05-01"}}} {
		if got := NetWorthTrendPoints(rows); len(got) != len(rows) {
			t.Fatalf("trend for %d rows = %v, want the input unchanged", len(rows), got)
		}
	}
}

func TestNetWorthTrendPointsSemantics(t *testing.T) {
	// Monthly-only history keeps each month's last point and never invents or
	// reorders rows.
	rows := []NetWorthPoint{
		{Date: "2022-01-31", NetWorth: 1},
		{Date: "2022-02-28", NetWorth: 2},
		{Date: "2022-03-31", NetWorth: 3},
	}
	trend := NetWorthTrendPoints(rows)
	if len(trend) != len(rows) {
		t.Fatalf("trend = %v, want every monthly point", trend)
	}
	for i, row := range trend {
		if row != rows[i] {
			t.Fatalf("trend[%d] = %v, want %v", i, row, rows[i])
		}
	}
}

// The accounts page chart used to read NetWorthHistory, which only covers the
// requested range: every chart window then showed the same month and the range
// buttons did nothing. The bootstrap must carry a series that reaches the whole
// ledger while NetWorthHistory keeps its period contract.
func TestBootstrapCarriesWholeLedgerTrendOutsideTheRequestedRange(t *testing.T) {
	snapshot := &LedgerSnapshot{
		Transactions: []Transaction{
			{Date: "2024-01-10", Postings: []Posting{
				{Account: "Assets:Cash", Amount: 1_000_000, Currency: "CNY"},
				{Account: "Equity:Opening", Amount: -1_000_000, Currency: "CNY"},
			}},
			{Date: "2025-06-15", Postings: []Posting{
				{Account: "Assets:Cash", Amount: 500_000, Currency: "CNY"},
				{Account: "Income:Salary", Amount: -500_000, Currency: "CNY"},
			}},
			{Date: "2026-08-20", Postings: []Posting{
				{Account: "Assets:Cash", Amount: 250_000, Currency: "CNY"},
				{Account: "Income:Salary", Amount: -250_000, Currency: "CNY"},
			}},
		},
		Commodities: []string{"CNY"},
	}
	payload := BuildLedgerBootstrap(snapshot, "2026-08-01", "2026-09-01", true, "CNY", "2026-09-01")

	for _, row := range payload.NetWorthHistory {
		if row.Date < "2026-08-01" || row.Date >= "2026-09-01" {
			t.Fatalf("netWorthHistory left the requested range: %v", row)
		}
	}
	if len(payload.NetWorthHistory) != 1 {
		t.Fatalf("netWorthHistory = %v, want only the August point", payload.NetWorthHistory)
	}
	wantTrend := []NetWorthPoint{
		{Date: "2024-01-10", Assets: 1_000_000, NetWorth: 1_000_000},
		{Date: "2025-06-15", Assets: 1_500_000, NetWorth: 1_500_000},
		{Date: "2026-08-20", Assets: 1_750_000, NetWorth: 1_750_000},
	}
	if !slices.Equal(payload.NetWorthTrend, wantTrend) {
		t.Fatalf("netWorthTrend = %v, want %v", payload.NetWorthTrend, wantTrend)
	}
}
