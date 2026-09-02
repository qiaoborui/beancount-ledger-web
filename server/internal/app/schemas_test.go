package app

import (
	"fmt"
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
	rich := valid
	rich.Flag = "!"
	rich.Links = []string{"receipt-2026"}
	rich.Postings = []EntryPosting{
		{Account: "Assets:Broker", Flag: "!", Amount: "1.23456789", Currency: "VT", CostKind: "total", CostAmount: "123.456789", CostCurrency: "USD", CostSpec: `{{ 123.456789 USD, 2026-05-01, "lot-a" }}`, PriceKind: "unit", PriceAmount: "100.1234567", PriceCurrency: "USD"},
		{Account: "Assets:Cash", Amount: "", Currency: ""},
	}
	if err := rich.Validate(); err != nil {
		t.Fatalf("complete editable transaction should preserve exact Beancount values: %v", err)
	}
	for _, amount := range []string{"+1", "1."} {
		direct := rich
		direct.Postings[0].Amount = amount
		if err := direct.Validate(); err != nil {
			t.Fatalf("valid direct Beancount amount %q should pass: %v", amount, err)
		}
	}

	invalid := valid
	invalid.Postings = []EntryPosting{{Account: "Expenses:Food", Amount: "9.0.01", Currency: "CNY"}}
	if err := invalid.Validate(); err == nil {
		t.Fatal("invalid postings should fail validation")
	}

	invalidCostSpec := rich
	invalidCostSpec.Postings[0].CostSpec = "{{ 123.456789 USD }}\n2026-05-02 close Assets:Broker"
	if err := invalidCostSpec.Validate(); err == nil {
		t.Fatal("cost spec with a newline should fail validation")
	}
	for _, costSpec := range []string{"{ ) }", "{ lowercase-garbage }", "{ 1 USD,, 2026-05-01 }", "{ * }", "{{ # 10 USD }}", "{ 1 USD } ; hide following price", "{ NULL }", "{ 1 TRUE }", "{ # 1 FALSE }"} {
		invalidCostSpec := rich
		invalidCostSpec.Postings[0].CostSpec = costSpec
		if err := invalidCostSpec.Validate(); err == nil {
			t.Fatalf("malformed cost spec %q should fail validation", costSpec)
		}
	}

	for _, costSpec := range []string{"{}", "{USD}", `{ "lot-a" }`, "{2026-05-01}", "{ 10 }", "{ 1 / 3 }", "{ # 10 USD }", "{ 1 # 10 USD, 2026-05-01, \"lot-a\" }", "{{ 10 }}"} {
		costOnly := rich
		costOnly.Postings[0].CostSpec = costSpec
		if err := costOnly.Validate(); err != nil {
			t.Fatalf("valid cost spec %q should pass: %v", costSpec, err)
		}
	}

	tooManyTags := valid
	tooManyTags.Tags = make([]string, maxTransactionTags+1)
	for index := range tooManyTags.Tags {
		tooManyTags.Tags[index] = fmt.Sprintf("tag-%d", index)
	}
	if err := tooManyTags.Validate(); err == nil {
		t.Fatal("transaction entry with too many final tags should fail validation")
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
