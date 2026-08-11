package app

import "time"

type ComparisonDateRange struct {
	Start string `json:"start"`
	End   string `json:"end"`
}

type PeriodComparison struct {
	CurrentRange  ComparisonDateRange `json:"currentRange"`
	BaselineRange ComparisonDateRange `json:"baselineRange"`
	Current       *int                `json:"current"`
	Baseline      *int                `json:"baseline"`
	Delta         *int                `json:"delta"`
	Percentage    *float64            `json:"percentage"`
}

type MetricPeriodComparisons struct {
	MonthOverMonth PeriodComparison `json:"monthOverMonth"`
	YearOverYear   PeriodComparison `json:"yearOverYear"`
}

type LedgerPeriodComparisons struct {
	Income      MetricPeriodComparisons  `json:"income"`
	Expense     MetricPeriodComparisons  `json:"expense"`
	TotalAssets *MetricPeriodComparisons `json:"totalAssets"`
}

type comparisonRanges struct {
	current ComparisonDateRange
	month   ComparisonDateRange
	year    ComparisonDateRange
}

func buildLedgerPeriodComparisons(snapshot *LedgerSnapshot, start, end string, unlocked bool, valuationCurrency string, assetHistory []NetWorthPoint, includeAssets bool, today string) *LedgerPeriodComparisons {
	ranges, ok := calendarMonthComparisonRanges(start, end, today)
	if !ok {
		return nil
	}

	currentSummary, currentAvailable := comparisonSummary(snapshot, ranges.current, valuationCurrency)
	monthSummary, monthAvailable := comparisonSummary(snapshot, ranges.month, valuationCurrency)
	yearSummary, yearAvailable := comparisonSummary(snapshot, ranges.year, valuationCurrency)

	income := metricPeriodComparisons(
		comparisonValues(ranges.current, ranges.month, currentSummary.Income, monthSummary.Income, currentAvailable, monthAvailable),
		comparisonValues(ranges.current, ranges.year, currentSummary.Income, yearSummary.Income, currentAvailable, yearAvailable),
	)
	expense := metricPeriodComparisons(
		comparisonValues(ranges.current, ranges.month, currentSummary.Expense, monthSummary.Expense, currentAvailable, monthAvailable),
		comparisonValues(ranges.current, ranges.year, currentSummary.Expense, yearSummary.Expense, currentAvailable, yearAvailable),
	)
	var assets *MetricPeriodComparisons
	if includeAssets {
		assetValues := metricPeriodComparisons(
			assetComparison(assetHistory, ranges.current, ranges.month),
			assetComparison(assetHistory, ranges.current, ranges.year),
		)
		assets = &assetValues
	}
	if !unlocked {
		income = maskedMetricPeriodComparisons(ranges)
		if assets != nil {
			maskedAssets := maskedMetricPeriodComparisons(ranges)
			assets = &maskedAssets
		}
	}

	return &LedgerPeriodComparisons{Income: income, Expense: expense, TotalAssets: assets}
}

func metricPeriodComparisons(month, year PeriodComparison) MetricPeriodComparisons {
	return MetricPeriodComparisons{MonthOverMonth: month, YearOverYear: year}
}

func maskedMetricPeriodComparisons(ranges comparisonRanges) MetricPeriodComparisons {
	return metricPeriodComparisons(
		comparisonValues(ranges.current, ranges.month, 0, 0, false, false),
		comparisonValues(ranges.current, ranges.year, 0, 0, false, false),
	)
}

func comparisonSummary(snapshot *LedgerSnapshot, dateRange ComparisonDateRange, valuationCurrency string) (Summary, bool) {
	endExclusive, ok := dayAfter(dateRange.End)
	if !ok {
		return Summary{}, false
	}
	available := false
	for _, txn := range snapshot.Transactions {
		if txn.Date >= dateRange.Start && txn.Date < endExclusive {
			available = true
			break
		}
	}
	return MonthSummaryInCurrency(dateRange.Start, endExclusive, snapshot.Transactions, snapshot.Prices, valuationCurrency), available
}

func comparisonValues(currentRange, baselineRange ComparisonDateRange, current, baseline int, currentAvailable, baselineAvailable bool) PeriodComparison {
	comparison := PeriodComparison{CurrentRange: currentRange, BaselineRange: baselineRange}
	if currentAvailable {
		comparison.Current = intPointer(current)
	}
	if baselineAvailable {
		comparison.Baseline = intPointer(baseline)
	}
	if !currentAvailable || !baselineAvailable {
		return comparison
	}
	delta := current - baseline
	comparison.Delta = intPointer(delta)
	if baseline != 0 {
		percentage := float64(delta) / float64(abs(baseline))
		comparison.Percentage = &percentage
	}
	return comparison
}

func assetComparison(history []NetWorthPoint, currentRange, baselineRange ComparisonDateRange) PeriodComparison {
	current, currentOK := latestAssetSnapshot(history, currentRange.End)
	baseline, baselineOK := latestAssetSnapshot(history, baselineRange.End)
	return comparisonValues(currentRange, baselineRange, current, baseline, currentOK, baselineOK)
}

func latestAssetSnapshot(history []NetWorthPoint, cutoff string) (int, bool) {
	found := false
	assets := 0
	for _, row := range history {
		if row.Date > cutoff {
			break
		}
		assets = row.Assets
		found = true
	}
	return assets, found
}

func calendarMonthComparisonRanges(start, end, today string) (comparisonRanges, bool) {
	startDate, err := time.Parse("2006-01-02", start)
	if err != nil || startDate.Day() != 1 || startDate.AddDate(0, 1, 0).Format("2006-01-02") != end {
		return comparisonRanges{}, false
	}
	endDate, _ := time.Parse("2006-01-02", end)
	currentEnd := endDate.AddDate(0, 0, -1)
	partial := false
	if todayDate, parseErr := time.Parse("2006-01-02", today); parseErr == nil && !todayDate.Before(startDate) && todayDate.Before(endDate) {
		currentEnd = todayDate
		partial = true
	}
	monthStart := startDate.AddDate(0, -1, 0)
	yearStart := startDate.AddDate(-1, 0, 0)
	monthRange := fullMonthComparisonDateRange(monthStart)
	yearRange := fullMonthComparisonDateRange(yearStart)
	if partial {
		monthRange = comparisonDateRange(monthStart, currentEnd.Day())
		yearRange = comparisonDateRange(yearStart, currentEnd.Day())
	}
	return comparisonRanges{
		current: comparisonDateRange(startDate, currentEnd.Day()),
		month:   monthRange,
		year:    yearRange,
	}, true
}

func fullMonthComparisonDateRange(start time.Time) ComparisonDateRange {
	return comparisonDateRange(start, start.AddDate(0, 1, -1).Day())
}

func comparisonDateRange(start time.Time, correspondingDay int) ComparisonDateRange {
	lastDay := start.AddDate(0, 1, -1).Day()
	if correspondingDay > lastDay {
		correspondingDay = lastDay
	}
	end := time.Date(start.Year(), start.Month(), correspondingDay, 0, 0, 0, 0, time.UTC)
	return ComparisonDateRange{Start: start.Format("2006-01-02"), End: end.Format("2006-01-02")}
}

func dayAfter(value string) (string, bool) {
	date, err := time.Parse("2006-01-02", value)
	if err != nil {
		return "", false
	}
	return date.AddDate(0, 0, 1).Format("2006-01-02"), true
}

func intPointer(value int) *int {
	return &value
}
