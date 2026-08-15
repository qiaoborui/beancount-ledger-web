package app

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"
)

func TestLedgerMetadataValuesRoundTripWithoutJSON(t *testing.T) {
	tests := []struct {
		name  string
		value MetadataValue
		want  MetadataValue
	}{
		{name: "null", value: nil, want: nil},
		{name: "string", value: "CMB", want: "CMB"},
		{name: "number", value: 18.5, want: 18.5},
		{name: "boolean", value: true, want: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			kind, textValue, numberValue, booleanValue, err := encodeLedgerMetadataValue(test.value)
			if err != nil {
				t.Fatal(err)
			}
			text, _ := textValue.(string)
			number, _ := numberValue.(float64)
			boolean, _ := booleanValue.(bool)
			got, err := decodeLedgerMetadataValue(kind, sql.NullString{String: text, Valid: textValue != nil}, sql.NullFloat64{Float64: number, Valid: numberValue != nil}, sql.NullBool{Bool: boolean, Valid: booleanValue != nil})
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("round trip = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestLedgerMetadataValuesRejectUnsupportedType(t *testing.T) {
	if _, _, _, _, err := encodeLedgerMetadataValue([]string{"unsupported"}); err == nil {
		t.Fatal("expected unsupported metadata value to fail")
	}
}

func TestMetadataUsesPostgresText(t *testing.T) {
	metadata, err := marshalPostgresJSON(map[string]any{"ok": true})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := any(metadata).(string); !ok {
		t.Fatalf("metadata type=%T, want string for Postgres JSONB", metadata)
	}
	if !json.Valid([]byte(metadata)) {
		t.Fatalf("invalid JSON metadata=%q", metadata)
	}
}

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
	defer store.db.ExecContext(context.Background(), `DELETE FROM ledger_index_revisions WHERE source_key = $1`, store.sourceKey)

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
	if got := activeSnapshot.Transactions[0]; len(got.Tags) != 2 || got.Tags[0] != "work" || got.Tags[1] != "food" || len(got.Links) != 1 || got.Links[0] != "receipt-cafe" {
		t.Fatalf("active snapshot transaction annotations=%#v", got)
	}
	if got, want := activeSnapshot.Transactions[0].Metadata, map[string]MetadataValue{"orderId": "order-cafe", "statementHash": "hash-cafe", "imported": true, "amount": float64(12), "empty": nil}; !reflect.DeepEqual(got, want) {
		t.Fatalf("active snapshot transaction metadata=%#v, want %#v", got, want)
	}
	if got, want := activeSnapshot.Accounts[0].Metadata, map[string]MetadataValue{"provider": "Cash", "statement-day": float64(18), "autopay": true, "empty": nil}; !reflect.DeepEqual(got, want) {
		t.Fatalf("active snapshot account metadata=%#v, want %#v", got, want)
	}
	if !reflect.DeepEqual(activeSnapshot.BeanEntries, second.BeanEntries) {
		t.Fatalf("active snapshot bean entries=%#v, want %#v", activeSnapshot.BeanEntries, second.BeanEntries)
	}
	if !reflect.DeepEqual(activeSnapshot.BeanErrors, second.BeanErrors) {
		t.Fatalf("active snapshot bean errors=%#v, want %#v", activeSnapshot.BeanErrors, second.BeanErrors)
	}
	txns, err := store.TransactionsForRevision(ctx, secondID, "2026-05-01", "2026-06-01")
	if err != nil {
		t.Fatal(err)
	}
	if len(txns) != 2 || txns[0].Payee != "Tea" || txns[1].Payee != "Cafe" {
		t.Fatalf("unexpected indexed transactions: %#v", txns)
	}
	if got := txns[0]; len(got.Tags) != 2 || got.Tags[0] != "work" || got.Tags[1] != "food" || len(got.Links) != 1 || got.Links[0] != "receipt-cafe" {
		t.Fatalf("range query transaction annotations=%#v", got)
	}
	if got, want := txns[0].Metadata, map[string]MetadataValue{"orderId": "order-cafe", "statementHash": "hash-cafe", "imported": true, "amount": float64(12), "empty": nil}; !reflect.DeepEqual(got, want) {
		t.Fatalf("range query transaction metadata=%#v, want %#v", got, want)
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
	if _, err := store.db.ExecContext(ctx, `UPDATE ledger_index_revisions SET activated_at = now() - INTERVAL '2 minutes' WHERE id = $1`, firstID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `
INSERT INTO ledger_index_revisions (source_key, ledger_version, status, indexed_at, activated_at)
VALUES ($1, 'legacy-stale', 'superseded', now() - INTERVAL '2 minutes', now() - INTERVAL '2 minutes')`, store.sourceKey); err != nil {
		t.Fatal(err)
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
	var revisionCount int
	if err := store.db.QueryRowContext(ctx, `SELECT count(*) FROM ledger_index_revisions WHERE source_key = $1`, store.sourceKey).Scan(&revisionCount); err != nil {
		t.Fatal(err)
	}
	if revisionCount != 2 {
		t.Fatalf("revision count=%d, want active plus one superseded revision", revisionCount)
	}
	var secondStatus string
	if err := store.db.QueryRowContext(ctx, `SELECT status FROM ledger_index_revisions WHERE id = $1`, secondID).Scan(&secondStatus); err != nil {
		t.Fatal(err)
	}
	if secondStatus != "superseded" {
		t.Fatalf("previous revision status=%q, want superseded", secondStatus)
	}
	var firstEntryCount int
	if err := store.db.QueryRowContext(ctx, `SELECT count(*) FROM ledger_index_bean_entries WHERE revision_id = $1`, firstID).Scan(&firstEntryCount); err != nil {
		t.Fatal(err)
	}
	if firstEntryCount != 0 {
		t.Fatalf("pruned revision bean entry count=%d, want 0", firstEntryCount)
	}
	thirdSnapshot, ok, err := store.ActiveSnapshot(ctx)
	if err != nil || !ok {
		t.Fatalf("third active snapshot: ok=%v err=%v", ok, err)
	}
	if got := thirdSnapshot.Transactions[0]; len(got.Tags) != 2 || got.Tags[0] != "work" || got.Tags[1] != "food" || len(got.Links) != 1 || got.Links[0] != "receipt-cafe" {
		t.Fatalf("reused transaction annotations=%#v", got)
	}
	if got, want := thirdSnapshot.Transactions[0].Metadata, map[string]MetadataValue{"orderId": "order-cafe", "statementHash": "hash-cafe", "imported": true, "amount": float64(12), "empty": nil}; !reflect.DeepEqual(got, want) {
		t.Fatalf("reused transaction metadata=%#v, want %#v", got, want)
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
		t.Fatalf("forced rebuild did not replace reconstructed transaction: %#v", forcedTransactions)
	}
	if got := forcedTransactions[1]; len(got.Tags) != 2 || got.Tags[0] != "work" || got.Tags[1] != "food" || len(got.Links) != 1 || got.Links[0] != "receipt-cafe" {
		t.Fatalf("forced rebuild transaction annotations=%#v", got)
	}
	if got, want := forcedTransactions[1].Metadata, map[string]MetadataValue{"orderId": "order-cafe", "statementHash": "hash-cafe", "imported": true, "amount": float64(12), "empty": nil}; !reflect.DeepEqual(got, want) {
		t.Fatalf("forced rebuild transaction metadata=%#v, want %#v", got, want)
	}
}

func testIndexSnapshot(version string, txns []Transaction) *LedgerSnapshot {
	snapshot := &LedgerSnapshot{
		LedgerVersion: LedgerVersion{Version: version, FileCount: 1},
		Transactions:  txns,
		BeanEntries:   testIndexedBeanEntries(),
		BeanErrors:    []BeanParseError{{File: "transactions/2026/bad.bean", Line: 12, Message: "unrecognized transaction body line"}},
		Accounts: []Account{
			{Account: "Assets:Cash", OpenDate: "2026-01-01", Currency: "CNY", Label: "Cash", Group: "cash", Active: true, Metadata: map[string]MetadataValue{"provider": "Cash", "statement-day": float64(18), "autopay": true, "empty": nil}},
			{Account: "Expenses:Food", OpenDate: "2026-01-01", Currency: "CNY", Label: "Food", Group: "expense", Active: true},
		},
		Commodities: []string{"CNY"},
	}
	prepareLedgerSnapshot(snapshot)
	return snapshot
}

func testIndexedBeanEntries() []BeanEntry {
	return []BeanEntry{{
		Kind:          "transaction",
		Date:          "2026-05-01",
		File:          "transactions/2026/05.bean",
		Line:          10,
		RawLines:      []string{`2026-05-01 * "Cafe" "Coffee" #work ^receipt-cafe`, `  orderId: "order-cafe"`, `  Expenses:Food 12.34 CNY { 11.00 CNY } @ 1.10 USD`},
		Name:          "event-name",
		Value:         "event-value",
		Filename:      "receipt.pdf",
		Flag:          "*",
		Payee:         "Cafe",
		Narration:     "Coffee",
		Account:       "Assets:Cash",
		Account2:      "Equity:Opening-Balances",
		Currencies:    []string{"CNY", "USD"},
		Currency:      "CNY",
		Amount:        1234,
		AmountValue:   BeanAmount{Number: "12.34", Currency: "CNY"},
		Tolerance:     "0.01",
		QuoteCurrency: "USD",
		Metadata: map[string]MetadataValue{
			"orderId":  "order-cafe",
			"imported": true,
			"amount":   float64(12),
			"empty":    nil,
		},
		Tags:       []string{"work", "food"},
		Links:      []string{"receipt-cafe"},
		CustomType: "budget",
		CustomValues: []MetadataValue{
			"Expenses:Food", float64(500), true, nil,
		},
		Postings: []parsedPosting{{
			Posting:       Posting{Account: "Expenses:Food", Amount: 1234, Currency: "CNY", Flag: "!"},
			Blank:         false,
			Quantity:      BeanAmount{Number: "12.34", Currency: "CNY"},
			CostAmount:    1100,
			CostCurrency:  "CNY",
			Cost:          BeanAmount{Number: "11.00", Currency: "CNY"},
			TotalCost:     true,
			PriceAmount:   110,
			PriceCurrency: "USD",
			Price:         BeanAmount{Number: "1.10", Currency: "USD"},
			TotalPrice:    true,
		}, {
			Posting: Posting{Account: "Assets:Cash", Flag: "?"},
			Blank:   true,
		}},
	}}
}

func testIndexedTransaction(date, payee, file string, line int, hash string, amount int) Transaction {
	return Transaction{
		Date:  date,
		Payee: payee,
		Metadata: map[string]MetadataValue{
			"orderId":       "order-cafe",
			"statementHash": "hash-cafe",
			"imported":      true,
			"amount":        float64(12),
			"empty":         nil,
		},
		Tags:  []string{"work", "food"},
		Links: []string{"receipt-cafe"},
		Postings: []Posting{
			{Account: "Expenses:Food", Amount: amount, Currency: "CNY"},
			{Account: "Assets:Cash", Amount: -amount, Currency: "CNY"},
		},
		Source: TransactionSource{File: file, Line: line, Hash: hash},
	}
}
