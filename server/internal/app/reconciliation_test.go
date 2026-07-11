package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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

func TestReconciliationServiceWritesAdjustment(t *testing.T) {
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
}

func TestReconciliationServiceUsesInjectedSnapshotWithoutLocalLedger(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"main.bean":                 "include \"commodities.bean\"\ninclude \"accounts.bean\"\ninclude \"transactions/2026/05.bean\"\n",
		"commodities.bean":          "2026-01-01 commodity CNY\n",
		"accounts.bean":             "2026-01-01 open Assets:Cash CNY\n2026-01-01 open Equity:Balance-Adjustments CNY\n",
		"transactions/2026/05.bean": "; 2026-05 transactions\n",
	})
	defer fake.server.Close()

	cfg := githubAPITestConfig(t, fake)
	snapshot := &LedgerSnapshot{
		Accounts: []Account{{Account: "Assets:Cash", Currency: "CNY", Label: "Cash", Group: "cash", Active: true}},
		Transactions: []Transaction{{
			Date: "2026-05-01",
			Postings: []Posting{
				{Account: "Assets:Cash", Amount: 10000, Currency: "CNY"},
				{Account: "Equity:Balance-Adjustments", Amount: -10000, Currency: "CNY"},
			},
		}},
	}
	service := NewReconciliationServiceWithSnapshot(nil, NewLedgerWriter(cfg, nil), func() (*LedgerSnapshot, error) {
		return snapshot, nil
	})

	result, err := service.Reconcile(ReconcileRequest{Account: "Assets:Cash", ActualAmount: "100.00", BalanceDate: "2026-05-31"})
	if err != nil {
		t.Fatal(err)
	}
	if !result.OK || fake.commitCount != 1 {
		t.Fatalf("result=%#v commits=%d", result, fake.commitCount)
	}
}
