package app

import (
	"encoding/json"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestAccountDetailReturnsFrontendContract(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodGet, "/api/ledger/accounts/detail?account=Assets%3ACash", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("account detail status=%d body=%s", res.Code, res.Body.String())
	}
	var body struct {
		Account        string             `json:"account"`
		Label          string             `json:"label"`
		Alias          string             `json:"alias"`
		Group          string             `json:"group"`
		Active         bool               `json:"active"`
		Currency       string             `json:"currency"`
		CurrentBalance int                `json:"currentBalance"`
		Rows           []AccountDetailRow `json:"rows"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Account != "Assets:Cash" || body.Label != "现金" || body.Alias != "现金" {
		t.Fatalf("account fields do not match frontend contract: %#v", body)
	}
	if body.Group != "cash" || !body.Active || body.Currency != "CNY" {
		t.Fatalf("unexpected account metadata: %#v", body)
	}
	if body.CurrentBalance != 98800 || len(body.Rows) != 2 {
		t.Fatalf("unexpected account detail rows or balance: %#v", body)
	}
}

func TestIncomeStatementReturnsCategoryTree(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodGet, "/api/ledger/income-statement?start=2026-05-01&end=2026-06-01", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("income statement status=%d body=%s", res.Code, res.Body.String())
	}
	var body struct {
		Income             []IncomeStatementNode      `json:"income"`
		Expense            []IncomeStatementNode      `json:"expense"`
		ExpenseAnalytics   []ExpenseCategoryAnalytics `json:"expenseAnalytics"`
		TopPaymentAccounts []AccountAnalytics         `json:"topPaymentAccounts"`
		TotalIncome        int                        `json:"totalIncome"`
		TotalExpense       int                        `json:"totalExpense"`
		NetIncome          int                        `json:"netIncome"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Income) != 1 || body.Income[0].Account != "Income:Salary" || body.Income[0].Amount != 100000 || body.Income[0].TxCount != 1 {
		t.Fatalf("income tree should include category detail, got %#v", body.Income)
	}
	if len(body.Expense) != 1 || body.Expense[0].Account != "Expenses:Food" || body.Expense[0].Amount != 1200 || body.Expense[0].TxCount != 1 {
		t.Fatalf("expense tree should include category detail, got %#v", body.Expense)
	}
	if len(body.ExpenseAnalytics) != 1 || body.ExpenseAnalytics[0].Account != "Expenses:Food" || body.ExpenseAnalytics[0].TxCount != 1 || len(body.ExpenseAnalytics[0].TopPayees) != 1 {
		t.Fatalf("expense analytics should include transaction counts and top payees, got %#v", body.ExpenseAnalytics)
	}
	if len(body.TopPaymentAccounts) != 1 || body.TopPaymentAccounts[0].Account != "Assets:Cash" || body.TopPaymentAccounts[0].Alias == nil || *body.TopPaymentAccounts[0].Alias != "现金" || body.TopPaymentAccounts[0].Label != "现金" {
		t.Fatalf("top payment accounts should include alias and label, got %#v", body.TopPaymentAccounts)
	}
	if body.TotalIncome != 100000 || body.TotalExpense != 1200 || body.NetIncome != 98800 {
		t.Fatalf("unexpected income statement totals: %#v", body)
	}
}

func TestInvestmentsReturnsCommodityPricesAndPositions(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "commodities.bean"), strings.Join([]string{
		"2026-01-01 commodity CNY",
		"2026-01-01 commodity USD",
		"2026-01-01 commodity QQQ",
		`  name: "Invesco QQQ Trust"`,
		"2026-01-01 commodity VOO",
		`  name: "Vanguard S&P 500 ETF"`,
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), strings.Join([]string{
		"2026-01-01 open Assets:Cash CNY",
		`  alias: "现金"`,
		"2026-01-01 open Assets:Broker:QQQ QQQ",
		`  alias: "券商 QQQ 持仓"`,
		"2026-01-01 open Assets:Broker:Taxable:QQQ QQQ",
		`  alias: "券商应税 QQQ 持仓"`,
		"2026-01-01 open Expenses:Food CNY",
		"2026-01-01 open Income:Salary CNY",
		"2026-01-01 open Equity:Opening-Balances CNY",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "prices.bean"), strings.Join([]string{
		"2026-05-31 price USD 7.0000 CNY",
		"2026-05-31 price QQQ 100.00 USD",
		"2026-06-01 price QQQ 110.00 USD",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean"), strings.Join([]string{
		`2026-05-01 * "Cafe" "Lunch" #work`,
		`  note: "noodles"`,
		"  Expenses:Food 12.00 CNY",
		"  Assets:Cash -12.00 CNY",
		"",
		`2026-05-31 * "Employer" "Salary"`,
		"  Assets:Cash 1000.00 CNY",
		"  Income:Salary -1000.00 CNY",
		"",
		`2026-05-31 * "Broker" "QQQ opening"`,
		"  Assets:Broker:QQQ 0.50 QQQ {100.00 USD}",
		"  Equity:Opening-Balances -0.50 QQQ",
		"",
		`2026-05-31 * "Broker" "QQQ taxable opening"`,
		"  Assets:Broker:Taxable:QQQ 0.25 QQQ {90.00 USD}",
		"  Equity:Opening-Balances -0.25 QQQ",
		"",
	}, "\n"))
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodGet, "/api/ledger/investments", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("investments status=%d body=%s", res.Code, res.Body.String())
	}
	var body InvestmentSummary
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.TotalMarketValueCNY != 57750 || body.UpdatedAt != "2026-06-01" {
		t.Fatalf("unexpected investment summary: %#v", body)
	}
	if len(body.Positions) != 2 {
		t.Fatalf("expected two positions, got %#v", body.Positions)
	}
	position := body.Positions[0]
	if position.Account != "Assets:Broker:QQQ" || position.AccountLabel != "券商 QQQ 持仓" || position.CommodityName != "Invesco QQQ Trust" {
		t.Fatalf("unexpected position identity: %#v", position)
	}
	if position.Quantity != 0.5 || position.LatestPrice == nil || position.LatestPrice.Amount != 110 || position.LatestPrice.Currency != "USD" {
		t.Fatalf("unexpected position pricing: %#v", position)
	}
	if position.MarketValueCNY == nil || *position.MarketValueCNY != 38500 {
		t.Fatalf("unexpected CNY value: %#v", position)
	}
	if position.AverageCost == nil || *position.AverageCost != 100 || position.CostValue == nil || *position.CostValue != 50 || position.CostCurrency != "USD" {
		t.Fatalf("unexpected position cost basis: %#v", position)
	}
	if len(position.Lots) != 1 || position.Lots[0].Date != "2026-05-31" || position.Lots[0].Quantity != 0.5 || position.Lots[0].UnitCost == nil || *position.Lots[0].UnitCost != 100 || position.Lots[0].CostValue == nil || *position.Lots[0].CostValue != 50 || position.Lots[0].CostCurrency != "USD" {
		t.Fatalf("unexpected position lots: %#v", position.Lots)
	}
	qqqQuote := InvestmentQuote{}
	for _, quote := range body.Quotes {
		if quote.Commodity == "QQQ" {
			qqqQuote = quote
		}
	}
	if qqqQuote.Commodity != "QQQ" || qqqQuote.PositionCount != 2 {
		t.Fatalf("unexpected quotes: %#v", body.Quotes)
	}
	if len(body.Holdings) != 1 {
		t.Fatalf("expected one held security, got %#v", body.Holdings)
	}
	holding := body.Holdings[0]
	if holding.Commodity != "QQQ" || holding.CommodityName != "Invesco QQQ Trust" || holding.AccountCount != 2 {
		t.Fatalf("unexpected holding identity: %#v", holding)
	}
	if holding.TotalQuantity != 0.75 || holding.LatestPrice == nil || holding.LatestPrice.Amount != 110 || holding.LatestPrice.Currency != "USD" {
		t.Fatalf("unexpected holding pricing: %#v", holding)
	}
	if holding.TotalMarketValueCNY == nil || *holding.TotalMarketValueCNY != 57750 {
		t.Fatalf("unexpected holding CNY value: %#v", holding)
	}
	if holding.TotalCostValue == nil || math.Abs(*holding.TotalCostValue-72.5) > 0.000001 || holding.AverageCost == nil || math.Abs(*holding.AverageCost-96.66666666666667) > 0.000001 || holding.CostCurrency != "USD" {
		t.Fatalf("unexpected holding cost basis: %#v", holding)
	}
	if len(body.Lots) != 2 || len(holding.Lots) != 2 {
		t.Fatalf("expected two investment lots, body=%#v holding=%#v", body.Lots, holding.Lots)
	}
	if holding.Lots[0].AccountLabel != "券商 QQQ 持仓" || holding.Lots[0].Date != "2026-05-31" || holding.Lots[0].Quantity != 0.5 || holding.Lots[0].UnitCost == nil || *holding.Lots[0].UnitCost != 100 || holding.Lots[0].CostValue == nil || *holding.Lots[0].CostValue != 50 || holding.Lots[0].CostCurrency != "USD" {
		t.Fatalf("unexpected first holding lot: %#v", holding.Lots[0])
	}
	if holding.Lots[1].AccountLabel != "券商应税 QQQ 持仓" || holding.Lots[1].Date != "2026-05-31" || holding.Lots[1].Quantity != 0.25 || holding.Lots[1].UnitCost == nil || *holding.Lots[1].UnitCost != 90 || holding.Lots[1].CostValue == nil || *holding.Lots[1].CostValue != 22.5 || holding.Lots[1].CostCurrency != "USD" {
		t.Fatalf("unexpected second holding lot: %#v", holding.Lots[1])
	}
	if len(holding.Positions) != 2 || holding.Positions[1].Account != "Assets:Broker:Taxable:QQQ" {
		t.Fatalf("unexpected holding positions: %#v", holding.Positions)
	}
	if len(holding.PriceHistory) != 2 || holding.PriceHistory[0].Date != "2026-05-31" || holding.PriceHistory[1].Date != "2026-06-01" {
		t.Fatalf("unexpected holding price history: %#v", holding.PriceHistory)
	}
	var raw map[string]any
	if err := json.Unmarshal(res.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	rawHoldings, ok := raw["holdings"].([]any)
	if !ok || len(rawHoldings) != 1 {
		t.Fatalf("unexpected raw holdings: %#v", raw["holdings"])
	}
	rawHeld, ok := rawHoldings[0].(map[string]any)
	if !ok {
		t.Fatalf("unexpected raw holding shape: %#v", rawHoldings[0])
	}
	if _, ok := rawHeld["priceHistory"].([]any); !ok {
		t.Fatalf("holding priceHistory should encode as an array, got %#v", rawHeld["priceHistory"])
	}
}

func TestInvestmentSummaryPreservesSecurityDecimalPrecision(t *testing.T) {
	text := []string{
		"2026-01-01 commodity CNY",
		"2026-01-01 commodity USD",
		"2026-01-01 commodity QQQ",
		"2026-01-01 commodity SZ159350",
		`  name: "Fullgoal Shenzhen 50 Index ETF (159350)"`,
		"2026-01-01 open Assets:Cash CNY",
		"2026-01-01 open Assets:Broker:QQQ QQQ",
		"2026-01-01 open Assets:CN:CMB:Securities:SZ159350 SZ159350",
		"2026-01-01 open Equity:Opening-Balances CNY",
		"2026-06-30 price USD 6.789900 CNY",
		"2026-06-30 price QQQ 736.40 USD",
		"2026-06-30 price SZ159350 1.79 CNY",
		`2026-06-30 * "Broker" "fractional QQQ"`,
		"  Assets:Broker:QQQ 0.0056 QQQ {725.20 USD}",
		"  Equity:Opening-Balances -0.0056 QQQ",
		`2026-06-30 * "CMB" "A share ETF"`,
		"  Assets:CN:CMB:Securities:SZ159350 1200 SZ159350 {1.7702 CNY}",
		"  Assets:Cash -2124.24 CNY",
		"",
	}
	lines := make([]BeanLine, 0, len(text))
	for index, line := range text {
		lines = append(lines, BeanLine{File: "main.bean", Line: index + 1, Text: line})
	}
	entries := ParseBeanLines(lines).Entries
	summary := BuildInvestmentSummaryFromBeanEntries(entries, AccountsFromBeanEntries(entries), PricesFromBeanEntries(entries))

	if len(summary.Holdings) != 2 {
		t.Fatalf("expected two holdings, got %#v", summary.Holdings)
	}
	if summary.TotalMarketValueCNY != 217600 {
		t.Fatalf("total CNY market value = %d, want 217600", summary.TotalMarketValueCNY)
	}
	byCommodity := map[string]InvestmentHolding{}
	for _, holding := range summary.Holdings {
		byCommodity[holding.Commodity] = holding
	}
	aShare := byCommodity["SZ159350"]
	if aShare.TotalQuantity != 1200 || aShare.LatestPrice == nil || aShare.LatestPrice.Amount != 1.79 || aShare.TotalMarketValueCNY == nil || *aShare.TotalMarketValueCNY != 214800 {
		t.Fatalf("unexpected A share valuation: %#v", aShare)
	}
	if aShare.TotalCostValue == nil || math.Abs(*aShare.TotalCostValue-2124.24) > 0.000001 || aShare.AverageCost == nil || math.Abs(*aShare.AverageCost-1.7702) > 0.000001 {
		t.Fatalf("A share cost lost decimal precision: %#v", aShare)
	}
	if aShare.TotalCostValueCNY == nil || *aShare.TotalCostValueCNY != 212424 {
		t.Fatalf("A share CNY cost = %#v, want 212424", aShare.TotalCostValueCNY)
	}
	if len(aShare.Lots) != 1 || aShare.Lots[0].UnitCost == nil || math.Abs(*aShare.Lots[0].UnitCost-1.7702) > 0.000001 || aShare.Lots[0].CostValue == nil || math.Abs(*aShare.Lots[0].CostValue-2124.24) > 0.000001 {
		t.Fatalf("A share lot lost decimal precision: %#v", aShare.Lots)
	}
	qqq := byCommodity["QQQ"]
	if math.Abs(qqq.TotalQuantity-0.0056) > 0.000000001 || qqq.TotalMarketValue == nil || math.Abs(*qqq.TotalMarketValue-4.12384) > 0.000001 || qqq.TotalMarketValueCNY == nil || *qqq.TotalMarketValueCNY != 2800 {
		t.Fatalf("fractional QQQ valuation lost precision: %#v", qqq)
	}
	if qqq.TotalCostValueCNY == nil || *qqq.TotalCostValueCNY != 2757 {
		t.Fatalf("fractional QQQ CNY cost = %#v, want 2757", qqq.TotalCostValueCNY)
	}
}

func TestInvestmentSummaryCalculatesRealizedPnLAndClosedHoldings(t *testing.T) {
	text := []string{
		"2026-01-01 commodity CNY",
		"2026-01-01 commodity USD",
		"2026-01-01 commodity QQQ",
		"2026-01-01 commodity VOO",
		"2026-01-01 open Assets:Broker:USD USD",
		"2026-01-01 open Assets:Broker:QQQ QQQ",
		`  alias: "券商 QQQ 持仓"`,
		"2026-01-01 open Assets:Broker:VOO VOO",
		`  alias: "券商 VOO 持仓"`,
		"2026-01-01 open Equity:Opening-Balances USD",
		"2026-01-01 open Income:Investment:Gain USD",
		"2026-06-30 price USD 7.00 CNY",
		"2026-06-30 price QQQ 130.00 USD",
		"2026-06-30 price VOO 45.00 USD",
		`2026-05-01 * "Broker" "buy QQQ first lot"`,
		"  Assets:Broker:QQQ 1 QQQ {100.00 USD}",
		"  Equity:Opening-Balances -1 QQQ",
		`2026-05-02 * "Broker" "buy QQQ second lot"`,
		"  Assets:Broker:QQQ 1 QQQ {120.00 USD}",
		"  Equity:Opening-Balances -1 QQQ",
		`2026-06-01 * "Broker" "sell QQQ partial"`,
		"  Assets:Broker:QQQ -1.5 QQQ {100.00 USD} @ 130.00 USD",
		"  Assets:Broker:USD 195.00 USD",
		"  Income:Investment:Gain -35.00 USD",
		`2026-05-01 * "Broker" "buy VOO"`,
		"  Assets:Broker:VOO 2 VOO {50.00 USD}",
		"  Equity:Opening-Balances -2 VOO",
		`2026-06-02 * "Broker" "sell VOO closed"`,
		"  Assets:Broker:VOO -2 VOO {50.00 USD} @ 45.00 USD",
		"  Assets:Broker:USD 90.00 USD",
		"  Income:Investment:Gain 10.00 USD",
		"",
	}
	lines := make([]BeanLine, 0, len(text))
	for index, line := range text {
		lines = append(lines, BeanLine{File: "main.bean", Line: index + 1, Text: line})
	}
	entries := ParseBeanLines(lines).Entries
	summary := BuildInvestmentSummaryFromBeanEntries(entries, AccountsFromBeanEntries(entries), PricesFromBeanEntries(entries))

	if summary.RealizedPnLCNY == nil || *summary.RealizedPnLCNY != 17500 {
		t.Fatalf("realized PnL CNY = %#v, want 17500", summary.RealizedPnLCNY)
	}
	if len(summary.Holdings) != 1 || summary.Holdings[0].Commodity != "QQQ" {
		t.Fatalf("expected only current QQQ holding, got %#v", summary.Holdings)
	}
	qqq := summary.Holdings[0]
	if math.Abs(qqq.TotalQuantity-0.5) > 0.000000001 || qqq.TotalCostValue == nil || math.Abs(*qqq.TotalCostValue-60) > 0.000001 || qqq.AverageCost == nil || math.Abs(*qqq.AverageCost-120) > 0.000001 {
		t.Fatalf("unexpected remaining QQQ cost basis after FIFO sale: %#v", qqq)
	}
	if qqq.RealizedPnL == nil || math.Abs(*qqq.RealizedPnL-35) > 0.000001 || qqq.RealizedCurrency != "USD" || qqq.RealizedPnLCNY == nil || *qqq.RealizedPnLCNY != 24500 {
		t.Fatalf("unexpected QQQ realized PnL: %#v", qqq)
	}
	if len(qqq.RealizedTrades) != 1 || qqq.RealizedTrades[0].CostValue == nil || math.Abs(*qqq.RealizedTrades[0].CostValue-160) > 0.000001 || qqq.RealizedTrades[0].ProceedsValue == nil || math.Abs(*qqq.RealizedTrades[0].ProceedsValue-195) > 0.000001 {
		t.Fatalf("unexpected QQQ realized trade: %#v", qqq.RealizedTrades)
	}
	if len(qqq.Lots) != 1 || math.Abs(qqq.Lots[0].Quantity-0.5) > 0.000000001 || qqq.Lots[0].CostValue == nil || math.Abs(*qqq.Lots[0].CostValue-60) > 0.000001 {
		t.Fatalf("unexpected remaining QQQ lot: %#v", qqq.Lots)
	}
	if len(summary.ClosedHoldings) != 1 || summary.ClosedHoldings[0].Commodity != "VOO" {
		t.Fatalf("expected VOO closed holding, got %#v", summary.ClosedHoldings)
	}
	closed := summary.ClosedHoldings[0]
	if !roundedZero(closed.TotalQuantity) || closed.RealizedPnL == nil || math.Abs(*closed.RealizedPnL+10) > 0.000001 || closed.RealizedPnLCNY == nil || *closed.RealizedPnLCNY != -7000 {
		t.Fatalf("unexpected VOO closed holding PnL: %#v", closed)
	}
}

func TestInvestmentSummaryInfersRealizedPnLFromCashPosting(t *testing.T) {
	text := []string{
		"2026-01-01 commodity CNY",
		"2026-01-01 commodity SZ159350",
		"2026-01-01 open Assets:CN:CMB:Cash CNY",
		"2026-01-01 open Assets:CN:CMB:Securities:SZ159350 SZ159350",
		`  alias: "招商证券深证50 ETF"`,
		"2026-01-01 open Equity:Opening-Balances CNY",
		"2026-01-01 open Income:Investment:Gain CNY",
		"2026-07-10 price SZ159350 1.72 CNY",
		`2026-06-01 * "招商证券" "buy SZ159350"`,
		"  Assets:CN:CMB:Securities:SZ159350 100 SZ159350 {1.50 CNY}",
		"  Equity:Opening-Balances -100 SZ159350",
		`2026-07-10 * "招商证券" "sell SZ159350 closed"`,
		"  Assets:CN:CMB:Securities:SZ159350 -100 SZ159350 {1.50 CNY}",
		"  Assets:CN:CMB:Cash 172.00 CNY",
		"  Income:Investment:Gain -22.00 CNY",
		"",
	}
	lines := make([]BeanLine, 0, len(text))
	for index, line := range text {
		lines = append(lines, BeanLine{File: "main.bean", Line: index + 1, Text: line})
	}
	entries := ParseBeanLines(lines).Entries
	summary := BuildInvestmentSummaryFromBeanEntries(entries, AccountsFromBeanEntries(entries), PricesFromBeanEntries(entries))

	if summary.RealizedPnLCNY == nil || *summary.RealizedPnLCNY != 2200 {
		t.Fatalf("realized PnL CNY = %#v, want 2200", summary.RealizedPnLCNY)
	}
	if len(summary.ClosedHoldings) != 1 || summary.ClosedHoldings[0].Commodity != "SZ159350" {
		t.Fatalf("expected SZ159350 closed holding, got %#v", summary.ClosedHoldings)
	}
	closed := summary.ClosedHoldings[0]
	if closed.RealizedPnL == nil || math.Abs(*closed.RealizedPnL-22) > 0.000001 || closed.RealizedCurrency != "CNY" || closed.RealizedPnLCNY == nil || *closed.RealizedPnLCNY != 2200 {
		t.Fatalf("unexpected closed holding PnL inferred from cash posting: %#v", closed)
	}
	if len(closed.RealizedTrades) != 1 || closed.RealizedTrades[0].ProceedsValue == nil || math.Abs(*closed.RealizedTrades[0].ProceedsValue-172) > 0.000001 {
		t.Fatalf("unexpected realized trade proceeds: %#v", closed.RealizedTrades)
	}
}

func TestInvestmentSummaryFallsBackToIndexedTransactions(t *testing.T) {
	snapshot := &LedgerSnapshot{
		Accounts: []Account{
			{Account: "Assets:Broker:QQQ", Currency: "QQQ", Label: "券商 QQQ 持仓", Group: "wealth", Active: true},
			{Account: "Equity:Opening-Balances", Currency: "CNY", Label: "Opening", Group: "equity", Active: true},
		},
		Commodities: []string{"CNY", "QQQ", "USD"},
		Prices: []Price{
			{Date: "2026-05-31", Currency: "USD", Amount: 700, AmountValue: BeanAmount{Number: "7.00", Currency: "CNY"}, QuoteCurrency: "CNY"},
			{Date: "2026-06-01", Currency: "QQQ", Amount: 11000, AmountValue: BeanAmount{Number: "110.00", Currency: "USD"}, QuoteCurrency: "USD"},
		},
		Transactions: []Transaction{{
			Date:      "2026-05-31",
			Payee:     "Broker",
			Narration: "QQQ opening",
			Postings: []Posting{
				{Account: "Assets:Broker:QQQ", Amount: 50, Currency: "QQQ"},
				{Account: "Equity:Opening-Balances", Amount: -50, Currency: "QQQ"},
			},
		}},
	}

	summary := BuildInvestmentSummaryFromSnapshot(snapshot)

	if len(summary.Positions) != 1 || len(summary.Holdings) != 1 {
		t.Fatalf("expected indexed transaction fallback to produce one holding, got positions=%#v holdings=%#v", summary.Positions, summary.Holdings)
	}
	position := summary.Positions[0]
	if position.Account != "Assets:Broker:QQQ" || position.Quantity != 0.5 || position.LatestPrice == nil || position.LatestPrice.Amount != 110 {
		t.Fatalf("unexpected fallback position: %#v", position)
	}
	if position.MarketValueCNY == nil || *position.MarketValueCNY != 38500 || summary.TotalMarketValueCNY != 38500 {
		t.Fatalf("fallback should value indexed holdings in CNY, summary=%#v position=%#v", summary, position)
	}
	if len(summary.Lots) != 1 || summary.Lots[0].Quantity != 0.5 {
		t.Fatalf("fallback should expose positive indexed postings as lots, got %#v", summary.Lots)
	}
}

func TestAccountsParseAdditionalIncludedFiles(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts_stocks.bean"), strings.Join([]string{
		"2026-06-16 open Assets:Broker:NVDA NVDA",
		`  alias: "券商 NVDA 持仓"`,
		`  group: "wealth"`,
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "main.bean"), strings.Join([]string{
		`option "title" "Test Ledger"`,
		`option "operating_currency" "CNY"`,
		`include "commodities.bean"`,
		`include "accounts.bean"`,
		`include "accounts_stocks.bean"`,
		`include "prices.bean"`,
		`include "transactions/2026/05.bean"`,
		"",
	}, "\n"))

	accounts, err := ParseAccounts(cfg)
	if err != nil {
		t.Fatal(err)
	}
	accountMap := map[string]Account{}
	for _, account := range accounts {
		accountMap[account.Account] = account
	}
	stock, ok := accountMap["Assets:Broker:NVDA"]
	if !ok {
		t.Fatalf("expected included stock account, got %#v", accounts)
	}
	if stock.Label != "券商 NVDA 持仓" || stock.Group != "wealth" || stock.Currency != "NVDA" {
		t.Fatalf("unexpected included stock account metadata: %#v", stock)
	}
}

func TestDashboardReturnsAggregatedReadOnlySeries(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2026-05-01&end=2026-06-01", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	var body DashboardSummary
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.KPIs.Income != 100000 || body.KPIs.Expense != 1200 || body.KPIs.Net != 98800 || body.KPIs.NetWorth != 98800 {
		t.Fatalf("unexpected dashboard kpis: %#v", body.KPIs)
	}
	wantMonthLabels := []string{"05-01", "05-02", "05-03", "05-04", "05-05", "05-06", "05-07", "05-08", "05-09", "05-10", "05-11", "05-12", "05-13", "05-14", "05-15", "05-16", "05-17", "05-18", "05-19", "05-20", "05-21", "05-22", "05-23", "05-24", "05-25", "05-26", "05-27", "05-28", "05-29", "05-30", "05-31"}
	gotMonthLabels := make([]string, 0, len(body.CashflowSeries))
	for _, point := range body.CashflowSeries {
		gotMonthLabels = append(gotMonthLabels, point.Month)
	}
	if !reflect.DeepEqual(gotMonthLabels, wantMonthLabels) || body.CashflowSeries[0].Net != -1200 || body.CashflowSeries[30].Net != 100000 {
		t.Fatalf("unexpected cashflow series: %#v", body.CashflowSeries)
	}
	if len(body.CategorySeries) != 1 || body.CategorySeries[0].Account != "Expenses:Food" || body.CategorySeries[0].Total != 1200 || len(body.CategorySeries[0].Values) != 31 || body.CategorySeries[0].Values[0].Value != 1200 {
		t.Fatalf("unexpected category series: %#v", body.CategorySeries)
	}
	if len(body.AccountBalanceSeries) != 1 || body.AccountBalanceSeries[0].Account != "Assets:Cash" || body.AccountBalanceSeries[0].Alias == nil || *body.AccountBalanceSeries[0].Alias != "现金" || body.AccountBalanceSeries[0].Label != "现金" || len(body.AccountBalanceSeries[0].Values) != 31 || body.AccountBalanceSeries[0].Values[0].Value != -1200 || body.AccountBalanceSeries[0].Values[30].Value != 98800 {
		t.Fatalf("unexpected account balance series: %#v", body.AccountBalanceSeries)
	}
	if len(body.NetWorthSeries) != 31 || body.NetWorthSeries[0].Date != "05-01" || body.NetWorthSeries[0].NetWorth != -1200 || body.NetWorthSeries[30].NetWorth != 98800 {
		t.Fatalf("unexpected net worth series: %#v", body.NetWorthSeries)
	}
	if len(body.Anomalies) != 1 || body.Anomalies[0].Amount != 1200 || body.Anomalies[0].Account != "Expenses:Food" {
		t.Fatalf("unexpected anomalies: %#v", body.Anomalies)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2026-05-01&end=2026-05-08", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("weekly dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	wantDayLabels := []string{"05-01", "05-02", "05-03", "05-04", "05-05", "05-06", "05-07"}
	gotDayLabels := make([]string, 0, len(body.CashflowSeries))
	for _, point := range body.CashflowSeries {
		gotDayLabels = append(gotDayLabels, point.Month)
	}
	if !reflect.DeepEqual(gotDayLabels, wantDayLabels) || body.CashflowSeries[0].Expense != 1200 || body.CashflowSeries[0].Net != -1200 {
		t.Fatalf("unexpected daily cashflow series: %#v", body.CashflowSeries)
	}
	if len(body.CategorySeries) != 1 || len(body.CategorySeries[0].Values) != 7 || body.CategorySeries[0].Values[0].Month != "05-01" || body.CategorySeries[0].Values[0].Value != 1200 {
		t.Fatalf("unexpected daily category series: %#v", body.CategorySeries)
	}
	if len(body.AccountBalanceSeries) != 1 || len(body.AccountBalanceSeries[0].Values) != 7 || body.AccountBalanceSeries[0].Values[0].Month != "05-01" || body.AccountBalanceSeries[0].Values[0].Value != -1200 {
		t.Fatalf("unexpected daily account balance series: %#v", body.AccountBalanceSeries)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2026-05-01&end=2026-08-01", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("quarter dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.CashflowSeries) != 14 || body.CashflowSeries[0].Month != "05-01~05-07" || body.CashflowSeries[13].Month != "07-31~07-31" {
		t.Fatalf("unexpected weekly dashboard buckets: %#v", body.CashflowSeries)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2026-05-01&end=2026-06-01&type=expense,income&category=Expenses%3AFood&payee=Cafe&tag=work&minAmount=10&maxAmount=20", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("filtered dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(body.Filters.Types, []string{"expense", "income"}) || !reflect.DeepEqual(body.Filters.Categories, []string{"Expenses:Food"}) || !reflect.DeepEqual(body.Filters.Payees, []string{"Cafe"}) || !reflect.DeepEqual(body.Filters.Tags, []string{"work"}) || body.Filters.MinAmount == nil || *body.Filters.MinAmount != 1000 || body.Filters.MaxAmount == nil || *body.Filters.MaxAmount != 2000 {
		t.Fatalf("unexpected filters echo: %#v", body.Filters)
	}
	if body.KPIs.Income != 0 || body.KPIs.Expense != 1200 || body.KPIs.Net != -1200 || len(body.Anomalies) != 1 {
		t.Fatalf("unexpected filtered dashboard data: %#v", body)
	}
	if len(body.FilterOptions.Categories) == 0 || body.FilterOptions.Categories[0].Value != "Expenses:Food" || len(body.FilterOptions.Accounts) == 0 || body.FilterOptions.Accounts[0].Value != "Assets:Cash" || body.FilterOptions.Accounts[0].Alias == nil || *body.FilterOptions.Accounts[0].Alias != "现金" {
		t.Fatalf("expected unfiltered category/account options with aliases, got categories=%#v accounts=%#v", body.FilterOptions.Categories, body.FilterOptions.Accounts)
	}
	if len(body.Annotations) == 0 || body.Annotations[0].Kind != "tag" || !strings.Contains(body.Annotations[0].Drilldown, "%23work") {
		t.Fatalf("expected dashboard annotation drilldown, got %#v", body.Annotations)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2026-05-01&end=2026-06-01&type=income&payee=Employer", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("income filtered dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.KPIs.Income != 100000 || body.KPIs.Expense != 0 || body.KPIs.Net != 100000 || len(body.CategorySeries) != 0 {
		t.Fatalf("unexpected income filtered dashboard data: %#v", body)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/dashboard?start=2000-01-01&end=2099-12-31", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("all-time dashboard status=%d body=%s", res.Code, res.Body.String())
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	gotAllLabels := make([]string, 0, len(body.CashflowSeries))
	for _, point := range body.CashflowSeries {
		gotAllLabels = append(gotAllLabels, point.Month)
	}
	wantAllLabels := make([]string, 0, len(wantMonthLabels))
	for _, label := range wantMonthLabels {
		wantAllLabels = append(wantAllLabels, "2026-"+label)
	}
	if body.Start != "2000-01-01" || body.End != "2099-12-31" {
		t.Fatalf("all-time dashboard should preserve requested range, got start=%s end=%s", body.Start, body.End)
	}
	if !reflect.DeepEqual(gotAllLabels, wantAllLabels) || len(body.NetWorthSeries) != 31 || body.NetWorthSeries[0].Date != "2026-05-01" || body.KPIs.Income != 100000 || body.KPIs.Expense != 1200 {
		t.Fatalf("all-time dashboard should trim chart buckets to ledger activity, got cashflow=%#v netWorth=%#v kpis=%#v", body.CashflowSeries, body.NetWorthSeries, body.KPIs)
	}
	if len(body.CategorySeries) != 1 || len(body.CategorySeries[0].Values) != 31 || body.CategorySeries[0].Values[0].Month != "2026-05-01" {
		t.Fatalf("all-time dashboard should trim category trend buckets to ledger activity, got %#v", body.CategorySeries)
	}
	if len(body.AccountBalanceSeries) != 1 || len(body.AccountBalanceSeries[0].Values) != 31 || body.AccountBalanceSeries[0].Values[0].Month != "2026-05-01" {
		t.Fatalf("all-time dashboard should trim account trend buckets to ledger activity, got %#v", body.AccountBalanceSeries)
	}
}

func TestTransactionEditDeleteReverseAndReconcile(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	updateBody := `{"source":{"file":"` + filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean") + `","line":1},"entry":{"kind":"transaction","date":"2026-05-01","payee":"Cafe","narration":"Dinner","metadata":{},"tags":[],"postings":[{"account":"Expenses:Food","amount":"20.00","currency":"CNY"},{"account":"Assets:Cash","amount":"-20.00","currency":"CNY"}],"confidence":1,"needsReview":false,"questions":[]}}`
	res := requestWithCookies(router, http.MethodPut, "/api/ledger/transactions", updateBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("update status=%d body=%s", res.Code, res.Body.String())
	}
	text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")))
	if !strings.Contains(text, `"Dinner"`) || strings.Contains(text, `"Lunch"`) {
		t.Fatalf("transaction was not replaced:\n%s", text)
	}

	salaryHash := transactionHash([]string{`2026-05-31 * "Employer" "Salary"`, "  Assets:Cash 1000.00 CNY", "  Income:Salary -1000.00 CNY"})
	deleteBody := `{"source":{"file":"` + filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean") + `","line":99,"hash":"` + salaryHash + `"},"reason":"duplicate"}`
	res = requestWithCookies(router, http.MethodDelete, "/api/ledger/transactions", deleteBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("delete status=%d body=%s", res.Code, res.Body.String())
	}
	text = string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")))
	if !strings.Contains(text, "; deleted") || !strings.Contains(text, "; 2026-05-31") {
		t.Fatalf("transaction was not commented:\n%s", text)
	}

	reverseBody := `{"source":{"file":"` + filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean") + `","line":1},"date":"2026-05-02"}`
	res = requestWithCookies(router, http.MethodPost, "/api/ledger/transactions", reverseBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("reverse status=%d body=%s", res.Code, res.Body.String())
	}
	text = string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")))
	if !strings.Contains(text, "冲销：Dinner") {
		t.Fatalf("reversal was not appended:\n%s", text)
	}

	reconcileBody := `{"account":"Assets:Cash","actualAmount":"980.00","balanceDate":"2026-05-31"}`
	res = requestWithCookies(router, http.MethodPost, "/api/ledger/reconciliation", reconcileBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("reconcile status=%d body=%s", res.Code, res.Body.String())
	}
	text = string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")))
	if !strings.Contains(text, "balance Assets:Cash 980.00 CNY") {
		t.Fatalf("balance assertion was not appended:\n%s", text)
	}
}

func TestAppendEntryTracksLedgerWritesInFiles(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	t.Setenv("APP_PASSWORD", "secret")
	runGit(t, cfg, "init")
	runGit(t, cfg, "config", "user.email", "ledger@example.test")
	runGit(t, cfg, "config", "user.name", "Ledger Test")
	runGit(t, cfg, "add", ".")
	runGit(t, cfg, "commit", "-m", "initial ledger")
	t.Setenv("GIT_TEST_ASSUME_DIFFERENT_OWNER", "true")

	router := NewRouter(cfg)
	cookies := loginCookies(t, router)
	appendBody := `{"kind":"transaction","date":"2026-06-02","payee":"Bakery","narration":"Breakfast","metadata":{},"tags":[],"postings":[{"account":"Expenses:Food","amount":"15.00","currency":"CNY"},{"account":"Assets:Cash","amount":"-15.00","currency":"CNY"}],"confidence":1,"needsReview":false,"questions":[]}`
	res := requestWithCookies(router, http.MethodPost, "/api/ledger/append", appendBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("append status=%d body=%s", res.Code, res.Body.String())
	}
	main := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean")))
	if !strings.Contains(main, `include "transactions/2026/06.bean"`) {
		t.Fatalf("main include was not appended:\n%s", main)
	}
	monthly := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "06.bean")))
	if !strings.Contains(monthly, "Bakery") || !strings.Contains(monthly, "Breakfast") {
		t.Fatalf("monthly transaction was not appended:\n%s", monthly)
	}
	runGit(t, cfg, "add", ".")
	runGit(t, cfg, "commit", "-m", "manual commit after append")
}

func TestAppendEntryWritesTransaction(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	t.Setenv("APP_PASSWORD", "secret")

	router := NewRouter(cfg)
	cookies := loginCookies(t, router)
	appendBody := `{"kind":"transaction","date":"2026-06-02","payee":"Bakery","narration":"Breakfast","metadata":{},"tags":[],"postings":[{"account":"Expenses:Food","amount":"15.00","currency":"CNY"},{"account":"Assets:Cash","amount":"-15.00","currency":"CNY"}],"confidence":1,"needsReview":false,"questions":[]}`
	res := requestWithCookies(router, http.MethodPost, "/api/ledger/append", appendBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("append status=%d body=%s", res.Code, res.Body.String())
	}
	text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "06.bean")))
	if !strings.Contains(text, "Bakery") || !strings.Contains(text, "Breakfast") {
		t.Fatalf("transaction was not appended:\n%s", text)
	}
}
