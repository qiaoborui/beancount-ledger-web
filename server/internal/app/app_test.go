package app

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func testLedger(t *testing.T) Config {
	t.Helper()
	root := t.TempDir()
	mustWrite(t, filepath.Join(root, "commodities.bean"), "2026-01-01 commodity CNY\n")
	mustWrite(t, filepath.Join(root, "accounts.bean"), strings.Join([]string{
		"2026-01-01 open Assets:Cash CNY",
		`  alias: "现金"`,
		"2026-01-01 open Expenses:Food CNY",
		"2026-01-01 open Income:Salary CNY",
		"2026-01-01 open Equity:Opening-Balances CNY",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(root, "budgets.bean"), `2026-01-01 custom "budget" Expenses:Food "monthly" 1000.00 CNY`+"\n")
	mustWrite(t, filepath.Join(root, "prices.bean"), "")
	mustWrite(t, filepath.Join(root, "transactions", "2026", "05.bean"), strings.Join([]string{
		`2026-05-01 * "Cafe" "Lunch" #work`,
		`  note: "noodles"`,
		"  Expenses:Food 12.00 CNY",
		"  Assets:Cash -12.00 CNY",
		"",
		`2026-05-31 * "Employer" "Salary"`,
		"  Assets:Cash 1000.00 CNY",
		"  Income:Salary -1000.00 CNY",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(root, "main.bean"), strings.Join([]string{
		`option "title" "Test Ledger"`,
		`option "operating_currency" "CNY"`,
		`include "commodities.bean"`,
		`include "accounts.bean"`,
		`include "budgets.bean"`,
		`include "prices.bean"`,
		`include "transactions/2026/05.bean"`,
		"",
	}, "\n"))
	return Config{AppRoot: root, LedgerRoot: root, RuntimeDir: filepath.Join(root, ".runtime"), StaticDir: filepath.Join(root, "dist"), Port: "0"}
}

func mustWrite(t *testing.T, file string, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLedgerParserAndCache(t *testing.T) {
	cfg := testLedger(t)
	cache := NewLedgerCache(cfg)
	snapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Transactions) != 2 {
		t.Fatalf("transactions = %d, want 2", len(snapshot.Transactions))
	}
	if snapshot.Balances["Assets:Cash"] != 98800 {
		t.Fatalf("cash balance = %d, want 98800", snapshot.Balances["Assets:Cash"])
	}
	if snapshot.Accounts[0].Account != "Assets:Cash" || snapshot.Accounts[0].Label != "现金" {
		t.Fatalf("account alias not parsed: %#v", snapshot.Accounts[0])
	}
	second, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if second != snapshot {
		t.Fatal("snapshot was not reused")
	}
}

func TestWriterRollsBackOnBeanCheckFailure(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 1\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	cache := NewLedgerCache(cfg)
	writer := NewLedgerWriter(cfg, cache)
	mainBefore, err := os.ReadFile(mainBeanPath(cfg))
	if err != nil {
		t.Fatal(err)
	}
	err = writer.AppendBeanText("2026-06-01", `2026-06-01 * "Shop" "Snack"`+"\n  Expenses:Food 8.00 CNY\n  Assets:Cash -8.00 CNY\n")
	if err == nil {
		t.Fatal("expected bean-check failure")
	}
	mainAfter, err := os.ReadFile(mainBeanPath(cfg))
	if err != nil {
		t.Fatal(err)
	}
	if string(mainAfter) != string(mainBefore) {
		t.Fatal("main.bean was not rolled back")
	}
	if _, err := os.Stat(filepath.Join(cfg.LedgerRoot, "transactions", "2026", "06.bean")); !os.IsNotExist(err) {
		t.Fatalf("new monthly file should have been removed, err=%v", err)
	}
}

func TestRouterAuthAndSummary(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)

	unauth := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/ledger/summary?start=2026-05-01&end=2026-06-01", nil)
	router.ServeHTTP(unauth, req)
	if unauth.Code != http.StatusUnauthorized {
		t.Fatalf("unauth status = %d, want 401", unauth.Code)
	}

	login := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/api/auth/login", bytes.NewBufferString(`{"password":"secret"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(login, req)
	if login.Code != http.StatusOK {
		t.Fatalf("login status = %d body=%s", login.Code, login.Body.String())
	}

	summary := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/api/ledger/summary?start=2026-05-01&end=2026-06-01", nil)
	for _, cookie := range login.Result().Cookies() {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(summary, req)
	if summary.Code != http.StatusOK {
		t.Fatalf("summary status = %d body=%s", summary.Code, summary.Body.String())
	}
	var body struct {
		Summary struct {
			Income  int `json:"income"`
			Expense int `json:"expense"`
		} `json:"summary"`
		SensitiveUnlocked bool `json:"sensitiveUnlocked"`
	}
	if err := json.Unmarshal(summary.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !body.SensitiveUnlocked || body.Summary.Income != 100000 || body.Summary.Expense != 1200 {
		t.Fatalf("unexpected summary: %#v", body)
	}
}

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

func TestAIParseRouteUsesOpenAICompatibleChatCompletions(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	fakeAI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" {
			t.Fatalf("unexpected AI path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"{\"entries\":[{\"kind\":\"transaction\",\"date\":\"2026-05-02\",\"payee\":\"Shop\",\"narration\":\"Snack\",\"metadata\":{},\"tags\":[],\"postings\":[{\"account\":\"Expenses:Food\",\"amount\":\"8.00\",\"currency\":\"CNY\"},{\"account\":\"Assets:Cash\",\"amount\":\"-8.00\",\"currency\":\"CNY\"}],\"confidence\":1,\"needsReview\":false,\"questions\":[]}]}"}}]}`))
	}))
	defer fakeAI.Close()
	t.Setenv("LEDGER_AI_PROVIDER", "openai")
	t.Setenv("OPENAI_API_KEY", "test-key")
	t.Setenv("OPENAI_BASE_URL", fakeAI.URL)
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodPost, "/api/ai/parse", `{"input":"买零食 8 元"}`, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("ai parse status=%d body=%s", res.Code, res.Body.String())
	}
	var body struct {
		Entries []LedgerEntry `json:"entries"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Entries) != 1 || body.Entries[0].Payee != "Shop" {
		t.Fatalf("unexpected AI entries: %#v", body.Entries)
	}
}

func TestImportPreviewAndCommit(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	deg := filepath.Join(t.TempDir(), "double-entry-generator")
	mustWrite(t, deg, strings.Join([]string{
		"#!/bin/sh",
		"out=\"\"",
		"prev=\"\"",
		"for arg in \"$@\"; do",
		"  if [ \"$prev\" = \"--output\" ]; then out=\"$arg\"; fi",
		"  prev=\"$arg\"",
		"done",
		"cat > \"$out\" <<'EOF'",
		"2026-05-03 * \"便利店\" \"便利店\"",
		"  orderId: \"alipay-1\"",
		"  source: \"alipay\"",
		"  Expenses:Food                         6.50 CNY",
		"  Assets:Cash                         -6.50 CNY",
		"EOF",
		"",
	}, "\n"))
	if err := os.Chmod(deg, 0o755); err != nil {
		t.Fatal(err)
	}
	fakePython := filepath.Join(t.TempDir(), "python3")
	mustWrite(t, fakePython, strings.Join([]string{
		"#!/bin/sh",
		"generated=\"$2\"",
		"out=\"\"",
		"prev=\"\"",
		"dry=\"\"",
		"for arg in \"$@\"; do",
		"  if [ \"$arg\" = \"--dry-run\" ]; then dry=1; fi",
		"  if [ \"$prev\" = \"-o\" ]; then out=\"$arg\"; fi",
		"  prev=\"$arg\"",
		"done",
		"if [ -n \"$dry\" ]; then echo \"dedup dry run: 1 candidate\"; exit 0; fi",
		"cp \"$generated\" \"$out\"",
		"",
	}, "\n"))
	if err := os.Chmod(fakePython, 0o755); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "alipay-config.yaml"), "alipay: {}\n")
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "scripts", "dedup_import.py"), "# test fixture\n")
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	t.Setenv("DOUBLE_ENTRY_GENERATOR_BIN", deg)
	t.Setenv("PYTHON_BIN", fakePython)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	var form bytes.Buffer
	writer := multipart.NewWriter(&form)
	part, err := writer.CreateFormFile("file", "alipay.csv")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = part.Write([]byte("交易创建时间,交易对方,金额\n2026-05-03,便利店,6.50\n"))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/ledger/imports/preview", &form)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	for _, cookie := range cookies {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("preview status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var preview struct {
		ImportID string        `json:"importId"`
		Provider string        `json:"provider"`
		Entries  []ImportEntry `json:"entries"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &preview); err != nil {
		t.Fatal(err)
	}
	if preview.ImportID == "" || len(preview.Entries) != 1 {
		t.Fatalf("unexpected preview: %#v", preview)
	}
	if preview.Entries[0].OrderID != "alipay-1" || preview.Entries[0].CategoryAccount != "Expenses:Food" {
		t.Fatalf("preview did not parse DEG output: %#v", preview.Entries[0])
	}

	body, _ := json.Marshal(map[string]any{"importId": preview.ImportID, "provider": preview.Provider, "entries": preview.Entries})
	recorder = requestWithCookies(router, http.MethodPost, "/api/ledger/imports/commit", string(body), cookies)
	if recorder.Code != http.StatusOK {
		t.Fatalf("commit status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	importsDir := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "imports")
	files, err := os.ReadDir(importsDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatal("expected import output file")
	}
	importText := string(mustRead(t, filepath.Join(importsDir, files[0].Name())))
	if !strings.Contains(importText, "document Assets:Cash") || !strings.Contains(importText, "orderId: \"alipay-1\"") {
		t.Fatalf("import output missing document or transaction:\n%s", importText)
	}
	documentsDir := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "documents", "imports")
	documents, err := os.ReadDir(documentsDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(documents) == 0 {
		t.Fatal("expected archived import document")
	}
}

func TestCmbImportHelpers(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "cmb-credit-card-config.yaml"), strings.Join([]string{
		"cmb:",
		"  paymentSourceHandledExternally:",
		"    - 支付宝-",
		"    - 财付通-",
		"    - 微信支付-",
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "cmb.csv")
	output := filepath.Join(t.TempDir(), "cmb-prefiltered.csv")
	mustWrite(t, input, strings.Join([]string{
		"招商银行信用卡对账单",
		"交易日,记账日,交易摘要,人民币金额,卡号末四位,交易地金额",
		"05/01,05/02,支付宝-中国铁路网络有限公司,10.00,1234,10.00(CNY)",
		"05/02,05/03,财付通-福州超体健康科技有限公司,20.00,1234,20.00(CNY)",
		"05/03,05/04,微信支付-某商户,30.00,1234,30.00(CNY)",
		"05/04,05/05,云闪付扫码-财付通(银联云闪付),40.00,1234,40.00(CNY)",
		"05/05,05/06,上海一嗨汽车租赁有限公司-Apple Pay:6131,50.00,1234,50.00(CNY)",
	}, "\n"))

	server := &Server{cfg: cfg}
	result, err := server.prefilterCmbCSV(input, output)
	if err != nil {
		t.Fatal(err)
	}
	filtered := string(mustRead(t, output))
	if result.RawRowCount != 5 || result.Skipped != 3 || result.FilteredRowCount != 2 {
		t.Fatalf("unexpected prefilter counts: %#v", result)
	}
	for _, skipped := range []string{"支付宝-中国铁路网络有限公司", "财付通-福州超体健康科技有限公司", "微信支付-某商户"} {
		if strings.Contains(filtered, skipped) {
			t.Fatalf("filtered CSV still contains skipped row %q:\n%s", skipped, filtered)
		}
	}
	if !strings.Contains(filtered, "云闪付扫码-财付通(银联云闪付)") || !strings.Contains(filtered, "上海一嗨汽车租赁有限公司-Apple Pay:6131") {
		t.Fatalf("filtered CSV dropped non-prefix rows:\n%s", filtered)
	}

	accounts := map[string]bool{"Assets:CN:CMB:Checking": true, "Liabilities:CN:CMB:CreditCard": true}
	if got := providerDocumentAccount("cmb", accounts, "Assets:CN:CMB:Checking"); got != "Liabilities:CN:CMB:CreditCard" {
		t.Fatalf("document account = %s", got)
	}
}

func TestCmbPDFTableHelpers(t *testing.T) {
	headerLine := pdfTextLine{Y: 700, Items: []pdfTextItem{
		{Text: "交易日", X: 10, Y: 700},
		{Text: "记账日", X: 60, Y: 700},
		{Text: "交易摘要", X: 110, Y: 700},
		{Text: "人民币金额", X: 260, Y: 700},
		{Text: "卡号末四位", X: 340, Y: 700},
		{Text: "交易地金额", X: 430, Y: 700},
	}}
	x, ok := findHeaderX(headerLine, "卡号末四位")
	if !ok || x != 340 {
		t.Fatalf("header x = %v, %v", x, ok)
	}
	ranges := []cmbPDFColumnRange{
		{Index: 0, Left: 10, Right: 59.99},
		{Index: 1, Left: 60, Right: 109.99},
		{Index: 2, Left: 110, Right: 259.99},
		{Index: 3, Left: 260, Right: 339.99},
		{Index: 4, Left: 340, Right: 429.99},
		{Index: 5, Left: 430, Right: 9999},
	}
	if got := cmbPDFColumnForX(431, ranges); got != 5 {
		t.Fatalf("column = %d", got)
	}
	row := normalizeCmbPDFRow([]string{"05/01", "05/02", "支付宝-商户", "10.00", "", "10.00(CNY)"})
	if !looksLikeCmbPDFDataRow(row) {
		t.Fatalf("row should be recognized: %#v", row)
	}
	line := csvLine([]string{"交易摘要", "A,B", `C"D`})
	if line != `交易摘要,"A,B","C""D"` {
		t.Fatalf("csv line = %s", line)
	}
}

func TestCmbPDFLayoutTextParser(t *testing.T) {
	text := strings.Join([]string{
		"招商银行信用卡对账单（个人消费卡账户 2026年05月）（补）",
		"交易日       记账日       交易摘要                                     人民币金额             卡号末四位             交易地金额",
		"          05/05     掌上生活还款                                     -7,662.12               9813         -7,662.12",
		" 04/21    04/22     财付通-示例商户有限公司                            -199.00                3218      -199.00(CN)",
		" 05/02    05/04     PP*APPLE.COM/BILL                       34.17    9813     4.99(US)",
	}, "\n")
	result, err := parseCmbPDFLayoutText(text)
	if err != nil {
		t.Fatal(err)
	}
	if result.RowCount != 3 {
		t.Fatalf("row count = %d", result.RowCount)
	}
	if !strings.Contains(result.CSV, `,05/05,掌上生活还款,"-7,662.12",9813,"-7,662.12"`) {
		t.Fatalf("missing payment row:\n%s", result.CSV)
	}
	if !strings.Contains(result.CSV, "04/21,04/22,财付通-示例商户有限公司,-199.00,3218,-199.00(CN)") {
		t.Fatalf("missing refund row:\n%s", result.CSV)
	}
	if !strings.Contains(result.CSV, "05/02,05/04,PP*APPLE.COM/BILL,34.17,9813,4.99(US)") {
		t.Fatalf("missing foreign currency row:\n%s", result.CSV)
	}
}

func TestRateLimitUsesRemoteAddrByDefault(t *testing.T) {
	limiter := NewRateLimiter()
	cfg := testLedger(t)
	router := NewRouter(cfg)
	server := &Server{cfg: cfg, limiter: limiter}
	router.Handle(http.MethodGet, "/limited", func(c *gin.Context) {
		if server.limiter.Check(c, "test", 1, 60_000_000_000) {
			c.JSON(http.StatusOK, map[string]bool{"ok": true})
		}
	})

	first := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/limited", nil)
	req.RemoteAddr = "203.0.113.10:1111"
	req.Header.Set("X-Forwarded-For", "198.51.100.1")
	router.ServeHTTP(first, req)
	if first.Code != http.StatusOK {
		t.Fatalf("first status = %d", first.Code)
	}
	second := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/limited", nil)
	req.RemoteAddr = "203.0.113.10:2222"
	req.Header.Set("X-Forwarded-For", "198.51.100.2")
	router.ServeHTTP(second, req)
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("second status = %d, want 429", second.Code)
	}
}

func TestPasskeyStatusAndOptionsPersistSession(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)

	status := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/passkey/status", nil)
	router.ServeHTTP(status, req)
	if status.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", status.Code, status.Body.String())
	}
	var statusBody struct {
		Registered bool `json:"registered"`
	}
	if err := json.Unmarshal(status.Body.Bytes(), &statusBody); err != nil {
		t.Fatal(err)
	}
	if statusBody.Registered {
		t.Fatal("new runtime should not have a registered passkey")
	}

	cookies := loginCookies(t, router)
	options := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/api/passkey/register/options", nil)
	req.Host = "ledger.test"
	for _, cookie := range cookies {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(options, req)
	if options.Code != http.StatusOK {
		t.Fatalf("options=%d body=%s", options.Code, options.Body.String())
	}
	var optionBody struct {
		Challenge string `json:"challenge"`
		RP        struct {
			ID string `json:"id"`
		} `json:"rp"`
		User struct {
			Name string `json:"name"`
		} `json:"user"`
	}
	if err := json.Unmarshal(options.Body.Bytes(), &optionBody); err != nil {
		t.Fatal(err)
	}
	if optionBody.Challenge == "" || optionBody.RP.ID != "ledger.test" || optionBody.User.Name != "owner" {
		t.Fatalf("unexpected options: %#v", optionBody)
	}
	storeText := string(mustRead(t, filepath.Join(cfg.RuntimeDir, "passkeys.json")))
	if !strings.Contains(storeText, `"currentSession"`) || !strings.Contains(storeText, optionBody.Challenge) {
		t.Fatalf("passkey session was not persisted:\n%s", storeText)
	}
}

func TestPasskeyLoginOptionsUseStoredCredentials(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	mustWrite(t, filepath.Join(cfg.RuntimeDir, "passkeys.json"), `{"credentials":[{"id":"AQID","publicKey":"BAUG","counter":7,"transports":["internal"]}]}`)
	router := NewRouter(cfg)

	res := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/passkey/login/options", nil)
	req.Host = "ledger.test"
	router.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("login options=%d body=%s", res.Code, res.Body.String())
	}
	var body struct {
		Challenge        string `json:"challenge"`
		AllowCredentials []struct {
			ID         string   `json:"id"`
			Transports []string `json:"transports"`
		} `json:"allowCredentials"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Challenge == "" || len(body.AllowCredentials) != 1 || body.AllowCredentials[0].ID != "AQID" {
		t.Fatalf("unexpected login options: %#v", body)
	}
}

func TestPushSubscriptionLifecycle(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	t.Setenv("WEB_PUSH_VAPID_PUBLIC_KEY", "public-key")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	subscription := `{"subscription":{"endpoint":"https://push.example/sub/1","keys":{"p256dh":"p256dh","auth":"auth"}}}`
	res := requestWithCookies(router, http.MethodPost, "/api/push/subscription", subscription, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("push save=%d body=%s", res.Code, res.Body.String())
	}
	var saved struct {
		ID    string `json:"id"`
		Count int    `json:"count"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &saved); err != nil {
		t.Fatal(err)
	}
	if saved.ID == "" || saved.Count != 1 {
		t.Fatalf("unexpected save response: %#v", saved)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/push/subscription", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("push status=%d body=%s", res.Code, res.Body.String())
	}
	var status struct {
		PublicKey  string `json:"publicKey"`
		Configured bool   `json:"configured"`
		Count      int    `json:"count"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status.PublicKey != "public-key" || status.Configured || status.Count != 1 {
		t.Fatalf("unexpected push status: %#v", status)
	}

	res = requestWithCookies(router, http.MethodDelete, "/api/push/subscription", `{"endpoint":"https://push.example/sub/1"}`, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("push delete=%d body=%s", res.Code, res.Body.String())
	}
	var deleted struct {
		Removed int `json:"removed"`
		Count   int `json:"count"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &deleted); err != nil {
		t.Fatal(err)
	}
	if deleted.Removed != 1 || deleted.Count != 0 {
		t.Fatalf("unexpected delete response: %#v", deleted)
	}
}

func TestInsightsAndNotifications(t *testing.T) {
	cfg := testLedger(t)
	monthFile := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	existing := string(mustRead(t, monthFile))
	mustWrite(t, monthFile, existing+strings.Join([]string{
		`2026-05-10 * "Electronics" "Monitor"`,
		"  Expenses:Food 400.00 CNY",
		"  Assets:Cash -400.00 CNY",
		"",
	}, "\n"))
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodGet, "/api/ledger/insights?month=2026-05", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("insights=%d body=%s", res.Code, res.Body.String())
	}
	var insights struct {
		Insights []Insight `json:"insights"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &insights); err != nil {
		t.Fatal(err)
	}
	if len(insights.Insights) == 0 || insights.Insights[0].Title != "大额支出" {
		t.Fatalf("unexpected insights: %#v", insights.Insights)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/notifications?start=2026-05-01&end=2026-06-01", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("notifications=%d body=%s", res.Code, res.Body.String())
	}
	var notifications struct {
		Notifications []StoredNotification `json:"notifications"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &notifications); err != nil {
		t.Fatal(err)
	}
	if len(notifications.Notifications) == 0 || notifications.Notifications[0].Status != "unread" {
		t.Fatalf("unexpected notifications: %#v", notifications.Notifications)
	}
	updateBody := `{"ids":["` + notifications.Notifications[0].ID + `"],"status":"read"}`
	res = requestWithCookies(router, http.MethodPatch, "/api/ledger/notifications", updateBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("notification patch=%d body=%s", res.Code, res.Body.String())
	}
	var updated struct {
		Notifications []StoredNotification `json:"notifications"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &updated); err != nil {
		t.Fatal(err)
	}
	if len(updated.Notifications) != 1 || updated.Notifications[0].Status != "read" || updated.Notifications[0].ReadAt == nil {
		t.Fatalf("unexpected updated notifications: %#v", updated.Notifications)
	}
}

func loginCookies(t *testing.T, router http.Handler) []*http.Cookie {
	t.Helper()
	login := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/auth/login", bytes.NewBufferString(`{"password":"secret"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(login, req)
	if login.Code != http.StatusOK {
		t.Fatalf("login status=%d body=%s", login.Code, login.Body.String())
	}
	return login.Result().Cookies()
}

func requestWithCookies(router http.Handler, method, path, body string, cookies []*http.Cookie) *httptest.ResponseRecorder {
	recorder := httptest.NewRecorder()
	req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	for _, cookie := range cookies {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(recorder, req)
	return recorder
}

func mustRead(t *testing.T, file string) []byte {
	t.Helper()
	content, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	return content
}
