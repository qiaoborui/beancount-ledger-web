package app

import (
	"fmt"
	"strings"
	"time"
)

type HomeReportKPI struct {
	Income           int      `json:"income"`
	Expense          int      `json:"expense"`
	Net              int      `json:"net"`
	TransactionCount int      `json:"transactionCount"`
	SavingsRate      *float64 `json:"savingsRate"`
}

type HomeReportPeriod struct {
	KPIs           HomeReportKPI             `json:"kpis"`
	CashflowSeries []DashboardCashflowPoint  `json:"cashflowSeries"`
	CategorySeries []DashboardCategorySeries `json:"categorySeries"`
}

type HomeReportBudget struct {
	Configured bool   `json:"configured"`
	Amount     int    `json:"amount"`
	Currency   string `json:"currency"`
}

type HomeReport struct {
	Start                string                   `json:"start"`
	End                  string                   `json:"end"`
	PreviousStart        string                   `json:"previousStart"`
	PreviousEnd          string                   `json:"previousEnd"`
	Currency             string                   `json:"currency"`
	Current              HomeReportPeriod         `json:"current"`
	Previous             HomeReportPeriod         `json:"previous"`
	Budget               HomeReportBudget         `json:"budget"`
	DailyExpenseSeries   []DashboardDailyExpense  `json:"dailyExpenseSeries"`
	AccountBalanceSeries []DashboardAccountSeries `json:"accountBalanceSeries"`
	TopPaymentAccounts   []AccountAnalytics       `json:"topPaymentAccounts"`
	GeneratedAt          string                   `json:"generatedAt"`
}

func BuildHomeReportInCurrency(snapshot *LedgerSnapshot, start, end, valuationCurrency string) HomeReport {
	previousStart, previousEnd := previousYearRange(start, end)
	current := BuildDashboardSummaryWithFiltersInCurrency(snapshot, start, end, DashboardFilters{}, valuationCurrency)
	previous := BuildDashboardSummaryWithFiltersInCurrency(snapshot, previousStart, previousEnd, DashboardFilters{}, current.Currency)

	return HomeReport{
		Start:         start,
		End:           end,
		PreviousStart: previousStart,
		PreviousEnd:   previousEnd,
		Currency:      current.Currency,
		Current: HomeReportPeriod{
			KPIs:           homeReportKPIs(current.KPIs, transactionCountInRange(snapshot.Transactions, start, end)),
			CashflowSeries: current.CashflowSeries,
			CategorySeries: current.CategorySeries,
		},
		Previous: HomeReportPeriod{
			KPIs:           homeReportKPIs(previous.KPIs, transactionCountInRange(snapshot.Transactions, previousStart, previousEnd)),
			CashflowSeries: previous.CashflowSeries,
			CategorySeries: previous.CategorySeries,
		},
		Budget:               homeReportBudget(snapshot, start, end, current.Currency),
		DailyExpenseSeries:   current.DailyExpenseSeries,
		AccountBalanceSeries: current.AccountBalanceSeries,
		TopPaymentAccounts:   current.TopPaymentAccounts,
		GeneratedAt:          time.Now().Format(time.RFC3339),
	}
}

type homeBudgetDirective struct {
	Date     string
	Account  string
	Amount   int
	Currency string
}

func homeReportBudget(snapshot *LedgerSnapshot, start, end, valuationCurrency string) HomeReportBudget {
	directives := homeBudgetDirectives(snapshot.BeanEntries)
	priceIndex := snapshotPriceIndex(snapshot)
	total := 0
	configured := false
	for _, month := range homeReportMonths(start, end) {
		active := map[string]homeBudgetDirective{}
		for _, directive := range directives {
			if directive.Date > month {
				continue
			}
			current, ok := active[directive.Account]
			if !ok || directive.Date >= current.Date {
				active[directive.Account] = directive
			}
		}
		for _, directive := range active {
			value, ok := priceIndex.Valuation(directive.Amount, directive.Currency, valuationCurrency, month)
			if !ok {
				continue
			}
			configured = true
			total += value
		}
	}
	return HomeReportBudget{Configured: configured, Amount: total, Currency: valuationCurrency}
}

func homeBudgetDirectives(entries []BeanEntry) []homeBudgetDirective {
	directives := []homeBudgetDirective{}
	for _, entry := range entries {
		if entry.Kind != "custom" || entry.CustomType != "budget" || len(entry.CustomValues) < 3 {
			continue
		}
		account := strings.TrimSpace(fmt.Sprint(entry.CustomValues[0]))
		cadence := strings.TrimSpace(fmt.Sprint(entry.CustomValues[1]))
		amountParts := strings.Fields(fmt.Sprint(entry.CustomValues[2]))
		if !strings.HasPrefix(account, "Expenses:") || cadence != "monthly" || len(amountParts) != 2 {
			continue
		}
		directives = append(directives, homeBudgetDirective{Date: entry.Date, Account: account, Amount: cents(amountParts[0]), Currency: amountParts[1]})
	}
	return directives
}

func homeReportMonths(start, end string) []string {
	startDate, startErr := time.Parse("2006-01-02", start)
	endDate, endErr := time.Parse("2006-01-02", end)
	if startErr != nil || endErr != nil || !startDate.Before(endDate) {
		return nil
	}
	cursor := time.Date(startDate.Year(), startDate.Month(), 1, 0, 0, 0, 0, time.UTC)
	months := []string{}
	for cursor.Before(endDate) {
		months = append(months, cursor.Format("2006-01-02"))
		cursor = cursor.AddDate(0, 1, 0)
	}
	return months
}

func homeReportKPIs(kpis DashboardKPI, transactionCount int) HomeReportKPI {
	return HomeReportKPI{
		Income:           kpis.Income,
		Expense:          kpis.Expense,
		Net:              kpis.Net,
		TransactionCount: transactionCount,
		SavingsRate:      kpis.SavingsRate,
	}
}

func transactionCountInRange(transactions []Transaction, start, end string) int {
	count := 0
	for _, transaction := range transactions {
		if transaction.Date >= start && transaction.Date < end {
			count++
		}
	}
	return count
}

func previousYearRange(start, end string) (string, string) {
	return shiftDateYear(start, -1), shiftDateYear(end, -1)
}

func shiftDateYear(value string, years int) string {
	date, err := time.Parse("2006-01-02", value)
	if err != nil {
		return value
	}
	targetYear := date.Year() + years
	lastDay := time.Date(targetYear, date.Month()+1, 0, 0, 0, 0, 0, time.UTC).Day()
	day := date.Day()
	if day > lastDay {
		day = lastDay
	}
	return time.Date(targetYear, date.Month(), day, 0, 0, 0, 0, time.UTC).Format("2006-01-02")
}
