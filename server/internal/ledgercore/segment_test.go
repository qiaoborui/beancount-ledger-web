package ledgercore

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

func assertSegmentParity(t *testing.T, name string, lines []BeanLine) {
	t.Helper()
	want := ParseLines(lines).Entries
	segments := SegmentLines(lines)
	if len(segments.Entries) != len(want) {
		t.Fatalf("%s: segmented %d entries, parsed %d", name, len(segments.Entries), len(want))
	}
	got := append([]BeanEntry(nil), segments.Entries...)
	deferred := map[int]bool{}
	for _, d := range segments.Deferred {
		deferred[d.Index] = true
		header := segments.Entries[d.Index]
		if header.Kind != want[d.Index].Kind || header.File != want[d.Index].File || header.Line != want[d.Index].Line ||
			header.Date != want[d.Index].Date || header.Flag != want[d.Index].Flag || !reflect.DeepEqual(header.RawLines, want[d.Index].RawLines) {
			t.Fatalf("%s: header %d = %+v, want locator of %+v", name, d.Index, header, want[d.Index])
		}
		got[d.Index] = d.Parse()
	}
	for i := range want {
		if want[i].Kind == "transaction" && !deferred[i] {
			t.Fatalf("%s: transaction %d was not deferred", name, i)
		}
	}
	if !reflect.DeepEqual(got, want) {
		for i := range want {
			if !reflect.DeepEqual(got[i], want[i]) {
				t.Fatalf("%s: entry %d\n got %#v\nwant %#v", name, i, got[i], want[i])
			}
		}
	}
}

func TestSegmentLinesMatchesParseLinesWithScopes(t *testing.T) {
	text := `option "operating_currency" "CNY"
plugin "beancount.plugins.auto_accounts"
2026-01-01 open Assets:Cash CNY
2026-01-01 open Expenses:Food

pushtag #trip
pushmeta location: "Tokyo"
2026-01-02 * "Cafe" "Coffee" #own ^link
  ; inline comment
  note: "kept"
  Expenses:Food  12.00 CNY
  Assets:Cash
; trailing comment kept in the block

2026-01-03 txn "Dinner"
  Expenses:Food  30 CNY @ 1 CNY
  Assets:Cash  -30 CNY
poptag #trip
2026-01-04 ! "Flagged"
  Expenses:Food  1 CNY
  Assets:Cash
popmeta location:
2026-01-05 balance Assets:Cash -43 CNY
2026-01-05 price USD 7.1 CNY
2026-01-06 A "Letter flag"
  Expenses:Food  1 CNY
  Assets:Cash
2026-01-07 bogus directive
2026-01-08 * "Last"
  Expenses:Food  2 CNY
  Assets:Cash`
	assertSegmentParity(t, "scopes", beanTextLines("main.bean", text))
}

func TestSegmentLinesMatchesParseLinesOnExamples(t *testing.T) {
	roots, _ := filepath.Glob(filepath.Join("..", "..", "..", "examples", "*"))
	checked := 0
	for _, root := range roots {
		var files []string
		_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err == nil && !info.IsDir() && filepath.Ext(path) == ".bean" {
				files = append(files, path)
			}
			return nil
		})
		sort.Strings(files)
		var lines []BeanLine
		for _, file := range files {
			data, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			lines = append(lines, beanTextLines(file, string(data))...)
		}
		if len(lines) == 0 {
			continue
		}
		assertSegmentParity(t, root, lines)
		checked++
	}
	if checked == 0 {
		t.Fatal("no example ledgers found")
	}
}
