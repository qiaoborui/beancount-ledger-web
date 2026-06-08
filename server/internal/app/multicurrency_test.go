package app

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestMultiCurrencyBalancesUseNativeAmountAndCNYValuation(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "commodities.bean"), strings.Join([]string{
		"2026-01-01 commodity CNY",
		"2026-01-01 commodity HKD",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "prices.bean"), "2026-05-15 price HKD 0.92 CNY\n")
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), strings.Join([]string{
		"2026-01-01 open Assets:Cash CNY",
		`  alias: "现金"`,
		"2026-01-01 open Assets:HK:HSBC:HKD HKD",
		"2026-01-01 open Expenses:Food CNY",
		"2026-01-01 open Income:Salary CNY",
		"2026-01-01 open Equity:Opening-Balances CNY",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean"), strings.Join([]string{
		`2026-05-01 * "Cafe" "Lunch" #work`,
		`  note: "noodles"`,
		"  Expenses:Food 12.00 CNY",
		"  Assets:Cash -12.00 CNY",
		"",
		`2026-05-15 * "HSBC" "Opening balance"`,
		"  Assets:HK:HSBC:HKD 100.00 HKD",
		"  Equity:Opening-Balances -100.00 HKD",
		"",
		`2026-05-31 * "Employer" "Salary"`,
		"  Assets:Cash 1000.00 CNY",
		"  Income:Salary -1000.00 CNY",
		"",
	}, "\n"))

	snapshot, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if got := snapshot.Transactions[1].Postings[0].Currency; got != "HKD" {
		t.Fatalf("posting currency = %q, want HKD", got)
	}
	if got := snapshot.Balances["Assets:HK:HSBC:HKD"]; got != 10000 {
		t.Fatalf("native HSBC balance = %d, want 10000", got)
	}
	foundValuation := false
	for _, row := range snapshot.AccountBalances {
		if row.Account == "Assets:HK:HSBC:HKD" && row.Currency == "HKD" {
			foundValuation = true
			if row.Amount != 10000 || row.Valuation != 9200 || row.ValuationCurrency != "CNY" || row.ValuationMissing {
				t.Fatalf("unexpected HSBC balance row: %#v", row)
			}
		}
	}
	if !foundValuation {
		t.Fatalf("HSBC account balance row not found: %#v", snapshot.AccountBalances)
	}
	summary := BuildDashboardSummary(snapshot, "2026-05-01", "2026-06-01")
	if summary.KPIs.Assets != 108000 || summary.KPIs.NetWorth != 108000 {
		t.Fatalf("dashboard valuation KPIs = %#v, want assets/netWorth 108000", summary.KPIs)
	}
}

func TestReconciliationUsesAccountCurrency(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "commodities.bean"), "2026-01-01 commodity CNY\n2026-01-01 commodity HKD\n")
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), strings.Join([]string{
		"2026-01-01 open Assets:HK:HSBC:HKD HKD",
		"2026-01-01 open Equity:Balance-Adjustments CNY",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean"), strings.Join([]string{
		`2026-05-15 * "HSBC" "Opening balance"`,
		"  Assets:HK:HSBC:HKD 100.00 HKD",
		"  Equity:Balance-Adjustments -100.00 HKD",
		"",
	}, "\n"))

	snapshot, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	result, err := BuildReconciliation(snapshot, ReconcileRequest{Account: "Assets:HK:HSBC:HKD", ActualAmount: "90.00", BalanceDate: "2026-05-31", AdjustmentDate: "2026-05-30"})
	if err != nil {
		t.Fatal(err)
	}
	if result.LedgerBalance != 10000 || result.Diff != -1000 {
		t.Fatalf("unexpected reconciliation amounts: %#v", result)
	}
	if result.Balance.Currency != "HKD" || result.Adjustment == nil || result.Adjustment.Postings[0].Currency != "HKD" {
		t.Fatalf("reconciliation did not use account currency: %#v", result)
	}
	if !strings.Contains(result.BeanText, "balance Assets:HK:HSBC:HKD 90.00 HKD") {
		t.Fatalf("bean text did not contain HKD balance:\n%s", result.BeanText)
	}
}
