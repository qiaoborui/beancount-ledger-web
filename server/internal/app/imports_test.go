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
)

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
	if preview.Entries[0].OrderID != "alipay-1" || preview.Entries[0].CategoryAccount != "Expenses:Food" {
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
	if filepath.Ext(documents[0].Name()) != ".pdf" {
		t.Fatalf("expected archived original PDF, got %s", documents[0].Name())
	}
	documentText := string(mustRead(t, filepath.Join(documentsDir, documents[0].Name())))
	if documentText != "%PDF original statement" {
		t.Fatalf("archived document content = %q", documentText)
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

func TestCmbCheckingImportHelpers(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "cmb-checking-config.yaml"), strings.Join([]string{
		"defaultDebitAccount: Expenses:Food",
		"defaultCreditAccount: Income:Salary",
		"cashAccount: Assets:Cash",
		"defaultCurrency: CNY",
		"cmbChecking:",
		"  rules:",
		"    - item: 掌上生活还款",
		"      targetAccount: Liabilities:CN:CMB:CreditCard",
		"    - item: 摩拜,岭南通",
		"      targetAccount: Expenses:Food",
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "cmb-checking.csv")
	output := filepath.Join(t.TempDir(), "cmb-checking.bean")
	mustWrite(t, input, strings.Join([]string{
		"记账日期,货币,交易金额,联机余额,交易摘要,对手信息",
		"2026-05-20,CNY,100.00,106.31,网联收款,乔博睿 10563996799",
		"2026-05-20,CNY,-50.00,56.31,银联线上有卡支付,广东岭南通股份有限公司308999841110034",
		"2026-06-05,CNY,\"-11,595.81\",\"1,459.63\",掌上生活还款,乔博睿 4514617564329813",
	}, "\n"))

	detection, err := detectBillProvider("招商银行交易流水.pdf.csv", []byte(mustRead(t, input)), "")
	if err != nil {
		t.Fatal(err)
	}
	if detection.Provider != "cmb-checking" {
		t.Fatalf("provider = %s", detection.Provider)
	}

	server := &Server{cfg: cfg}
	if err := server.generateCmbCheckingBean(input, output); err != nil {
		t.Fatal(err)
	}
	generated := string(mustRead(t, output))
	if !strings.Contains(generated, `source: "cmb-checking"`) || !strings.Contains(generated, `Assets:Cash`) {
		t.Fatalf("generated bean missing checking metadata or cash account:\n%s", generated)
	}
	if !strings.Contains(generated, `Liabilities:CN:CMB:CreditCard`) || !strings.Contains(generated, `11595.81 CNY`) {
		t.Fatalf("generated bean missing credit-card repayment posting:\n%s", generated)
	}
	entries, err := parsePreviewEntries(generated)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 || entries[0].Source != "cmb-checking" || entries[1].FundingAccount != "Assets:Cash" {
		t.Fatalf("unexpected preview entries: %#v", entries)
	}

	accounts := map[string]bool{"Assets:CN:CMB:Checking": true, "Liabilities:CN:CMB:CreditCard": true}
	if got := providerDocumentAccount("cmb-checking", accounts, "Liabilities:CN:CMB:CreditCard"); got != "Assets:CN:CMB:Checking" {
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
