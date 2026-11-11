package app

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func setupPostDateBackfill(t *testing.T) (*Server, string) {
	t.Helper()
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "scripts", "dedup_import.py"), "# test fixture\n")
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
		`2026-05-16 * "STARBUCKS" "APPLEPAY STARBUCKS"`,
		`  credit_or_debit: "DEBIT"`,
		`  post_date: "17/05/2026"`,
		`  source: "HSBC HK"`,
		`  status: "POSTED"`,
		"  Expenses:Food 9.90 CNY",
		"  " + testHSBCCard + " -9.90 CNY",
		"",
		`2026-05-16 * "星巴克" "咖啡"`,
		`  source: "微信支付"`,
		"  Expenses:Food 9.90 CNY",
		"  " + testHSBCCard + " -9.90 CNY",
		"",
	}, "\n"))
	header := strings.Join(hsbchkCreditCSVHeaders, ",")
	tea := `10/05/2026,11/05/2026,APPLEPAY TEA,"-7.50",CNY,POSTED,TEA SHOP,CHINA,CHN,DEBIT`
	documents := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "documents", "imports")
	// Two exports whose ranges overlap on the tea purchase.
	mustWrite(t, filepath.Join(documents, "2026-05-10_2026-05-13-hsbchk-credit-first.csv"), strings.Join([]string{
		header, tea,
		`13/05/2026,15/05/2026,ELEME,"-33.33",CNY,POSTED,ELEME PLATFORM MERCHANT,CHINA,CHN,DEBIT`,
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(documents, "2026-05-10_2026-05-16-hsbchk-credit-second.csv"), strings.Join([]string{
		header, tea,
		`16/05/2026,17/05/2026,APPLEPAY STARBUCKS,"-9.90",CNY,POSTED,STARBUCKS,CHINA,CHN,DEBIT`,
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(documents, "2026-05-01_2026-05-31-alipay-ignored.csv"), "not a statement\n")
	server := &Server{cfg: cfg, cache: NewLedgerCache(cfg)}
	server.writer = NewLedgerWriter(cfg, server.cache)
	return server, monthFile
}

func TestPostDateBackfillPreviewFillsReviewsAndReportsDuplicates(t *testing.T) {
	server, _ := setupPostDateBackfill(t)
	result, err := server.buildPostDateBackfill(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.Documents != 2 || result.BankRows != 3 || len(result.Warnings) != 0 {
		t.Fatalf("documents=%d rows=%d warnings=%v", result.Documents, result.BankRows, result.Warnings)
	}
	if len(result.Fills) != 1 || result.Fills[0].Payee != "茶庄" || result.Fills[0].PostDate != "11/05/2026" || !strings.HasPrefix(result.Fills[0].Source, "hsbchk-credit:") {
		t.Fatalf("fills = %#v", result.Fills)
	}
	if len(result.Reviews) != 1 || result.Reviews[0].BankPayee != "ELEME PLATFORM MERCHANT" || result.Reviews[0].Hint.Payee != "河南早点" {
		t.Fatalf("reviews = %#v", result.Reviews)
	}
	if len(result.PossibleDuplicates) != 1 {
		t.Fatalf("duplicates = %#v", result.PossibleDuplicates)
	}
	duplicate := result.PossibleDuplicates[0]
	if duplicate.Bank.Payee != "STARBUCKS" || duplicate.Existing.Payee != "星巴克" || duplicate.AmountDiff != "0.00" || duplicate.Existing.Line == 0 {
		t.Fatalf("duplicate = %#v", duplicate)
	}
	if result.MissingPostDate != 3 {
		t.Fatalf("missing post date = %d", result.MissingPostDate)
	}
}

func TestPostDateBackfillApplyWritesSelectedFillsOnce(t *testing.T) {
	server, monthFile := setupPostDateBackfill(t)
	ctx := context.Background()
	if _, err := server.applyPostDateBackfill(ctx, nil); err == nil {
		t.Fatal("an empty selection must fail")
	}
	if _, err := server.applyPostDateBackfill(ctx, []string{"stale-id"}); err == nil {
		t.Fatal("a stale selection must fail")
	}
	preview, err := server.buildPostDateBackfill(ctx)
	if err != nil {
		t.Fatal(err)
	}
	result, err := server.applyPostDateBackfill(ctx, []string{preview.Fills[0].ID})
	if err != nil {
		t.Fatal(err)
	}
	if result["count"] != 1 {
		t.Fatalf("result = %#v", result)
	}
	month := string(mustRead(t, monthFile))
	want := `2026-05-10 * "茶庄" "会员"` + "\n" + `  post_date: "11/05/2026"` + "\n" + `  post_date_source: "` + preview.Fills[0].Source + `"` + "\n" + `  source: "支付宝"`
	if !strings.Contains(month, want) || strings.Count(month, "post_date_source") != 1 {
		t.Fatalf("post date not written:\n%s", month)
	}
	if _, err := server.applyPostDateBackfill(ctx, []string{preview.Fills[0].ID}); err == nil {
		t.Fatal("re-applying a written fill must fail instead of writing twice")
	}
	again, err := server.buildPostDateBackfill(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(again.Fills) != 0 || again.MissingPostDate != 2 {
		t.Fatalf("rerun fills=%#v missing=%d", again.Fills, again.MissingPostDate)
	}
}

func TestMergePostDateStatementRowsKeepsMultiplicityWithinOneStatement(t *testing.T) {
	row := func(source string) postDateBankRow {
		return postDateBankRow{dateText: "2026-05-14", key: "2026-05-14|15/05/2026|card|-120|CNY", source: source}
	}
	merged := mergePostDateStatementRows([][]postDateBankRow{{row("a"), row("a")}, {row("b")}, {row("c"), row("c")}})
	if len(merged) != 2 || merged[0].source != "a" || merged[1].index != 1 {
		t.Fatalf("merged = %#v", merged)
	}
}

func TestPostDateBackfillRoutesReachTheLocalTransport(t *testing.T) {
	server := &Server{}
	if handler, mutating := localHandler(server, "POST", "/api/ledger/imports/post-date-backfill"); handler == nil || mutating {
		t.Fatalf("preview handler=%v mutating=%v", handler != nil, mutating)
	}
	if handler, mutating := localHandler(server, "POST", "/api/ledger/imports/post-date-backfill/apply"); handler == nil || !mutating {
		t.Fatalf("apply handler=%v mutating=%v", handler != nil, mutating)
	}
}
