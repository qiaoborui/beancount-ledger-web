package app

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

// A deterministic booked model for these USD fixtures, independent of the raw
// parse retained by Snapshot. The inferred cash leg is intentionally explicit
// only in the canonical model, never in the source editor/reversal draft.
func retentionModel(lines []BeanLine, root string) *LocalCanonicalModel {
	parsed := ParseBeanLines(lines)
	model := &LocalCanonicalModel{Version: 1, Options: map[string]string{"operating_currency": "USD"}}
	for _, entry := range parsed.Entries {
		switch entry.Kind {
		case "transaction", "open", "commodity", "balance", "price":
		default:
			continue
		}
		entry.File, _ = filepath.Rel(root, entry.File)
		entry.RawLines = nil
		for i := range entry.Postings {
			if entry.Postings[i].Blank {
				entry.Postings[i].Quantity = BeanAmount{Number: "-12", Currency: "USD"}
			}
		}
		model.Entries = append(model.Entries, entry)
	}
	return model
}

func retentionConfig(t *testing.T, text string) (Config, []BeanEntry) {
	t.Helper()
	cfg := canonicalTestConfig(t, text)
	lines, err := readConfiguredLedgerLines(cfg)
	if err != nil {
		t.Fatal(err)
	}
	parsed := ParseBeanLines(lines)
	if len(parsed.Errors) != 0 {
		t.Fatal(parsed.Errors)
	}
	cfg.localCanonical = retentionModel(lines, cfg.LedgerRoot)
	return cfg, parsed.Entries
}

func TestCompactLocalCanonicalSourceSelection(t *testing.T) {
	var source []BeanEntry
	for i, kind := range []string{"option", "plugin", "include", "pushtag", "poptag", "pushmeta", "popmeta", "open", "price", "balance", "transaction", "transaction", "transaction"} {
		source = append(source, BeanEntry{Kind: kind, File: "main.bean", Line: i + 1, RawLines: []string{kind}})
	}
	source = append(source, BeanEntry{Kind: "transaction", File: "other.bean", Line: 12}, BeanEntry{Kind: "transaction", File: "main.bean", Line: 0})
	txns := []Transaction{
		{Source: TransactionSource{File: "main.bean", Line: 11}, Entry: &LedgerEntry{}},
		{Source: TransactionSource{File: "main.bean", Line: 12}},
		// A second canonical row sharing a source must not erase the first's need.
		{Source: TransactionSource{File: "main.bean", Line: 12}, Entry: &LedgerEntry{}},
		{Source: TransactionSource{File: "main.bean", Line: 12}},
		{Source: TransactionSource{File: "main.bean", Line: 0, Hash: "generated:example"}},
	}
	want := append(append([]BeanEntry(nil), source[1:7]...), source[11])
	got := compactLocalCanonicalSource(source, txns)
	if !reflect.DeepEqual(got, want) || cap(got) != len(want) {
		t.Fatalf("unexpected retention: len=%d cap=%d", len(got), cap(got))
	}
	source[1].Kind = "changed"
	if got[0].Kind != "plugin" {
		t.Fatal("retained original parser backing array")
	}
	for _, input := range [][]BeanEntry{nil, {source[10]}} {
		empty := compactLocalCanonicalSource(input, nil)
		snapshot := &LedgerSnapshot{SourceBeanEntries: empty, BeanEntries: source}
		if empty == nil || cap(empty) != 0 || len(snapshotSourceBeanEntries(snapshot)) != 0 {
			t.Fatal("empty compact source fell back to canonical entries")
		}
	}
	legacy := &LedgerSnapshot{BeanEntries: source}
	if !reflect.DeepEqual(snapshotSourceBeanEntries(legacy), source) {
		t.Fatal("noncanonical fallback changed")
	}
}

const retentionFixture = `option "operating_currency" "USD"
plugin "beancount.plugins.auto_accounts"
2000-01-01 open Assets:Cash USD
2000-01-01 open Expenses:Food USD
2026-01-01 * "Ordinary" "Keep draft" #food ^receipt
  note: "literal"
  Expenses:Food 12 USD
  Assets:Cash
2026-01-02 * "Commented" ; keep comment
  Expenses:Food 12 USD ; posting comment
  Assets:Cash
pushtag #trip
pushmeta project: "scope"
2026-01-03 * "Scoped"
  Expenses:Food 12 USD
  Assets:Cash
popmeta project:
poptag #trip
2026-01-04 * "Posting metadata"
  Expenses:Food 12 USD
    receipt: "posting only"
  Assets:Cash
`

func TestLocalSourceRetentionSnapshotEquivalence(t *testing.T) {
	cfg, source := retentionConfig(t, retentionFixture)
	// A transformed row shares a source, plus a generated row has no editable
	// source. Both must preserve exactly the old canonical/raw split.
	duplicate := cfg.localCanonical.Entries[2]
	duplicate.Narration = "plugin transformed"
	duplicate.Postings = append([]parsedPosting(nil), duplicate.Postings...)
	duplicate.Postings[0].Quantity.Number = "24"
	duplicate.Postings[1].Quantity.Number = "-24"
	generated := duplicate
	generated.Line = 999
	cfg.localCanonical.Entries = append(cfg.localCanonical.Entries, duplicate, generated)
	expectedEntries, err := localCanonicalEntries(cfg, source)
	if err != nil {
		t.Fatal(err)
	}
	expectedTxns := legacyCanonicalTransactionsForTest(expectedEntries, source)
	snapshot, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(snapshot.BeanEntries, expectedEntries) || !reflect.DeepEqual(snapshot.Transactions, expectedTxns) {
		t.Fatal("canonical entries/postings/rawlines/hashes/editor drafts changed")
	}
	if len(snapshot.SourceBeanEntries) != 8 || cap(snapshot.SourceBeanEntries) != 8 {
		t.Fatalf("retained %d/%d source entries, want 8", len(snapshot.SourceBeanEntries), cap(snapshot.SourceBeanEntries))
	}
	for _, entry := range snapshot.SourceBeanEntries {
		if entry.Kind == "transaction" && entry.Payee == "Ordinary" {
			t.Fatal("ordinary source retained")
		}
	}
	full := *snapshot
	full.SourceBeanEntries = source
	full.BeanEntries = expectedEntries
	full.Transactions = expectedTxns
	for _, unlocked := range []bool{false, true} {
		got := BuildLedgerBootstrap(snapshot, "2026-01-01", "2026-02-01", unlocked, "USD", "2026-01-31")
		want := BuildLedgerBootstrap(&full, "2026-01-01", "2026-02-01", unlocked, "USD", "2026-01-31")
		if !reflect.DeepEqual(got, want) {
			t.Fatal("bootstrap changed")
		}
	}
	for _, txn := range snapshot.Transactions {
		query := map[string]string{"file": "main.bean", "line": fmt.Sprint(txn.Source.Line), "hash": txn.Source.Hash}
		status, got, err := localTransactionDetailResponse(cfg, snapshot, query)
		wantStatus, want, wantErr := localTransactionDetailResponse(cfg, &full, query)
		if status != 200 || err != nil || wantStatus != status || wantErr != nil || !bytes.Equal(got, want) {
			t.Fatal("detail changed", status, err)
		}
	}
	last := snapshot.Transactions[len(snapshot.Transactions)-1]
	if last.Source.Line != 0 || last.Entry != nil || !strings.HasPrefix(last.Source.Hash, "generated:") {
		t.Fatal("generated locator changed")
	}
	if snapshot.Transactions[0].Entry == nil || snapshot.Transactions[0].Entry.Postings[1].Amount != "" {
		t.Fatal("inferred editor leg changed")
	}
	if snapshot.Transactions[2].Entry != nil || snapshot.Transactions[2].Metadata["project"] != "scope" || !reflect.DeepEqual(snapshot.Transactions[2].Tags, []string{"trip"}) {
		t.Fatal("metadata scope or edit guard changed")
	}
}

func TestLocalSourceRetentionEntriesEndpointControls(t *testing.T) {
	input := localTestRequest(t)
	mustWrite(t, filepath.Join(input.WorkspaceRoot, "main.bean"), "include \"child.bean\"\n")
	mustWrite(t, filepath.Join(input.WorkspaceRoot, "child.bean"), retentionFixture)
	cfg, err := localConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	lines, err := readConfiguredLedgerLines(cfg)
	if err != nil {
		t.Fatal(err)
	}
	source := ParseBeanLines(lines).Entries
	input.Canonical = retentionModel(lines, cfg.LedgerRoot)
	input.Path = "/api/ledger/entries"
	var got BeanLoadResult
	if err := json.Unmarshal(localTestDispatch(t, input), &got); err != nil {
		t.Fatal(err)
	}
	cfg.localCanonical = input.Canonical
	entries, err := localCanonicalEntries(cfg, source)
	if err != nil {
		t.Fatal(err)
	}
	want := BeanLoadResultFromEntries(entries, nil)
	want.OptionsMap = copyStringMap(input.Canonical.Options)
	want.Plugins = SDKPluginsFromBeanEntries(source)
	want.Includes = SDKIncludesFromBeanEntries(source)
	want.Directives = SDKControlEntriesFromBeanEntries(source)
	// Round-trip the expected SDK projection just as the endpoint does, including
	// its existing source locators and nil/empty JSON representation.
	raw, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	var expected BeanLoadResult
	if err := json.Unmarshal(raw, &expected); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, expected) {
		t.Fatalf("entries endpoint changed\ngot=%+v\nwant=%+v", got, expected)
	}
	if len(got.Plugins) != 1 || len(got.Includes) != 1 || len(got.Directives) != 4 {
		t.Fatal("missing controls")
	}
}

func TestLocalSourceRetentionReversalGuards(t *testing.T) {
	cases := []struct {
		name, body string
		allowed    bool
	}{
		{"ordinary", "  Expenses:Food 12 USD\n  Assets:Cash\n", true},
		{"commented", "  ; whole line\n  Expenses:Food 12 USD ; posting\n  Assets:Cash\n", true},
		{"posting-metadata", "  Expenses:Food 12 USD\n    receipt: \"keep\"\n  Assets:Cash\n", false},
		{"expression", "  Expenses:Food (6 + 6) USD\n  Assets:Cash\n", false},
		{"typed-metadata", "  when: 2026-01-01\n  Expenses:Food 12 USD\n  Assets:Cash\n", false},
		{"scoped-metadata", "  Expenses:Food 12 USD\n  Assets:Cash\npopmeta project:\n", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var outputs []LedgerEntry
			var failures []string
			for _, compact := range []bool{false, true} {
				text := "2000-01-01 open Assets:Cash USD\n2000-01-01 open Expenses:Food USD\n"
				if tc.name == "scoped-metadata" {
					text += "pushmeta project: \"scope\"\n"
				}
				text += "2026-01-01 * \"Lunch\""
				if tc.name != "ordinary" {
					text += " ; original comment"
				}
				text += "\n" + tc.body
				cfg, source := retentionConfig(t, text)
				cache := NewLedgerCache(cfg)
				snapshot, err := cache.Snapshot()
				if err != nil {
					t.Fatal(err)
				}
				if !compact {
					snapshot.SourceBeanEntries = source
				}
				original := snapshot.Transactions[0]
				if tc.name != "ordinary" && original.Entry != nil {
					t.Fatal("unsafe editor draft accepted")
				}
				writer := NewLedgerWriter(cfg, cache)
				writer.stagingValidation = func() error { return nil }
				before := mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean"))
				entry, err := NewTransactionServiceWithSnapshot(nil, writer, func() (*LedgerSnapshot, error) { return snapshot, nil }).Reverse(ReverseTransactionRequest{Source: original.Source, Date: "2026-01-02"})
				if tc.allowed {
					if err != nil {
						t.Fatal(err)
					}
					if entry.Postings[0].Amount != "-12" || entry.Postings[1].Amount != "" {
						t.Fatal("raw inferred amount lost", entry)
					}
					outputs = append(outputs, entry)
				} else {
					if err == nil {
						t.Fatal("lossless reversal guard bypassed")
					}
					failures = append(failures, err.Error())
				}
				after := mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean"))
				if tc.allowed {
					// The writer may append an include to main.bean; the original
					// transaction block itself must still resolve by its exact hash.
					if _, _, _, err := transactionBlock(string(after), original.Source); err != nil {
						t.Fatal("original transaction modified", err)
					}
				} else if !bytes.Equal(before, after) {
					t.Fatal("rejected reversal modified source")
				}
			}
			if len(outputs) == 2 && !reflect.DeepEqual(outputs[0], outputs[1]) {
				t.Fatal("reversal changed")
			}
			if len(failures) == 2 && failures[0] != failures[1] {
				t.Fatal("reversal guard changed")
			}
		})
	}
}

func TestLocalSourceRetentionReversalRejectsStaleHash(t *testing.T) {
	cfg, _ := retentionConfig(t, `2026-01-01 * "Lunch" ; retain for reversal
  Expenses:Food 12 USD
  Assets:Cash
`)
	cache := NewLedgerCache(cfg)
	snapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.SourceBeanEntries) != 1 || snapshot.Transactions[0].Entry != nil {
		t.Fatal("missing fallback fixture")
	}
	// FindTransaction still locates this row, but its retained raw block must
	// independently pass the reversal hash check before any write is attempted.
	snapshot.Transactions[0].Source.Hash = "stale"
	writer := NewLedgerWriter(cfg, cache)
	writer.stagingValidation = func() error {
		t.Fatal("stale reversal reached validation")
		return nil
	}
	before := mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean"))
	_, err = NewTransactionServiceWithSnapshot(nil, writer, func() (*LedgerSnapshot, error) {
		return snapshot, nil
	}).Reverse(ReverseTransactionRequest{Source: snapshot.Transactions[0].Source, Date: "2026-01-02"})
	if err == nil || !bytes.Equal(before, mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean"))) {
		t.Fatal("stale source hash accepted or source modified")
	}
}

func TestLocalSourceRetentionNativeCanonicalOnly(t *testing.T) {
	for _, local := range []bool{false, true} {
		t.Run(fmt.Sprintf("local=%t", local), func(t *testing.T) {
			cfg := testLedger(t)
			cfg.localTransport = local
			cfg.localEntrypoint = "main.bean"
			if !local {
				// A model alone must not opt the web/filesystem cache into the
				// native canonical path (this version would fail normalization).
				cfg.localCanonical = &LocalCanonicalModel{Version: -1}
			}
			snapshot, err := NewLedgerCache(cfg).Snapshot()
			if err != nil {
				t.Fatal(err)
			}
			if snapshot.SourceBeanEntries != nil || len(snapshot.BeanEntries) == 0 ||
				!reflect.DeepEqual(snapshotSourceBeanEntries(snapshot), snapshot.BeanEntries) {
				t.Fatal("noncanonical source fallback changed")
			}
		})
	}
}

func TestLocalSourceRetentionOwnedRebuildAndMutation(t *testing.T) {
	cfg, _ := retentionConfig(t, retentionFixture)
	cfg.localCanonicalOwned = true
	version, err := ledgerVersion(cfg)
	if err != nil {
		t.Fatal(err)
	}
	cfg.localCanonicalVersion = version.Version
	pointer := &cfg.localCanonical.Entries[0]
	cache := NewLedgerCache(cfg)
	first, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	cache.Clear()
	again, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if &again.BeanEntries[0] != pointer || !reflect.DeepEqual(first.SourceBeanEntries, again.SourceBeanEntries) || !reflect.DeepEqual(first.Transactions, again.Transactions) {
		t.Fatal("owned rebuild changed source or canonical model")
	}
	path := filepath.Join(cfg.LedgerRoot, "main.bean")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	text := strings.Replace(retentionFixture, "Commented", "Rewritten", 1)
	mustWrite(t, path, text)
	if err := os.Chtimes(path, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	for _, clear := range []bool{false, true} {
		if clear {
			cache.Clear()
		}
		if _, err := cache.Snapshot(); !errors.Is(err, ErrLocalModelUnavailable) {
			t.Fatal("stale owned model accepted", err)
		}
	}
}

// The paired retained-heap probe deliberately keeps the SAME canonical model,
// raw lines and transactions alive across both GCs. Unlike B/op this measures
// surviving Go heap, not cumulative allocation or peak/device footprint. A
// comment-heavy fixture (every row commented) exposes the fallback worst case.
func BenchmarkLocalSourceRetainedHeap100k(b *testing.B) {
	for _, commented := range []bool{false, true} {
		b.Run(fmt.Sprintf("commented=%t", commented), func(b *testing.B) {
			var fullBytes, compactBytes, retainedRows float64
			for range b.N {
				runtime.GC()
				var baseline, full, compact runtime.MemStats
				runtime.ReadMemStats(&baseline)
				snapshot, model := retentionHeapFixture(100000, commented)
				if len(snapshot.Transactions) != 100000 || len(model.Entries) != 100000 ||
					&snapshot.BeanEntries[0] != &model.Entries[0] {
					b.Fatal("probe lost the owned canonical model")
				}
				runtime.GC()
				runtime.ReadMemStats(&full)
				snapshot.SourceBeanEntries = compactLocalCanonicalSource(snapshot.SourceBeanEntries, snapshot.Transactions)
				runtime.GC()
				runtime.ReadMemStats(&compact)
				fullBytes += float64(int64(full.HeapAlloc) - int64(baseline.HeapAlloc))
				compactBytes += float64(int64(compact.HeapAlloc) - int64(baseline.HeapAlloc))
				retainedRows += float64(len(snapshot.SourceBeanEntries))
				wantRows := 0
				if commented {
					wantRows = 100000
				}
				if len(snapshot.SourceBeanEntries) != wantRows {
					b.Fatal("unexpected fallback count", len(snapshot.SourceBeanEntries))
				}
				runtime.KeepAlive(snapshot)
				runtime.KeepAlive(model)
			}
			b.ReportMetric(fullBytes/float64(b.N), "full-live-B")
			b.ReportMetric(compactBytes/float64(b.N), "compact-live-B")
			b.ReportMetric((fullBytes-compactBytes)/float64(b.N), "saved-live-B")
			b.ReportMetric(retainedRows/float64(b.N), "retained-rows")
		})
	}
}

func retentionHeapFixture(count int, commented bool) (*LedgerSnapshot, *LocalCanonicalModel) {
	const root = "/synthetic"
	lines := make([]BeanLine, 0, count*4)
	for i := range count {
		header := fmt.Sprintf("2026-01-01 * \"Shop %d\" \"Synthetic expense\" #food", i)
		if commented {
			header += " ; preserve receipt comment"
		}
		for _, text := range []string{header, "  note: \"synthetic metadata\"", "  Expenses:Food 12 USD", "  Assets:Cash"} {
			lines = append(lines, BeanLine{File: root + "/main.bean", Line: len(lines) + 1, Text: text})
		}
	}
	source := ParseBeanLines(lines).Entries
	model := retentionModel(lines, root)
	cfg := Config{LedgerRoot: root, localCanonical: model, localCanonicalOwned: true}
	entries, err := localCanonicalEntries(cfg, source)
	if err != nil {
		panic(err)
	}
	return &LedgerSnapshot{BeanEntries: entries, SourceBeanEntries: source, Transactions: localCanonicalTransactions(entries, source)}, model
}
