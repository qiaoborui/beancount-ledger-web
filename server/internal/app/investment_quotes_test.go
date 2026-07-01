package app

import (
	"context"
	"strings"
	"testing"
)

func TestInvestmentQuoteSymbolUsesCommodityMetadata(t *testing.T) {
	commodity := Commodity{
		Symbol: "SZ159350",
		Metadata: map[string]MetadataValue{
			"quote_symbol": "SZSE:159350",
		},
	}

	if got := investmentQuoteSymbol(commodity); got != "SZSE:159350" {
		t.Fatalf("quote symbol = %q, want SZSE:159350", got)
	}
}

func TestLedgerInvestmentQuoteProviderUsesLatestLedgerPrices(t *testing.T) {
	holding := InvestmentHolding{
		Commodity:     "QQQ",
		CommodityName: "Invesco QQQ Trust",
		LatestPrice:   &CommodityPrice{Date: "2026-06-30", Commodity: "QQQ", Amount: 736.40, Currency: "USD"},
		TotalQuantity: 0.0056,
	}
	quotes, err := (ledgerInvestmentQuoteProvider{}).Quotes(context.Background(), investmentQuoteRequest{Holdings: []InvestmentHolding{holding}, Symbols: map[string]string{"QQQ": "QQQ"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(quotes) != 1 || quotes[0].Commodity != "QQQ" || quotes[0].Amount != 736.40 || quotes[0].Status != "ledger" || quotes[0].Source != "ledger" {
		t.Fatalf("unexpected ledger quotes: %#v", quotes)
	}
}

func TestMergeInvestmentQuotesPrefersLiveQuotes(t *testing.T) {
	fallback := []InvestmentLiveQuote{{Commodity: "QQQ", Amount: 736.40, Currency: "USD", Source: "ledger", Status: "ledger"}}
	live := []InvestmentLiveQuote{{Commodity: "QQQ", Amount: 737.01, Currency: "USD", Source: "mock", Status: "live"}}

	quotes := mergeInvestmentQuotes(fallback, live)
	if len(quotes) != 1 || quotes[0].Amount != 737.01 || quotes[0].Source != "mock" {
		t.Fatalf("live quote should override fallback, got %#v", quotes)
	}
}

func TestQuotesWithProviderErrorKeepsLedgerFallback(t *testing.T) {
	quotes := quotesWithProviderError([]InvestmentLiveQuote{{Commodity: "QQQ", Amount: 736.40, Currency: "USD"}}, errString("provider down"))
	if len(quotes) != 1 || quotes[0].Amount != 736.40 || quotes[0].Status != "ledger" || !strings.Contains(quotes[0].Error, "provider down") {
		t.Fatalf("unexpected errored fallback quotes: %#v", quotes)
	}
}

type errString string

func (err errString) Error() string {
	return string(err)
}
