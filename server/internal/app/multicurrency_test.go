package app

import (
	"encoding/json"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
)

func TestMultiCurrencyBalancesUseNativeAmountAndCNYValuation(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "commodities.bean"), strings.Join([]string{
		"2026-01-01 commodity CNY",
		"2026-01-01 commodity HKD",
		"2026-01-01 commodity USD",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "prices.bean"), "2026-01-01 price HKD 0.92 CNY\n2026-01-01 price USD 7.10 CNY\n")
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), strings.Join([]string{
		"2026-01-01 open Assets:Cash CNY",
		`  alias: "现金"`,
		"2026-01-01 open Assets:HK:HSBC:HKD HKD",
		"2026-01-01 open Expenses:Food",
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
		`2026-05-16 * "Cha Chaan Teng" "Lunch"`,
		"  Expenses:Food 10.00 HKD",
		"  Assets:HK:HSBC:HKD -10.00 HKD",
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
	if account := FindAccount(snapshot.Accounts, "Expenses:Food"); account == nil || account.Currency != "" {
		t.Fatalf("expense account currency = %#v, want unconstrained", account)
	}
	if got := snapshot.Balances["Assets:HK:HSBC:HKD"]; got != 9000 {
		t.Fatalf("native HSBC balance = %d, want 9000", got)
	}
	foundValuation := false
	for _, row := range snapshot.AccountBalances {
		if row.Account == "Assets:HK:HSBC:HKD" && row.Currency == "HKD" {
			foundValuation = true
			if row.Amount != 9000 || row.Valuation != 8280 || row.ValuationCurrency != "CNY" || row.ValuationMissing {
				t.Fatalf("unexpected HSBC balance row: %#v", row)
			}
		}
	}
	if !foundValuation {
		t.Fatalf("HSBC account balance row not found: %#v", snapshot.AccountBalances)
	}
	summary := BuildDashboardSummary(snapshot, "2026-05-01", "2026-06-01")
	if summary.KPIs.Assets != 107080 || summary.KPIs.NetWorth != 107080 || summary.KPIs.Expense != 2120 {
		t.Fatalf("dashboard valuation KPIs = %#v, want assets/netWorth 107080 and expense 2120", summary.KPIs)
	}
	usdSummary := BuildDashboardSummaryWithFiltersInCurrency(snapshot, "2026-05-01", "2026-06-01", DashboardFilters{}, "USD")
	if usdSummary.Currency != "USD" || usdSummary.KPIs.Assets != 15081 || usdSummary.KPIs.NetWorth != 15081 || usdSummary.KPIs.Expense != 298 {
		t.Fatalf("USD dashboard valuation KPIs = %#v currency=%s, want assets/netWorth 15081 and expense 298", usdSummary.KPIs, usdSummary.Currency)
	}
	incomePayload := BuildLedgerIncomeStatement(snapshot, "2026-05-01", "2026-06-01", true, "USD")
	if incomePayload["valuationCurrency"] != "USD" || incomePayload["totalIncome"] != 14084 || incomePayload["totalExpense"] != 298 || incomePayload["netIncome"] != 13786 {
		t.Fatalf("USD income statement payload = %#v, want USD totals income=14084 expense=298 net=13786", incomePayload)
	}
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)
	res := requestWithCookies(router, http.MethodGet, "/api/ledger/income-statement?start=2026-05-01&end=2026-06-01&valuationCurrency=USD", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("USD income statement status=%d body=%s", res.Code, res.Body.String())
	}
	var incomeBody struct {
		ValuationCurrency string `json:"valuationCurrency"`
		TotalIncome       int    `json:"totalIncome"`
		TotalExpense      int    `json:"totalExpense"`
		NetIncome         int    `json:"netIncome"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &incomeBody); err != nil {
		t.Fatal(err)
	}
	if incomeBody.ValuationCurrency != "USD" || incomeBody.TotalIncome != 14084 || incomeBody.TotalExpense != 298 || incomeBody.NetIncome != 13786 {
		t.Fatalf("USD income statement response = %#v, want USD totals income=14084 expense=298 net=13786", incomeBody)
	}
	usdBalances := AccountBalanceRowsInCurrency(CurrentBalances(snapshot.Transactions), snapshot.Prices, "", "USD")
	foundUSDValuation := false
	for _, row := range usdBalances {
		if row.Account == "Assets:HK:HSBC:HKD" && row.Currency == "HKD" {
			foundUSDValuation = true
			if row.Valuation != 1166 || row.ValuationCurrency != "USD" || row.ValuationMissing {
				t.Fatalf("unexpected USD HSBC valuation row: %#v", row)
			}
		}
	}
	if !foundUSDValuation {
		t.Fatalf("HSBC USD valuation row not found: %#v", usdBalances)
	}
}

func TestAccountToBeanCanCreateUnconstrainedCategoryAccount(t *testing.T) {
	text := AccountToBean("2026-01-01", "Expenses:Travel", "旅行", "")
	if !strings.Contains(text, "2026-01-01 open Expenses:Travel\n") {
		t.Fatalf("account should be opened without currency constraint:\n%s", text)
	}
	if strings.Contains(text, "open Expenses:Travel CNY") {
		t.Fatalf("category account unexpectedly constrained to CNY:\n%s", text)
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

func TestCreditCardAnalyticsUsePostingCurrencyWhenAccountCurrencyIsUnconstrained(t *testing.T) {
	txns := []Transaction{
		{
			Date: "2026-05-10",
			Postings: []Posting{
				{Account: "Expenses:Travel", Amount: 1000, Currency: "USD"},
				{Account: "Liabilities:Card", Amount: -1000, Currency: "USD"},
			},
		},
		{
			Date: "2026-05-12",
			Postings: []Posting{
				{Account: "Assets:USD", Amount: -500, Currency: "USD"},
				{Account: "Liabilities:Card", Amount: 500, Currency: "USD"},
			},
		},
	}
	accounts := []Account{
		{Account: "Liabilities:Card", Label: "USD Card", Group: "credit"},
	}
	prices := []Price{{Date: "2026-01-01", Currency: "USD", Amount: 710, QuoteCurrency: "CNY"}}

	cards := CreditCardsInCurrency(txns, nil, accounts, "2026-05-01", "2026-06-01", prices, "CNY")
	if len(cards) != 1 {
		t.Fatalf("expected one card, got %#v", cards)
	}
	card := cards[0]
	if card.PeriodSpend != 7100 || card.PeriodRepayments != 3550 || card.Balance != -3550 || card.Outstanding != 3550 {
		t.Fatalf("credit card analytics used wrong currency: %#v", card)
	}
}
