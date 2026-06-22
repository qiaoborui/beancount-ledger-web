package app

import (
	"encoding/json"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

func TestCreditCardAnalyticsOnlyIncludesCreditCardLiabilities(t *testing.T) {
	accounts := []Account{
		{Account: "Liabilities:CN:CMB:CreditCard:0016", Label: "CMB Card", Group: "credit"},
		{Account: "Liabilities:Friends", Label: "Friend payable", Group: "liability"},
	}

	cards := CreditCardsInCurrency(nil, nil, accounts, "2026-05-01", "2026-06-01", nil, "CNY")

	if len(cards) != 1 || cards[0].Account != "Liabilities:CN:CMB:CreditCard:0016" {
		t.Fatalf("credit card analytics included non-card liabilities: %#v", cards)
	}
}

func TestCreditCardAnalyticsUsesAccountBillingMetadata(t *testing.T) {
	account := Account{
		Account: "Liabilities:Card",
		Label:   "Card",
		Group:   "credit",
		Metadata: map[string]MetadataValue{
			"statement-day": float64(10),
			"due-day":       float64(25),
		},
	}
	expectedStart, expectedEnd, expectedStatement, expectedDue := creditCardBillingCycleForAccount(time.Now().Format("2006-01-02"), account)

	cards := CreditCardsInCurrency(nil, nil, []Account{account}, "2026-05-01", "2026-06-01", nil, "CNY")

	if len(cards) != 1 {
		t.Fatalf("expected one card, got %#v", cards)
	}
	card := cards[0]
	if card.BillCycleStart != expectedStart || card.BillCycleEnd != expectedEnd || card.StatementDate != expectedStatement || card.DueDate != expectedDue {
		t.Fatalf("credit card billing metadata was ignored: %#v, want %s %s %s %s", card, expectedStart, expectedEnd, expectedStatement, expectedDue)
	}
	if card.StatementDate == "" || card.DueDate == "" {
		t.Fatalf("credit card billing dates are empty: %#v", card)
	}
}

func TestCreditCardBillingCycleSupportsMonthEndStatementDay(t *testing.T) {
	account := Account{
		Account: "Liabilities:Huabei",
		Label:   "Huabei",
		Group:   "credit",
		Metadata: map[string]MetadataValue{
			"statementDay":  "month-end",
			"paymentDueDay": float64(8),
		},
	}

	cycleStart, cycleEnd, statementDate, dueDate := creditCardBillingCycleForAccount("2026-06-22", account)

	if cycleStart != "2026-06-01" || cycleEnd != "2026-07-01" || statementDate != "2026-06-30" || dueDate != "2026-07-08" {
		t.Fatalf("month-end billing cycle = %s %s %s %s", cycleStart, cycleEnd, statementDate, dueDate)
	}

	_, _, statementDate, dueDate = creditCardBillingCycleForAccount("2028-02-15", account)
	if statementDate != "2028-02-29" || dueDate != "2028-03-08" {
		t.Fatalf("leap-year month-end billing dates = %s %s", statementDate, dueDate)
	}
}

func TestAccountGroupSeparatesCreditCardsFromOtherLiabilities(t *testing.T) {
	if got := accountGroup("Liabilities:Friends", nil, nil); got != "liability" {
		t.Fatalf("plain liability group = %s, want liability", got)
	}
	if got := accountGroup("Liabilities:CN:CMB:CreditCard:0016", nil, nil); got != "credit" {
		t.Fatalf("credit card group = %s, want credit", got)
	}
	if got := normalizeGroup("负债"); got != "liability" {
		t.Fatalf("normalized liability group = %s, want liability", got)
	}
}

func TestValuationUsesLatestPriceOutsideHistoricalNetWorth(t *testing.T) {
	prices := []Price{
		{Date: "2026-06-01", Currency: "USD", Amount: 720, QuoteCurrency: "CNY"},
		{Date: "2026-06-08", Currency: "USD", Amount: 680, QuoteCurrency: "CNY"},
	}
	value, ok := ValuationInCurrency(680, "CNY", "USD", prices, "2026-06-01")
	if !ok || value != 100 {
		t.Fatalf("latest valuation = %d ok=%v, want 100 true", value, ok)
	}
	summary := MonthSummaryInCurrency("2026-06-01", "2026-06-02", []Transaction{{
		Date: "2026-06-01",
		Postings: []Posting{
			{Account: "Expenses:Food", Amount: 680, Currency: "CNY"},
			{Account: "Assets:Cash", Amount: -680, Currency: "CNY"},
		},
	}}, prices, "USD")
	if summary.Currency != "USD" || summary.Expense != 100 {
		t.Fatalf("summary with latest valuation = %#v, want USD expense=100", summary)
	}
	history := NetWorthHistoryInCurrency([]Transaction{{
		Date: "2026-06-01",
		Postings: []Posting{
			{Account: "Assets:USD", Amount: 10000, Currency: "USD"},
			{Account: "Equity:Opening-Balances", Amount: -10000, Currency: "USD"},
		},
	}}, prices, "CNY")
	if len(history) != 1 || history[0].Assets != 72000 {
		t.Fatalf("net worth history = %#v, want 2026-06-01 assets valued at historical price 72000", history)
	}
}

func TestSecurityAccountBalancesUseDatedPriceChain(t *testing.T) {
	prices := []Price{
		{Date: "2026-05-31", Currency: "USD", Amount: 700, QuoteCurrency: "CNY"},
		{Date: "2026-05-31", Currency: "QQQ", Amount: 10000, QuoteCurrency: "USD"},
		{Date: "2026-06-01", Currency: "QQQ", Amount: 11000, QuoteCurrency: "USD"},
	}
	balances := map[string]map[string]int{
		"Assets:Broker:QQQ": {"QQQ": 50},
	}

	mayRows := AccountBalanceRowsInCurrency(balances, prices, "2026-05-31", "CNY")
	mayAssets, _ := balanceTotals(mayRows)
	if len(mayRows) != 1 || mayRows[0].Valuation != 35000 || mayRows[0].ValuationMissing || mayAssets != 35000 {
		t.Fatalf("May security valuation rows=%#v assets=%d, want QQQ valued at 35000 CNY", mayRows, mayAssets)
	}

	juneRows := AccountBalanceRowsInCurrency(balances, prices, "2026-06-01", "CNY")
	juneAssets, _ := balanceTotals(juneRows)
	if len(juneRows) != 1 || juneRows[0].Valuation != 38500 || juneRows[0].ValuationMissing || juneAssets != 38500 {
		t.Fatalf("June security valuation rows=%#v assets=%d, want QQQ valued at 38500 CNY", juneRows, juneAssets)
	}

	beforeRows := AccountBalanceRowsInCurrency(balances, prices, "2026-05-30", "CNY")
	beforeAssets, _ := balanceTotals(beforeRows)
	if len(beforeRows) != 1 || !beforeRows[0].ValuationMissing || beforeAssets != 0 {
		t.Fatalf("pre-price valuation rows=%#v assets=%d, want missing valuation and zero assets", beforeRows, beforeAssets)
	}
}

func TestPriceIndexMatchesLegacyValuationSemantics(t *testing.T) {
	prices := []Price{
		{Date: "2026-06-08", Currency: "USD", Amount: 680, QuoteCurrency: "CNY"},
		{Date: "2026-06-01", Currency: "USD", Amount: 720, QuoteCurrency: "CNY"},
		{Date: "2026-05-01", Currency: "HKD", Amount: 92, QuoteCurrency: "CNY"},
		{Date: "2026-06-08", Currency: "QQQ", Amount: 11000, QuoteCurrency: "USD"},
	}
	index := NewPriceIndex(prices)
	cases := []struct {
		amount int
		from   string
		to     string
		date   string
		want   int
	}{
		{amount: 100, from: "USD", to: "CNY", want: 680},
		{amount: 680, from: "CNY", to: "USD", want: 100},
		{amount: 100, from: "USD", to: "CNY", date: "2026-06-01", want: 720},
		{amount: 920, from: "HKD", to: "USD", want: 124},
		{amount: 50, from: "QQQ", to: "CNY", want: 37400},
		{amount: 37400, from: "CNY", to: "QQQ", want: 50},
	}
	for _, tc := range cases {
		got, ok := index.Valuation(tc.amount, tc.from, tc.to, tc.date)
		if !ok || got != tc.want {
			t.Fatalf("indexed valuation %d %s to %s at %q = %d ok=%v, want %d true", tc.amount, tc.from, tc.to, tc.date, got, ok, tc.want)
		}
	}
	if got, ok := index.Valuation(100, "USD", "CNY", "2026-05-01"); ok {
		t.Fatalf("historical valuation before first price = %d ok=%v, want missing valuation", got, ok)
	}
}
