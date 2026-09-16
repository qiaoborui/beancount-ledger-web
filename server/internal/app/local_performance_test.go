package app

import (
	"fmt"
	"github.com/gin-gonic/gin"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func BenchmarkLocalPageLoad(b *testing.B) {
	gin.SetMode(gin.ReleaseMode)
	root := filepath.Join(b.TempDir(), "generations", "benchmark", "workspace")
	if err := os.MkdirAll(root, 0700); err != nil {
		b.Fatal(err)
	}
	var source strings.Builder
	source.WriteString("option \"operating_currency\" \"CNY\"\n2020-01-01 open Assets:Cash CNY\n2020-01-01 open Expenses:Food CNY\n")
	for i := 0; i < 1000; i++ {
		fmt.Fprintf(&source, "2026-%02d-%02d * \"Shop\" \"Expense %d\"\n  Expenses:Food  10.00 CNY\n  Assets:Cash  -10.00 CNY\n", i%9+1, i%28+1, i)
	}
	if err := os.WriteFile(filepath.Join(root, "main.bean"), []byte(source.String()), 0600); err != nil {
		b.Fatal(err)
	}
	// The iPhone supplies booked canonical entries through its Python bridge.
	// Include that model in the benchmark so hashing it is part of the cost.
	cfg := Config{localTransport: true, localEntrypoint: "main.bean", LedgerRoot: root}
	lines, _, err := localLedgerSource(cfg)
	if err != nil {
		b.Fatal(err)
	}
	compiled := CompileBeanLines(lines)
	model := &LocalCanonicalModel{Version: 1, Entries: compiled.Entries, Options: OptionsMapFromBeanEntries(compiled.Entries)}
	for i := range model.Entries {
		model.Entries[i].File, err = filepath.Rel(root, model.Entries[i].File)
		if err != nil {
			b.Fatal(err)
		}
	}
	for _, page := range []string{"bootstrap", "dashboard", "income-statement", "investments"} {
		b.Run(page, func(b *testing.B) {
			input := LocalRequest{WorkspaceRoot: root, Canonical: model, Path: "/api/ledger/" + page, Query: map[string]string{"start": "2026-09-01", "end": "2026-10-01", "today": "2026-09-16", "valuationCurrency": "CNY"}}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				status, _, err := DispatchLocalRequest(input)
				if status != http.StatusOK || err != nil {
					b.Fatalf("status=%d err=%v", status, err)
				}
			}
		})
	}
}

func TestLocalPageCacheReusesOnlyUnchangedReadModels(t *testing.T) {
	input := localTestRequest(t)
	cfg, err := localConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	first, err := localRequestCache(cfg, false)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := first.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	second, err := localRequestCache(cfg, false)
	if err != nil {
		t.Fatal(err)
	}
	reused, err := second.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if first != second || snapshot != reused {
		t.Fatal("page navigation rebuilt the unchanged ledger")
	}
	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	info, err := os.Stat(file)
	if err != nil {
		t.Fatal(err)
	}
	source := mustRead(t, file)
	changed := strings.Replace(string(source), "2026-05", "2026-04", 1)
	if changed == string(source) {
		t.Fatal("fixture did not change")
	}
	mustWrite(t, file, changed)
	if err := os.Chtimes(file, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	afterEdit, err := localRequestCache(cfg, false)
	if err != nil {
		t.Fatal(err)
	}
	if afterEdit == first {
		t.Fatal("same-size/mtime source edit reused a stale ledger")
	}
	cfg.localCanonical = &LocalCanonicalModel{Version: 1, Options: map[string]string{"operating_currency": "CNY"}}
	canonical, err := localRequestCache(cfg, false)
	if err != nil {
		t.Fatal(err)
	}
	cfg.localCanonical.Options["operating_currency"] = "USD"
	updated, err := localRequestCache(cfg, false)
	if err != nil {
		t.Fatal(err)
	}
	if updated == canonical {
		t.Fatal("canonical model change reused stale plugin output")
	}
	staged, err := localRequestCache(cfg, true)
	if err != nil {
		t.Fatal(err)
	}
	stagedAgain, err := localRequestCache(cfg, true)
	if err != nil {
		t.Fatal(err)
	}
	if staged == updated || staged == stagedAgain {
		t.Fatal("mutable stage reused a read model")
	}
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	if _, err := localRequestCache(cfg, false); err == nil {
		t.Fatal("cached model hid a missing include")
	}
}

func TestLocalPageCacheIsolatesLedgersAndRechecksPathSafety(t *testing.T) {
	first := localTestRequest(t)
	second := localTestRequest(t)
	cfgA, err := localConfig(first)
	if err != nil {
		t.Fatal(err)
	}
	cfgB, err := localConfig(second)
	if err != nil {
		t.Fatal(err)
	}
	a, err := localRequestCache(cfgA, false)
	if err != nil {
		t.Fatal(err)
	}
	b, err := localRequestCache(cfgB, false)
	if err != nil {
		t.Fatal(err)
	}
	if a == b {
		t.Fatal("two ledgers share a cache")
	}
	first.Path = "/api/ledger/bootstrap"
	localTestDispatch(t, first)
	file := filepath.Join(first.WorkspaceRoot, "main.bean")
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(second.WorkspaceRoot, "main.bean"), file); err != nil {
		t.Fatal(err)
	}
	if status, _, err := DispatchLocalRequest(first); status != http.StatusBadRequest || err == nil {
		t.Fatalf("cached generation bypassed path safety: %d %v", status, err)
	}
}
