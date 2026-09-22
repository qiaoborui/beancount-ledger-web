package app

import (
	"context"
	"math/rand"
	"sort"
	"testing"

	"github.com/borui/beancount-ledger-web/server/internal/ledger"
)

// The unchanged application PriceIndex is the legacy oracle. Do not replace its
// traversal with the shared implementation: its bool-only API cannot expose
// resource failures, and equal-date unstable sorting must remain unchanged.
type policyPriceAdapter struct{ PriceIndex }

func (p policyPriceAdapter) Lookup(ctx context.Context, b, q, d string) (int64, bool, error) {
	v, ok := p.latestPrice(b, q, d)
	if !ok {
		return 0, false, nil
	}
	return int64(v.Amount), true, nil
}
func (p policyPriceAdapter) NextPair(ctx context.Context, after string) (string, bool, error) {
	n := sort.Search(len(p.pairKeys), func(n int) bool { return p.pairKeys[n] > after })
	if n == len(p.pairKeys) {
		return "", false, nil
	}
	return p.pairKeys[n], true, nil
}
func TestBoundedValuationDifferentialLegacyOracle(t *testing.T) {
	rng := rand.New(rand.NewSource(7629))
	currencies := []string{"A", "B", "C", "D", "T"}
	for run := 0; run < 150; run++ {
		var prices []Price
		for _, b := range currencies {
			for _, q := range currencies {
				if rng.Intn(3) != 0 {
					continue
				}
				for _, date := range []string{"2025-01-01", "2026-02-01"} {
					prices = append(prices, Price{Currency: b, QuoteCurrency: q, Date: date, Amount: []int{-155, -50, 0, 33, 100, 155, 200}[rng.Intn(7)]})
				}
			}
		}
		old := NewPriceIndex(prices)
		for _, date := range []string{"", "2024-12-31", "2025-01-01", "2026-01-01", "2026-02-01"} {
			for _, b := range currencies {
				for _, q := range currencies {
					for _, amount := range []int{-123, 0, 123} {
						want, found := old.Valuation(amount, b, q, date)
						got, ok, e := ledger.ValueLegacyCents(context.Background(), policyPriceAdapter{old}, int64(amount), b, q, date)
						if e != nil || ok != found || got != int64(want) {
							t.Fatalf("run %d %s %s/%s %d got %d,%v,%v want %d,%v", run, date, b, q, amount, got, ok, e, want, found)
						}
					}
				}
			}
		}
	}
}
