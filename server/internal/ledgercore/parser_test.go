package ledgercore_test

import (
	"testing"

	"github.com/borui/beancount-ledger-web/server/internal/ledgercore"
)

func TestParseTextBuildsSourceAwareEntries(t *testing.T) {
	result := ledgercore.ParseText("mobile.bean", "option \"title\" \"Local Ledger\"\r\n"+
		"pushtag #trip\r\n"+
		"pushmeta source: \"ios\"\r\n"+
		"2026/09/15 * \"Cafe\" \"Lunch\" ^receipt-1\r\n"+
		"  Expenses:Food 12.34 CNY\r\n"+
		"  Assets:Cash\r\n")

	if len(result.Errors) != 0 {
		t.Fatalf("parse errors: %#v", result.Errors)
	}
	if len(result.Entries) != 4 {
		t.Fatalf("entries = %d, want 4", len(result.Entries))
	}
	txn := result.Entries[3]
	if txn.Kind != "transaction" || txn.Date != "2026-09-15" || txn.File != "mobile.bean" || txn.Line != 4 {
		t.Fatalf("unexpected transaction source: %#v", txn)
	}
	if txn.Payee != "Cafe" || txn.Narration != "Lunch" || len(txn.Tags) != 1 || txn.Tags[0] != "trip" {
		t.Fatalf("unexpected transaction header: %#v", txn)
	}
	if txn.Metadata["source"] != "ios" || len(txn.Links) != 1 || txn.Links[0] != "receipt-1" {
		t.Fatalf("scope metadata or links missing: %#v", txn)
	}
	if len(txn.Postings) != 2 || txn.Postings[0].Quantity.Number != "12.34" || txn.Postings[1].Blank != true {
		t.Fatalf("unexpected postings: %#v", txn.Postings)
	}
}

func TestCompileLinesPreservesCompilerValidation(t *testing.T) {
	result := ledgercore.CompileLines([]ledgercore.Line{
		{File: "invalid.bean", Line: 1, Text: "poptag #missing"},
		{File: "invalid.bean", Line: 2, Text: `2026-09-15 * "Cafe" "Lunch"`},
		{File: "invalid.bean", Line: 3, Text: "  Expenses:Food 10.00 CNY"},
		{File: "invalid.bean", Line: 4, Text: "  Assets:Cash -9.00 CNY"},
	})

	if len(result.Errors) != 2 {
		t.Fatalf("compile errors = %#v, want scope and balance errors", result.Errors)
	}
	if result.Errors[0].File != "invalid.bean" || result.Errors[0].Line != 1 {
		t.Fatalf("unexpected source location: %#v", result.Errors[0])
	}
}

func TestLexerCompatibilitySurface(t *testing.T) {
	tokens := ledgercore.ScanBeanLine(`include "accounts.bean"`)
	if len(tokens) != 2 || tokens[1].Kind != ledgercore.TokenString || tokens[1].Value != "accounts.bean" {
		t.Fatalf("tokens = %#v", tokens)
	}
}

func TestParserPreservesLargeExponentBehavior(t *testing.T) {
	result := ledgercore.ParseText("canonical.bean", "2026-09-15 price USD 1e65 CNY")
	if len(result.Errors) != 0 || len(result.Entries) != 1 {
		t.Fatalf("large canonical decimal rejected: %#v", result)
	}
	if result.Entries[0].AmountValue.Number != "1e65" {
		t.Fatalf("amount = %#v", result.Entries[0].AmountValue)
	}
}
