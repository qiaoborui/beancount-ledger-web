package app

import (
	"reflect"
	"testing"

	"github.com/borui/beancount-ledger-web/server/internal/ledgercore"
)

func TestAppParserAdapterMatchesLedgerCore(t *testing.T) {
	lines := []BeanLine{
		{File: "main.bean", Line: 1, Text: `option "title" "Parity"`},
		{File: "main.bean", Line: 2, Text: `2026-09-15 * "Store" "Water" #daily`},
		{File: "main.bean", Line: 3, Text: "  Expenses:Food 1.25 CNY"},
		{File: "main.bean", Line: 4, Text: "  Assets:Cash"},
	}

	want := ledgercore.ParseLines(lines)
	got := ParseBeanLines(lines)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("app parser drifted from ledgercore:\n got: %#v\nwant: %#v", got, want)
	}
}
