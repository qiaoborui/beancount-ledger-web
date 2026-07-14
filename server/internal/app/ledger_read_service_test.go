package app

import (
	"context"
	"encoding/json"
	"testing"
)

func TestLedgerReadServiceTransactionsRespectSensitiveUnlock(t *testing.T) {
	service := NewLedgerReadService(NewLedgerCache(testLedger(t)))

	locked, err := service.Transactions("2026-05-01", "2026-06-01", false)
	if err != nil {
		t.Fatal(err)
	}
	lockedTxns := locked.Transactions
	if len(lockedTxns) != 1 || lockedTxns[0].Payee != "Cafe" {
		t.Fatalf("locked transaction feed should hide income transactions: %#v", lockedTxns)
	}
	if locked.Start != "2026-05-01" || locked.End != "2026-06-01" || locked.SensitiveUnlocked {
		t.Fatalf("locked transaction query metadata changed: %#v", locked)
	}

	unlocked, err := service.Transactions("2026-05-01", "2026-06-01", true)
	if err != nil {
		t.Fatal(err)
	}
	unlockedTxns := unlocked.Transactions
	if len(unlockedTxns) != 2 || unlockedTxns[0].Payee != "Employer" || unlockedTxns[1].Payee != "Cafe" {
		t.Fatalf("unlocked transaction feed should include all transactions newest first: %#v", unlockedTxns)
	}
	if !unlocked.SensitiveUnlocked {
		t.Fatalf("unlocked transaction query metadata changed: %#v", unlocked)
	}
}

func TestTransactionQueryResultJSONContract(t *testing.T) {
	payload := TransactionQueryResult{
		Start:             "2026-05-01",
		End:               "2026-06-01",
		Transactions:      []Transaction{},
		SensitiveUnlocked: false,
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"start":"2026-05-01","end":"2026-06-01","transactions":[],"sensitiveUnlocked":false}`
	if string(raw) != want {
		t.Fatalf("transaction query JSON = %s, want %s", raw, want)
	}
}

func TestSummaryQueryResultJSONContract(t *testing.T) {
	payload := SummaryQueryResult{
		Start:             "2026-05-01",
		End:               "2026-06-01",
		Summary:           Summary{Currency: "CNY", Days: map[string]map[string]int{}, Categories: map[string]int{}},
		Balances:          map[string]int{},
		AccountBalances:   []AccountBalance{},
		NetWorthHistory:   []NetWorthPoint{},
		MonthEndNetWorth:  []NetWorthPoint{},
		CreditCards:       []CreditCardAnalytics{},
		Commodities:       []string{},
		Prices:            []Price{},
		ValuationCurrency: "CNY",
		SensitiveUnlocked: false,
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"start":"2026-05-01","end":"2026-06-01","summary":{"currency":"CNY","income":0,"expense":0,"net":0,"days":{},"categories":{}},"balances":{},"accountBalances":[],"netWorthHistory":[],"monthEndNetWorth":[],"netWorthWindows":null,"creditCards":[],"commodities":[],"prices":[],"valuationCurrency":"CNY","sensitiveUnlocked":false}`
	if string(raw) != want {
		t.Fatalf("summary query JSON = %s, want %s", raw, want)
	}
}

func TestIncomeStatementQueryResultJSONContract(t *testing.T) {
	payload := IncomeStatementQueryResult{
		Start: "2026-05-01",
		End:   "2026-06-01",
		IncomeStatementResult: IncomeStatementResult{
			Income:             []IncomeStatementNode{},
			Expense:            []IncomeStatementNode{},
			ExpenseAnalytics:   []ExpenseCategoryAnalytics{},
			TopPayees:          []PayeeAnalytics{},
			TopPaymentAccounts: []AccountAnalytics{},
			ValuationCurrency:  "CNY",
		},
		SensitiveUnlocked: false,
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"start":"2026-05-01","end":"2026-06-01","income":[],"expense":[],"totalIncome":0,"totalExpense":0,"expenseAnalytics":[],"topPayees":[],"topPaymentAccounts":[],"netIncome":0,"valuationCurrency":"CNY","sensitiveUnlocked":false}`
	if string(raw) != want {
		t.Fatalf("income statement query JSON = %s, want %s", raw, want)
	}
}

func TestBootstrapResultJSONContract(t *testing.T) {
	payload := BootstrapResult{
		Start:              "2026-05-01",
		End:                "2026-06-01",
		Summary:            Summary{Currency: "CNY", Days: map[string]map[string]int{}, Categories: map[string]int{}},
		Balances:           map[string]int{},
		AccountBalances:    []AccountBalance{},
		NetWorthHistory:    []NetWorthPoint{},
		MonthEndNetWorth:   []NetWorthPoint{},
		CreditCards:        []CreditCardAnalytics{},
		Investments:        InvestmentSummary{},
		Transactions:       []Transaction{},
		ReconciliationRows: []ReconciliationRow{},
		Accounts:           []Account{},
		Commodities:        []string{},
		Prices:             []Price{},
		ValuationCurrency:  "CNY",
		IncomeStatement: IncomeStatementResult{
			Income:             []IncomeStatementNode{},
			Expense:            []IncomeStatementNode{},
			ExpenseAnalytics:   []ExpenseCategoryAnalytics{},
			TopPayees:          []PayeeAnalytics{},
			TopPaymentAccounts: []AccountAnalytics{},
			ValuationCurrency:  "CNY",
		},
		AccountStatuses:   []AccountStatus{},
		LedgerVersion:     LedgerVersion{Version: "version", LatestMtime: 1, FileCount: 2},
		SensitiveUnlocked: false,
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	wantFields := []string{
		"start", "end", "summary", "balances", "accountBalances", "netWorthHistory",
		"monthEndNetWorth", "netWorthWindows", "creditCards", "investments", "transactions",
		"reconciliationRows", "accounts", "commodities", "prices", "valuationCurrency",
		"incomeStatement", "accountStatuses", "ledgerVersion", "sensitiveUnlocked",
	}
	if len(fields) != len(wantFields) {
		t.Fatalf("bootstrap JSON fields = %d, want %d: %s", len(fields), len(wantFields), raw)
	}
	for _, field := range wantFields {
		if _, ok := fields[field]; !ok {
			t.Fatalf("bootstrap JSON missing %q: %s", field, raw)
		}
	}
	if string(fields["netWorthWindows"]) != "null" || string(fields["reconciliationRows"]) != "[]" || string(fields["sensitiveUnlocked"]) != "false" {
		t.Fatalf("bootstrap JSON empty and privacy semantics changed: %s", raw)
	}
}

func TestReconciliationRowJSONContract(t *testing.T) {
	alias := "现金"
	payload := ReconciliationRow{
		Account:       "Assets:Cash",
		Alias:         &alias,
		Label:         "现金",
		Currency:      "CNY",
		LedgerBalance: 98800,
		Status:        "asserted",
		LastAssertion: &BalanceAssertion{Date: "2026-05-31", Account: "Assets:Cash", Amount: 98800, Currency: "CNY"},
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"account":"Assets:Cash","alias":"现金","label":"现金","currency":"CNY","ledgerBalance":98800,"status":"asserted","lastAssertion":{"date":"2026-05-31","account":"Assets:Cash","amount":98800,"currency":"CNY"}}`
	if string(raw) != want {
		t.Fatalf("reconciliation row JSON = %s, want %s", raw, want)
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
	lockedTxns := locked.Transactions
	if len(lockedTxns) != 1 || lockedTxns[0].Payee != "Cafe" {
		t.Fatalf("direct indexed feed should hide income transactions: %#v", lockedTxns)
	}

	unlocked := BuildLedgerTransactionsFromIndexedRange(txns, "2026-05-01", "2026-06-01", true)
	unlockedTxns := unlocked.Transactions
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
	txns := payload.Transactions
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
	lockedSummary := locked.Summary
	if lockedSummary.Income != 0 || lockedSummary.Net != 0 || lockedSummary.Expense != 1200 {
		t.Fatalf("locked summary should hide income while preserving expense: %#v", lockedSummary)
	}
	if balances := locked.Balances; len(balances) != 0 {
		t.Fatalf("locked summary should hide balances: %#v", balances)
	}
	if locked.Start != "2026-05-01" || locked.End != "2026-06-01" || locked.SensitiveUnlocked || locked.NetWorthWindows != nil {
		t.Fatalf("locked summary query metadata changed: %#v", locked)
	}
	unlockedSummary, err := service.Summary("2026-05-01", "2026-06-01", true)
	if err != nil {
		t.Fatal(err)
	}
	if !unlockedSummary.SensitiveUnlocked || len(unlockedSummary.Balances) == 0 || unlockedSummary.NetWorthWindows == nil {
		t.Fatalf("unlocked summary query metadata changed: %#v", unlockedSummary)
	}

	lockedIncome, err := service.IncomeStatement("2026-05-01", "2026-06-01", false)
	if err != nil {
		t.Fatal(err)
	}
	if income := lockedIncome.Income; len(income) != 0 {
		t.Fatalf("locked income statement should hide income nodes: %#v", income)
	}
	if lockedIncome.TotalIncome != 0 || lockedIncome.NetIncome != 0 || lockedIncome.TotalExpense != 1200 {
		t.Fatalf("locked income statement totals should hide income: %#v", lockedIncome)
	}
	if lockedIncome.Start != "2026-05-01" || lockedIncome.End != "2026-06-01" || lockedIncome.SensitiveUnlocked {
		t.Fatalf("locked income statement query metadata changed: %#v", lockedIncome)
	}

	unlocked, err := service.IncomeStatement("2026-05-01", "2026-06-01", true)
	if err != nil {
		t.Fatal(err)
	}
	if income := unlocked.Income; len(income) != 1 || income[0].Account != "Income:Salary" {
		t.Fatalf("unlocked income statement should include income nodes: %#v", income)
	}
	if unlocked.TotalIncome != 100000 || unlocked.NetIncome != 98800 || !unlocked.SensitiveUnlocked {
		t.Fatalf("unlocked income statement totals should include income: %#v", unlocked)
	}
}

func TestLedgerBootstrapKeepsNestedIncomeStatementShape(t *testing.T) {
	service := NewLedgerReadService(NewLedgerCache(testLedger(t)))

	bootstrap, err := service.Bootstrap("2026-05-01", "2026-06-01", true)
	if err != nil {
		t.Fatal(err)
	}
	incomeStatement := bootstrap.IncomeStatement
	raw, err := json.Marshal(incomeStatement)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	if _, ok := fields["start"]; ok {
		t.Fatalf("nested income statement should not include top-level date fields: %s", raw)
	}
	if incomeStatement.ValuationCurrency != "CNY" {
		t.Fatalf("nested income statement should include valuation currency: %#v", incomeStatement)
	}
	if incomeStatement.TotalIncome != 100000 || incomeStatement.NetIncome != 98800 {
		t.Fatalf("nested income statement totals changed: %#v", incomeStatement)
	}
	if !bootstrap.SensitiveUnlocked || len(bootstrap.Balances) == 0 || len(bootstrap.ReconciliationRows) == 0 || len(bootstrap.AccountStatuses) == 0 {
		t.Fatalf("full unlocked bootstrap fields changed: %#v", bootstrap)
	}

	lite, err := service.BootstrapLite("2026-05-01", "2026-06-01", true)
	if err != nil {
		t.Fatal(err)
	}
	if lite.NetWorthWindows != nil || len(lite.ReconciliationRows) != 0 || len(lite.AccountStatuses) != 0 {
		t.Fatalf("lite bootstrap should keep expensive derived fields empty: %#v", lite)
	}

	locked, err := service.Bootstrap("2026-05-01", "2026-06-01", false)
	if err != nil {
		t.Fatal(err)
	}
	if locked.SensitiveUnlocked || len(locked.Balances) != 0 || len(locked.ReconciliationRows) != 0 || len(locked.AccountStatuses) != 0 {
		t.Fatalf("locked bootstrap should hide sensitive fields: %#v", locked)
	}
}

func BenchmarkBuildLedgerTransactionsCached(b *testing.B) {
	snapshot := benchmarkLedgerSnapshot(2000)

	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		payload := BuildLedgerTransactions(snapshot, "2026-05-01", "2026-06-01", true)
		if len(payload.Transactions) != len(snapshot.Transactions) {
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
		if len(payload.Transactions) != len(snapshot.Transactions) {
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
