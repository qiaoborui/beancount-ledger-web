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
