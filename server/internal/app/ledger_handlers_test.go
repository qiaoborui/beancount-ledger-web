package app

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
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
		Income           []IncomeStatementNode      `json:"income"`
		Expense          []IncomeStatementNode      `json:"expense"`
		ExpenseAnalytics []ExpenseCategoryAnalytics `json:"expenseAnalytics"`
		TotalIncome      int                        `json:"totalIncome"`
		TotalExpense     int                        `json:"totalExpense"`
		NetIncome        int                        `json:"netIncome"`
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
	if body.TotalIncome != 100000 || body.TotalExpense != 1200 || body.NetIncome != 98800 {
		t.Fatalf("unexpected income statement totals: %#v", body)
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
	if len(body.AccountBalanceSeries) != 1 || body.AccountBalanceSeries[0].Account != "Assets:Cash" || len(body.AccountBalanceSeries[0].Values) != 31 || body.AccountBalanceSeries[0].Values[0].Value != -1200 || body.AccountBalanceSeries[0].Values[30].Value != 98800 {
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
