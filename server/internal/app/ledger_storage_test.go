package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
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

func TestLedgerWriteTransactionRollsBackExistingAndNewFiles(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 1\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	cache := NewLedgerCache(cfg)
	writer := NewLedgerWriter(cfg, cache)
	accountsFile := accountsBeanPath(cfg)
	accountsBefore := string(mustRead(t, accountsFile))
	newFile := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "imports", "rollback.bean")

	err := writer.RunTransaction(func(tx *LedgerWriteTransaction) error {
		if err := tx.WriteFile(accountsFile, []byte(accountsBefore+"\n2026-01-02 open Expenses:Travel CNY\n"), 0o644); err != nil {
			return err
		}
		return tx.WriteFile(newFile, []byte("; should roll back\n"), 0o644)
	})
	if err == nil {
		t.Fatal("expected bean-check failure")
	}
	if got := string(mustRead(t, accountsFile)); got != accountsBefore {
		t.Fatalf("existing file was not restored:\n%s", got)
	}
	if _, err := os.Stat(newFile); !os.IsNotExist(err) {
		t.Fatalf("new file should have been removed, err=%v", err)
	}
}

func TestLedgerWriteTransactionClearsCacheAfterSuccessfulWrite(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	cache := NewLedgerCache(cfg)
	beforeSnapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	writer := NewLedgerWriter(cfg, cache)
	accountsFile := accountsBeanPath(cfg)
	accountsBefore := string(mustRead(t, accountsFile))

	err = writer.RunTransaction(func(tx *LedgerWriteTransaction) error {
		next := appendText(accountsBefore, `2026-01-02 open Expenses:Travel CNY
  alias: "差旅"`)
		return tx.WriteFile(accountsFile, []byte(next), 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	afterSnapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if afterSnapshot == beforeSnapshot {
		t.Fatal("snapshot cache was not cleared after successful transaction")
	}
	found := false
	for _, account := range afterSnapshot.Accounts {
		if account.Account == "Expenses:Travel" && account.Alias != nil && strings.Contains(*account.Alias, "差旅") {
			found = true
		}
	}
	if !found {
		t.Fatalf("new account was not visible after cache reload: %#v", afterSnapshot.Accounts)
	}
}

func TestLedgerWriteTransactionPublishesSpecificSource(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	sub := ledgerEventHub.Subscribe()
	defer sub.Close()
	writer := NewLedgerWriter(cfg, NewLedgerCache(cfg))
	err := writer.AppendAccount(AccountInput{Date: "2026-01-02", Account: "Expenses:Travel", Alias: "差旅", Currency: "CNY"})
	if err != nil {
		t.Fatal(err)
	}

	select {
	case event := <-sub.ch:
		if event.Type != "ledger.updated" {
			t.Fatalf("event type = %s, want ledger.updated", event.Type)
		}
		data, ok := event.Data.(gin.H)
		if !ok {
			t.Fatalf("event data has unexpected type: %#v", event.Data)
		}
		if data["source"] != "account-append" {
			t.Fatalf("source = %#v, want account-append", data["source"])
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for ledger.updated event")
	}
}
