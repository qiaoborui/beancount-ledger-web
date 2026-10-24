package app

import (
	"testing"
)

func priceFixture() *LedgerSnapshot {
	snapshot := &LedgerSnapshot{}
	for _, price := range []Price{
		{Date: "2025-01-01", Currency: "USD", QuoteCurrency: "CNY", Amount: 700},
		{Date: "2026-06-01", Currency: "USD", QuoteCurrency: "CNY", Amount: 710},
		{Date: "2026-09-30", Currency: "USD", QuoteCurrency: "CNY", Amount: 720},
		{Date: "2026-10-05", Currency: "USD", QuoteCurrency: "CNY", Amount: 730},
		{Date: "2026-12-01", Currency: "USD", QuoteCurrency: "CNY", Amount: 740},
		{Date: "2025-03-01", Currency: "HKD", QuoteCurrency: "CNY", Amount: 90},
		{Date: "2026-10-02", Currency: "HKD", QuoteCurrency: "CNY", Amount: 92},
	} {
		snapshot.Prices = append(snapshot.Prices, price)
	}
	snapshot.PriceIndex = NewPriceIndex(snapshot.Prices)
	return snapshot
}

// The native page carries only the rates it can use: everything inside the
// visible range plus the most recent rate before it per currency pair. Shipping
// the whole history is what pushed a 100k ledger past the page byte budget.
func TestScopedBootstrapPricesKeepsRangeAndAnchor(t *testing.T) {
	snapshot := priceFixture()
	scoped := scopedBootstrapPrices(snapshot, "2026-10-01", "2026-11-01")
	got := make(map[string]int, len(scoped))
	for _, price := range scoped {
		got[price.Currency+"@"+price.Date] = price.Amount
	}
	// HKD@2025-03-01 is the only HKD rate before the range, so it is the anchor
	// a rate lookup at 2026-10-01 falls back to.
	for _, want := range []string{"USD@2026-09-30", "USD@2026-10-05", "HKD@2026-10-02", "HKD@2025-03-01"} {
		if _, ok := got[want]; !ok {
			t.Fatalf("clipped prices missing %s: %v", want, got)
		}
	}
	for _, unwanted := range []string{"USD@2025-01-01", "USD@2026-06-01", "USD@2026-12-01"} {
		if _, ok := got[unwanted]; ok {
			t.Fatalf("clipped prices kept out-of-range %s: %v", unwanted, got)
		}
	}
}

// A range that spans the history keeps every rate: clipping must never drop data
// the visible range actually needs.
func TestScopedBootstrapPricesKeepsFullRange(t *testing.T) {
	snapshot := priceFixture()
	scoped := scopedBootstrapPrices(snapshot, "2000-01-01", "2030-01-01")
	if len(scoped) != len(snapshot.Prices) {
		t.Fatalf("full range clipped %d of %d prices", len(scoped), len(snapshot.Prices))
	}
}

// Prices stay chronological so callers can binary-search or assume sorted order.
func TestScopedBootstrapPricesStaysSorted(t *testing.T) {
	snapshot := priceFixture()
	scoped := scopedBootstrapPrices(snapshot, "2026-10-01", "2026-11-01")
	for i := 1; i < len(scoped); i++ {
		if scoped[i-1].Date > scoped[i].Date {
			t.Fatalf("clipped prices out of order at %d: %v", i, scoped)
		}
	}
}
