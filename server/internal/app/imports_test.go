package app

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
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
	router := testRouter(t, cfg)
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

func TestDedupImportBeanTextUsesOrderIDAndSignature(t *testing.T) {
	existing := []Transaction{
		{
			Date:      "2026-05-24",
			Payee:     "便利店",
			Narration: "零食",
			Metadata:  map[string]MetadataValue{"orderId": "module-order", "statementHash": "statement-1"},
			Postings: []Posting{
				{Account: "Expenses:Food", Amount: 650, Currency: "CNY"},
				{Account: "Assets:Cash", Amount: -650, Currency: "CNY"},
			},
		},
		{
			Date:      "2026-05-25",
			Payee:     "咖啡",
			Narration: "拿铁",
			Metadata:  map[string]MetadataValue{"statementHash": "statement-1"},
			Postings: []Posting{
				{Account: "Expenses:Food", Amount: 2800, Currency: "CNY"},
				{Account: "Assets:Cash", Amount: -2800, Currency: "CNY"},
			},
		},
	}
	beanText := strings.Join([]string{
		`2026-05-24 * "便利店" "零食"`,
		`  orderId: "module-order"`,
		"  Expenses:Food                         6.50 CNY",
		"  Assets:Cash                          -6.50 CNY",
		"",
		`2026-05-25 * "咖啡" "拿铁"`,
		"  Expenses:Food                        28.00 CNY",
		"  Assets:Cash                         -28.00 CNY",
		"",
		`2026-05-26 * "书店" "书"`,
		"  Expenses:Books                       45.00 CNY",
		"  Assets:Cash                         -45.00 CNY",
		"",
	}, "\n")

	deduped, skipped, err := dedupImportBeanText(existing, beanText, "statement-1")
	if err != nil {
		t.Fatal(err)
	}
	if skipped != 2 {
		t.Fatalf("skipped=%d, want 2\ndeduped:\n%s", skipped, deduped)
	}
	if strings.Contains(deduped, "module-order") || strings.Contains(deduped, "咖啡") {
		t.Fatalf("deduped text still contains duplicates:\n%s", deduped)
	}
	if !strings.Contains(deduped, "书店") {
		t.Fatalf("deduped text dropped new transaction:\n%s", deduped)
	}
}

func TestDedupImportBeanTextFallsBackToFundingPosting(t *testing.T) {
	existing := []Transaction{
		{
			Date:      "2026-05-24",
			Payee:     "Edited Payee",
			Narration: "Edited category",
			Postings: []Posting{
				{Account: "Expenses:Groceries", Amount: 650, Currency: "CNY"},
				{Account: "Assets:CN:Wechat:Balance", Amount: -650, Currency: "CNY"},
			},
		},
	}
	beanText := strings.Join([]string{
		`2026-05-24 * "Original Payee" "Original narration"`,
		"  Expenses:Food                         6.50 CNY",
		"  Assets:CN:Wechat:Balance             -6.50 CNY",
		"",
		`2026-05-25 * "Original Payee" "Original narration"`,
		"  Expenses:Food                         6.50 CNY",
		"  Assets:CN:Wechat:Balance             -6.50 CNY",
		"",
	}, "\n")

	deduped, skipped, err := dedupImportBeanText(existing, beanText, "")
	if err != nil {
		t.Fatal(err)
	}
	if skipped != 1 {
		t.Fatalf("skipped=%d, want 1\ndeduped:\n%s", skipped, deduped)
	}
	if strings.Contains(deduped, "2026-05-24") || !strings.Contains(deduped, "2026-05-25") {
		t.Fatalf("unexpected deduped text:\n%s", deduped)
	}
}

func TestImportProvidersEndpoint(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := testRouter(t, cfg)
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
	if len(response.Providers) != 6 {
		t.Fatalf("providers = %#v", response.Providers)
	}
	if response.Providers[0].ID != "alipay" || response.Providers[1].ID != "alipay-small-purse" || response.Providers[2].ID != "wechat" || response.Providers[3].ID != "cmb" || response.Providers[4].ID != "ccb-credit" || response.Providers[5].ID != "cmb-checking" {
		t.Fatalf("unexpected provider order: %#v", response.Providers)
	}
	if response.Providers[4].Label != "建设银行信用卡" || response.Providers[4].Accept != ".eml / .html / .htm / .csv" {
		t.Fatalf("unexpected ccb metadata: %#v", response.Providers[4])
	}
	if response.Providers[0].Engine != "deg-module" || response.Providers[1].Engine != "native-alipay-small-purse" || response.Providers[4].Engine != "native-ccb-credit" || response.Providers[5].Engine != "deg-module" {
		t.Fatalf("unexpected provider engines: %#v", response.Providers)
	}
	if response.Providers[5].Label != "招商银行储蓄卡" || response.Providers[5].Accept != ".pdf / .csv" {
		t.Fatalf("unexpected checking metadata: %#v", response.Providers[5])
	}
}

func writeAlipayImportRequirements(t *testing.T, cfg Config) {
	t.Helper()
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
}

func fakeDedupPython(t *testing.T) string {
	t.Helper()
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
	return fakePython
}

func alipayCSVFixture() []byte {
	return []byte(strings.Join([]string{
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
}

func TestAlipaySmallPurseImportGeneratesSharedPoolEntries(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "alipay-config.yaml"), strings.Join([]string{
		"defaultPlusAccount: Expenses:Food",
		"defaultCurrency: CNY",
		"alipaySmallPurse:",
		"  cashAccount: Assets:Cash",
		"  partnerLiabilityAccount: Liabilities:Payable:Friends:SmallPurse",
		"  rules:",
		"    - item: 盒马",
		"      targetAccount: Expenses:Food",
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "支付宝小荷包余额收支明细.xlsx")
	mustWriteAlipaySmallPurseXLSX(t, input)

	detection, err := detectBillProvider(filepath.Base(input), mustRead(t, input), "")
	if err != nil {
		t.Fatal(err)
	}
	if detection.Provider != "alipay-small-purse" {
		t.Fatalf("provider = %s", detection.Provider)
	}

	server := &Server{cfg: cfg}
	prepared, err := server.prepareAlipaySmallPurseInput(input, "smallpurse")
	if err != nil {
		t.Fatal(err)
	}
	if prepared.RawRowCount != 2 || prepared.FilteredRowCount != 2 || prepared.DateStart != "2026-06-22" || prepared.DateEnd != "2026-06-25" {
		t.Fatalf("unexpected prepared input: %#v", prepared)
	}

	output := filepath.Join(t.TempDir(), "smallpurse.bean")
	importer, ok := importProvider("alipay-small-purse")
	if !ok {
		t.Fatal("missing alipay-small-purse provider")
	}
	if err := importer.Generate(context.Background(), server, prepared, output); err != nil {
		t.Fatal(err)
	}
	generated := string(mustRead(t, output))
	for _, want := range []string{
		`source: "支付宝小荷包"`,
		`orderId: "topup-order"`,
		`Assets:Cash`,
		`500.00 CNY`,
		`Liabilities:Payable:Friends:SmallPurse`,
		`-500.00 CNY`,
		`orderId: "spend-order"`,
		`Expenses:Food`,
		`67.95 CNY`,
		`67.94 CNY`,
		`-135.89 CNY`,
	} {
		if !strings.Contains(generated, want) {
			t.Fatalf("generated bean missing %q:\n%s", want, generated)
		}
	}
	entries, err := parsePreviewEntries(generated)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 || entries[1].CategoryAccount != "Expenses:Food" || entries[1].FundingAccount != "Assets:Cash" {
		t.Fatalf("unexpected preview entries: %#v", entries)
	}
}

func TestAlipaySmallPurseRunningContributionBalanceUsesTimedTopups(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "alipay-config.yaml"), strings.Join([]string{
		"defaultPlusAccount: Expenses:Food",
		"defaultCurrency: CNY",
		"alipaySmallPurse:",
		"  cashAccount: Assets:SmallPurse",
		"  partnerLiabilityAccount: Liabilities:Payable:Friends:SmallPurse",
		"  allocationMode: runningContributionBalance",
		"  ownerNames:",
		"    - 乔博睿",
		"  partnerNames:",
		"    - 何缘立",
		"  rules:",
		"    - item: 盒马",
		"      targetAccount: Expenses:Food",
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "支付宝小荷包余额收支明细.xlsx")
	mustWriteAlipaySmallPurseRowsXLSX(t, input, []alipaySmallPurseTestRow{
		{OrderID: "late-spend", DateTime: "2026-07-05 12:00:00", Description: "盒马 晚饭", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Expense: "130.00"},
		{OrderID: "partner-topup", DateTime: "2026-07-04 12:00:00", Description: "转入", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Income: "500.00"},
		{OrderID: "middle-spend", DateTime: "2026-07-03 18:00:00", Description: "盒马 午饭", OperatorNick: "borui", OperatorName: "乔博睿", Expense: "100.00"},
		{OrderID: "owner-topup", DateTime: "2026-07-02 12:00:00", Description: "转入", OperatorNick: "borui", OperatorName: "乔博睿", Income: "800.00"},
		{OrderID: "early-spend", DateTime: "2026-07-01 12:00:00", Description: "盒马 早饭", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Expense: "100.00"},
	})

	server := &Server{cfg: cfg}
	output := filepath.Join(t.TempDir(), "smallpurse.bean")
	importer, ok := importProvider("alipay-small-purse")
	if !ok {
		t.Fatal("missing alipay-small-purse provider")
	}
	prepared, err := importer.Prepare(server, importFileInput{InputFile: input})
	if err != nil {
		t.Fatal(err)
	}
	if prepared.RawRowCount != 5 || prepared.FilteredRowCount != 4 || prepared.PrefilterSkipped != 1 {
		t.Fatalf("unexpected prepared row counts: %#v", prepared)
	}
	if _, err := importer.PreviewWarnings(prepared, providerSourceAnalysis{}, beanSummary{CandidateCount: 4}, beanSummary{CandidateCount: 4}, ""); err != nil {
		t.Fatal(err)
	}
	if err := importer.Generate(context.Background(), server, preparedImportInput{InputFile: input}, output); err != nil {
		t.Fatal(err)
	}

	generated := string(mustRead(t, output))
	for _, want := range []string{
		`orderId: "early-spend"`,
		`Expenses:Food                                 50.00 CNY`,
		`orderId: "middle-spend"`,
		`Expenses:Food                                100.00 CNY`,
		`orderId: "partner-topup"`,
		`orderId: "late-spend"`,
		`Expenses:Food                                 76.82 CNY`,
	} {
		if !strings.Contains(generated, want) {
			t.Fatalf("generated bean missing %q:\n%s", want, generated)
		}
	}
	requirePostingLine(t, generated, "Liabilities:Payable:Friends:SmallPurse", "50.00")
	requirePostingLine(t, generated, "Liabilities:Payable:Friends:SmallPurse", "-500.00")
	requirePostingLine(t, generated, "Liabilities:Payable:Friends:SmallPurse", "53.18")
	if strings.Contains(generated, `orderId: "owner-topup"`) {
		t.Fatalf("owner topup should be ignored after updating contribution balance:\n%s", generated)
	}
	middleStart := strings.Index(generated, `orderId: "middle-spend"`)
	partnerStart := strings.Index(generated, `orderId: "partner-topup"`)
	if middleStart < 0 || partnerStart < 0 || middleStart > partnerStart {
		t.Fatalf("small purse entries were not rendered chronologically:\n%s", generated)
	}
}

func TestAlipaySmallPurseFiltersFullyRefundedGroups(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "alipay-config.yaml"), strings.Join([]string{
		"defaultPlusAccount: Expenses:Food",
		"defaultCurrency: CNY",
		"alipaySmallPurse:",
		"  cashAccount: Assets:SmallPurse",
		"  partnerLiabilityAccount: Liabilities:Payable:Friends:SmallPurse",
		"  rules:",
		"    - item: 正常消费",
		"      targetAccount: Expenses:Food",
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "支付宝小荷包余额收支明细.xlsx")
	mustWriteAlipaySmallPurseRowsXLSX(t, input, []alipaySmallPurseTestRow{
		{OrderID: "normal-spend", DateTime: "2026-06-30 18:00:00", Description: "正常消费", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Expense: "10.00"},
		{OrderID: "2026063004200214001066007061_20260630300002007006141238430705", DateTime: "2026-06-30 17:15:49", Description: "退款-盒马工坊 手作老面香菇青菜包 200g等多件", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Income: "0.92"},
		{OrderID: "2026063004200214001066007061_20260630300002007006141237920970", DateTime: "2026-06-30 17:15:43", Description: "退款-盒马工坊 手作老面香菇青菜包 200g等多件", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Income: "24.90"},
		{OrderID: "2026063004200214001066007061_20260630300002007006141237852037", DateTime: "2026-06-30 17:15:06", Description: "退款-盒马工坊 手作老面香菇青菜包 200g等多件", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Income: "19.90"},
		{OrderID: "2026063004200214001066007061_20260630300002007006141237673911", DateTime: "2026-06-30 17:15:03", Description: "退款-盒马工坊 手作老面香菇青菜包 200g等多件", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Income: "4.28"},
		{OrderID: "2026063004200214001066007061_20260630300002007006141239623775", DateTime: "2026-06-30 17:15:00", Description: "退款-盒马工坊 手作老面香菇青菜包 200g等多件", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Income: "6.90"},
		{OrderID: "2026063004200214001066007061", DateTime: "2026-06-30 16:49:52", Description: "已退款 - 盒马工坊 手作老面香菇青菜包 200g等多件", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Expense: "56.90"},
	})

	server := &Server{cfg: cfg}
	output := filepath.Join(t.TempDir(), "smallpurse.bean")
	importer, ok := importProvider("alipay-small-purse")
	if !ok {
		t.Fatal("missing alipay-small-purse provider")
	}
	prepared, err := importer.Prepare(server, importFileInput{InputFile: input})
	if err != nil {
		t.Fatal(err)
	}
	if prepared.RawRowCount != 7 || prepared.FilteredRowCount != 1 || prepared.PrefilterSkipped != 6 {
		t.Fatalf("unexpected prepared row counts: %#v", prepared)
	}
	if _, err := importer.PreviewWarnings(prepared, providerSourceAnalysis{}, beanSummary{CandidateCount: 1}, beanSummary{CandidateCount: 1}, ""); err != nil {
		t.Fatal(err)
	}
	if err := importer.Generate(context.Background(), server, preparedImportInput{InputFile: input}, output); err != nil {
		t.Fatal(err)
	}

	generated := string(mustRead(t, output))
	if strings.Count(generated, `source: "支付宝小荷包"`) != 1 {
		t.Fatalf("unexpected generated entries:\n%s", generated)
	}
	if strings.Contains(generated, "2026063004200214001066007061") {
		t.Fatalf("fully refunded group should be filtered:\n%s", generated)
	}
	if !strings.Contains(generated, `orderId: "normal-spend"`) {
		t.Fatalf("normal spend should be kept:\n%s", generated)
	}
}

func TestAlipaySmallPurseRunningContributionBalanceUsesLedgerHistory(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "alipay-config.yaml"), strings.Join([]string{
		"defaultPlusAccount: Expenses:Food",
		"defaultCurrency: CNY",
		"alipaySmallPurse:",
		"  cashAccount: Assets:SmallPurse",
		"  partnerLiabilityAccount: Liabilities:Payable:Friends:SmallPurse",
		"  allocationMode: runningContributionBalance",
		"  ownerNames:",
		"    - 乔博睿",
		"  partnerNames:",
		"    - 何缘立",
		"  rules:",
		"    - item: 盒马",
		"      targetAccount: Expenses:Food",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "imports", "small-purse-history.bean"), strings.Join([]string{
		`2026-06-28 * "支付宝小荷包(草莓汤圆的恋爱开支)" "支付宝小荷包-转入"`,
		`  source: "支付宝"`,
		`  Assets:SmallPurse 800.00 CNY`,
		`  Assets:CN:MYBank:Yulibao -800.00 CNY`,
		"",
		`2026-06-29 * "盒马" "历史消费"`,
		`  source: "支付宝小荷包"`,
		`  type: "支出"`,
		`  Expenses:Food 50.00 CNY`,
		`  Liabilities:Payable:Friends:SmallPurse 50.00 CNY`,
		`  Assets:SmallPurse -100.00 CNY`,
		"",
		`2026-06-30 * "支付宝小荷包(草莓汤圆的恋爱开支)" "转入"`,
		`  source: "支付宝小荷包"`,
		`  type: "收入"`,
		`  Assets:SmallPurse 500.00 CNY`,
		`  Liabilities:Payable:Friends:SmallPurse -500.00 CNY`,
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "main.bean"), strings.Join([]string{
		`option "title" "Test Ledger"`,
		`option "operating_currency" "CNY"`,
		`include "commodities.bean"`,
		`include "accounts.bean"`,
		`include "prices.bean"`,
		`include "transactions/2026/05.bean"`,
		`include "transactions/2026/imports/small-purse-history.bean"`,
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "支付宝小荷包余额收支明细.xlsx")
	mustWriteAlipaySmallPurseRowsXLSX(t, input, []alipaySmallPurseTestRow{
		{OrderID: "current-spend", DateTime: "2026-07-05 12:00:00", Description: "盒马 晚饭", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Expense: "130.00"},
	})

	server := &Server{cfg: cfg}
	output := filepath.Join(t.TempDir(), "smallpurse.bean")
	importer, ok := importProvider("alipay-small-purse")
	if !ok {
		t.Fatal("missing alipay-small-purse provider")
	}
	if err := importer.Generate(context.Background(), server, preparedImportInput{InputFile: input}, output); err != nil {
		t.Fatal(err)
	}

	generated := string(mustRead(t, output))
	for _, want := range []string{
		`orderId: "current-spend"`,
		`Expenses:Food                                 81.25 CNY`,
	} {
		if !strings.Contains(generated, want) {
			t.Fatalf("generated bean missing %q:\n%s", want, generated)
		}
	}
	requirePostingLine(t, generated, "Liabilities:Payable:Friends:SmallPurse", "48.75")
}

func TestAlipaySmallPurseRunningContributionBalanceUsesReadModelSnapshotInGitHubAPIMode(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"imports/alipay-config.yaml": strings.Join([]string{
			"defaultPlusAccount: Expenses:Food",
			"defaultCurrency: CNY",
			"alipaySmallPurse:",
			"  cashAccount: Assets:SmallPurse",
			"  partnerLiabilityAccount: Liabilities:Payable:Friends:SmallPurse",
			"  allocationMode: runningContributionBalance",
			"  ownerNames:",
			"    - 乔博睿",
			"  partnerNames:",
			"    - 何缘立",
			"  rules:",
			"    - item: 盒马",
			"      targetAccount: Expenses:Food",
			"",
		}, "\n"),
	})
	defer fake.server.Close()
	cfg := githubAPITestConfig(t, fake)
	cfg.LedgerStorage = "github_api"
	cfg.LedgerReadModel = "postgres"
	cfg.ReadModelStrict = true
	input := filepath.Join(t.TempDir(), "支付宝小荷包余额收支明细.xlsx")
	mustWriteAlipaySmallPurseRowsXLSX(t, input, []alipaySmallPurseTestRow{
		{OrderID: "read-model-spend", DateTime: "2026-07-05 12:00:00", Description: "盒马 晚饭", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Expense: "130.00"},
	})

	server := &Server{
		cfg: cfg,
		readService: fakeLedgerReadService{snapshot: &LedgerSnapshot{
			LedgerVersion: LedgerVersion{Version: "read-model"},
			Transactions: []Transaction{
				{Date: "2026-06-28", Postings: []Posting{
					{Account: "Assets:SmallPurse", Amount: 80000, Currency: "CNY"},
					{Account: "Assets:CN:MYBank:Yulibao", Amount: -80000, Currency: "CNY"},
				}},
				{Date: "2026-06-29", Postings: []Posting{
					{Account: "Expenses:Food", Amount: 5000, Currency: "CNY"},
					{Account: "Liabilities:Payable:Friends:SmallPurse", Amount: 5000, Currency: "CNY"},
					{Account: "Assets:SmallPurse", Amount: -10000, Currency: "CNY"},
				}},
				{Date: "2026-06-30", Postings: []Posting{
					{Account: "Assets:SmallPurse", Amount: 50000, Currency: "CNY"},
					{Account: "Liabilities:Payable:Friends:SmallPurse", Amount: -50000, Currency: "CNY"},
				}},
			},
		}},
	}
	output := filepath.Join(t.TempDir(), "smallpurse.bean")
	importer, ok := importProvider("alipay-small-purse")
	if !ok {
		t.Fatal("missing alipay-small-purse provider")
	}
	if err := importer.Generate(context.Background(), server, preparedImportInput{InputFile: input}, output); err != nil {
		t.Fatal(err)
	}

	generated := string(mustRead(t, output))
	for _, want := range []string{
		`orderId: "read-model-spend"`,
		`Expenses:Food                                 81.25 CNY`,
	} {
		if !strings.Contains(generated, want) {
			t.Fatalf("generated bean missing %q:\n%s", want, generated)
		}
	}
	requirePostingLine(t, generated, "Liabilities:Payable:Friends:SmallPurse", "48.75")
}

func TestAlipaySmallPurseFallbackRulesSkipGenericAlipayMethodIgnore(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "alipay-config.yaml"), strings.Join([]string{
		"defaultPlusAccount: Expenses:Unknown",
		"defaultCurrency: CNY",
		"alipay:",
		"  rules:",
		"    - method: 支付宝小荷包",
		"      ignore: true",
		"    - method: 余额",
		"      methodAccount: Assets:CN:Alipay:Balance",
		"    - item: 盒马",
		"      targetAccount: Expenses:Food",
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "支付宝小荷包余额收支明细.xlsx")
	mustWriteAlipaySmallPurseXLSX(t, input)

	server := &Server{cfg: cfg}
	output := filepath.Join(t.TempDir(), "smallpurse.bean")
	importer, ok := importProvider("alipay-small-purse")
	if !ok {
		t.Fatal("missing alipay-small-purse provider")
	}
	if err := importer.Generate(context.Background(), server, preparedImportInput{InputFile: input}, output); err != nil {
		t.Fatal(err)
	}

	generated := string(mustRead(t, output))
	if got := strings.Count(generated, `source: "支付宝小荷包"`); got != 2 {
		t.Fatalf("generated %d small purse entries, want 2:\n%s", got, generated)
	}
	if !strings.Contains(generated, `Expenses:Food`) {
		t.Fatalf("fallback item classification was not applied:\n%s", generated)
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

	ctx := context.Background()
	importID := "removeentry1"
	sourceFile := previewPath(cfg, importID, "original.csv")
	sourceRaw := []byte("交易创建时间,交易对方,金额\n2026-05-03,便利店,6.50\n")
	sourceFileKey, err := server.putImportFile(ctx, importID, "original", sourceRaw)
	if err != nil {
		t.Fatal(err)
	}
	expected := 2
	meta := importMeta{
		Provider:           "alipay",
		OriginalFilename:   "alipay.csv",
		InputFile:          sourceFile,
		InputFileKey:       sourceFileKey,
		ProviderDetection:  providerDetection{Provider: "alipay", Reason: "test", Confidence: "high"},
		StatementHash:      sha256Hex(sourceRaw),
		ExpectedEntryCount: &expected,
	}
	if err := server.writeImportMeta(ctx, importID, meta); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(sourceFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("source file should start missing, stat err = %v", err)
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
	result, err := server.commitImport(ctx, importID, "alipay", entries)
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

	_, err := server.writeImportedBeanFile(outputFile, monthFile, beanText, "alipay", "2026-06-01", "2026-06-02", sourceFile, documentFile, "Assets:Cash")
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
	err = degModuleImportEngine{}.Generate(context.Background(), server, importEngineInput{
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
	if err := importer.Generate(context.Background(), server, preparedImportInput{InputFile: input}, output); err != nil {
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
	if err := server.generateCcbCreditBean(context.Background(), normalized+".filtered", output); err != nil {
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
	router := testRouter(t, cfg)
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

type alipaySmallPurseTestRow struct {
	OrderID      string
	DateTime     string
	Description  string
	Remark       string
	OperatorNick string
	OperatorName string
	Income       string
	Expense      string
}

func mustWriteAlipaySmallPurseXLSX(t *testing.T, file string) {
	t.Helper()
	mustWriteAlipaySmallPurseRowsXLSX(t, file, []alipaySmallPurseTestRow{
		{OrderID: "topup-order", DateTime: "2026-06-22 21:58:03", Description: "转入", Remark: "", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Income: "500.00", Expense: ""},
		{OrderID: "spend-order", DateTime: "2026-06-25 17:26:07", Description: "盒马 4.0低脂高钙鲜牛奶 950ml等多件", Remark: "", OperatorNick: "阿一哒哒", OperatorName: "何缘立", Income: "", Expense: "135.89"},
	})
}

func mustWriteAlipaySmallPurseRowsXLSX(t *testing.T, file string, rows []alipaySmallPurseTestRow) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := os.Create(file)
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	zipper := zip.NewWriter(out)
	defer zipper.Close()
	writeZipText := func(name, text string) {
		t.Helper()
		writer, err := zipper.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte(text)); err != nil {
			t.Fatal(err)
		}
	}
	shared := []string{}
	sharedIndex := func(value string) int {
		for index, item := range shared {
			if item == value {
				return index
			}
		}
		shared = append(shared, value)
		return len(shared) - 1
	}
	var sharedXML strings.Builder
	periodStart, periodEnd := alipaySmallPurseTestPeriod(rows)
	metadataRows := [][]string{
		{"支付宝小荷包名称：草莓汤圆的恋爱开支"},
		{"支付宝小荷包账户ID：2088780263501952"},
		{fmt.Sprintf("收支明细对应的期间：自[%s]至[%s]", periodStart, periodEnd)},
		{"订单号", "交易时间", "交易说明", "备注", "操作人昵称", "操作人姓名", "收入金额", "支出金额"},
	}
	dataRows := make([][]string, 0, len(rows))
	for _, row := range rows {
		dataRows = append(dataRows, []string{row.OrderID, row.DateTime, row.Description, row.Remark, row.OperatorNick, row.OperatorName, row.Income, row.Expense})
	}
	sharedXML.WriteString(`<?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">`)
	for _, row := range append(metadataRows, dataRows...) {
		for _, value := range row {
			sharedIndex(value)
		}
	}
	for _, value := range shared {
		sharedXML.WriteString(`<si><t>`)
		sharedXML.WriteString(escapeTestXML(value))
		sharedXML.WriteString(`</t></si>`)
	}
	sharedXML.WriteString(`</sst>`)
	writeZipText("[Content_Types].xml", `<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>`)
	writeZipText("xl/workbook.xml", `<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></sheets></workbook>`)
	writeZipText("xl/sharedStrings.xml", sharedXML.String())
	var sheet strings.Builder
	sheet.WriteString(`<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>`)
	allRows := append(metadataRows, dataRows...)
	for rowIndex, row := range allRows {
		rowNumber := rowIndex + 1
		sheet.WriteString(fmt.Sprintf(`<row r="%d">`, rowNumber))
		for colIndex, value := range row {
			ref := fmt.Sprintf("%s%d", xlsxTestColumnName(colIndex), rowNumber)
			sheet.WriteString(fmt.Sprintf(`<c r="%s" t="s"><v>%d</v></c>`, ref, sharedIndex(value)))
		}
		sheet.WriteString(`</row>`)
	}
	sheet.WriteString(`</sheetData></worksheet>`)
	writeZipText("xl/worksheets/sheet1.xml", sheet.String())
}

func xlsxTestColumnName(index int) string {
	return string(rune('A' + index))
}

func escapeTestXML(value string) string {
	value = strings.ReplaceAll(value, "&", "&amp;")
	value = strings.ReplaceAll(value, "<", "&lt;")
	value = strings.ReplaceAll(value, ">", "&gt;")
	return value
}

func alipaySmallPurseTestPeriod(rows []alipaySmallPurseTestRow) (string, string) {
	start, end := "", ""
	for _, row := range rows {
		date := alipaySmallPurseDate(row.DateTime)
		if date == "" {
			continue
		}
		if start == "" || date < start {
			start = date
		}
		if end == "" || date > end {
			end = date
		}
	}
	if start == "" {
		start = "2026-06-22"
	}
	if end == "" {
		end = start
	}
	return alipaySmallPurseTestChineseDate(start), alipaySmallPurseTestChineseDate(end)
}

func alipaySmallPurseTestChineseDate(date string) string {
	parts := strings.Split(date, "-")
	if len(parts) != 3 {
		return "2026年06月22日"
	}
	return fmt.Sprintf("%s年%s月%s日", parts[0], parts[1], parts[2])
}

func requirePostingLine(t *testing.T, beanText, account, amount string) {
	t.Helper()
	pattern := regexp.MustCompile(`(?m)^\s+` + regexp.QuoteMeta(account) + `\s+` + regexp.QuoteMeta(amount) + `\s+CNY\b`)
	if !pattern.MatchString(beanText) {
		t.Fatalf("generated bean missing posting %s %s CNY:\n%s", account, amount, beanText)
	}
}

type fakeLedgerReadService struct {
	snapshot *LedgerSnapshot
}

func (s fakeLedgerReadService) Version(context.Context) (LedgerVersion, error) {
	return s.snapshot.LedgerVersion, nil
}

func (s fakeLedgerReadService) Snapshot(context.Context) (*LedgerSnapshot, error) {
	return s.snapshot, nil
}

func (s fakeLedgerReadService) SnapshotLite(context.Context) (*LedgerSnapshot, error) {
	return s.snapshot, nil
}

func (s fakeLedgerReadService) Bootstrap(string, string, bool, ...string) (gin.H, error) {
	return nil, errors.New("unused fake ledger read service method")
}

func (s fakeLedgerReadService) BootstrapLite(string, string, bool, ...string) (gin.H, error) {
	return nil, errors.New("unused fake ledger read service method")
}

func (s fakeLedgerReadService) Summary(string, string, bool, ...string) (gin.H, error) {
	return nil, errors.New("unused fake ledger read service method")
}

func (s fakeLedgerReadService) Transactions(string, string, bool) (gin.H, error) {
	return nil, errors.New("unused fake ledger read service method")
}

func (s fakeLedgerReadService) Balances(context.Context) (map[string]int, []BalanceAssertion, error) {
	return nil, nil, errors.New("unused fake ledger read service method")
}

func (s fakeLedgerReadService) IncomeStatement(string, string, bool, ...string) (gin.H, error) {
	return nil, errors.New("unused fake ledger read service method")
}
