package app

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestClassifyReusableTransactionsRequiresStableSourceHashAndLine(t *testing.T) {
	txns := []Transaction{
		{Date: "2026-05-01", Payee: "Reuse", Source: TransactionSource{File: "transactions/2026/05.bean", Line: 10, Hash: "same"}},
		{Date: "2026-05-02", Payee: "Changed line", Source: TransactionSource{File: "transactions/2026/05.bean", Line: 11, Hash: "same"}},
		{Date: "2026-05-03", Payee: "No hash", Source: TransactionSource{File: "transactions/2026/05.bean", Line: 30}},
		{Date: "2026-05-04", Payee: "New", Source: TransactionSource{File: "transactions/2026/05.bean", Line: 40, Hash: "new"}},
	}
	oldByKey := map[transactionReuseKey]int{
		{file: "transactions/2026/05.bean", line: 10, hash: "same"}: 7,
		{file: "transactions/2026/05.bean", line: 20, hash: "same"}: 8,
	}

	reused, fresh := classifyReusableTransactions(txns, oldByKey)

	if len(reused) != 1 || reused[0].newOrdinal != 0 || reused[0].oldOrdinal != 7 {
		t.Fatalf("unexpected reused rows: %#v", reused)
	}
	if len(fresh) != 3 || fresh[0].ordinal != 1 || fresh[1].ordinal != 2 || fresh[2].ordinal != 3 {
		t.Fatalf("unexpected fresh rows: %#v", fresh)
	}
}

func TestLedgerIndexStoreReplaceActiveSnapshotPostgres(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	branch := "test-ledger-index-store-" + time.Now().Format("20060102150405.000000000")

	store, err := NewLedgerIndexStore(Config{DatabaseURL: databaseURL, LedgerReadModel: "postgres", LedgerGitBranch: branch})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctx := context.Background()
	first := testIndexSnapshot("v1", []Transaction{
		testIndexedTransaction("2026-05-01", "Cafe", "transactions/2026/05.bean", 10, "same", 1200),
		testIndexedTransaction("2026-05-02", "Book", "transactions/2026/05.bean", 20, "old", 2400),
	})
	firstID, err := store.ReplaceActiveSnapshot(ctx, first, "sha-1")
	if err != nil {
		t.Fatal(err)
	}
	second := testIndexSnapshot("v2", []Transaction{
		testIndexedTransaction("2026-05-01", "Cafe", "transactions/2026/05.bean", 10, "same", 1200),
		testIndexedTransaction("2026-05-03", "Tea", "transactions/2026/05.bean", 30, "new", 800),
	})
	second.BalanceAssertions = []BalanceAssertion{{Date: "2026-05-31", Account: "Assets:Cash", Amount: -2000, Currency: "CNY"}}
	secondID, err := store.ReplaceActiveSnapshot(ctx, second, "sha-2")
	if err != nil {
		t.Fatal(err)
	}
	if secondID == firstID {
		t.Fatalf("expected a new revision id, got %d", secondID)
	}
	revision, ok, err := store.ActiveRevision(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !ok || revision.ID != secondID || revision.GitSHA != "sha-2" {
		t.Fatalf("unexpected active revision: ok=%v revision=%#v", ok, revision)
	}
	activeSnapshot, ok, err := store.ActiveSnapshot(ctx)
	if err != nil || !ok {
		t.Fatalf("active snapshot: ok=%v err=%v", ok, err)
	}
	if len(activeSnapshot.Transactions) != 2 || activeSnapshot.Transactions[0].Source.GitSHA != "sha-2" {
		t.Fatalf("active snapshot transaction source SHA=%#v", activeSnapshot.Transactions)
	}
	txns, err := store.TransactionsForRevision(ctx, secondID, "2026-05-01", "2026-06-01")
	if err != nil {
		t.Fatal(err)
	}
	if len(txns) != 2 || txns[0].Payee != "Tea" || txns[1].Payee != "Cafe" {
		t.Fatalf("unexpected indexed transactions: %#v", txns)
	}
	balances, assertions, err := store.BalancesForRevision(ctx, secondID)
	if err != nil {
		t.Fatal(err)
	}
	if balances["Assets:Cash"] != -2000 || balances["Expenses:Food"] != 2000 {
		t.Fatalf("unexpected indexed balances: %#v", balances)
	}
	if len(assertions) != 1 || assertions[0] != second.BalanceAssertions[0] {
		t.Fatalf("unexpected indexed assertions: %#v", assertions)
	}
	var postingCount int
	if err := store.db.QueryRowContext(ctx, `SELECT count(*) FROM ledger_index_postings WHERE revision_id = $1`, secondID).Scan(&postingCount); err != nil {
		t.Fatal(err)
	}
	if postingCount != 4 {
		t.Fatalf("posting count=%d, want 4", postingCount)
	}

	third := testIndexSnapshot("v3", second.Transactions)
	thirdID, err := store.ReplaceActiveSnapshot(ctx, third, "sha-3")
	if err != nil {
		t.Fatal(err)
	}
	if thirdID == secondID {
		t.Fatalf("expected a third revision id, got %d", thirdID)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT count(*) FROM ledger_index_postings WHERE revision_id = $1`, thirdID).Scan(&postingCount); err != nil {
		t.Fatal(err)
	}
	if postingCount != 4 {
		t.Fatalf("reused-only posting count=%d, want 4", postingCount)
	}

	forced := testIndexSnapshot("v3", []Transaction{
		testIndexedTransaction("2026-05-01", "Cafe", "transactions/2026/05.bean", 10, "same", 1800),
		testIndexedTransaction("2026-05-03", "Tea", "transactions/2026/05.bean", 30, "new", 800),
	})
	forcedID, err := store.ForceReplaceActiveSnapshot(ctx, forced, "sha-3")
	if err != nil {
		t.Fatal(err)
	}
	if forcedID != thirdID {
		t.Fatalf("forced rebuild revision id=%d, want %d", forcedID, thirdID)
	}
	forcedTransactions, err := store.TransactionsForRevision(ctx, forcedID, "2026-05-01", "2026-06-01")
	if err != nil {
		t.Fatal(err)
	}
	if len(forcedTransactions) != 2 || forcedTransactions[1].Postings[0].Amount != 1800 {
		t.Fatalf("forced rebuild did not replace transaction payload: %#v", forcedTransactions)
	}
}

func testIndexSnapshot(version string, txns []Transaction) *LedgerSnapshot {
	snapshot := &LedgerSnapshot{
		LedgerVersion: LedgerVersion{Version: version, FileCount: 1},
		Transactions:  txns,
		Accounts: []Account{
			{Account: "Assets:Cash", OpenDate: "2026-01-01", Currency: "CNY", Label: "Cash", Group: "cash", Active: true},
			{Account: "Expenses:Food", OpenDate: "2026-01-01", Currency: "CNY", Label: "Food", Group: "expense", Active: true},
		},
		Commodities: []string{"CNY"},
	}
	prepareLedgerSnapshot(snapshot)
	return snapshot
}

func testIndexedTransaction(date, payee, file string, line int, hash string, amount int) Transaction {
	return Transaction{
		Date:  date,
		Payee: payee,
		Postings: []Posting{
			{Account: "Expenses:Food", Amount: amount, Currency: "CNY"},
			{Account: "Assets:Cash", Amount: -amount, Currency: "CNY"},
		},
		Source: TransactionSource{File: file, Line: line, Hash: hash},
	}
}
