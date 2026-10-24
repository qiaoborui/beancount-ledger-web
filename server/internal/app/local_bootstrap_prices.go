package app

import "sort"

// scopedBootstrapPrices bounds the price table carried by the native bootstrap
// page. The full table grows with the whole ledger history, and on a 100k
// synthetic ledger it alone exhausted the page byte budget (793 KiB of a 1 MiB
// limit) even though the app only reads the latest rate per currency pair plus
// rates inside the visible range.
//
// The result keeps every price inside [start, end) and the most recent price
// before start for each currency pair, which is what a rate lookup at the start
// of the range needs. snapshot.Prices keeps its chronological order, so the
// clipped table stays sorted by date.
func scopedBootstrapPrices(snapshot *LedgerSnapshot, start, end string) []Price {
	if snapshot == nil || len(snapshot.Prices) == 0 {
		return snapshot.Prices
	}
	anchor := make(map[string]Price, len(snapshot.PriceIndex.pairKeys))
	for _, key := range snapshot.PriceIndex.pairKeys {
		for _, price := range snapshot.PriceIndex.byPair[key] {
			if price.Date >= start {
				break
			}
			anchor[key] = price
		}
	}
	scoped := make([]Price, 0, len(anchor)+len(snapshot.Prices)/4)
	for _, price := range snapshot.Prices {
		if price.Date >= start && price.Date < end {
			scoped = append(scoped, price)
		}
	}
	for _, key := range snapshot.PriceIndex.pairKeys {
		price, ok := anchor[key]
		if !ok {
			continue
		}
		scoped = append(scoped, price)
	}
	// Anchors are collected per currency pair, so their dates interleave with the
	// in-range rows. Sort once here rather than inserting pair by pair, which
	// would need a fresh scan for every anchor and still depend on pair order.
	sort.SliceStable(scoped, func(i, j int) bool { return scoped[i].Date < scoped[j].Date })
	return scoped
}

// bootstrapPrices returns the price table for one bootstrap envelope.
func bootstrapPrices(snapshot *LedgerSnapshot, start, end string, scoped bool) []Price {
	if !scoped {
		return snapshot.Prices
	}
	return scopedBootstrapPrices(snapshot, start, end)
}
