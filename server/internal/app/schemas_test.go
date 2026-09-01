package app

import (
	"strings"
	"testing"
)

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
	validTags := AddTransactionTagsRequest{
		Sources: []TransactionSource{{File: "transactions/2026/05.bean", Line: 1, Hash: "hash"}},
		Tags:    []string{"travel", "#trip-2026-hokkaido"},
	}
	if err := validTags.Validate(); err != nil {
		t.Fatalf("valid bulk tags should pass: %v", err)
	}
	invalidTags := validTags
	invalidTags.Tags = []string{"北海道旅行"}
	if err := invalidTags.Validate(); err == nil {
		t.Fatal("non-ASCII tag should fail validation")
	}
	tooLong := validTags
	tooLong.Tags = []string{strings.Repeat("a", maxTagLength+1)}
	if err := tooLong.Validate(); err == nil {
		t.Fatal("oversized tag should fail validation")
	}
	missingHash := validTags
	missingHash.Sources = []TransactionSource{{File: "transactions/2026/05.bean", Line: 1}}
	if err := missingHash.Validate(); err == nil {
		t.Fatal("bulk tag source without hash should fail validation")
	}
}
