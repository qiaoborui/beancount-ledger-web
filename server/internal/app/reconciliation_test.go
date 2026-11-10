package app

import (
	"encoding/json"
	"net/http"
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
		"transactions/2026/05.bean": "2026-05-01 * \"Opening cash\"\n  Assets:Cash 100 CNY\n  Equity:Balance-Adjustments -100 CNY\n",
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

func TestReconciliationBalanceAsOfMatchesWrittenDiff(t *testing.T) {
	cfg := testLedger(t)
	snapshot, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	// The 05-31 salary is excluded on its own day: an assertion holds at the
	// start of the day, which is also what the write compares against.
	for date, want := range map[string]int{"2026-05-01": 0, "2026-05-31": -1200, "2026-06-01": 98800} {
		balance, _, err := ReconciliationBalanceAsOf(snapshot, "Assets:Cash", date)
		if err != nil {
			t.Fatal(err)
		}
		if balance.LedgerBalance != want || balance.Currency != "CNY" || balance.Date != date {
			t.Fatalf("%s: unexpected balance %#v", date, balance)
		}
		result, err := BuildReconciliation(snapshot, ReconcileRequest{Account: "Assets:Cash", ActualAmount: fromCents(want), BalanceDate: date})
		if err != nil {
			t.Fatal(err)
		}
		if result.Diff != 0 || result.Adjustment != nil {
			t.Fatalf("%s: actual equal to the as-of balance still adjusted: %#v", date, result)
		}
	}
	if _, _, err := ReconciliationBalanceAsOf(snapshot, "Expenses:Food", "2026-05-31"); err == nil {
		t.Fatal("expected unsupported account error")
	}
}

func TestReconciliationBalanceRoute(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := testRouter(t, cfg)

	locked := requestWithCookies(router, http.MethodGet, "/api/ledger/reconciliation/balance?account=Assets:Cash&date=2026-05-31", "", nil)
	if locked.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status=%d body=%s", locked.Code, locked.Body.String())
	}
	cookies := loginCookies(t, router)
	res := requestWithCookies(router, http.MethodGet, "/api/ledger/reconciliation/balance?account=Assets:Cash&date=2026-05-31", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.Code, res.Body.String())
	}
	var balance ReconciliationBalance
	if err := json.Unmarshal(res.Body.Bytes(), &balance); err != nil {
		t.Fatal(err)
	}
	if balance.Account != "Assets:Cash" || balance.LedgerBalance != -1200 || balance.Currency != "CNY" {
		t.Fatalf("unexpected balance: %#v", balance)
	}
	for _, query := range []string{"account=Assets:Cash&date=bad", "account=Expenses:Food&date=2026-05-31", "date=2026-05-31"} {
		bad := requestWithCookies(router, http.MethodGet, "/api/ledger/reconciliation/balance?"+query, "", cookies)
		if bad.Code != http.StatusBadRequest {
			t.Fatalf("%s: status=%d body=%s", query, bad.Code, bad.Body.String())
		}
	}
}

func TestLocalReconciliationBalanceRoute(t *testing.T) {
	input := localTestRequest(t)
	input.Path = "/api/ledger/reconciliation/balance"
	input.Query = map[string]string{"account": "Assets:Cash", "date": "2026-06-01"}
	var balance ReconciliationBalance
	if err := json.Unmarshal(localTestDispatch(t, input), &balance); err != nil {
		t.Fatal(err)
	}
	if balance.LedgerBalance != 98800 {
		t.Fatalf("unexpected local balance: %#v", balance)
	}
}
