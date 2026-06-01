package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestBuildReconciliationRejectsUnsupportedAccount(t *testing.T) {
	cfg := testLedger(t)
	snapshot, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	_, err = BuildReconciliation(snapshot, ReconcileRequest{Account: "Expenses:Food", ActualAmount: "10.00", BalanceDate: "2026-05-31"})
	if err == nil || !strings.Contains(err.Error(), "不支持的对账账户") {
		t.Fatalf("expected unsupported account error, got %v", err)
	}
}

func TestReconciliationServiceWritesAdjustmentAndPublishesSource(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	cache := NewLedgerCache(cfg)
	writer := NewLedgerWriter(cfg, cache)
	service := NewReconciliationService(cache, writer)
	sub := ledgerEventHub.Subscribe()
	defer sub.Close()
	result, err := service.Reconcile(ReconcileRequest{Account: "Assets:Cash", ActualAmount: "980.00", BalanceDate: "2026-05-31", AdjustmentDate: "2026-05-30"})
	if err != nil {
		t.Fatal(err)
	}
	if !result.OK || result.LedgerBalance != -1200 || result.Actual != 98000 || result.Diff != 99200 {
		t.Fatalf("unexpected reconciliation result: %#v", result)
	}
	if result.Adjustment == nil || result.Adjustment.Postings[1].Account != "Equity:Balance-Adjustments" {
		t.Fatalf("unexpected adjustment: %#v", result.Adjustment)
	}
	text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")))
	if !strings.Contains(text, "余额差额调整") || !strings.Contains(text, "balance Assets:Cash 980.00 CNY") {
		t.Fatalf("reconciliation was not written:\n%s", text)
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
		if data["source"] != ledgerWriteSourceReconciliation {
			t.Fatalf("source = %#v, want %s", data["source"], ledgerWriteSourceReconciliation)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for ledger.updated event")
	}
}
