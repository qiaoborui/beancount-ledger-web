package app

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestAccountDetailReturnsFrontendContract(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodGet, "/api/ledger/accounts/detail?account=Assets%3ACash", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("account detail status=%d body=%s", res.Code, res.Body.String())
	}
	var body struct {
		Account        string             `json:"account"`
		Label          string             `json:"label"`
		Alias          string             `json:"alias"`
		Group          string             `json:"group"`
		Active         bool               `json:"active"`
		Currency       string             `json:"currency"`
		CurrentBalance int                `json:"currentBalance"`
		Rows           []AccountDetailRow `json:"rows"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Account != "Assets:Cash" || body.Label != "现金" || body.Alias != "现金" {
		t.Fatalf("account fields do not match frontend contract: %#v", body)
	}
	if body.Group != "cash" || !body.Active || body.Currency != "CNY" {
		t.Fatalf("unexpected account metadata: %#v", body)
	}
	if body.CurrentBalance != 98800 || len(body.Rows) != 2 {
		t.Fatalf("unexpected account detail rows or balance: %#v", body)
	}
}

func TestIncomeStatementReturnsCategoryTree(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodGet, "/api/ledger/income-statement?start=2026-05-01&end=2026-06-01", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("income statement status=%d body=%s", res.Code, res.Body.String())
	}
	var body struct {
		Income             []IncomeStatementNode      `json:"income"`
		Expense            []IncomeStatementNode      `json:"expense"`
		ExpenseAnalytics   []ExpenseCategoryAnalytics `json:"expenseAnalytics"`
		TopPaymentAccounts []AccountAnalytics         `json:"topPaymentAccounts"`
		TotalIncome        int                        `json:"totalIncome"`
		TotalExpense       int                        `json:"totalExpense"`
		NetIncome          int                        `json:"netIncome"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Income) != 1 || body.Income[0].Account != "Income:Salary" || body.Income[0].Amount != 100000 || body.Income[0].TxCount != 1 {
		t.Fatalf("income tree should include category detail, got %#v", body.Income)
	}
	if len(body.Expense) != 1 || body.Expense[0].Account != "Expenses:Food" || body.Expense[0].Amount != 1200 || body.Expense[0].TxCount != 1 {
		t.Fatalf("expense tree should include category detail, got %#v", body.Expense)
	}
	if len(body.ExpenseAnalytics) != 1 || body.ExpenseAnalytics[0].Account != "Expenses:Food" || body.ExpenseAnalytics[0].TxCount != 1 || len(body.ExpenseAnalytics[0].TopPayees) != 1 {
		t.Fatalf("expense analytics should include transaction counts and top payees, got %#v", body.ExpenseAnalytics)
	}
	if len(body.TopPaymentAccounts) != 1 || body.TopPaymentAccounts[0].Account != "Assets:Cash" || body.TopPaymentAccounts[0].Alias == nil || *body.TopPaymentAccounts[0].Alias != "现金" || body.TopPaymentAccounts[0].Label != "现金" {
		t.Fatalf("top payment accounts should include alias and label, got %#v", body.TopPaymentAccounts)
	}
	if body.TotalIncome != 100000 || body.TotalExpense != 1200 || body.NetIncome != 98800 {
		t.Fatalf("unexpected income statement totals: %#v", body)
	}
}

func TestInvestmentsReturnsCommodityPricesAndPositions(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "commodities.bean"), strings.Join([]string{
		"2026-01-01 commodity CNY",
		"2026-01-01 commodity USD",
		"2026-01-01 commodity QQQ",
		`  name: "Invesco QQQ Trust"`,
		"2026-01-01 commodity VOO",
		`  name: "Vanguard S&P 500 ETF"`,
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), strings.Join([]string{
		"2026-01-01 open Assets:Cash CNY",
		`  alias: "现金"`,
		"2026-01-01 open Assets:Broker:QQQ QQQ",
		`  alias: "券商 QQQ 持仓"`,
		"2026-01-01 open Assets:Broker:Taxable:QQQ QQQ",
		`  alias: "券商应税 QQQ 持仓"`,
		"2026-01-01 open Expenses:Food CNY",
		"2026-01-01 open Income:Salary CNY",
		"2026-01-01 open Equity:Opening-Balances CNY",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "prices.bean"), strings.Join([]string{
		"2026-05-31 price USD 7.0000 CNY",
		"2026-05-31 price QQQ 100.00 USD",
		"2026-06-01 price QQQ 110.00 USD",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean"), strings.Join([]string{
		`2026-05-01 * "Cafe" "Lunch" #work`,
		`  note: "noodles"`,
		"  Expenses:Food 12.00 CNY",
		"  Assets:Cash -12.00 CNY",
		"",
		`2026-05-31 * "Employer" "Salary"`,
		"  Assets:Cash 1000.00 CNY",
		"  Income:Salary -1000.00 CNY",
		"",
		`2026-05-31 * "Broker" "QQQ opening"`,
		"  Assets:Broker:QQQ 0.50 QQQ",
		"  Equity:Opening-Balances -0.50 QQQ",
		"",
		`2026-05-31 * "Broker" "QQQ taxable opening"`,
		"  Assets:Broker:Taxable:QQQ 0.25 QQQ",
		"  Equity:Opening-Balances -0.25 QQQ",
		"",
	}, "\n"))
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodGet, "/api/ledger/investments", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("investments status=%d body=%s", res.Code, res.Body.String())
	}
	var body InvestmentSummary
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.TotalMarketValueCNY != 57750 || body.UpdatedAt != "2026-06-01" {
		t.Fatalf("unexpected investment summary: %#v", body)
	}
	if len(body.Positions) != 2 {
		t.Fatalf("expected two positions, got %#v", body.Positions)
	}
	position := body.Positions[0]
	if position.Account != "Assets:Broker:QQQ" || position.AccountLabel != "券商 QQQ 持仓" || position.CommodityName != "Invesco QQQ Trust" {
		t.Fatalf("unexpected position identity: %#v", position)
	}
	if position.Quantity != 0.5 || position.LatestPrice == nil || position.LatestPrice.Amount != 110 || position.LatestPrice.Currency != "USD" {
		t.Fatalf("unexpected position pricing: %#v", position)
	}
	if position.MarketValueCNY == nil || *position.MarketValueCNY != 38500 {
		t.Fatalf("unexpected CNY value: %#v", position)
	}
	qqqQuote := InvestmentQuote{}
	for _, quote := range body.Quotes {
		if quote.Commodity == "QQQ" {
			qqqQuote = quote
		}
	}
	if qqqQuote.Commodity != "QQQ" || qqqQuote.PositionCount != 2 {
		t.Fatalf("unexpected quotes: %#v", body.Quotes)
	}
	if len(body.Holdings) != 2 {
		t.Fatalf("expected two holdings, got %#v", body.Holdings)
	}
	holding := body.Holdings[0]
	if holding.Commodity != "QQQ" || holding.CommodityName != "Invesco QQQ Trust" || holding.AccountCount != 2 {
		t.Fatalf("unexpected holding identity: %#v", holding)
	}
	if holding.TotalQuantity != 0.75 || holding.LatestPrice == nil || holding.LatestPrice.Amount != 110 || holding.LatestPrice.Currency != "USD" {
		t.Fatalf("unexpected holding pricing: %#v", holding)
	}
	if holding.TotalMarketValueCNY == nil || *holding.TotalMarketValueCNY != 57750 {
		t.Fatalf("unexpected holding CNY value: %#v", holding)
	}
	if len(holding.Positions) != 2 || holding.Positions[1].Account != "Assets:Broker:Taxable:QQQ" {
		t.Fatalf("unexpected holding positions: %#v", holding.Positions)
	}
	if len(holding.PriceHistory) != 2 || holding.PriceHistory[0].Date != "2026-05-31" || holding.PriceHistory[1].Date != "2026-06-01" {
		t.Fatalf("unexpected holding price history: %#v", holding.PriceHistory)
	}
	if body.Holdings[1].Commodity != "VOO" || body.Holdings[1].PriceHistory == nil || len(body.Holdings[1].PriceHistory) != 0 {
		t.Fatalf("unpriced holding should keep an empty price history array: %#v", body.Holdings[1])
	}
	var raw map[string]any
	if err := json.Unmarshal(res.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	rawHoldings, ok := raw["holdings"].([]any)
	if !ok || len(rawHoldings) != 2 {
		t.Fatalf("unexpected raw holdings: %#v", raw["holdings"])
	}
	rawUnpriced, ok := rawHoldings[1].(map[string]any)
	if !ok {
		t.Fatalf("unexpected raw holding shape: %#v", rawHoldings[1])
	}
	if _, ok := rawUnpriced["priceHistory"].([]any); !ok {
		t.Fatalf("unpriced holding priceHistory should encode as an array, got %#v", rawUnpriced["priceHistory"])
	}
}

func TestDashboardReturnsAggregatedReadOnlySeries(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2026-05-01&end=2026-06-01", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	var body DashboardSummary
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.KPIs.Income != 100000 || body.KPIs.Expense != 1200 || body.KPIs.Net != 98800 || body.KPIs.NetWorth != 98800 {
		t.Fatalf("unexpected dashboard kpis: %#v", body.KPIs)
	}
	wantMonthLabels := []string{"05-01", "05-02", "05-03", "05-04", "05-05", "05-06", "05-07", "05-08", "05-09", "05-10", "05-11", "05-12", "05-13", "05-14", "05-15", "05-16", "05-17", "05-18", "05-19", "05-20", "05-21", "05-22", "05-23", "05-24", "05-25", "05-26", "05-27", "05-28", "05-29", "05-30", "05-31"}
	gotMonthLabels := make([]string, 0, len(body.CashflowSeries))
	for _, point := range body.CashflowSeries {
		gotMonthLabels = append(gotMonthLabels, point.Month)
	}
	if !reflect.DeepEqual(gotMonthLabels, wantMonthLabels) || body.CashflowSeries[0].Net != -1200 || body.CashflowSeries[30].Net != 100000 {
		t.Fatalf("unexpected cashflow series: %#v", body.CashflowSeries)
	}
	if len(body.CategorySeries) != 1 || body.CategorySeries[0].Account != "Expenses:Food" || body.CategorySeries[0].Total != 1200 || len(body.CategorySeries[0].Values) != 31 || body.CategorySeries[0].Values[0].Value != 1200 {
		t.Fatalf("unexpected category series: %#v", body.CategorySeries)
	}
	if len(body.AccountBalanceSeries) != 1 || body.AccountBalanceSeries[0].Account != "Assets:Cash" || body.AccountBalanceSeries[0].Alias == nil || *body.AccountBalanceSeries[0].Alias != "现金" || body.AccountBalanceSeries[0].Label != "现金" || len(body.AccountBalanceSeries[0].Values) != 31 || body.AccountBalanceSeries[0].Values[0].Value != -1200 || body.AccountBalanceSeries[0].Values[30].Value != 98800 {
		t.Fatalf("unexpected account balance series: %#v", body.AccountBalanceSeries)
	}
	if len(body.NetWorthSeries) != 31 || body.NetWorthSeries[0].Date != "05-01" || body.NetWorthSeries[0].NetWorth != -1200 || body.NetWorthSeries[30].NetWorth != 98800 {
		t.Fatalf("unexpected net worth series: %#v", body.NetWorthSeries)
	}
	if len(body.BudgetPressure) != 1 || body.BudgetPressure[0].Remaining != 98800 {
		t.Fatalf("unexpected budget pressure: %#v", body.BudgetPressure)
	}
	if len(body.Anomalies) != 1 || body.Anomalies[0].Amount != 1200 || body.Anomalies[0].Account != "Expenses:Food" {
		t.Fatalf("unexpected anomalies: %#v", body.Anomalies)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2026-05-01&end=2026-05-08", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("weekly dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	wantDayLabels := []string{"05-01", "05-02", "05-03", "05-04", "05-05", "05-06", "05-07"}
	gotDayLabels := make([]string, 0, len(body.CashflowSeries))
	for _, point := range body.CashflowSeries {
		gotDayLabels = append(gotDayLabels, point.Month)
	}
	if !reflect.DeepEqual(gotDayLabels, wantDayLabels) || body.CashflowSeries[0].Expense != 1200 || body.CashflowSeries[0].Net != -1200 {
		t.Fatalf("unexpected daily cashflow series: %#v", body.CashflowSeries)
	}
	if len(body.CategorySeries) != 1 || len(body.CategorySeries[0].Values) != 7 || body.CategorySeries[0].Values[0].Month != "05-01" || body.CategorySeries[0].Values[0].Value != 1200 {
		t.Fatalf("unexpected daily category series: %#v", body.CategorySeries)
	}
	if len(body.AccountBalanceSeries) != 1 || len(body.AccountBalanceSeries[0].Values) != 7 || body.AccountBalanceSeries[0].Values[0].Month != "05-01" || body.AccountBalanceSeries[0].Values[0].Value != -1200 {
		t.Fatalf("unexpected daily account balance series: %#v", body.AccountBalanceSeries)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2026-05-01&end=2026-08-01", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("quarter dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.CashflowSeries) != 14 || body.CashflowSeries[0].Month != "05-01~05-07" || body.CashflowSeries[13].Month != "07-31~07-31" {
		t.Fatalf("unexpected weekly dashboard buckets: %#v", body.CashflowSeries)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2026-05-01&end=2026-06-01&type=expense,income&category=Expenses%3AFood&payee=Cafe&tag=work&minAmount=10&maxAmount=20", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("filtered dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(body.Filters.Types, []string{"expense", "income"}) || !reflect.DeepEqual(body.Filters.Categories, []string{"Expenses:Food"}) || !reflect.DeepEqual(body.Filters.Payees, []string{"Cafe"}) || !reflect.DeepEqual(body.Filters.Tags, []string{"work"}) || body.Filters.MinAmount == nil || *body.Filters.MinAmount != 1000 || body.Filters.MaxAmount == nil || *body.Filters.MaxAmount != 2000 {
		t.Fatalf("unexpected filters echo: %#v", body.Filters)
	}
	if body.KPIs.Income != 0 || body.KPIs.Expense != 1200 || body.KPIs.Net != -1200 || len(body.Anomalies) != 1 {
		t.Fatalf("unexpected filtered dashboard data: %#v", body)
	}
	if len(body.FilterOptions.Categories) == 0 || body.FilterOptions.Categories[0].Value != "Expenses:Food" || len(body.FilterOptions.Accounts) == 0 || body.FilterOptions.Accounts[0].Value != "Assets:Cash" || body.FilterOptions.Accounts[0].Alias == nil || *body.FilterOptions.Accounts[0].Alias != "现金" {
		t.Fatalf("expected unfiltered category/account options with aliases, got categories=%#v accounts=%#v", body.FilterOptions.Categories, body.FilterOptions.Accounts)
	}
	if len(body.Annotations) == 0 || body.Annotations[0].Kind != "tag" || !strings.Contains(body.Annotations[0].Drilldown, "%23work") {
		t.Fatalf("expected dashboard annotation drilldown, got %#v", body.Annotations)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2026-05-01&end=2026-06-01&type=income&payee=Employer", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("income filtered dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.KPIs.Income != 100000 || body.KPIs.Expense != 0 || body.KPIs.Net != 100000 || len(body.CategorySeries) != 0 {
		t.Fatalf("unexpected income filtered dashboard data: %#v", body)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2000-01-01&end=2099-12-31", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("all-time dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	gotAllLabels := make([]string, 0, len(body.CashflowSeries))
	for _, point := range body.CashflowSeries {
		gotAllLabels = append(gotAllLabels, point.Month)
	}
	wantAllLabels := make([]string, 0, len(wantMonthLabels))
	for _, label := range wantMonthLabels {
		wantAllLabels = append(wantAllLabels, "2026-"+label)
	}
	if body.Start != "2000-01-01" || body.End != "2099-12-31" {
		t.Fatalf("all-time dashboard should preserve requested range, got start=%s end=%s", body.Start, body.End)
	}
	if !reflect.DeepEqual(gotAllLabels, wantAllLabels) || len(body.NetWorthSeries) != 31 || body.NetWorthSeries[0].Date != "2026-05-01" || body.KPIs.Income != 100000 || body.KPIs.Expense != 1200 {
		t.Fatalf("all-time dashboard should trim chart buckets to ledger activity, got cashflow=%#v netWorth=%#v kpis=%#v", body.CashflowSeries, body.NetWorthSeries, body.KPIs)
	}
	if len(body.CategorySeries) != 1 || len(body.CategorySeries[0].Values) != 31 || body.CategorySeries[0].Values[0].Month != "2026-05-01" {
		t.Fatalf("all-time dashboard should trim category trend buckets to ledger activity, got %#v", body.CategorySeries)
	}
	if len(body.AccountBalanceSeries) != 1 || len(body.AccountBalanceSeries[0].Values) != 31 || body.AccountBalanceSeries[0].Values[0].Month != "2026-05-01" {
		t.Fatalf("all-time dashboard should trim account trend buckets to ledger activity, got %#v", body.AccountBalanceSeries)
	}
}

func TestTransactionEditDeleteReverseAndReconcile(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	updateBody := `{"source":{"file":"` + filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean") + `","line":1},"entry":{"kind":"transaction","date":"2026-05-01","payee":"Cafe","narration":"Dinner","metadata":{},"tags":[],"postings":[{"account":"Expenses:Food","amount":"20.00","currency":"CNY"},{"account":"Assets:Cash","amount":"-20.00","currency":"CNY"}],"confidence":1,"needsReview":false,"questions":[]}}`
	res := requestWithCookies(router, http.MethodPut, "/api/ledger/transactions", updateBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("update status=%d body=%s", res.Code, res.Body.String())
	}
	text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")))
	if !strings.Contains(text, `"Dinner"`) || strings.Contains(text, `"Lunch"`) {
		t.Fatalf("transaction was not replaced:\n%s", text)
	}

	salaryHash := transactionHash([]string{`2026-05-31 * "Employer" "Salary"`, "  Assets:Cash 1000.00 CNY", "  Income:Salary -1000.00 CNY"})
	deleteBody := `{"source":{"file":"` + filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean") + `","line":99,"hash":"` + salaryHash + `"},"reason":"duplicate"}`
	res = requestWithCookies(router, http.MethodDelete, "/api/ledger/transactions", deleteBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("delete status=%d body=%s", res.Code, res.Body.String())
	}
	text = string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")))
	if !strings.Contains(text, "; deleted") || !strings.Contains(text, "; 2026-05-31") {
		t.Fatalf("transaction was not commented:\n%s", text)
	}

	reverseBody := `{"source":{"file":"` + filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean") + `","line":1},"date":"2026-05-02"}`
	res = requestWithCookies(router, http.MethodPost, "/api/ledger/transactions", reverseBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("reverse status=%d body=%s", res.Code, res.Body.String())
	}
	text = string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")))
	if !strings.Contains(text, "冲销：Dinner") {
		t.Fatalf("reversal was not appended:\n%s", text)
	}

	reconcileBody := `{"account":"Assets:Cash","actualAmount":"980.00","balanceDate":"2026-05-31"}`
	res = requestWithCookies(router, http.MethodPost, "/api/ledger/reconciliation", reconcileBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("reconcile status=%d body=%s", res.Code, res.Body.String())
	}
	text = string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")))
	if !strings.Contains(text, "balance Assets:Cash 980.00 CNY") {
		t.Fatalf("balance assertion was not appended:\n%s", text)
	}
}

func TestGitStatusAndCommitTrackLedgerWrites(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	t.Setenv("APP_PASSWORD", "secret")
	t.Setenv("LEDGER_GIT_REMOTE_DISABLED", "true")
	runGit(t, cfg, "init")
	runGit(t, cfg, "config", "user.email", "ledger@example.test")
	runGit(t, cfg, "config", "user.name", "Ledger Test")
	runGit(t, cfg, "add", ".")
	runGit(t, cfg, "commit", "-m", "initial ledger")
	t.Setenv("GIT_TEST_ASSUME_DIFFERENT_OWNER", "true")

	router := NewRouter(cfg)
	cookies := loginCookies(t, router)
	appendBody := `{"kind":"transaction","date":"2026-06-02","payee":"Bakery","narration":"Breakfast","metadata":{},"tags":[],"postings":[{"account":"Expenses:Food","amount":"15.00","currency":"CNY"},{"account":"Assets:Cash","amount":"-15.00","currency":"CNY"}],"confidence":1,"needsReview":false,"questions":[]}`
	res := requestWithCookies(router, http.MethodPost, "/api/ledger/append", appendBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("append status=%d body=%s", res.Code, res.Body.String())
	}

	res = requestWithCookies(router, http.MethodGet, "/api/git/status", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("git status=%d body=%s", res.Code, res.Body.String())
	}
	var statusBody struct {
		Dirty            bool        `json:"dirty"`
		ChangedFileCount int         `json:"changedFileCount"`
		Changes          []GitChange `json:"changes"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &statusBody); err != nil {
		t.Fatal(err)
	}
	if !statusBody.Dirty || statusBody.ChangedFileCount != 2 || !hasGitChange(statusBody.Changes, "main.bean") || !hasGitChange(statusBody.Changes, "transactions/2026/06.bean") {
		t.Fatalf("git status should include main include and new monthly file: %#v", statusBody)
	}

	res = requestWithCookies(router, http.MethodPost, "/api/git/commit", `{"message":"test: save ledger"}`, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("git commit=%d body=%s", res.Code, res.Body.String())
	}
	var commitBody struct {
		ChangedFileCount          int    `json:"changedFileCount"`
		RemainingChangedFileCount int    `json:"remainingChangedFileCount"`
		Output                    string `json:"output"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &commitBody); err != nil {
		t.Fatal(err)
	}
	if commitBody.ChangedFileCount != 2 || commitBody.RemainingChangedFileCount != 0 || !strings.Contains(commitBody.Output, "Git remote sync disabled") {
		t.Fatalf("unexpected git commit response: %#v", commitBody)
	}
	if status := runGit(t, cfg, "status", "--short", "--", "main.bean", "transactions"); strings.TrimSpace(status) != "" {
		t.Fatalf("ledger files should be clean after commit:\n%s", status)
	}
	lastCommitFiles := runGit(t, cfg, "show", "--name-only", "--pretty=format:", "HEAD")
	if !strings.Contains(lastCommitFiles, "main.bean") || !strings.Contains(lastCommitFiles, "transactions/2026/06.bean") {
		t.Fatalf("commit should include ledger write files:\n%s", lastCommitFiles)
	}
}

func TestAppendEntryPublishesAppendEntrySource(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	t.Setenv("APP_PASSWORD", "secret")

	router := NewRouter(cfg)
	cookies := loginCookies(t, router)
	sub := ledgerEventHub.Subscribe()
	defer sub.Close()
	appendBody := `{"kind":"transaction","date":"2026-06-02","payee":"Bakery","narration":"Breakfast","metadata":{},"tags":[],"postings":[{"account":"Expenses:Food","amount":"15.00","currency":"CNY"},{"account":"Assets:Cash","amount":"-15.00","currency":"CNY"}],"confidence":1,"needsReview":false,"questions":[]}`
	res := requestWithCookies(router, http.MethodPost, "/api/ledger/append", appendBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("append status=%d body=%s", res.Code, res.Body.String())
	}

	select {
	case event := <-sub.ch:
		if event.Type != "ledger.updated" {
			t.Fatalf("event type = %s, want ledger.updated", event.Type)
		}
		data, ok := event.Data.(gin.H)
		if !ok {
			t.Fatalf("event data has unexpected type: %#v", event.Data)
		}
		if data["source"] != ledgerWriteSourceAppendEntry {
			t.Fatalf("source = %#v, want %s", data["source"], ledgerWriteSourceAppendEntry)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for ledger.updated event")
	}
}

func TestLedgerGitCommitUsesEnvAuthor(t *testing.T) {
	cfg := testLedger(t)
	isolateGitIdentity(t)
	t.Setenv("LEDGER_GIT_REMOTE_DISABLED", "true")
	t.Setenv("LEDGER_GIT_AUTHOR_NAME", "Ledger Bot")
	t.Setenv("LEDGER_GIT_AUTHOR_EMAIL", "ledger-bot@example.test")
	runGit(t, cfg, "init")

	output, err := ledgerGitCommitPullPush(cfg, "test: save ledger")
	if err != nil {
		t.Fatalf("ledger git commit failed: %v\n%s", err, output)
	}
	identity := strings.TrimSpace(runGit(t, cfg, "log", "-1", "--format=%an <%ae>"))
	if identity != "Ledger Bot <ledger-bot@example.test>" {
		t.Fatalf("commit should use env author, got %q", identity)
	}
}

func TestLedgerGitCommitExplainsMissingAuthor(t *testing.T) {
	cfg := testLedger(t)
	isolateGitIdentity(t)
	t.Setenv("LEDGER_GIT_REMOTE_DISABLED", "true")
	runGit(t, cfg, "init")

	_, err := ledgerGitCommitPullPush(cfg, "test: save ledger")
	if err == nil {
		t.Fatal("ledger git commit should fail without an author identity")
	}
	message := err.Error()
	if !strings.Contains(message, "Git 提交缺少作者身份") || !strings.Contains(message, "LEDGER_GIT_AUTHOR_NAME") || !strings.Contains(message, cfg.LedgerRoot) {
		t.Fatalf("missing-author error should be actionable, got:\n%s", message)
	}
}
