package app

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	degmt "github.com/deb-sig/double-entry-generator/v2/pkg/analyser/mt"
	degconfig "github.com/deb-sig/double-entry-generator/v2/pkg/config"
	"github.com/deb-sig/double-entry-generator/v2/pkg/ir"
	"github.com/spf13/viper"
)

// meituanCSVFixture mirrors the app export: a BOM, a free-text preamble, the
// table header, and order numbers padded with tabs.
func meituanCSVFixture(rows ...string) []byte {
	lines := []string{
		"\uFEFF美团交易账单明细",
		"美团用户名：[TEST]",
		"起始时间：[2026-05-01] 终止时间：[2026-05-31]",
		`""`,
		"共：3笔记录",
		"特别提示：",
		"1. 本明细与实际交易结果不符时，以实际交易情况为准",
		`""`,
		"【美团交易账单明细列表】",
		"交易创建时间,交易成功时间,交易类型,订单标题,收/支,支付方式,订单金额,实付金额,交易单号,商家单号,备注",
	}
	lines = append(lines, rows...)
	return []byte(strings.Join(lines, "\r\n") + "\r\n")
}

var meituanDefaultRows = []string{
	"2026-05-10 12:01:02,2026-05-10 12:01:05,支付,河南烩面单人餐,支出,汇丰银行信用卡(1234),¥36.00,¥33.48,\"26051011100401670006000394166443\t\",\"0_2204430449361044\t\",/",
	"2026-05-11 08:30:00,2026-05-11 08:30:01,支付,瑞幸咖啡,支出,微信支付,¥9.90,¥9.90,\"26051111100401670006000394166444\t\",\"0_2204430449361045\t\",/",
	"2026-05-12 19:00:00,2026-05-12 19:20:00,退款,河南烩面单人餐,收入,美团余额,￥5.00,￥5.00,\"2605120181541103443\t\",\"4981008581243837847AL7R600WKKG\t\",/",
}

func TestMeituanProviderDetectionComesBeforeAlipay(t *testing.T) {
	detection, err := detectBillProvider("export.csv", meituanCSVFixture(meituanDefaultRows...), "")
	if err != nil {
		t.Fatal(err)
	}
	if detection.Provider != "meituan" || detection.Confidence != "high" {
		t.Fatalf("detection = %#v", detection)
	}
	importer, ok := importProvider("meituan")
	if !ok {
		t.Fatal("missing meituan provider")
	}
	if importer.ImportEngine().ID() != "deg-module" || importer.ProviderConfig().DEGProviderID != "mt" || importer.ProviderConfig().Config != "imports/meituan-config.yaml" {
		t.Fatalf("unexpected importer: %s %#v", importer.ImportEngine().ID(), importer.ProviderConfig())
	}
	// An Alipay export still goes to Alipay.
	alipay := []byte("支付宝交易记录明细查询\n交易号,商家订单号,交易创建时间,付款时间,最近修改时间,交易来源地,类型,交易对方,商品名称,金额（元）,收/支\n")
	if detection, err := detectBillProvider("alipay.csv", alipay, ""); err != nil || detection.Provider != "alipay" {
		t.Fatalf("alipay detection = %#v, %v", detection, err)
	}
}

func TestPrepareMeituanInputNormalizesExport(t *testing.T) {
	cfg := testLedger(t)
	input := filepath.Join(t.TempDir(), "meituan.csv")
	mustWrite(t, input, string(meituanCSVFixture(meituanDefaultRows...)))
	server := &Server{cfg: cfg}
	prepared, err := server.prepareMeituanInput(input, "meituan-normalize")
	if err != nil {
		t.Fatal(err)
	}
	if prepared.RawRowCount != 3 || prepared.FilteredRowCount != 3 || prepared.DateStart != "2026-05-10" || prepared.DateEnd != "2026-05-12" {
		t.Fatalf("prepared = %#v", prepared)
	}
	normalized := string(mustRead(t, prepared.InputFile))
	if !strings.HasPrefix(normalized, "交易创建时间,") || strings.Contains(normalized, "美团用户名") || strings.ContainsAny(normalized, "\t\r\uFEFF") {
		t.Fatalf("normalized CSV kept the preamble, tabs or CRLF:\n%q", normalized)
	}
	if strings.Contains(normalized, "￥") || !strings.Contains(normalized, "¥5.00") || !strings.Contains(normalized, "¥33.48") {
		t.Fatalf("amounts not normalized:\n%s", normalized)
	}
}

func TestPrepareMeituanInputRejectsBrokenRows(t *testing.T) {
	cfg := testLedger(t)
	server := &Server{cfg: cfg}
	for name, content := range map[string][]byte{
		"no header":  []byte("美团交易账单明细\n共：0笔记录\n"),
		"short row":  meituanCSVFixture("2026-05-10 12:01:02,2026-05-10 12:01:05,支付,烩面"),
		"bad amount": meituanCSVFixture("2026-05-10 12:01:02,2026-05-10 12:01:05,支付,烩面,支出,美团余额,¥36.00,abc,1,2,/"),
		"bad time":   meituanCSVFixture("2026/05/10,2026-05-10 12:01:05,支付,烩面,支出,美团余额,¥36.00,¥36.00,1,2,/"),
		"bad type":   meituanCSVFixture("2026-05-10 12:01:02,2026-05-10 12:01:05,支付,烩面,出账,美团余额,¥36.00,¥36.00,1,2,/"),
		"no rows":    meituanCSVFixture(),
	} {
		input := filepath.Join(t.TempDir(), "meituan.csv")
		mustWrite(t, input, string(content))
		if _, err := server.prepareMeituanInput(input, "meituan-broken"); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestExampleMeituanConfigMapsHSBCAndSkipsWalletPayments(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "examples", "preview-ledger", "imports", "meituan-config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	reader := viper.New()
	reader.SetConfigType("yaml")
	if err := reader.ReadConfig(bytes.NewReader(raw)); err != nil {
		t.Fatal(err)
	}
	config := &degconfig.Config{}
	if err := reader.Unmarshal(config); err != nil {
		t.Fatal(err)
	}
	analyser := degmt.MT{}
	for method, want := range map[string]string{
		"汇丰银行信用卡(1234)": testHSBCCard,
		"HSBC信用卡(1234)": testHSBCCard,
		"招商银行信用卡(0016)": "Liabilities:CN:CreditCard",
		"美团余额":          "Assets:CN:Meituan:Balance",
	} {
		order := &ir.Order{Item: "河南烩面单人餐", TypeOriginal: "支出", Type: ir.TypeSend, Method: method, Money: 33.48}
		ignore, minus, plus, _, _ := analyser.GetAccountsAndTags(order, config, "", "mt")
		if ignore || minus != want || plus != "Expenses:Food:Meals" {
			t.Errorf("%s: ignore=%v %s -> %s, want %s -> Expenses:Food:Meals", method, ignore, minus, plus, want)
		}
	}
	for _, method := range []string{"微信支付", "支付宝"} {
		order := &ir.Order{Item: "瑞幸咖啡", TypeOriginal: "支出", Type: ir.TypeSend, Method: method, Money: 9.9}
		if ignore, _, _, _, _ := analyser.GetAccountsAndTags(order, config, "", "mt"); !ignore {
			t.Errorf("%s payments must be ignored", method)
		}
	}
	refund := &ir.Order{Item: "瑞幸咖啡", TypeOriginal: "收入", Type: ir.TypeRecv, Method: "汇丰银行信用卡(1234)", Money: 9.9}
	if _, minus, plus, _, _ := analyser.GetAccountsAndTags(refund, config, "", "mt"); minus != "Expenses:Food:Drinks" || plus != testHSBCCard {
		t.Errorf("refund: %s -> %s", minus, plus)
	}
}

// A Meituan order paid with the HSBC HK card is booked without a post date,
// exactly like an Alipay one; importing the HSBC statement later writes the
// bank post date onto it instead of adding a second copy.
func TestMeituanHSBCOrderGetsPostDateFromLaterHSBCImport(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "scripts", "dedup_import.py"), strings.Join([]string{
		"import shutil, sys",
		"args = sys.argv",
		"if '-o' in args:",
		"    shutil.copy(args[1], args[args.index('-o') + 1])",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "meituan-config.yaml"), strings.Join([]string{
		"defaultMinusAccount: Income:Salary",
		"defaultPlusAccount: Expenses:Food",
		"defaultCurrency: CNY",
		"mt:",
		"  rules:",
		"    - method: 美团余额",
		"      methodAccount: Assets:Cash",
		"    - method: 汇丰",
		"      methodAccount: " + testHSBCCard,
		"    - method: 微信支付",
		"      ignore: true",
		"    - type: 收入",
		"      targetAccount: Expenses:Food",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "hsbchk-credit-card-config.yaml"), strings.Join([]string{
		"defaultMinusAccount: Income:Salary",
		"defaultPlusAccount: Expenses:Food",
		"defaultCashAccount: " + testHSBCCard,
		"defaultCurrency: CNY",
		"hsbchk:",
		"  rules:",
		"    - item: PAYMENT - THANK YOU",
		"      targetAccount: Assets:Cash",
		"",
	}, "\n"))
	accounts := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"))) + "2026-01-01 open " + testHSBCCard + " CNY\n"
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), accounts)

	server := &Server{cfg: cfg, cache: NewLedgerCache(cfg)}
	server.writer = NewLedgerWriter(cfg, server.cache)
	ctx := context.Background()

	preview, err := server.createImportPreviewFromUploadsWithID(ctx, "meituanpreview1", "", false, importUpload{Filename: "美团账单.csv", Content: meituanCSVFixture(meituanDefaultRows...)}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if preview["provider"] != "meituan" {
		t.Fatalf("provider = %v", preview["provider"])
	}
	entries := preview["entries"].([]ImportEntry)
	if len(entries) != 2 {
		t.Fatalf("entries = %#v\n%s", entries, preview["generatedBean"])
	}
	warnings := strings.Join(preview["warnings"].([]string), "\n")
	if !strings.Contains(warnings, "美团账单行数核对通过：CSV 明细 3 条，配置忽略 1 条") || !strings.Contains(warnings, "补写汇丰记账日") {
		t.Fatalf("warnings = %s", warnings)
	}
	result, err := server.commitImport(ctx, "meituanpreview1", "meituan", entries)
	if err != nil {
		t.Fatal(err)
	}
	if result["count"] != 2 {
		t.Fatalf("commit = %#v", result)
	}
	written := result["beanText"].(string)
	if !regexp.MustCompile(regexp.QuoteMeta(testHSBCCard)+`\s+-33\.48 CNY`).MatchString(written) || !regexp.MustCompile(`Expenses:Food\s+-5\.00 CNY`).MatchString(written) || strings.Contains(written, "post_date") || !strings.Contains(written, `source: "美团"`) {
		t.Fatalf("meituan bean = %s", written)
	}

	statement := strings.Join([]string{
		strings.Join(hsbchkCreditCSVHeaders, ","),
		`10/05/2026,12/05/2026,MEITUAN,"-33.48",CNY,POSTED,MEITUAN PLATFORM,CHINA,CHN,DEBIT`,
		"",
	}, "\n")
	hsbc, err := server.createImportPreviewFromUploadsWithID(ctx, "meituanhsbc1", "hsbchk-credit", false, importUpload{Filename: "hsbc.csv", Content: []byte(statement)}, nil)
	if err != nil {
		t.Fatal(err)
	}
	fills := hsbc["postDateFills"].([]importPostDateFill)
	if len(fills) != 1 || fills[0].Narration != "河南烩面单人餐" || fills[0].PostDate != "12/05/2026" {
		t.Fatalf("fills = %#v", fills)
	}
	if got := hsbc["entries"].([]ImportEntry); len(got) != 0 {
		t.Fatalf("the bank row must not be imported a second time: %#v", got)
	}
	if _, err := server.commitImport(ctx, "meituanhsbc1", "hsbchk-credit", nil); err != nil {
		t.Fatal(err)
	}
	imported, err := filepath.Glob(filepath.Join(cfg.LedgerRoot, "transactions", "2026", "imports", "*-meituan-*.bean"))
	if err != nil || len(imported) != 1 {
		t.Fatalf("meituan import file = %v, %v", imported, err)
	}
	meituan := string(mustRead(t, imported[0]))
	if !strings.Contains(meituan, `"河南烩面单人餐"`+"\n"+`  merchantId: "0_2204430449361044"`+"\n"+`  method: "汇丰银行信用卡(1234)"`+"\n"+`  orderId: "26051011100401670006000394166443"`+"\n"+`  payTime: "2026-05-10 12:01:02 +0800 CST"`+"\n"+`  post_date: "12/05/2026"`) || strings.Count(meituan, "post_date:") != 1 {
		t.Fatalf("post date not written onto the Meituan entry:\n%s", meituan)
	}
	bankFiles, _ := filepath.Glob(filepath.Join(cfg.LedgerRoot, "transactions", "2026", "imports", "*-hsbchk-credit-*.bean"))
	for _, file := range bankFiles {
		if strings.Contains(string(mustRead(t, file)), "33.48") {
			t.Fatalf("the HSBC row was booked a second time in %s", file)
		}
	}
}

// A local ledger without imports/meituan-config.yaml still imports: every order
// is booked to an existing funding account, and WeChat/Alipay-paid orders are
// left to those bills.
func TestLocalDefaultMeituanConfigIgnoresWalletPayments(t *testing.T) {
	cfg := testLedger(t)
	cfg.localTransport = true
	server := &Server{cfg: cfg, cache: NewLedgerCache(cfg)}
	importer, _ := importProvider("meituan")
	config, err := loadDEGModuleConfig(context.Background(), server, importer.ProviderConfig())
	if err != nil {
		t.Fatal(err)
	}
	analyser := degmt.MT{}
	order := &ir.Order{Item: "烩面", TypeOriginal: "支出", Type: ir.TypeSend, Method: "美团余额", Money: 10}
	if ignore, minus, plus, _, _ := analyser.GetAccountsAndTags(order, config, "", "mt"); ignore || minus != "Assets:Cash" || plus != "Expenses:Food" {
		t.Fatalf("default order: ignore=%v %s -> %s", ignore, minus, plus)
	}
	order.Method = "微信支付"
	if ignore, _, _, _, _ := analyser.GetAccountsAndTags(order, config, "", "mt"); !ignore {
		t.Fatal("WeChat Pay orders must be ignored by default")
	}
}
