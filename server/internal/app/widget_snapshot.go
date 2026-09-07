package app

import (
	"fmt"
	"math"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

const widgetSnapshotSchemaVersion = 2
const widgetSnapshotMaxRequestBodyLength = 8 << 10

type WidgetSnapshotRequest struct {
	DeviceID          string `json:"deviceId"`
	Token             string `json:"token"`
	Today             string `json:"today"`
	ValuationCurrency string `json:"valuationCurrency"`
}

func (r WidgetSnapshotRequest) Validate() error {
	if err := (QuickUnlockVerifyRequest{DeviceID: r.DeviceID, Token: r.Token}).Validate(); err != nil {
		return err
	}
	if _, err := time.Parse("2006-01-02", r.Today); err != nil {
		return fmt.Errorf("today is invalid")
	}
	if r.ValuationCurrency != "" && !currencyPattern.MatchString(r.ValuationCurrency) {
		return fmt.Errorf("valuationCurrency is invalid")
	}
	return nil
}

type WidgetSnapshotResponse struct {
	SchemaVersion    int                     `json:"schemaVersion"`
	UpdatedAt        string                  `json:"updatedAt"`
	Expense          WidgetExpenseSnapshot   `json:"expense"`
	Accounts         []WidgetAccountSnapshot `json:"accounts"`
	Imports          *[]WidgetImportSnapshot `json:"imports"`
	ImportsUpdatedAt *string                 `json:"importsUpdatedAt"`
	Insights         *WidgetExpenseInsights  `json:"insights,omitempty"`
}

type WidgetExpenseInsights struct {
	UpdatedAt string                `json:"updatedAt"`
	Week      WidgetExpenseSnapshot `json:"week"`
	Year      WidgetExpenseSnapshot `json:"year"`
	History   WidgetExpenseSnapshot `json:"history"`
}

type WidgetExpenseSnapshot struct {
	PeriodTitle            string                  `json:"periodTitle"`
	Start                  string                  `json:"start"`
	End                    string                  `json:"end"`
	Currency               string                  `json:"currency"`
	Amount                 int                     `json:"amount"`
	TransactionCount       int                     `json:"transactionCount"`
	YearOverYearPercentage *float64                `json:"yearOverYearPercentage"`
	Categories             []WidgetExpenseCategory `json:"categories"`
	DailySeries            []WidgetDailyExpense    `json:"dailySeries"`
}

type WidgetExpenseCategory struct {
	Account string `json:"account"`
	Label   string `json:"label"`
	Amount  int    `json:"amount"`
}

type WidgetDailyExpense struct {
	Date   string `json:"date"`
	Amount int    `json:"amount"`
}

type WidgetAccountSnapshot struct {
	Account           string `json:"account"`
	Label             string `json:"label"`
	Group             string `json:"group"`
	Currency          string `json:"currency"`
	Balance           int    `json:"balance"`
	ValuationCurrency string `json:"valuationCurrency"`
	Valuation         *int   `json:"valuation"`
}

type WidgetImportSnapshot struct {
	Provider      string `json:"provider"`
	Label         string `json:"label"`
	CoverageStart string `json:"coverageStart,omitempty"`
	CoverageEnd   string `json:"coverageEnd,omitempty"`
}

func (s *Server) widgetSnapshot(c *gin.Context) {
	if !s.limiter.Check(c, "widget.snapshot", 120, time.Hour) {
		return
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, widgetSnapshotMaxRequestBodyLength)
	var input WidgetSnapshotRequest
	if !bindJSON(c, &input) {
		return
	}
	if err := s.verifyQuickUnlockDevice(input.DeviceID, input.Token, quickUnlockModeWidget); err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Widget access failed"})
		return
	}
	start, end, err := widgetMonthRange(input.Today, time.Now())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	snapshot, err := s.ledgerSnapshot(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	report := BuildHomeReportInCurrency(snapshot, start, end, input.ValuationCurrency)

	var importSnapshots *[]WidgetImportSnapshot
	var importsUpdatedAt *string
	if documents, documentsErr := s.listImportDocuments(c.Request.Context()); documentsErr == nil {
		values := buildWidgetImportSnapshots(documents)
		importSnapshots = &values
		updatedAt := time.Now().UTC().Format(time.RFC3339)
		importsUpdatedAt = &updatedAt
	} else {
		s.loggerOr().Warn("refresh widget import status", "error", documentsErr)
	}

	response := buildWidgetSnapshotResponse(snapshot, report, importSnapshots, importsUpdatedAt)
	response.Insights = buildWidgetExpenseInsights(snapshot, input.Today, input.ValuationCurrency, report.GeneratedAt)
	c.JSON(http.StatusOK, response)
}

func buildWidgetExpenseInsights(snapshot *LedgerSnapshot, today, currency, updatedAt string) *WidgetExpenseInsights {
	date, _ := time.Parse("2006-01-02", today) // validated by widgetMonthRange
	week := date.AddDate(0, 0, -(int(date.Weekday())+6)%7)
	year := time.Date(date.Year(), 1, 1, 0, 0, 0, 0, time.UTC)
	build := func(start, end time.Time) WidgetExpenseSnapshot {
		report := BuildHomeReportInCurrency(snapshot, start.Format("2006-01-02"), end.Format("2006-01-02"), currency)
		return buildWidgetExpenseSnapshot(report)
	}
	return &WidgetExpenseInsights{
		UpdatedAt: updatedAt,
		Week:      build(week, week.AddDate(0, 0, 7)),
		Year:      build(year, year.AddDate(1, 0, 0)),
		History:   build(week.AddDate(0, 0, -77), date.AddDate(0, 0, 1)),
	}
}

func widgetMonthRange(today string, now time.Time) (string, string, error) {
	date, err := time.Parse("2006-01-02", today)
	if err != nil {
		return "", "", fmt.Errorf("today is invalid")
	}
	serverDate := time.Date(now.UTC().Year(), now.UTC().Month(), now.UTC().Day(), 0, 0, 0, 0, time.UTC)
	if math.Abs(date.Sub(serverDate).Hours()) > 72 {
		return "", "", fmt.Errorf("today is outside the allowed clock window")
	}
	start := time.Date(date.Year(), date.Month(), 1, 0, 0, 0, 0, time.UTC)
	return start.Format("2006-01-02"), start.AddDate(0, 1, 0).Format("2006-01-02"), nil
}

func buildWidgetSnapshotResponse(snapshot *LedgerSnapshot, report HomeReport, imports *[]WidgetImportSnapshot, importsUpdatedAt *string) WidgetSnapshotResponse {
	return WidgetSnapshotResponse{
		SchemaVersion:    widgetSnapshotSchemaVersion,
		UpdatedAt:        report.GeneratedAt,
		Expense:          buildWidgetExpenseSnapshot(report),
		Accounts:         buildWidgetAccountSnapshots(snapshot, report.Start, report.End, report.Currency),
		Imports:          imports,
		ImportsUpdatedAt: importsUpdatedAt,
	}
}

func buildWidgetExpenseSnapshot(report HomeReport) WidgetExpenseSnapshot {
	categories := append([]DashboardCategorySeries(nil), report.Current.CategorySeries...)
	sort.Slice(categories, func(i, j int) bool { return categories[i].Total > categories[j].Total })
	categorySnapshots := make([]WidgetExpenseCategory, 0, 3)
	for _, category := range categories {
		if category.Total <= 0 {
			continue
		}
		categorySnapshots = append(categorySnapshots, WidgetExpenseCategory{
			Account: category.Account,
			Label:   category.Label,
			Amount:  category.Total,
		})
		if len(categorySnapshots) == 3 {
			break
		}
	}
	daily := make([]WidgetDailyExpense, 0, len(report.DailyExpenseSeries))
	for _, point := range report.DailyExpenseSeries {
		daily = append(daily, WidgetDailyExpense{Date: point.Date, Amount: point.Amount})
	}

	month, _ := time.Parse("2006-01-02", report.Start)
	return WidgetExpenseSnapshot{
		PeriodTitle:            fmt.Sprintf("%d年%d月", month.Year(), int(month.Month())),
		Start:                  report.Start,
		End:                    report.End,
		Currency:               report.Currency,
		Amount:                 report.Current.KPIs.Expense,
		TransactionCount:       report.Current.KPIs.TransactionCount,
		YearOverYearPercentage: widgetPercentageChange(report.Current.KPIs.Expense, report.Previous.KPIs.Expense),
		Categories:             categorySnapshots,
		DailySeries:            daily,
	}
}

func buildWidgetAccountSnapshots(snapshot *LedgerSnapshot, start, end, valuationCurrency string) []WidgetAccountSnapshot {
	accounts := make(map[string]Account, len(snapshot.Accounts))
	for _, account := range snapshot.Accounts {
		accounts[account.Account] = account
	}
	result := []WidgetAccountSnapshot{}
	for _, balance := range snapshotAccountBalancesForRange(snapshot, start, end, valuationCurrency) {
		if !strings.HasPrefix(balance.Account, "Assets:") && !strings.HasPrefix(balance.Account, "Liabilities:") {
			continue
		}
		account, ok := accounts[balance.Account]
		if !ok || !account.Active {
			continue
		}
		var valuation *int
		if !balance.ValuationMissing {
			value := balance.Valuation
			valuation = &value
		}
		result = append(result, WidgetAccountSnapshot{
			Account:           balance.Account,
			Label:             widgetAccountLabel(account),
			Group:             account.Group,
			Currency:          balance.Currency,
			Balance:           balance.Amount,
			ValuationCurrency: balance.ValuationCurrency,
			Valuation:         valuation,
		})
	}
	sort.Slice(result, func(i, j int) bool {
		leftLiability := strings.HasPrefix(result[i].Account, "Liabilities:")
		rightLiability := strings.HasPrefix(result[j].Account, "Liabilities:")
		if leftLiability != rightLiability {
			return !leftLiability
		}
		return result[i].Label < result[j].Label
	})
	return result
}

func widgetAccountLabel(account Account) string {
	if account.Alias != nil {
		if alias := strings.TrimSpace(*account.Alias); alias != "" {
			return strings.Split(alias, "/")[0]
		}
	}
	if account.Label != "" {
		return account.Label
	}
	parts := strings.Split(account.Account, ":")
	return parts[len(parts)-1]
}

func buildWidgetImportSnapshots(documents []ImportDocument) []WidgetImportSnapshot {
	latest := map[string]ImportDocument{}
	for _, document := range documents {
		_, ok := importProvider(document.Provider)
		if !ok {
			continue
		}
		current, exists := latest[document.Provider]
		if exists && !widgetImportDocumentIsLater(document, current) {
			continue
		}
		latest[document.Provider] = document
	}
	result := []WidgetImportSnapshot{}
	for _, providerID := range importProviderIDs() {
		document, ok := latest[providerID]
		if !ok {
			continue
		}
		provider, _ := importProvider(providerID)
		result = append(result, WidgetImportSnapshot{
			Provider:      providerID,
			Label:         provider.ProviderLabel(),
			CoverageStart: document.DateStart,
			CoverageEnd:   document.DateEnd,
		})
	}
	return result
}

func widgetImportDocumentIsLater(candidate, current ImportDocument) bool {
	candidateCoverage := candidate.DateEnd
	if candidateCoverage == "" {
		candidateCoverage = candidate.DateStart
	}
	currentCoverage := current.DateEnd
	if currentCoverage == "" {
		currentCoverage = current.DateStart
	}
	if candidateCoverage != currentCoverage {
		return candidateCoverage > currentCoverage
	}
	return candidate.ModTime > current.ModTime
}

func widgetPercentageChange(current, baseline int) *float64 {
	if baseline == 0 {
		return nil
	}
	value := (float64(current) - float64(baseline)) / math.Abs(float64(baseline))
	return &value
}
