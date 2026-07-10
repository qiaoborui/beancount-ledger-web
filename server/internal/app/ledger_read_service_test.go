package app

import (
	"context"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestLedgerReadServiceTransactionsRespectSensitiveUnlock(t *testing.T) {
	service := NewLedgerReadService(NewLedgerCache(testLedger(t)))

	locked, err := service.Transactions("2026-05-01", "2026-06-01", false)
	if err != nil {
		t.Fatal(err)
	}
	lockedTxns := locked["transactions"].([]Transaction)
	if len(lockedTxns) != 1 || lockedTxns[0].Payee != "Cafe" {
		t.Fatalf("locked transaction feed should hide income transactions: %#v", lockedTxns)
	}

	unlocked, err := service.Transactions("2026-05-01", "2026-06-01", true)
	if err != nil {
		t.Fatal(err)
	}
	unlockedTxns := unlocked["transactions"].([]Transaction)
	if len(unlockedTxns) != 2 || unlockedTxns[0].Payee != "Employer" || unlockedTxns[1].Payee != "Cafe" {
		t.Fatalf("unlocked transaction feed should include all transactions newest first: %#v", unlockedTxns)
	}
}

func TestLedgerReadServiceBalancesFallsBackToCache(t *testing.T) {
	service := NewLedgerReadService(NewLedgerCache(testLedger(t)))

	balances, assertions, err := service.Balances(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if balances["Assets:Cash"] != 98800 || balances["Expenses:Food"] != 1200 {
		t.Fatalf("unexpected cache balances: %#v", balances)
	}
	if len(assertions) != 0 {
		t.Fatalf("unexpected cache assertions: %#v", assertions)
	}
}

func TestBuildLedgerTransactionsFromIndexedRangeRespectSensitiveUnlock(t *testing.T) {
	txns := []Transaction{
		{
			Date: "2026-05-31", Payee: "Employer",
			Postings: []Posting{
				{Account: "Assets:Cash", Amount: 100000, Currency: "CNY"},
				{Account: "Income:Salary", Amount: -100000, Currency: "CNY"},
			},
		},
		{
			Date: "2026-05-01", Payee: "Cafe",
			Postings: []Posting{
				{Account: "Expenses:Food", Amount: 1200, Currency: "CNY"},
				{Account: "Assets:Cash", Amount: -1200, Currency: "CNY"},
			},
		},
	}

	locked := BuildLedgerTransactionsFromIndexedRange(txns, "2026-05-01", "2026-06-01", false)
	lockedTxns := locked["transactions"].([]Transaction)
	if len(lockedTxns) != 1 || lockedTxns[0].Payee != "Cafe" {
		t.Fatalf("direct indexed feed should hide income transactions: %#v", lockedTxns)
	}

	unlocked := BuildLedgerTransactionsFromIndexedRange(txns, "2026-05-01", "2026-06-01", true)
	unlockedTxns := unlocked["transactions"].([]Transaction)
	if len(unlockedTxns) != 2 || unlockedTxns[0].Payee != "Employer" || unlockedTxns[1].Payee != "Cafe" {
		t.Fatalf("direct indexed feed should preserve database order: %#v", unlockedTxns)
	}
}

func TestLedgerSnapshotCachesDerivedViews(t *testing.T) {
	cache := NewLedgerCache(testLedger(t))
	snapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.RawBalances["Assets:Cash"]["CNY"] != 98800 {
		t.Fatalf("raw balances not cached correctly: %#v", snapshot.RawBalances)
	}
	if snapshot.transactionsAsc == nil || snapshot.transactionsDesc == nil {
		t.Fatal("transaction sort views should be prepared with the snapshot")
	}
	if len(snapshotTransactionsAsc(snapshot)) != 2 || snapshotTransactionsAsc(snapshot)[0].Payee != "Cafe" || snapshotTransactionsAsc(snapshot)[1].Payee != "Employer" {
		t.Fatalf("ascending transaction cache changed order: %#v", snapshotTransactionsAsc(snapshot))
	}
	if len(snapshotTransactionsDesc(snapshot)) != 2 || snapshotTransactionsDesc(snapshot)[0].Payee != "Employer" || snapshotTransactionsDesc(snapshot)[1].Payee != "Cafe" {
		t.Fatalf("descending transaction cache changed order: %#v", snapshotTransactionsDesc(snapshot))
	}
	_, sameDayDesc := sortedTransactionViews([]Transaction{
		{Date: "2026-05-02", Payee: "Second line", Source: TransactionSource{Line: 20}},
		{Date: "2026-05-02", Payee: "First line", Source: TransactionSource{Line: 10}},
	})
	if sameDayDesc[0].Payee != "First line" || sameDayDesc[1].Payee != "Second line" {
		t.Fatalf("descending cache should keep same-day ledger order: %#v", sameDayDesc)
	}

	payload := BuildLedgerTransactions(snapshot, "2026-05-01", "2026-06-01", false)
	txns := payload["transactions"].([]Transaction)
	if len(txns) != 1 || txns[0].Payee != "Cafe" {
		t.Fatalf("cached transaction filtering should preserve locked privacy: %#v", txns)
	}
}

func TestLedgerReadServiceSummaryAndIncomeStatementPrivacy(t *testing.T) {
	service := NewLedgerReadService(NewLedgerCache(testLedger(t)))

	locked, err := service.Summary("2026-05-01", "2026-06-01", false)
	if err != nil {
		t.Fatal(err)
	}
	lockedSummary := locked["summary"].(Summary)
	if lockedSummary.Income != 0 || lockedSummary.Net != 0 || lockedSummary.Expense != 1200 {
		t.Fatalf("locked summary should hide income while preserving expense: %#v", lockedSummary)
	}
	if balances := locked["balances"].(map[string]int); len(balances) != 0 {
		t.Fatalf("locked summary should hide balances: %#v", balances)
	}

	lockedIncome, err := service.IncomeStatement("2026-05-01", "2026-06-01", false)
	if err != nil {
		t.Fatal(err)
	}
	if income := lockedIncome["income"].([]IncomeStatementNode); len(income) != 0 {
		t.Fatalf("locked income statement should hide income nodes: %#v", income)
	}
	if lockedIncome["totalIncome"].(int) != 0 || lockedIncome["netIncome"].(int) != 0 || lockedIncome["totalExpense"].(int) != 1200 {
		t.Fatalf("locked income statement totals should hide income: %#v", lockedIncome)
	}

	unlocked, err := service.IncomeStatement("2026-05-01", "2026-06-01", true)
	if err != nil {
		t.Fatal(err)
	}
	if income := unlocked["income"].([]IncomeStatementNode); len(income) != 1 || income[0].Account != "Income:Salary" {
		t.Fatalf("unlocked income statement should include income nodes: %#v", income)
	}
	if unlocked["totalIncome"].(int) != 100000 || unlocked["netIncome"].(int) != 98800 {
		t.Fatalf("unlocked income statement totals should include income: %#v", unlocked)
	}
}

func TestLedgerBootstrapKeepsNestedIncomeStatementShape(t *testing.T) {
	service := NewLedgerReadService(NewLedgerCache(testLedger(t)))

	bootstrap, err := service.Bootstrap("2026-05-01", "2026-06-01", true)
	if err != nil {
		t.Fatal(err)
	}
	incomeStatement := bootstrap["incomeStatement"].(gin.H)
	if _, ok := incomeStatement["start"]; ok {
		t.Fatalf("nested income statement should not include top-level date fields: %#v", incomeStatement)
	}
	if incomeStatement["valuationCurrency"].(string) != "CNY" {
		t.Fatalf("nested income statement should include valuation currency: %#v", incomeStatement)
	}
	if incomeStatement["totalIncome"].(int) != 100000 || incomeStatement["netIncome"].(int) != 98800 {
		t.Fatalf("nested income statement totals changed: %#v", incomeStatement)
	}
}

func BenchmarkBuildLedgerTransactionsCached(b *testing.B) {
	snapshot := benchmarkLedgerSnapshot(2000)

	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		payload := BuildLedgerTransactions(snapshot, "2026-05-01", "2026-06-01", true)
		if len(payload["transactions"].([]Transaction)) != len(snapshot.Transactions) {
			b.Fatal("missing transactions")
		}
	}
}

func BenchmarkBuildLedgerTransactionsFromIndexedRange(b *testing.B) {
	snapshot := benchmarkLedgerSnapshot(2000)
	txns := snapshotTransactionsDesc(snapshot)

	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		payload := BuildLedgerTransactionsFromIndexedRange(txns, "2026-05-01", "2026-06-01", true)
		if len(payload["transactions"].([]Transaction)) != len(snapshot.Transactions) {
			b.Fatal("missing transactions")
		}
	}
}

func BenchmarkFilterLedgerTransactionsSortEachCall(b *testing.B) {
	snapshot := benchmarkLedgerSnapshot(2000)

	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		txns := FilterLedgerTransactions(snapshot.Transactions, "2026-05-01", "2026-06-01", true)
		if len(txns) != len(snapshot.Transactions) {
			b.Fatal("missing transactions")
		}
	}
}

func benchmarkLedgerSnapshot(count int) *LedgerSnapshot {
	snapshot := &LedgerSnapshot{}
	for i := 0; i < count; i++ {
		date := "2026-05-01"
		if i%2 == 0 {
			date = "2026-05-31"
		}
		snapshot.Transactions = append(snapshot.Transactions, Transaction{
			Date:  date,
			Payee: "Cafe",
			Postings: []Posting{
				{Account: "Expenses:Food", Amount: 1200, Currency: "CNY"},
				{Account: "Assets:Cash", Amount: -1200, Currency: "CNY"},
			},
			Source: TransactionSource{Line: i + 1},
		})
	}
	prepareLedgerSnapshot(snapshot)
	return snapshot
}
