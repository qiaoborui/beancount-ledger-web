package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
)

func cloneCanonicalForTest(t *testing.T, model *LocalCanonicalModel) *LocalCanonicalModel {
	t.Helper()
	data, err := json.Marshal(model)
	if err != nil {
		t.Fatal(err)
	}
	var copy LocalCanonicalModel
	if err := json.Unmarshal(data, &copy); err != nil {
		t.Fatal(err)
	}
	return &copy
}

func TestLocalCanonicalOwnedNormalizesWithoutDuplicateArrays(t *testing.T) {
	cfg := canonicalTestConfig(t, canonicalBookingFixture)
	model := canonicalPythonModel(t, cfg)
	cfg.localCanonical = cloneCanonicalForTest(t, model)
	before, err := json.Marshal(cfg.localCanonical)
	if err != nil {
		t.Fatal(err)
	}
	legacy, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.localCanonical.normalizedRoot != "" {
		t.Fatal("caller model mutated")
	}
	after, err := json.Marshal(cfg.localCanonical)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatal("legacy path changed caller input")
	}
	owned := cfg
	owned.localCanonical = cloneCanonicalForTest(t, model)
	owned.localCanonicalOwned = true
	version, err := ledgerVersion(owned)
	if err != nil {
		t.Fatal(err)
	}
	owned.localCanonicalVersion = version.Version
	originalEntries := &owned.localCanonical.Entries[0]
	var originalPostings []parsedPosting
	for _, entry := range owned.localCanonical.Entries {
		if len(entry.Postings) > 0 {
			originalPostings = entry.Postings
			break
		}
	}
	cache := NewLedgerCache(owned)
	got, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if &got.BeanEntries[0] != originalEntries {
		t.Fatal("entry array copied")
	}
	for _, entry := range got.BeanEntries {
		if len(entry.Postings) > 0 {
			if &entry.Postings[0] != &originalPostings[0] {
				t.Fatal("posting array copied")
			}
			break
		}
	}
	if !reflect.DeepEqual(got.BeanEntries, legacy.BeanEntries) || !reflect.DeepEqual(got.Transactions, legacy.Transactions) || !reflect.DeepEqual(got.RawBalances, legacy.RawBalances) {
		t.Fatal("booked/generated/editor semantics changed")
	}
	// Clearing derived state on unchanged source must not normalize twice or fail
	// on the absolute paths that now belong to this exact workspace.
	cache.Clear()
	again, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if &again.BeanEntries[0] != originalEntries || !reflect.DeepEqual(again.Transactions, legacy.Transactions) {
		t.Fatal("rebuild lost owned model")
	}
	// Same-size and same-mtime source changes are still rejected, even on a
	// pinned cache pointer after its handle has been resolved.
	path := filepath.Join(cfg.LedgerRoot, "main.bean")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	raw[0] = ';'
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	if _, err := cache.Snapshot(); !errors.Is(err, ErrLocalModelUnavailable) {
		t.Fatal("changed source accepted", err)
	}
	cache.MarkDirty()
	if _, err := cache.Snapshot(); !errors.Is(err, ErrLocalModelUnavailable) {
		t.Fatal("dirty canonical rebuilt stale", err)
	}
}

func TestLocalCanonicalOwnedRejectsInvalidBeforeMutation(t *testing.T) {
	for _, bad := range []BeanEntry{
		{File: "../escape.bean"}, {File: "/absolute.bean"},
		{Postings: []parsedPosting{{Quantity: BeanAmount{Number: "", Currency: "CNY"}}}},
	} {
		cfg := canonicalTestConfig(t, "")
		cfg.localCanonicalOwned = true
		cfg.localCanonical = &LocalCanonicalModel{Version: 1, Entries: []BeanEntry{{File: "main.bean"}, bad}}
		if _, err := localCanonicalEntries(cfg, nil); err == nil {
			t.Fatal("bad model accepted")
		}
		if cfg.localCanonical.Entries[0].File != "main.bean" || cfg.localCanonical.normalizedRoot != "" {
			t.Fatal("partial normalization on error")
		}
	}
}

func TestLocalCanonicalOwnedRejectsWrongRoot(t *testing.T) {
	cfg := canonicalTestConfig(t, "")
	cfg.localCanonicalOwned = true
	cfg.localCanonical = &LocalCanonicalModel{Version: 1, Entries: []BeanEntry{{File: "main.bean"}}}
	if _, err := localCanonicalEntries(cfg, nil); err != nil {
		t.Fatal(err)
	}
	cfg.LedgerRoot = t.TempDir()
	if _, err := localCanonicalEntries(cfg, nil); err == nil {
		t.Fatal("owned model crossed workspace")
	}
}

func BenchmarkLocalCanonicalEntryOwnership10k(b *testing.B) {
	template := make([]BeanEntry, 10000)
	for i := range template {
		template[i] = BeanEntry{Kind: "transaction", File: "main.bean", Line: i + 1, Date: "2026-09-01", Postings: []parsedPosting{{Posting: Posting{Account: "Assets:Cash"}, Quantity: BeanAmount{Number: "-10", Currency: "CNY"}}, {Posting: Posting{Account: "Expenses:Food"}, Quantity: BeanAmount{Number: "10", Currency: "CNY"}}}}
	}
	for _, owned := range []bool{false, true} {
		b.Run(fmt.Sprintf("owned=%t", owned), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				// Both paths include allocation of the input model. Owned normalization
				// avoids a SECOND entry/posting array rather than masking input allocation.
				entries := append([]BeanEntry(nil), template...)
				for j := range entries {
					entries[j].Postings = append([]parsedPosting(nil), template[j].Postings...)
				}
				cfg := Config{LedgerRoot: "/synthetic", localCanonicalOwned: owned, localCanonical: &LocalCanonicalModel{Version: 1, Entries: entries}}
				got, err := localCanonicalEntries(cfg, nil)
				if err != nil || len(got) != 10000 {
					b.Fatal(err)
				}
			}
		})
	}
}

func TestLocalRegisteredModelOwnsCanonicalArrays(t *testing.T) {
	input := localTestRequest(t)
	handle := registerHandleFixture(t, input)
	cfg, err := localConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := resolveLocalModel(cfg, handle, false)
	if err != nil {
		t.Fatal(err)
	}
	cache := resolved.localRegisteredCache
	if !cache.cfg.localCanonicalOwned || cache.cfg.localCanonicalVersion == "" {
		t.Fatal("registration lost exclusive ownership")
	}
	entries := resolved.localCanonical.Entries
	// Exercise concurrent first reads through the same handle/cache. Only the
	// cache mutex may normalize the owned arrays; readers publish immutable rows.
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			snapshot, err := cache.Snapshot()
			if err != nil {
				t.Error(err)
				return
			}
			if &snapshot.BeanEntries[0] != &entries[0] {
				t.Error("registered array copied")
			}
		}()
	}
	wg.Wait()
	snapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Transactions) != 2 || snapshot.BeanEntries[0].Postings[0].Quantity.Number != "123.456789" {
		t.Fatal("booked precision changed")
	}
}
