package app

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLedgerParserAndCache(t *testing.T) {
	cfg := testLedger(t)
	cache := NewLedgerCache(cfg)
	snapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Transactions) != 2 {
		t.Fatalf("transactions = %d, want 2", len(snapshot.Transactions))
	}
	if snapshot.Balances["Assets:Cash"] != 98800 {
		t.Fatalf("cash balance = %d, want 98800", snapshot.Balances["Assets:Cash"])
	}
	if snapshot.Accounts[0].Account != "Assets:Cash" || snapshot.Accounts[0].Label != "现金" {
		t.Fatalf("account alias not parsed: %#v", snapshot.Accounts[0])
	}
	second, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if second != snapshot {
		t.Fatal("snapshot was not reused")
	}
}

func TestWriterRollsBackOnBeanCheckFailure(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 1\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	cache := NewLedgerCache(cfg)
	writer := NewLedgerWriter(cfg, cache)
	mainBefore, err := os.ReadFile(mainBeanPath(cfg))
	if err != nil {
		t.Fatal(err)
	}
	err = writer.AppendBeanText("2026-06-01", `2026-06-01 * "Shop" "Snack"`+"\n  Expenses:Food 8.00 CNY\n  Assets:Cash -8.00 CNY\n")
	if err == nil {
		t.Fatal("expected bean-check failure")
	}
	mainAfter, err := os.ReadFile(mainBeanPath(cfg))
	if err != nil {
		t.Fatal(err)
	}
	if string(mainAfter) != string(mainBefore) {
		t.Fatal("main.bean was not rolled back")
	}
	if _, err := os.Stat(filepath.Join(cfg.LedgerRoot, "transactions", "2026", "06.bean")); !os.IsNotExist(err) {
		t.Fatalf("new monthly file should have been removed, err=%v", err)
	}
}
