//go:build cgo

package app

import (
	"context"
	"crypto/sha256"
	"fmt"
	"math/rand"
	"path/filepath"
	"strings"
	"testing"

	"github.com/borui/beancount-ledger-web/server/internal/readindex"
)

func TestIndexedValuationDifferentialLegacyOracle(t *testing.T) {
	rng := rand.New(rand.NewSource(762960))
	currencies := []string{"A", "B", "éur", "T"}
	for run := 0; run < 12; run++ {
		var prices []Price
		var stream strings.Builder
		stream.WriteString(`{"type":"header","version":1,"source_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","entry_file":"main.bean","runtime":"beancount/3.2.3 python/3.13.2","exporter":"bounded-v1"}` + "\n")
		for _, b := range currencies {
			for _, q := range currencies {
				if rng.Intn(3) != 0 {
					continue
				}
				for _, date := range []string{"2025-01-01", "2026-02-01"} {
					number := []string{"-1.55", "-.5", "0", ".33", "1.005", "1.55", "2"}[rng.Intn(7)]
					prices = append(prices, Price{Currency: b, QuoteCurrency: q, Date: date, Amount: (BeanAmount{Number: number}).Cents()})
					fmt.Fprintf(&stream, `{"type":"directive","id":%d,"value":{"Kind":"price","Date":%q,"File":"main.bean","Line":1,"Currency":%q,"QuoteCurrency":%q,"AmountValue":{"Number":%q,"Currency":%q}}}`+"\n", len(prices), date, b, q, number, q)
				}
			}
		}
		hash := sha256.Sum256([]byte(stream.String()))
		fmt.Fprintf(&stream, `{"type":"footer","records":%d,"directives":%d,"postings":0,"sha256":"%x"}`+"\n", len(prices)+1, len(prices), hash)
		path := filepath.Join(t.TempDir(), "private", "index.sqlite")
		m, e := readindex.Build(context.Background(), strings.NewReader(stream.String()), path)
		if e != nil {
			t.Fatal(e)
		}
		idx, e := readindex.Open(path, m)
		if e != nil {
			t.Fatal(e)
		}
		old := NewPriceIndex(prices)
		for _, date := range []string{"", "2024-12-31", "2025-01-01", "2026-01-01", "2026-02-01"} {
			for _, b := range currencies {
				for _, q := range currencies {
					for _, amount := range []int{-123, 0, 123} {
						want, found := old.Valuation(amount, b, q, date)
						got, e := idx.ValueLegacyCents(context.Background(), readindex.LegacyCentsRequest{Basis: "legacy_cents", Amount: int64(amount), Base: b, Quote: q, Date: date})
						if e != nil || got.Found != found || got.Amount != int64(want) {
							idx.Close()
							t.Fatalf("run %d %s %s/%s %d got %+v,%v want %d,%v", run, date, b, q, amount, got, e, want, found)
						}
					}
				}
			}
		}
		if e := idx.Close(); e != nil {
			t.Fatal(e)
		}
	}
}
