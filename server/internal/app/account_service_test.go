package app

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestAccountServiceDetail(t *testing.T) {
	service := NewAccountService(NewLedgerCache(testLedger(t)), nil)

	if _, err := service.Detail(""); !errors.Is(err, ErrAccountRequired) {
		t.Fatalf("empty account error = %v, want ErrAccountRequired", err)
	}
	if _, err := service.Detail("Assets:Missing"); !errors.Is(err, ErrAccountNotFound) {
		t.Fatalf("missing account error = %v, want ErrAccountNotFound", err)
	}

	detail, err := service.Detail("Assets:Cash")
	if err != nil {
		t.Fatal(err)
	}
	if detail.Account != "Assets:Cash" || detail.Label != "现金" || detail.Alias == nil || *detail.Alias != "现金" {
		t.Fatalf("unexpected account detail metadata: %#v", detail)
	}
	if detail.CurrentBalance != 98800 || len(detail.Rows) != 2 {
		t.Fatalf("unexpected account detail balance/rows: %#v", detail)
	}
}

func TestAccountServiceAppendDefaultsCurrencyAndPublishesSource(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	cache := NewLedgerCache(cfg)
	service := NewAccountService(cache, NewLedgerWriter(cfg, cache))
	sub := ledgerEventHub.Subscribe()
	defer sub.Close()

	input, err := service.Append(AccountInput{Date: "2026-01-01", Account: "Assets:Wallet", Alias: "钱包"})
	if err != nil {
		t.Fatal(err)
	}
	if input.Currency != "CNY" {
		t.Fatalf("default currency = %q, want CNY", input.Currency)
	}
	text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "accounts.bean")))
	if !strings.Contains(text, "open Assets:Wallet CNY") || !strings.Contains(text, `alias: "钱包"`) {
		t.Fatalf("account was not appended:\n%s", text)
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
		if data["source"] != ledgerWriteSourceAccountAppend {
			t.Fatalf("source = %#v, want %s", data["source"], ledgerWriteSourceAccountAppend)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for ledger.updated event")
	}
}

func TestAccountServiceStatuses(t *testing.T) {
	service := NewAccountService(NewLedgerCache(testLedger(t)), nil)

	statuses, err := service.Statuses()
	if err != nil {
		t.Fatal(err)
	}
	if len(statuses) == 0 || statuses[0].Account == "" {
		t.Fatalf("expected account statuses, got %#v", statuses)
	}
}
