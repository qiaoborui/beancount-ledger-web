package app

import (
	"testing"
	"time"
)

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
