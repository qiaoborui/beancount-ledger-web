package app

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestLocalSourceStatsTraversalMatchesSourceLoading(t *testing.T) {
	cfg := canonicalTestConfig(t, "include \"parts/*.bean\"\r\n; final comment")
	if err := os.Mkdir(filepath.Join(cfg.LedgerRoot, "parts"), 0700); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "parts", "a.bean"), "include \"../main.bean\"\n2026-01-01 open Assets:Cash CNY\n")
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "parts", "b.bean"), "; unicode 商店\r\n")
	lines, want, err := localLedgerSource(cfg)
	if err != nil {
		t.Fatal(err)
	}
	empty, got, err := walkLocalLedgerSource(cfg, false)
	if err != nil {
		t.Fatal(err)
	}
	if empty != nil || !reflect.DeepEqual(got, want) {
		t.Fatal("stats-only traversal retained lines or changed version inputs")
	}
	if len(got) != 3 || len(lines) != 7 {
		t.Fatalf("files=%d lines=%d", len(got), len(lines))
	}
	if lines[0].Text != `include "parts/*.bean"` || lines[len(lines)-1].Line != 2 {
		t.Fatal("CRLF or include insertion order changed")
	}
}

func TestLocalSourceTraversalModesRejectInvalidIncludes(t *testing.T) {
	for _, name := range []string{"missing", "escape", "absolute", "symlink", "oversize"} {
		t.Run(name, func(t *testing.T) {
			cfg := canonicalTestConfig(t, "")
			include := "missing.bean"
			switch name {
			case "escape":
				include = "../outside.bean"
			case "absolute":
				include = filepath.Join(t.TempDir(), "outside.bean")
			case "symlink":
				include = "link.bean"
				if err := os.Symlink(filepath.Join(cfg.LedgerRoot, "main.bean"), filepath.Join(cfg.LedgerRoot, include)); err != nil {
					t.Fatal(err)
				}
			case "oversize":
				include = "large.bean"
				f, err := os.Create(filepath.Join(cfg.LedgerRoot, include))
				if err != nil {
					t.Fatal(err)
				}
				err = f.Truncate((8 << 20) + 1)
				closeErr := f.Close()
				if err != nil || closeErr != nil {
					t.Fatalf("truncate=%v close=%v", err, closeErr)
				}
			}
			mustWrite(t, filepath.Join(cfg.LedgerRoot, "main.bean"), fmt.Sprintf("include %q\n", include))
			_, _, fullErr := walkLocalLedgerSource(cfg, true)
			_, _, statsErr := walkLocalLedgerSource(cfg, false)
			if fullErr == nil || statsErr == nil || fullErr.Error() != statsErr.Error() {
				t.Fatalf("full=%v stats=%v", fullErr, statsErr)
			}
		})
	}
}

// Reference the pre-optimization conversion so editor hashes, generated IDs,
// metadata, transformed postings and pad handling cannot silently change.
func legacyCanonicalTransactionsForTest(entries, source []BeanEntry) []Transaction {
	var transactions []BeanEntry
	for _, entry := range entries {
		if entry.Kind == "transaction" {
			transactions = append(transactions, entry)
		}
	}
	txns := TransactionsFromBeanEntries(transactions)
	bySource := map[string]BeanEntry{}
	for _, entry := range source {
		if entry.Kind == "transaction" {
			bySource[canonicalSourceKey(entry)] = entry
		}
	}
	for i, entry := range transactions {
		txns[i].Entry = nil
		if raw, ok := bySource[canonicalSourceKey(entry)]; ok {
			txns[i].Source.Hash = transactionHash(raw.RawLines)
			txns[i].Entry = EditableLedgerEntryFromBeanTransaction(raw)
		} else {
			txns[i].Source.Line = 0
			txns[i].Source.Hash = "generated:" + transactionHash([]string{canonicalSourceKey(entry), fmt.Sprint(i)})
		}
	}
	return txns
}

func TestLocalCanonicalTransactionsAllocationParity(t *testing.T) {
	source := ParseBeanLines([]BeanLine{
		{File: "main.bean", Line: 1, Text: `2026-01-01 * "Shop" "Lunch" #food ^receipt`},
		{File: "main.bean", Line: 2, Text: `  note: "Keep raw editor text"`},
		{File: "main.bean", Line: 3, Text: `  Expenses:Food  12.34 CNY`},
		{File: "main.bean", Line: 4, Text: `  Assets:Cash`},
	}).Entries
	if len(source) != 1 {
		t.Fatal("invalid fixture")
	}
	transformed := source[0]
	transformed.Narration = "Plugin transformed"
	transformed.Postings = append([]parsedPosting(nil), transformed.Postings...)
	transformed.Postings[0].Amount = 5678
	transformed.Postings[1].Amount = -5678
	transformed.Postings[1].Blank = false
	transformed.Postings[1].Currency = "CNY"
	generated := transformed
	generated.File = "generated.bean"
	generated.Line = 23
	entries := []BeanEntry{{Kind: "pad", Account: "Assets:Cash", Account2: "Equity:Opening"}, transformed, {Kind: "balance", Account: "Assets:Cash", Amount: 99999, Currency: "CNY"}, generated}
	want := legacyCanonicalTransactionsForTest(entries, source)
	got := localCanonicalTransactions(entries, source)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("optimized conversion differs\ngot=%+v\nwant=%+v", got, want)
	}
	if len(got) != 2 || got[0].Entry == nil || got[1].Entry != nil || got[1].Source.Line != 0 || got[0].Postings[0].Amount != 5678 {
		t.Fatal("source/transformed/generated semantics lost")
	}
}

func BenchmarkLocalSourceTraversal(b *testing.B) {
	root := b.TempDir()
	var source strings.Builder
	for i := 0; i < 10000; i++ {
		fmt.Fprintf(&source, "2026-01-01 * \"Shop\" \"Expense %d\"\n  Expenses:Food  10 CNY\n  Assets:Cash  -10 CNY\n", i)
	}
	if err := os.WriteFile(filepath.Join(root, "main.bean"), []byte(source.String()), 0600); err != nil {
		b.Fatal(err)
	}
	cfg := Config{localTransport: true, localEntrypoint: "main.bean", LedgerRoot: root}
	for _, collect := range []bool{true, false} {
		b.Run(fmt.Sprintf("collectLines=%t", collect), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if _, _, err := walkLocalLedgerSource(cfg, collect); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkLocalCanonicalTransactionConversion(b *testing.B) {
	source := make([]BeanEntry, 10000)
	for i := range source {
		source[i] = BeanEntry{Kind: "transaction", Date: "2026-01-01", Flag: "*", File: "main.bean", Line: i*3 + 1, Narration: "Synthetic", RawLines: []string{"2026-01-01 * \"Synthetic\"", "  Expenses:Food  10 CNY", "  Assets:Cash  -10 CNY"}, Postings: []parsedPosting{{Posting: Posting{Account: "Expenses:Food", Amount: 1000, Currency: "CNY"}}, {Posting: Posting{Account: "Assets:Cash", Amount: -1000, Currency: "CNY"}}}}
	}
	for _, optimized := range []bool{false, true} {
		b.Run(fmt.Sprintf("optimized=%t", optimized), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if optimized {
					localCanonicalTransactions(source, source)
				} else {
					legacyCanonicalTransactionsForTest(source, source)
				}
			}
		})
	}
}
