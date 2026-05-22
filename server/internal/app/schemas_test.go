package app

import "testing"

func TestLedgerEntrySchemaValidation(t *testing.T) {
	valid := LedgerEntry{
		Kind:       "transaction",
		Date:       "2026-05-03",
		Payee:      "Bakery",
		Narration:  "Bread",
		Metadata:   map[string]MetadataValue{"orderId": "1"},
		Tags:       []string{"daily"},
		Postings:   []EntryPosting{{Account: "Expenses:Food", Amount: "9.00", Currency: "CNY"}, {Account: "Assets:Cash", Amount: "-9.00", Currency: "CNY"}},
		Confidence: 0.8,
	}
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid transaction should pass: %v", err)
	}

	invalid := valid
	invalid.Postings = []EntryPosting{{Account: "Expenses:Food", Amount: "9.001", Currency: "CNY"}}
	if err := invalid.Validate(); err == nil {
		t.Fatal("invalid postings should fail validation")
	}
}

func TestRequestSchemaValidation(t *testing.T) {
	if err := (ReconcileRequest{Account: "Assets:Cash", ActualAmount: "1.00", BalanceDate: "2026-05-31"}).Validate(); err != nil {
		t.Fatalf("valid reconcile request should pass: %v", err)
	}
	if err := (ReconcileRequest{Account: "Assets:Cash", ActualAmount: "1.001", BalanceDate: "2026-05-31"}).Validate(); err == nil {
		t.Fatal("invalid amount should fail validation")
	}
	if err := (ReverseTransactionRequest{Source: TransactionSource{File: "transactions/2026/05.bean", Line: 1}, Date: "2026-05-02"}).Validate(); err != nil {
		t.Fatalf("valid reverse request should pass: %v", err)
	}
	if err := (ReverseTransactionRequest{Source: TransactionSource{Line: 1}, Date: "2026-05-02"}).Validate(); err == nil {
		t.Fatal("missing source file should fail validation")
	}
}
