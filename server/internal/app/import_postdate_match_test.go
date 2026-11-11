package app

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testHSBCCard = "Liabilities:HK:HSBC:CreditCard"

func postDateTestTxn(date, payee, source string, amountCents int, line int, metadata map[string]MetadataValue) Transaction {
	if metadata == nil {
		metadata = map[string]MetadataValue{}
	}
	if source != "" {
		metadata["source"] = source
	}
	return Transaction{
		Date:     date,
		Payee:    payee,
		Metadata: metadata,
		Postings: []Posting{
			{Account: "Expenses:Food", Amount: -amountCents, Currency: "CNY"},
			{Account: testHSBCCard, Amount: amountCents, Currency: "CNY"},
		},
		Source: TransactionSource{File: "transactions/2026/10.bean", Line: line, Hash: payee + date},
	}
}

func postDateTestBankRow(date, postDate, payee, amount, status string) string {
	return strings.Join([]string{
		date + ` * "` + payee + `" "` + payee + `"`,
		`    post_date: "` + postDate + `"`,
		`    status: "` + status + `"`,
		`    credit_or_debit: "DEBIT"`,
		"    Expenses:Unknown " + amount + " CNY",
		"    " + testHSBCCard + " -" + amount + " CNY",
	}, "\n")
}

func TestMatchImportPostDatesFillsExactPairsAndHintsNearOnes(t *testing.T) {
	existing := []Transaction{
		postDateTestTxn("2026-10-12", "茶庄", "支付宝", -750, 10, nil),
		postDateTestTxn("2026-10-13", "河南早点", "支付宝", -3348, 20, nil),
		postDateTestTxn("2026-10-14", "魔盒", "支付宝", -120, 30, nil),
		postDateTestTxn("2026-10-14", "魔盒", "支付宝", -120, 40, nil),
		postDateTestTxn("2026-10-15", "便利店", "", -500, 50, nil),
		// A row the bank importer already wrote, plus an Alipay copy of it.
		postDateTestTxn("2026-10-16", "BANK ROW", "HSBC HK", -990, 60, map[string]MetadataValue{"post_date": "17/10/2026", "credit_or_debit": "DEBIT"}),
		postDateTestTxn("2026-10-16", "咖啡", "微信支付", -990, 70, nil),
	}
	bean := strings.Join([]string{
		postDateTestBankRow("2026-10-12", "13/10/2026", "APPLEPAY TEA", "7.50", "POSTED"),
		postDateTestBankRow("2026-10-13", "15/10/2026", "ELEME PLATFORM MERCHANT", "33.33", "POSTED"),
		postDateTestBankRow("2026-10-14", "15/10/2026", "MOHE", "1.20", "POSTED"),
		postDateTestBankRow("2026-10-14", "15/10/2026", "MOHE", "1.20", "POSTED"),
		postDateTestBankRow("2026-10-15", "16/10/2026", "PENDING SHOP", "5.00", "PENDING"),
		postDateTestBankRow("2026-10-16", "17/10/2026", "BANK ROW", "9.90", "POSTED"),
		postDateTestBankRow("2026-10-20", "21/10/2026", "UNMATCHED", "88.00", "POSTED"),
	}, "\n\n")

	result, err := matchImportPostDates(existing, bean)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Fills) != 3 {
		t.Fatalf("fills = %#v", result.Fills)
	}
	if result.Fills[0].Payee != "茶庄" || result.Fills[0].PostDate != "13/10/2026" {
		t.Fatalf("first fill = %#v", result.Fills[0])
	}
	if result.Fills[1].Target.Line == result.Fills[2].Target.Line || result.Fills[1].ID == result.Fills[2].ID || result.Fills[1].PostDate != "15/10/2026" {
		t.Fatalf("same-amount rows must fill distinct entries: %#v", result.Fills[1:])
	}
	hint, ok := result.Hints[postDateBankKey("2026-10-13", "15/10/2026", testHSBCCard, -3333, "CNY")]
	if len(result.Hints) != 1 || !ok || hint.Reason != duplicateHintAmountDiffers || hint.Amount != "-33.48" || hint.Source != "支付宝" {
		t.Fatalf("hints = %#v", result.Hints)
	}
	kept := strings.Join(result.Kept, "\n")
	for _, payee := range []string{"ELEME", "PENDING SHOP", "BANK ROW", "UNMATCHED"} {
		if !strings.Contains(kept, payee) {
			t.Fatalf("kept rows missing %s:\n%s", payee, kept)
		}
	}
	if strings.Contains(kept, "APPLEPAY TEA") || strings.Contains(kept, "MOHE") {
		t.Fatalf("filled rows must leave the import:\n%s", kept)
	}
	for _, fill := range result.Fills {
		if fill.Payee == "咖啡" {
			t.Fatalf("a row already imported by the bank must not fill its duplicate: %#v", fill)
		}
	}
}

func TestMatchImportPostDatesLeavesAmbiguousPairsForReview(t *testing.T) {
	t.Run("two bank rows, one entry", func(t *testing.T) {
		existing := []Transaction{postDateTestTxn("2026-10-12", "早餐", "支付宝", -1050, 10, nil)}
		bean := postDateTestBankRow("2026-10-11", "12/10/2026", "A", "10.50", "POSTED") + "\n\n" +
			postDateTestBankRow("2026-10-13", "14/10/2026", "B", "10.50", "POSTED")
		result, err := matchImportPostDates(existing, bean)
		if err != nil {
			t.Fatal(err)
		}
		if len(result.Fills) != 0 || len(result.Hints) != 1 || len(result.Kept) != 2 {
			t.Fatalf("result = %#v", result)
		}
		for _, hint := range result.Hints {
			if hint.Reason != duplicateHintAmbiguous {
				t.Fatalf("hint = %#v", hint)
			}
		}
	})
	t.Run("one bank row, two entries on either side", func(t *testing.T) {
		existing := []Transaction{
			postDateTestTxn("2026-10-11", "早餐", "支付宝", -1050, 10, nil),
			postDateTestTxn("2026-10-13", "早餐", "支付宝", -1050, 20, nil),
		}
		result, err := matchImportPostDates(existing, postDateTestBankRow("2026-10-12", "13/10/2026", "A", "10.50", "POSTED"))
		if err != nil {
			t.Fatal(err)
		}
		if len(result.Fills) != 0 || len(result.Hints) != 1 {
			t.Fatalf("result = %#v", result)
		}
	})
	t.Run("competitors already matched elsewhere", func(t *testing.T) {
		existing := []Transaction{
			postDateTestTxn("2026-10-11", "早餐", "支付宝", -1050, 10, nil),
			postDateTestTxn("2026-10-13", "早餐", "支付宝", -1050, 20, nil),
		}
		bean := postDateTestBankRow("2026-10-12", "13/10/2026", "A", "10.50", "POSTED") + "\n\n" +
			postDateTestBankRow("2026-10-14", "15/10/2026", "B", "10.50", "POSTED")
		result, err := matchImportPostDates(existing, bean)
		if err != nil {
			t.Fatal(err)
		}
		if len(result.Fills) != 2 || len(result.Hints) != 0 {
			t.Fatalf("result = %#v", result)
		}
	})
}

func TestInsertPostDateMetadataKeepsKeyOrderAndIsIdempotent(t *testing.T) {
	text := strings.Join([]string{
		`2026-09-10 * "友宝智能货柜" "售货柜"`,
		`  category: "日用百货"`,
		`  payTime: "2026-09-10 12:12:29 +0800 CST"`,
		`  source: "支付宝"`,
		"  Expenses:Food 1.50 CNY",
		"  " + testHSBCCard + " -1.50 CNY",
		"",
	}, "\n")
	fill := importPostDateFill{Target: TransactionSource{Line: 1}, Date: "2026-09-10", PostDate: "11/09/2026"}
	next, err := insertPostDateMetadata(text, fill, "hsbchk-credit:abc")
	if err != nil {
		t.Fatal(err)
	}
	want := `  payTime: "2026-09-10 12:12:29 +0800 CST"` + "\n" + `  post_date: "11/09/2026"` + "\n" + `  post_date_source: "hsbchk-credit:abc"` + "\n" + `  source: "支付宝"`
	if !strings.Contains(next, want) {
		t.Fatalf("unexpected insertion:\n%s", next)
	}
	again, err := insertPostDateMetadata(next, fill, "hsbchk-credit:abc")
	if err != nil {
		t.Fatal(err)
	}
	if again != next {
		t.Fatalf("second insertion changed the entry:\n%s", again)
	}
	if _, err := insertPostDateMetadata(text, importPostDateFill{Target: TransactionSource{Line: 1}, Date: "2026-09-11"}, "x"); err == nil {
		t.Fatal("a moved entry must fail the write")
	}
}

func setupPostDateCommit(t *testing.T, beanCheckExit string) (*Server, string, string) {
	t.Helper()
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit "+beanCheckExit+"\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "hsbchk-credit-card-config.yaml"), "defaultCashAccount: "+testHSBCCard+"\n")
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "scripts", "dedup_import.py"), "# test fixture\n")
	accounts := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"))) + "2026-01-01 open " + testHSBCCard + " CNY\n"
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), accounts)
	monthFile := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	month := string(mustRead(t, monthFile)) + strings.Join([]string{
		"",
		`2026-05-10 * "茶庄" "会员"`,
		`  payTime: "2026-05-10 09:00:00 +0800 CST"`,
		`  source: "支付宝"`,
		"  Expenses:Food 7.50 CNY",
		"  " + testHSBCCard + " -7.50 CNY",
		"",
	}, "\n")
	mustWrite(t, monthFile, month)

	server := &Server{cfg: cfg, cache: NewLedgerCache(cfg)}
	server.writer = NewLedgerWriter(cfg, server.cache)
	snapshot, err := server.cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	bean := postDateTestBankRow("2026-05-10", "11/05/2026", "APPLEPAY TEA", "7.50", "POSTED")
	match, err := matchImportPostDates(snapshot.Transactions, bean)
	if err != nil {
		t.Fatal(err)
	}
	if len(match.Fills) != 1 || len(match.Kept) != 0 {
		t.Fatalf("match = %#v", match)
	}

	ctx := context.Background()
	importID := "postdatefill1"
	sourceRaw := []byte("Transaction date,Post date\n10/05/2026,11/05/2026\n")
	sourceKey, err := server.putImportFile(ctx, importID, "original", sourceRaw)
	if err != nil {
		t.Fatal(err)
	}
	expected := 0
	meta := importMeta{
		Provider:           "hsbchk-credit",
		OriginalFilename:   "hsbc.csv",
		InputFile:          previewPath(cfg, importID, "original.csv"),
		InputFileKey:       sourceKey,
		ProviderDetection:  providerDetection{Provider: "hsbchk-credit", Reason: "test", Confidence: "high"},
		StatementHash:      sha256Hex(sourceRaw),
		DateStart:          "2026-05-10",
		DateEnd:            "2026-05-10",
		ExpectedEntryCount: &expected,
	}
	if err := server.writeImportMeta(ctx, importID, meta); err != nil {
		t.Fatal(err)
	}
	if err := server.savePostDateMatch(ctx, importID, match); err != nil {
		t.Fatal(err)
	}
	return server, importID, monthFile
}

func TestImportCommitWritesPostDateOntoMatchedEntry(t *testing.T) {
	server, importID, monthFile := setupPostDateCommit(t, "0")
	result, err := server.commitImport(context.Background(), importID, "hsbchk-credit", nil)
	if err != nil {
		t.Fatal(err)
	}
	if result["count"] != 0 || result["postDateFillCount"] != 1 {
		t.Fatalf("result = %#v", result)
	}
	month := string(mustRead(t, monthFile))
	if !strings.Contains(month, `  payTime: "2026-05-10 09:00:00 +0800 CST"`+"\n"+`  post_date: "11/05/2026"`+"\n"+`  post_date_source: "hsbchk-credit:`) {
		t.Fatalf("post date not written:\n%s", month)
	}
	if strings.Count(month, `"茶庄"`) != 1 {
		t.Fatalf("the purchase must not be duplicated:\n%s", month)
	}
}

func TestImportCommitHonorsExcludedPostDateFills(t *testing.T) {
	server, importID, monthFile := setupPostDateCommit(t, "0")
	match, err := server.loadPostDateMatch(context.Background(), importID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := server.commitImportWithOptions(context.Background(), importID, "hsbchk-credit", nil, []string{match.Fills[0].ID}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(mustRead(t, monthFile)), "post_date") {
		t.Fatal("a declined fill must not be written")
	}
}

func TestImportCommitRollsBackPostDateOnBeanCheckFailure(t *testing.T) {
	server, importID, monthFile := setupPostDateCommit(t, "1")
	before := string(mustRead(t, monthFile))
	if _, err := server.commitImport(context.Background(), importID, "hsbchk-credit", nil); err == nil {
		t.Fatal("expected bean-check failure")
	}
	if after := string(mustRead(t, monthFile)); after != before {
		t.Fatalf("post date must roll back:\n%s", after)
	}
}

func TestHsbcHKCreditPreviewMatchesExistingEntriesAndCommitFillsPostDate(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	// A pass-through dedup script, so the test sees exactly what the matcher
	// handed to deduplication.
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "scripts", "dedup_import.py"), strings.Join([]string{
		"import shutil, sys",
		"args = sys.argv",
		"if '-o' in args:",
		"    shutil.copy(args[1], args[args.index('-o') + 1])",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "hsbchk-credit-card-config.yaml"), strings.Join([]string{
		"defaultMinusAccount: Income:Salary",
		"defaultPlusAccount: Expenses:Food",
		"defaultCashAccount: " + testHSBCCard,
		"defaultCurrency: CNY",
		// DEG only books the card as the funding account once any rule exists.
		"hsbchk:",
		"  rules:",
		"    - item: PAYMENT - THANK YOU",
		"      targetAccount: Assets:Cash",
		"",
	}, "\n"))
	accounts := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"))) + "2026-01-01 open " + testHSBCCard + " CNY\n"
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), accounts)
	monthFile := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	mustWrite(t, monthFile, string(mustRead(t, monthFile))+strings.Join([]string{
		"",
		`2026-05-10 * "茶庄" "会员"`,
		`  source: "支付宝"`,
		"  Expenses:Food 7.50 CNY",
		"  " + testHSBCCard + " -7.50 CNY",
		"",
		`2026-05-13 * "河南早点" "外卖"`,
		`  source: "支付宝"`,
		"  Expenses:Food 33.48 CNY",
		"  " + testHSBCCard + " -33.48 CNY",
		"",
	}, "\n"))
	statement := strings.Join([]string{
		strings.Join(hsbchkCreditCSVHeaders, ","),
		`10/05/2026,11/05/2026,APPLEPAY TEA,"-7.50",CNY,POSTED,TEA SHOP,CHINA,CHN,DEBIT`,
		`13/05/2026,15/05/2026,ELEME,"-33.33",CNY,POSTED,ELEME PLATFORM MERCHANT,CHINA,CHN,DEBIT`,
		`20/05/2026,21/05/2026,APPLEPAY TAXI,"-88.00",CNY,POSTED,TAXI,CHINA,CHN,DEBIT`,
		"",
	}, "\n")

	server := &Server{cfg: cfg, cache: NewLedgerCache(cfg)}
	server.writer = NewLedgerWriter(cfg, server.cache)
	ctx := context.Background()
	preview, err := server.createImportPreviewFromUploadsWithID(ctx, "postdatepreview1", "hsbchk-credit", false, importUpload{Filename: "hsbc.csv", Content: []byte(statement)}, nil)
	if err != nil {
		t.Fatal(err)
	}
	entries := preview["entries"].([]ImportEntry)
	fills := preview["postDateFills"].([]importPostDateFill)
	if len(fills) != 1 || fills[0].Payee != "茶庄" || fills[0].PostDate != "11/05/2026" {
		t.Fatalf("fills = %#v\n%s", fills, preview["generatedBean"])
	}
	if len(entries) != 2 {
		t.Fatalf("entries = %#v", entries)
	}
	hinted := 0
	for _, entry := range entries {
		if entry.DuplicateHint != nil {
			hinted++
			if entry.Date != "2026-05-13" || entry.DuplicateHint.Payee != "河南早点" || entry.DuplicateHint.Reason != duplicateHintAmountDiffers {
				t.Fatalf("hinted entry = %#v / %#v", entry, entry.DuplicateHint)
			}
		}
	}
	if hinted != 1 || preview["skippedDuplicateCount"] != 0 {
		t.Fatalf("hinted=%d preview=%#v", hinted, preview)
	}
	if !strings.Contains(strings.Join(preview["warnings"].([]string), "\n"), "记账日匹配：1 条") {
		t.Fatalf("warnings = %#v", preview["warnings"])
	}

	// The rebuilt preview (another device, a reload) carries the same result.
	rebuilt, err := server.readImportPreview(ctx, "postdatepreview1")
	if err != nil {
		t.Fatal(err)
	}
	if raw, _ := json.Marshal(rebuilt["postDateFills"]); !strings.Contains(string(raw), "11/05/2026") {
		t.Fatalf("rebuilt fills = %s", raw)
	}

	// The user drops the near-duplicate and keeps the bank-only taxi ride.
	kept := []ImportEntry{}
	for _, entry := range entries {
		if entry.DuplicateHint == nil {
			kept = append(kept, entry)
		}
	}
	result, err := server.commitImport(ctx, "postdatepreview1", "hsbchk-credit", kept)
	if err != nil {
		t.Fatal(err)
	}
	if result["count"] != 1 || result["postDateFillCount"] != 1 {
		t.Fatalf("commit = %#v", result)
	}
	month := string(mustRead(t, monthFile))
	if !strings.Contains(month, `2026-05-10 * "茶庄" "会员"`+"\n"+`  post_date: "11/05/2026"`) || strings.Count(month, "post_date:") != 1 {
		t.Fatalf("post date not written onto the Alipay entry:\n%s", month)
	}
	written := result["beanText"].(string)
	if !strings.Contains(written, "88.00") || strings.Contains(written, "7.50") || strings.Contains(written, "33.33") {
		t.Fatalf("imported bean = %s", written)
	}
}
