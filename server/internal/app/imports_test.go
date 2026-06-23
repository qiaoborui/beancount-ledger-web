package app

import (
	"bytes"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	pdf "github.com/ledongthuc/pdf"
)

func TestImportPreviewAndCommit(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
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
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "alipay-config.yaml"), strings.Join([]string{
		"defaultMinusAccount: Income:Other",
		"defaultPlusAccount: Expenses:Food",
		"defaultCurrency: CNY",
		"alipay:",
		"  rules:",
		"    - method: 网商银行储蓄卡",
		"      methodAccount: Assets:Cash",
		"    - category: 日用百货",
		"      targetAccount: Expenses:Food",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "scripts", "dedup_import.py"), "# test fixture\n")
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
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
	_, _ = part.Write([]byte(strings.Join([]string{
		"------------------------------------------------------------------------------------",
		"导出信息：",
		"姓名：测试",
		"支付宝账户：test@example.com",
		"起始时间：[2026-05-24 00:00:00]    终止时间：[2026-05-24 23:59:59]",
		"导出交易类型：[全部]",
		"导出时间：[2026-05-24 23:24:06]",
		"共1笔记录",
		"收入：0笔 0.00元",
		"支出：1笔 6.50元",
		"不计收支：0笔 0.00元",
		"",
		"特别提示：",
		"1.提示",
		"2.提示",
		"3.提示",
		"4.提示",
		"5.提示",
		"6.提示",
		"7.提示",
		"8.提示",
		"",
		"------------------------支付宝支付科技有限公司  电子客户回单------------------------",
		"交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,",
		"2026-05-24 17:55:17,日用百货,便利店,157******14,零食,支出,6.50,网商银行储蓄卡(0691),交易成功,module-order,merchant-1,,",
	}, "\n")))
	originalPart, err := writer.CreateFormFile("originalFile", "statement.pdf")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = originalPart.Write([]byte("%PDF original statement"))
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
		ImportID       string        `json:"importId"`
		Provider       string        `json:"provider"`
		Entries        []ImportEntry `json:"entries"`
		AccountOptions []struct {
			Account string  `json:"account"`
			Alias   *string `json:"alias"`
			Label   string  `json:"label"`
		} `json:"accountOptions"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &preview); err != nil {
		t.Fatal(err)
	}
	if preview.ImportID == "" || len(preview.Entries) != 1 {
		t.Fatalf("unexpected preview: %#v", preview)
	}
	if preview.Entries[0].OrderID != "module-order" || preview.Entries[0].CategoryAccount != "Expenses:Food" {
		t.Fatalf("preview did not parse DEG output: %#v", preview.Entries[0])
	}
	foundAlias := false
	for _, option := range preview.AccountOptions {
		if option.Account == "Assets:Cash" && option.Alias != nil && *option.Alias == "现金" && option.Label == "现金" {
			foundAlias = true
		}
	}
	if !foundAlias {
		t.Fatalf("preview account options missing alias: %#v", preview.AccountOptions)
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
	if !strings.Contains(importText, "document Assets:Cash") || !strings.Contains(importText, "orderId: \"module-order\"") {
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
	if filepath.Ext(documents[0].Name()) != ".pdf" {
		t.Fatalf("expected archived original PDF, got %s", documents[0].Name())
	}
	documentText := string(mustRead(t, filepath.Join(documentsDir, documents[0].Name())))
	if documentText != "%PDF original statement" {
		t.Fatalf("archived document content = %q", documentText)
	}
	list := requestWithCookies(router, http.MethodGet, "/api/ledger/imports/documents", "", cookies)
	if list.Code != http.StatusOK {
		t.Fatalf("documents status=%d body=%s", list.Code, list.Body.String())
	}
	var history struct {
		Documents []ImportDocument `json:"documents"`
	}
	if err := json.Unmarshal(list.Body.Bytes(), &history); err != nil {
		t.Fatal(err)
	}
	if len(history.Documents) != 1 {
		t.Fatalf("documents = %#v", history.Documents)
	}
	if history.Documents[0].Provider != "alipay" || history.Documents[0].DateStart != "2026-05-24" || history.Documents[0].Ext != ".pdf" {
		t.Fatalf("unexpected document metadata: %#v", history.Documents[0])
	}
	fileRes := requestWithCookies(router, http.MethodGet, "/api/ledger/imports/documents/file?path="+url.QueryEscape(history.Documents[0].Path), "", cookies)
	if fileRes.Code != http.StatusOK {
		t.Fatalf("document file status=%d body=%s", fileRes.Code, fileRes.Body.String())
	}
	if fileRes.Body.String() != "%PDF original statement" {
		t.Fatalf("document file body = %q", fileRes.Body.String())
	}
	badPath := requestWithCookies(router, http.MethodGet, "/api/ledger/imports/documents/file?path="+url.QueryEscape("../main.bean"), "", cookies)
	if badPath.Code != http.StatusBadRequest {
		t.Fatalf("bad document path status=%d body=%s", badPath.Code, badPath.Body.String())
	}
}

func TestImportProvidersEndpoint(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	recorder := requestWithCookies(router, http.MethodGet, "/api/ledger/imports/providers", "", cookies)
	if recorder.Code != http.StatusOK {
		t.Fatalf("providers status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Providers []importProviderOption `json:"providers"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Providers) != 5 {
		t.Fatalf("providers = %#v", response.Providers)
	}
	if response.Providers[0].ID != "alipay" || response.Providers[1].ID != "wechat" || response.Providers[2].ID != "cmb" || response.Providers[3].ID != "ccb-credit" || response.Providers[4].ID != "cmb-checking" {
		t.Fatalf("unexpected provider order: %#v", response.Providers)
	}
	if response.Providers[3].Label != "建设银行信用卡" || response.Providers[3].Accept != ".eml / .html / .htm / .csv" {
		t.Fatalf("unexpected ccb metadata: %#v", response.Providers[3])
	}
	if response.Providers[0].Engine != "deg-module" || response.Providers[3].Engine != "native-ccb-credit" || response.Providers[4].Engine != "deg-module" {
		t.Fatalf("unexpected provider engines: %#v", response.Providers)
	}
	if response.Providers[4].Label != "招商银行储蓄卡" || response.Providers[4].Accept != ".pdf / .csv" {
		t.Fatalf("unexpected checking metadata: %#v", response.Providers[3])
	}
}

func TestImportCommitAllowsRemovedPreviewEntries(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "alipay-config.yaml"), "alipay: {}\n")
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "scripts", "dedup_import.py"), "# test fixture\n")
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	server := &Server{cfg: cfg, cache: NewLedgerCache(cfg)}
	server.writer = NewLedgerWriter(cfg, server.cache)

	importID := "removeentry1"
	sourceFile := filepath.Join(importRuntimeDir(cfg, importID), "original.csv")
	if err := os.MkdirAll(filepath.Dir(sourceFile), 0o700); err != nil {
		t.Fatal(err)
	}
	sourceRaw := []byte("交易创建时间,交易对方,金额\n2026-05-03,便利店,6.50\n")
	if err := os.WriteFile(sourceFile, sourceRaw, 0o600); err != nil {
		t.Fatal(err)
	}
	expected := 2
	meta := importMeta{
		Provider:           "alipay",
		OriginalFilename:   "alipay.csv",
		InputFile:          sourceFile,
		ProviderDetection:  providerDetection{Provider: "alipay", Reason: "test", Confidence: "high"},
		StatementHash:      sha256Hex(sourceRaw),
		ExpectedEntryCount: &expected,
	}
	if err := server.writeImportMeta(importID, meta); err != nil {
		t.Fatal(err)
	}

	entries := []ImportEntry{{
		ID:              "alipay-1",
		Date:            "2026-05-03",
		Flag:            "*",
		Payee:           "便利店",
		Narration:       "便利店",
		Source:          "alipay",
		OrderID:         "alipay-1",
		CategoryAccount: "Expenses:Food",
		FundingAccount:  "Assets:Cash",
		Amount:          6.50,
		Currency:        "CNY",
		Metadata:        map[string]string{"orderId": "alipay-1", "source": "alipay"},
	}}
	result, err := server.commitImport(importID, "alipay", entries)
	if err != nil {
		t.Fatal(err)
	}
	if result["count"] != 1 {
		t.Fatalf("count = %#v", result["count"])
	}
	beanText := result["beanText"].(string)
	if !strings.Contains(beanText, `orderId: "alipay-1"`) {
		t.Fatalf("committed bean missing kept entry:\n%s", beanText)
	}
}

func TestImportWriteRollsBackOnBeanCheckFailure(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 1\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	server := &Server{cfg: cfg, cache: NewLedgerCache(cfg)}
	server.writer = NewLedgerWriter(cfg, server.cache)
	mainBefore := string(mustRead(t, mainBeanPath(cfg)))
	sourceFile := filepath.Join(t.TempDir(), "statement.csv")
	mustWrite(t, sourceFile, "date,payee,amount\n2026-06-01,Shop,8.00\n")
	outputFile := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "imports", "failed-import.bean")
	documentFile := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "documents", "imports", "failed-statement.csv")
	monthFile := transactionFileForDate(cfg, "2026-06-01")
	beanText := strings.Join([]string{
		`2026-06-01 * "Shop" "Snack"`,
		"  Expenses:Food                         8.00 CNY",
		"  Assets:Cash                          -8.00 CNY",
	}, "\n")

	err := server.writeImportedBeanFile(outputFile, monthFile, beanText, "alipay", "2026-06-01", "2026-06-02", sourceFile, documentFile, "Assets:Cash")
	if err == nil {
		t.Fatal("expected bean-check failure")
	}
	if got := string(mustRead(t, mainBeanPath(cfg))); got != mainBefore {
		t.Fatalf("main.bean was not rolled back:\n%s", got)
	}
	for _, file := range []string{monthFile, outputFile, documentFile} {
		if _, err := os.Stat(file); !os.IsNotExist(err) {
			t.Fatalf("%s should have been removed after rollback, err=%v", file, err)
		}
	}
}

func TestPrepareAlipayCSVForDEGPadsHeaderRecord(t *testing.T) {
	cfg := testLedger(t)
	input := filepath.Join(t.TempDir(), "alipay.csv")
	mustWrite(t, input, strings.Join([]string{
		"------------------------------------------------------------------------------------",
		"导出信息：",
		"姓名：测试",
		"支付宝账户：test@example.com",
		"起始时间：[2026-05-24 00:00:00]    终止时间：[2026-05-24 23:59:59]",
		"导出交易类型：[全部]",
		"导出时间：[2026-05-24 23:24:06]",
		"共1笔记录",
		"收入：0笔 0.00元",
		"支出：1笔 195.22元",
		"不计收支：0笔 0.00元",
		"",
		"特别提示：",
		"1.提示",
		"2.提示",
		"3.提示",
		"4.提示",
		"5.提示",
		"6.提示",
		"7.提示",
		"8.提示",
		"",
		"------------------------支付宝支付科技有限公司  电子客户回单------------------------",
		"交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,",
		"2026-05-24 17:55:17,日用百货,x***1,157******14,椰客椰子鸡,支出,195.22,网商银行储蓄卡(0691),交易成功,first-order,merchant-1,,",
	}, "\n"))

	server := &Server{cfg: cfg}
	originalText := string(mustRead(t, input))
	originalInfo, err := alipayCSVHeaderInfo(originalText)
	if err != nil {
		t.Fatal(err)
	}
	if originalInfo.RecordIndex != 22 {
		t.Fatalf("fixture should reproduce DEG header offset, got record %d", originalInfo.RecordIndex)
	}

	prepared, err := server.prepareAlipayCSVForDEG(input, "alipaytest")
	if err != nil {
		t.Fatal(err)
	}
	if prepared.InputFile == input {
		t.Fatal("expected DEG-compatible copy")
	}
	preparedText, err := decodeAlipayCSV(mustRead(t, prepared.InputFile))
	if err != nil {
		t.Fatal(err)
	}
	preparedInfo, err := alipayCSVHeaderInfo(preparedText)
	if err != nil {
		t.Fatal(err)
	}
	if preparedInfo.RecordIndex != 23 {
		t.Fatalf("prepared header record = %d, want 23", preparedInfo.RecordIndex)
	}
	rows, err := readAlipaySourceRows(prepared.InputFile)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].OrderID != "first-order" {
		t.Fatalf("prepared CSV did not preserve first transaction: %#v", rows)
	}
}

func TestDEGModuleImportEngineGeneratesBeancount(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "alipay-config.yaml"), strings.Join([]string{
		"defaultMinusAccount: Income:Other",
		"defaultPlusAccount: Expenses:Food",
		"defaultCurrency: CNY",
		"alipay:",
		"  rules:",
		"    - method: 网商银行储蓄卡",
		"      methodAccount: Assets:Cash",
		"    - category: 日用百货",
		"      targetAccount: Expenses:Food",
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "alipay.csv")
	mustWrite(t, input, strings.Join([]string{
		"------------------------------------------------------------------------------------",
		"导出信息：",
		"姓名：测试",
		"支付宝账户：test@example.com",
		"起始时间：[2026-05-24 00:00:00]    终止时间：[2026-05-24 23:59:59]",
		"导出交易类型：[全部]",
		"导出时间：[2026-05-24 23:24:06]",
		"共1笔记录",
		"收入：0笔 0.00元",
		"支出：1笔 6.50元",
		"不计收支：0笔 0.00元",
		"",
		"特别提示：",
		"1.提示",
		"2.提示",
		"3.提示",
		"4.提示",
		"5.提示",
		"6.提示",
		"7.提示",
		"8.提示",
		"",
		"------------------------支付宝支付科技有限公司  电子客户回单------------------------",
		"交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,",
		"2026-05-24 17:55:17,日用百货,便利店,157******14,零食,支出,6.50,网商银行储蓄卡(0691),交易成功,module-order,merchant-1,,",
	}, "\n"))

	server := &Server{cfg: cfg}
	prepared, err := server.prepareAlipayCSVForDEG(input, "degmodule")
	if err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(t.TempDir(), "alipay.bean")
	err = degModuleImportEngine{}.Generate(server, importEngineInput{
		ProviderID: "alipay",
		Config:     importProviderConfigs["alipay"],
		InputFile:  prepared.InputFile,
		OutputFile: output,
	})
	if err != nil {
		t.Fatal(err)
	}
	generated := string(mustRead(t, output))
	if !strings.Contains(generated, `orderId: "module-order"`) || !strings.Contains(generated, "Expenses:Food") || !strings.Contains(generated, "Assets:Cash") {
		t.Fatalf("generated bean missing expected module output:\n%s", generated)
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

	accounts := map[string]bool{"Assets:CN:CMB:Checking": true, "Liabilities:CN:CMB:CreditCard:0016": true}
	if got := providerDocumentAccount("cmb", accounts, "Assets:CN:CMB:Checking"); got != "Liabilities:CN:CMB:CreditCard:0016" {
		t.Fatalf("document account = %s", got)
	}
}

func TestCmbCreditPDFParserWithFixture(t *testing.T) {
	fixture := strings.TrimSpace(os.Getenv("CMB_CREDIT_PDF_FIXTURE"))
	if fixture == "" {
		t.Skip("set CMB_CREDIT_PDF_FIXTURE to verify a real 招商银行信用卡 PDF")
	}
	result, err := parseCmbCreditPDFToCSV(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if result.RowCount == 0 {
		t.Fatalf("expected PDF rows, got %#v", result)
	}
	if !strings.Contains(result.Title, "招商银行信用卡对账单") {
		t.Fatalf("unexpected title: %s", result.Title)
	}
	if !strings.Contains(result.CSV, "掌上生活还款") || !strings.Contains(result.CSV, "人民币金额") {
		t.Fatalf("unexpected normalized CSV:\n%s", result.CSV)
	}
}

func TestCmbCheckingImportHelpers(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "cmb-checking-config.yaml"), strings.Join([]string{
		"defaultMinusAccount: Expenses:Food",
		"defaultPlusAccount: Income:Salary",
		"defaultCashAccount: Assets:Cash",
		"defaultCurrency: CNY",
		"title: 招商银行储蓄卡流水",
		"cmb:",
		"  rules:",
		"    - txType: 掌上生活还款",
		"      targetAccount: Liabilities:CN:CMB:CreditCard:0016",
		"    - peer: 摩拜,岭南通",
		"      targetAccount: Expenses:Food",
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "cmb-checking.csv")
	output := filepath.Join(t.TempDir(), "cmb-checking.bean")
	mustWrite(t, input, strings.Join([]string{
		"记账日期,货币,交易金额,联机余额,交易摘要,对手信息,客户摘要",
		"2026-05-20,CNY,100.00,106.31,网联收款,乔博睿 10563996799,",
		"2026-05-20,CNY,-50.00,56.31,银联线上有卡支付,广东岭南通股份有限公司308999841110034,",
		"2026-06-05,CNY,\"-11,595.81\",\"1,459.63\",掌上生活还款,乔博睿 4514617564329813,",
	}, "\n"))

	detection, err := detectBillProvider("招商银行交易流水.pdf.csv", []byte(mustRead(t, input)), "")
	if err != nil {
		t.Fatal(err)
	}
	if detection.Provider != "cmb-checking" {
		t.Fatalf("provider = %s", detection.Provider)
	}

	server := &Server{cfg: cfg}
	importer, ok := importProvider("cmb-checking")
	if !ok {
		t.Fatal("missing cmb-checking provider")
	}
	if importer.ImportEngine().ID() != "deg-module" {
		t.Fatalf("engine = %s", importer.ImportEngine().ID())
	}
	if err := importer.Generate(server, preparedImportInput{InputFile: input}, output); err != nil {
		t.Fatal(err)
	}
	generated := string(mustRead(t, output))
	if !strings.Contains(generated, `Assets:Cash`) {
		t.Fatalf("generated bean missing checking cash account:\n%s", generated)
	}
	if !strings.Contains(generated, `Liabilities:CN:CMB:CreditCard:0016`) || !strings.Contains(generated, `11595.81 CNY`) {
		t.Fatalf("generated bean missing credit-card repayment posting:\n%s", generated)
	}
	entries, err := parsePreviewEntries(generated)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 || entries[1].FundingAccount != "Assets:Cash" {
		t.Fatalf("unexpected preview entries: %#v", entries)
	}

	accounts := map[string]bool{"Assets:CN:CMB:Checking": true, "Liabilities:CN:CMB:CreditCard:0016": true}
	if got := providerDocumentAccount("cmb-checking", accounts, "Liabilities:CN:CMB:CreditCard:0016"); got != "Assets:CN:CMB:Checking" {
		t.Fatalf("document account = %s", got)
	}
}

func TestCmbCheckingPDFParserWithFixture(t *testing.T) {
	fixture := strings.TrimSpace(os.Getenv("CMB_CHECKING_PDF_FIXTURE"))
	if fixture == "" {
		t.Skip("set CMB_CHECKING_PDF_FIXTURE to verify a real 招商银行储蓄卡 PDF")
	}
	result, err := parseCmbCheckingPDFToCSV(fixture)
	if err != nil {
		t.Logf("first PDF lines:\n%s", debugCmbCheckingPDFLines(t, fixture, 80))
		t.Logf("first PDF items:\n%s", debugCmbCheckingPDFItems(t, fixture, 80))
		t.Fatal(err)
	}
	if result.RowCount == 0 {
		t.Fatalf("expected PDF rows, got %#v", result)
	}
	output := filepath.Join(t.TempDir(), "cmb-checking-normalized.csv")
	mustWrite(t, output, result.CSV)
	rows, err := readCmbCheckingCSVRows(output)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != result.RowCount {
		t.Fatalf("row count mismatch: result=%d csv=%d", result.RowCount, len(rows))
	}
}

func debugCmbCheckingPDFLines(t *testing.T, fixture string, limit int) string {
	t.Helper()
	file, reader, err := pdf.Open(fixture)
	if err != nil {
		return err.Error()
	}
	defer file.Close()
	lines := []string{}
	for pageNo := 1; pageNo <= reader.NumPage() && len(lines) < limit; pageNo++ {
		for _, line := range groupPDFTextLines(pageTextItems(reader.Page(pageNo))) {
			text := strings.TrimSpace(compactPDFLineText(line))
			if text == "" {
				continue
			}
			lines = append(lines, text)
			if len(lines) >= limit {
				break
			}
		}
	}
	return strings.Join(lines, "\n")
}

func debugCmbCheckingPDFItems(t *testing.T, fixture string, limit int) string {
	t.Helper()
	file, reader, err := pdf.Open(fixture)
	if err != nil {
		return err.Error()
	}
	defer file.Close()
	items := pageTextItems(reader.Page(1))
	sort.Slice(items, func(i, j int) bool {
		if absFloat(items[i].Y-items[j].Y) > 1.5 {
			return items[i].Y > items[j].Y
		}
		return items[i].X < items[j].X
	})
	lines := []string{}
	for i, item := range items {
		if i >= limit {
			break
		}
		lines = append(lines, fmt.Sprintf("x=%.2f y=%.2f w=%.2f text=%q", item.X, item.Y, item.W, item.Text))
	}
	return strings.Join(lines, "\n")
}

func TestCmbCheckingPDFRowsResultProducesImportableCSV(t *testing.T) {
	result := cmbCheckingPDFRowsResult([][]string{
		{"2026-06-06", "CNY", "-12.34", "100.00", "银联线上有卡支付", "示例商户"},
	})
	if result.RowCount != 1 {
		t.Fatalf("row count = %d", result.RowCount)
	}
	output := filepath.Join(t.TempDir(), "cmb-checking-normalized.csv")
	mustWrite(t, output, result.CSV)
	rows, err := readCmbCheckingCSVRows(output)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Date != "2026-06-06" || rows[0].Counterparty != "示例商户" {
		t.Fatalf("unexpected rows: %#v", rows)
	}
	if len(result.Warnings) == 0 {
		t.Fatal("expected parser warning")
	}
}

func TestCmbCheckingFXImportHelpers(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "commodities.bean"), strings.Join([]string{
		"2026-01-01 commodity CNY",
		"2026-01-01 commodity HKD",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), strings.Join([]string{
		"2026-01-01 open Assets:Cash CNY",
		"2026-01-01 open Assets:CN:CMB:Checking CNY",
		"2026-01-01 open Assets:CN:CMB:HKD HKD",
		"2026-01-01 open Expenses:Food CNY",
		"2026-01-01 open Income:Salary CNY",
		"2026-01-01 open Income:Other CNY",
		"2026-01-01 open Equity:Opening-Balances CNY",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "cmb-checking-config.yaml"), strings.Join([]string{
		"defaultDebitAccount: Expenses:Food",
		"defaultCreditAccount: Income:Salary",
		"cashAccount: Assets:CN:CMB:Checking",
		"defaultCurrency: CNY",
		"currencyAccounts:",
		"  CNY: Assets:CN:CMB:Checking",
		"  HKD: Assets:CN:CMB:HKD",
		"cmbChecking:",
		"  rules: []",
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "cmb-checking-fx.csv")
	output := filepath.Join(t.TempDir(), "cmb-checking-fx.bean")
	mustWrite(t, input, strings.Join([]string{
		"记账日期,货币,交易金额,联机余额,交易摘要,对手信息",
		"2026-06-07,CNY,-86.86,\"11,322.78\",结售汇即时售汇,乔博睿",
		"2026-06-07,HKD,100.00,100.00,结售汇即时售汇,乔博睿",
		"2026-06-07,HKD,-100.00,0.00,结售汇即时结汇,乔博睿",
		"2026-06-07,CNY,86.52,\"11,409.30\",结售汇即时结汇,乔博睿",
	}, "\n"))

	server := &Server{cfg: cfg, cache: NewLedgerCache(cfg)}
	server.writer = NewLedgerWriter(cfg, server.cache)
	if err := server.generateCmbCheckingBean(input, output); err != nil {
		t.Fatal(err)
	}
	generated := string(mustRead(t, output))
	if strings.Count(generated, `txType: "fx"`) != 2 {
		t.Fatalf("expected two fx entries:\n%s", generated)
	}
	if !strings.Contains(generated, "Assets:CN:CMB:HKD") || !strings.Contains(generated, "100.00 HKD @@ 86.86 CNY") || !strings.Contains(generated, "-100.00 HKD @@ 86.52 CNY") {
		t.Fatalf("generated bean missing FX postings:\n%s", generated)
	}
	entries, err := parsePreviewEntries(generated)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 || entries[0].TxType != "fx" || entries[0].Postings[0].PriceKind != "total" || entries[0].Postings[0].PriceAmount != "86.86" {
		t.Fatalf("unexpected preview entries: %#v", entries)
	}
	rendered, err := server.validateAndRenderImportEntries(entries)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(rendered, "100.00 HKD @@ 86.86 CNY") || !strings.Contains(rendered, "-100.00 HKD @@ 86.52 CNY") {
		t.Fatalf("rendered import lost FX prices:\n%s", rendered)
	}
}

func TestCcbCreditEmailImportHelpers(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "ccb-credit-card-config.yaml"), strings.Join([]string{
		"defaultMinusAccount: Expenses:Unknown",
		"defaultPlusAccount: Expenses:Unknown",
		"defaultCashAccount: Liabilities:CN:CCB:CreditCard:7720",
		"defaultCurrency: CNY",
		"ccbCredit:",
		"  paymentSourceHandledExternally:",
		"    - 支付宝-",
		"    - 财付通-",
		"  rules:",
		"    - item: OPENROUTER",
		"      targetAccount: Expenses:Digital:Subscription",
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "ccb.eml")
	normalized := filepath.Join(t.TempDir(), "ccb-normalized.csv")
	output := filepath.Join(t.TempDir(), "ccb.bean")
	mustWrite(t, input, ccbCreditTestEmail([]string{
		"2026-06-13,2026-06-13,7720,财付通-滴滴出行,CNY,1.60,CNY,1.60",
		"2026-06-18,2026-06-18,7720,支付宝-瑞幸咖啡（中国）有限公司,CNY,3.40,CNY,3.40",
		"2026-06-20,2026-06-20,7720,OPENROUTER,CNY,10.00,CNY,10.00",
	}))

	statement, err := parseCcbCreditStatementFile(input)
	if err != nil {
		t.Fatal(err)
	}
	if len(statement.Rows) != 3 || statement.Cycle != "2026/06/13-2026/06/21" || statement.DueDate != "2026-07-10" {
		t.Fatalf("unexpected statement: %#v", statement)
	}
	normalizedStatement := normalizedCcbCreditStatement(statement.Rows, statement)
	if len(normalizedStatement.Transactions) != 3 || normalizedStatement.Transactions[0].Amount != 160 || normalizedStatement.Cycle != statement.Cycle {
		t.Fatalf("unexpected normalized statement: %#v", normalizedStatement)
	}
	if err := writeCcbCreditCSV(statement.Rows, normalized); err != nil {
		t.Fatal(err)
	}
	server := &Server{cfg: cfg}
	prefilter, err := server.prefilterCcbCreditCSV(normalized, normalized+".filtered")
	if err != nil {
		t.Fatal(err)
	}
	if prefilter.RawRowCount != 3 || prefilter.Skipped != 2 || prefilter.FilteredRowCount != 1 {
		t.Fatalf("unexpected prefilter counts: %#v", prefilter)
	}
	if err := server.generateCcbCreditBean(normalized+".filtered", output); err != nil {
		t.Fatal(err)
	}
	generated := string(mustRead(t, output))
	if !strings.Contains(generated, `source: "ccb-credit"`) || !strings.Contains(generated, "Expenses:Digital:Subscription") || !strings.Contains(generated, "Liabilities:CN:CCB:CreditCard:7720") {
		t.Fatalf("generated bean missing CCB credit postings:\n%s", generated)
	}
	entries, err := parsePreviewEntries(generated)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Source != "ccb-credit" || entries[0].FundingAccount != "Liabilities:CN:CCB:CreditCard:7720" {
		t.Fatalf("unexpected preview entries: %#v", entries)
	}

	reviewCSV := filepath.Join(t.TempDir(), "ccb-review.csv")
	mustWrite(t, reviewCSV, strings.Join([]string{
		"no,transactionDate,postingDate,cardLast4,description,transactionCurrency,transactionAmount,settlementCurrency,settlementAmount,action,reason,page",
		"1,2026-06-13,2026-06-13,7720,财付通-滴滴出行,人民币元,1.60,人民币元,1.60,excluded-platform,platform-payment-source,1",
	}, "\n"))
	reviewRows, err := readCcbCreditCSVRows(reviewCSV)
	if err != nil {
		t.Fatal(err)
	}
	if len(reviewRows) != 1 || reviewRows[0].TransactionCurrency != "CNY" || reviewRows[0].SettlementCurrency != "CNY" {
		t.Fatalf("unexpected review CSV rows: %#v", reviewRows)
	}
	detection, err := detectImportProvider("ccb-review.csv", mustRead(t, reviewCSV), "")
	if err != nil || detection.Provider != "ccb-credit" {
		t.Fatalf("unexpected review CSV detection: %#v err=%v", detection, err)
	}

	encodedEmail := strings.Join([]string{
		"From: service@vip.ccb.com",
		"To: ledger@example.test",
		"Subject: =?UTF-8?B?5Lit5Zu95bu66K6+6ZO26KGM5L+h55So5Y2h55S15a2Q6LSm5Y2V?=",
		"Content-Type: multipart/mixed; boundary=\"ccb-test\"",
		"",
		"--ccb-test",
		"Content-Type: text/html; charset=utf-8",
		"Content-Transfer-Encoding: base64",
		"",
		"PCFET0NUWVBFIEhUTUw+PGh0bWw+PC9odG1sPg==",
		"--ccb-test--",
	}, "\r\n")
	detection, err = detectImportProvider("statement.eml", []byte(encodedEmail), "")
	if err != nil || detection.Provider != "ccb-credit" {
		t.Fatalf("unexpected encoded EML detection: %#v err=%v", detection, err)
	}
}

func TestCcbCreditAllPlatformPreview(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), strings.Join([]string{
		"2026-01-01 open Assets:Cash CNY",
		"2026-01-01 open Expenses:Food CNY",
		"2026-01-01 open Income:Salary CNY",
		"2026-01-01 open Liabilities:CN:CCB:CreditCard:7720 CNY",
		"2026-01-01 open Equity:Opening-Balances CNY",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "ccb-credit-card-config.yaml"), strings.Join([]string{
		"defaultCashAccount: Liabilities:CN:CCB:CreditCard:7720",
		"ccbCredit:",
		"  paymentSourceHandledExternally:",
		"    - 财付通-",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "scripts", "dedup_import.py"), "# test fixture\n")
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	var form bytes.Buffer
	writer := multipart.NewWriter(&form)
	part, err := writer.CreateFormFile("file", "中国建设银行信用卡电子账单.eml")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = part.Write([]byte(ccbCreditTestEmail([]string{
		"2026-06-13,2026-06-13,7720,财付通-滴滴出行,CNY,1.60,CNY,1.60",
	})))
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
		ImportID         string        `json:"importId"`
		Provider         string        `json:"provider"`
		Entries          []ImportEntry `json:"entries"`
		RawRowCount      int           `json:"rawRowCount"`
		FilteredRowCount int           `json:"filteredRowCount"`
		ExcludedRowCount int           `json:"excludedRowCount"`
		Warnings         []string      `json:"warnings"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &preview); err != nil {
		t.Fatal(err)
	}
	if preview.Provider != "ccb-credit" || len(preview.Entries) != 0 || preview.RawRowCount != 1 || preview.FilteredRowCount != 0 || preview.ExcludedRowCount != 1 {
		t.Fatalf("unexpected preview: %#v", preview)
	}
	if !strings.Contains(strings.Join(preview.Warnings, "\n"), "前置过滤") {
		t.Fatalf("preview warnings missing filter detail: %#v", preview.Warnings)
	}

	body, _ := json.Marshal(map[string]any{"importId": preview.ImportID, "provider": preview.Provider, "entries": preview.Entries})
	recorder = requestWithCookies(router, http.MethodPost, "/api/ledger/imports/commit", string(body), cookies)
	if recorder.Code != http.StatusOK {
		t.Fatalf("commit status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var commitResult struct {
		OK       bool   `json:"ok"`
		Count    int    `json:"count"`
		BeanText string `json:"beanText"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &commitResult); err != nil {
		t.Fatal(err)
	}
	if !commitResult.OK || commitResult.Count != 0 || commitResult.BeanText != "" {
		t.Fatalf("unexpected commit result: %#v", commitResult)
	}
	importsDir := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "imports")
	files, err := os.ReadDir(importsDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 {
		t.Fatalf("expected one import file, got %d", len(files))
	}
	importText := string(mustRead(t, filepath.Join(importsDir, files[0].Name())))
	if !strings.Contains(importText, "document Liabilities:CN:CCB:CreditCard:7720") || strings.Contains(importText, "财付通-滴滴出行") {
		t.Fatalf("empty import output missing document or leaked platform row:\n%s", importText)
	}
}

func TestCcbCreditEmailParserWithFixture(t *testing.T) {
	fixture := strings.TrimSpace(os.Getenv("CCB_CREDIT_EMAIL_FIXTURE"))
	if fixture == "" {
		t.Skip("set CCB_CREDIT_EMAIL_FIXTURE to verify a real 建设银行信用卡 EML")
	}
	content := mustRead(t, fixture)
	detection, err := detectImportProvider(filepath.Base(fixture), content, "")
	if err != nil {
		t.Fatal(err)
	}
	if detection.Provider != "ccb-credit" {
		t.Fatalf("provider = %s", detection.Provider)
	}
	statement, err := parseCcbCreditStatementFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if len(statement.Rows) == 0 {
		t.Fatalf("expected statement rows, got %#v", statement)
	}
}

func ccbCreditTestEmail(csvRows []string) string {
	bodyRows := []string{}
	for _, row := range csvRows {
		cells := strings.Split(row, ",")
		bodyRows = append(bodyRows, strings.Join([]string{
			"<tr>",
			"<td>" + cells[0] + "</td>",
			"<td>" + cells[1] + "</td>",
			"<td>" + cells[2] + "</td>",
			"<td>" + cells[3] + "</td>",
			"<td>" + cells[4] + "</td>",
			"<td>" + cells[5] + "</td>",
			"<td>" + cells[6] + "</td>",
			"<td>" + cells[7] + "</td>",
			"</tr>",
		}, ""))
	}
	html := strings.Join([]string{
		"<html><body>",
		"<table><tr><td>本期账单日</td><td>2026-06-21</td></tr></table>",
		"<table><tr><td>账单周期</td><td>2026/06/13-2026/06/21</td></tr><tr><td>本期到期还款日</td><td>2026/07/10</td></tr></table>",
		"<table>",
		"<tr><td>【交易明细】</td></tr>",
		"<tr><td>交易日</td><td>银行记账日</td><td>卡号后四位</td><td>交易描述</td><td>交易币/金额</td><td>结算币/金额</td></tr>",
		strings.Join(bodyRows, "\n"),
		"</table>",
		"</body></html>",
	}, "\n")
	return strings.Join([]string{
		"From: service@vip.ccb.com",
		"To: ledger@example.test",
		"Subject: 中国建设银行信用卡电子账单",
		"Content-Type: text/html; charset=UTF-8",
		"",
		html,
	}, "\r\n")
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
