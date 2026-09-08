package app

import (
	"testing"
	"time"
)

func TestWidgetInsightsRanges(t *testing.T) {
	for _, test := range []struct{ today, weekStart, weekEnd, yearEnd string }{
		{"2027-01-01", "2026-12-28", "2027-01-04", "2028-01-01"},
		{"2028-02-29", "2028-02-28", "2028-03-06", "2029-01-01"},
		{"2026-09-06", "2026-08-31", "2026-09-07", "2027-01-01"},
	} {
		t.Run(test.today, func(t *testing.T) {
			insights := buildWidgetExpenseInsights(&LedgerSnapshot{}, test.today, "CNY", "2026-09-07T04:00:00Z")
			if insights.Week.Start != test.weekStart || insights.Week.End != test.weekEnd || insights.Year.End != test.yearEnd {
				t.Fatalf("incorrect ranges: %+v", insights)
			}
			today, _ := time.Parse("2006-01-02", test.today)
			start, _ := time.Parse("2006-01-02", insights.History.Start)
			if start.Weekday() != time.Monday || today.Sub(start).Hours()/24 < 77 || today.Sub(start).Hours()/24 > 83 {
				t.Fatalf("incorrect history start: %s", insights.History.Start)
			}
			if insights.History.End != today.AddDate(0, 0, 1).Format("2006-01-02") {
				t.Fatalf("incorrect history end: %s", insights.History.End)
			}
		})
	}
}

func TestWidgetMonthRangeAllowsNearbyDeviceDates(t *testing.T) {
	now := time.Date(2026, time.September, 6, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name      string
		today     string
		wantStart string
		wantEnd   string
		wantError bool
	}{
		{name: "same day", today: "2026-09-06", wantStart: "2026-09-01", wantEnd: "2026-10-01"},
		{name: "nearby timezone date", today: "2026-09-07", wantStart: "2026-09-01", wantEnd: "2026-10-01"},
		{name: "three days", today: "2026-09-03", wantStart: "2026-09-01", wantEnd: "2026-10-01"},
		{name: "outside window", today: "2026-09-02", wantError: true},
		{name: "invalid", today: "September 6", wantError: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			start, end, err := widgetMonthRange(test.today, now)
			if test.wantError {
				if err == nil {
					t.Fatalf("widgetMonthRange(%q) = %q, %q, nil", test.today, start, end)
				}
				return
			}
			if err != nil || start != test.wantStart || end != test.wantEnd {
				t.Fatalf("widgetMonthRange(%q) = %q, %q, %v", test.today, start, end, err)
			}
		})
	}
}
