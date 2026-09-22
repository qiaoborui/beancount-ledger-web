package readindex

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/ledger"
	"github.com/borui/beancount-ledger-web/server/internal/readindex/sqlite"
)

func priceRecord(id int, date, base, number, quote string) string {
	encode := func(s string) string { raw, _ := json.Marshal(s); return string(raw) }
	return fmt.Sprintf(`{"type":"directive","id":%d,"value":{"Kind":"price","Date":%s,"File":"main.bean","Line":1,"Currency":%s,"QuoteCurrency":%s,"AmountValue":{"Number":%s,"Currency":%s}}}`, id, encode(date), encode(base), encode(quote), encode(number), encode(quote))
}

func valuationRequest(amount int64, b, q, d string) LegacyCentsRequest {
	return LegacyCentsRequest{ledger.LegacyCentsBasis, amount, b, q, d}
}
func TestPriceLookupExactNormalizedAndTies(t *testing.T) {
	records := []string{testHeader,
		priceRecord(1, "2026-01-01", " éur ", "1.00500000000000000001", " usd "),
		priceRecord(2, "2025-01-01", "ÉUR", "2.000", "USD"),
		priceRecord(3, "2026-01-01", "ÉUR", "3e0", "USD"),
		priceRecord(4, "2027-01-01", "ÉUR", "4.000", "USD"),
		priceRecord(5, "2026-01-01", "HUGE", "1e999999999", "USD")}
	path, m := buildText(t, makeStream(records...))
	i := openIndex(t, path, m)
	ctx := context.Background()
	if m.SchemaVersion != 3 {
		t.Fatal(m.SchemaVersion)
	}
	for _, tc := range []struct {
		date, quantity string
		id             int64
	}{{"2024-01-01", "", 0}, {"2025-01-01", "2.000", 2}, {"2026-01-01", "3e0", 3}, {"2026-12-31", "3e0", 3}, {"", "4.000", 4}} {
		p, e := i.PriceLookup(ctx, PriceLookupRequest{" \téur\u2003", "usd", tc.date})
		if e != nil || p.Found != (tc.id != 0) || p.Revision != m.Revision || p.TiePolicy != PriceTiePolicy {
			t.Fatal(p, e)
		}
		if p.Found && (p.Price.EntryID != tc.id || p.Price.Quantity != tc.quantity) {
			t.Fatal(p.Price)
		}
	}
	// Equal-date winner is last source sequence, not an asserted unstable-sort match.
	p, e := i.PriceLookup(ctx, PriceLookupRequest{"HUGE", "USD", ""})
	if e != nil || !p.Found || p.Price.Quantity != "1e999999999" {
		t.Fatal(p, e)
	}
	_, e = i.ValueLegacyCents(ctx, valuationRequest(100, "HUGE", "USD", ""))
	wantError(t, e, ErrResourceLimit)
	d, e := i.Detail(ctx, 1)
	if e != nil || string(d.Records[0]) != records[1] {
		t.Fatal("raw price changed", e)
	}
}
func TestIndexedLegacyCentsPolicy(t *testing.T) {
	path, m := buildText(t, makeStream(testHeader,
		priceRecord(1, "2025-01-01", "A", "1.55", "B"), priceRecord(2, "2025-01-01", "B", "1.55", "T"),
		priceRecord(3, "2026-01-01", "T", "2", "A"), priceRecord(4, "2027-01-01", "A", "0", "T"),
		priceRecord(5, "2025-01-01", "NEG", "-1.55", "T"), priceRecord(6, "2025-01-01", "ROUND", "1.005", "T"),
		priceRecord(7, "2025-01-01", "ZERO", "0", "USD")))
	i := openIndex(t, path, m)
	for _, tc := range []struct {
		amount  int64
		b, q, d string
		want    int64
		found   bool
	}{
		{123, "A", "T", "2025-01-01", 294, true}, {123, "A", "T", "2026-01-01", 61, true}, {123, "A", "T", "", 0, true},
		{-123, "NEG", "T", "", 190, true}, {123, "ROUND", "T", "", 124, true}, {123, "A", "T", "2024-01-01", 0, false},
		{100, "USD", "ZERO", "", 0, false}, {100, "ZERO", "USD", "", 0, true}, {123, "MISS", "T", "", 0, false},
		{math.MaxInt64, " usd ", "USD", "", math.MaxInt64, true}, {100, "", "cny", "", 100, true},
	} {
		r, e := i.ValueLegacyCents(context.Background(), valuationRequest(tc.amount, tc.b, tc.q, tc.d))
		if e != nil || r.Amount != tc.want || r.Found != tc.found || r.Basis != "legacy_cents" || r.Revision != m.Revision {
			t.Fatal(tc, r, e)
		}
	}
	for _, r := range []LegacyCentsRequest{valuationRequest(math.MaxInt64, "A", "B", ""), valuationRequest(math.MaxInt64, "B", "A", ""), valuationRequest(math.MinInt64, "NEG", "T", "")} {
		_, e := i.ValueLegacyCents(context.Background(), r)
		if e != ErrResourceLimit {
			t.Fatal("overflow must return unwrapped resource error", e)
		}
	}
}
func TestPriceQueryPlansAndScalarIteration(t *testing.T) {
	path, m := buildText(t, makeStream(testHeader, priceRecord(1, "2025-01-01", "Z", "1", "A"), priceRecord(2, "2025-01-01", "A", "1", "Z"), priceRecord(3, "2026-01-01", "A", "2", "Z")))
	i := openIndex(t, path, m)
	for _, q := range []struct {
		sql  string
		args []any
	}{{latestPriceQuery, []any{"A\x00Z", "2026-01-01"}}, {nextPricePairQuery, []any{""}}} {
		rows, e := i.db.Query("EXPLAIN QUERY PLAN "+q.sql, q.args...)
		if e != nil {
			t.Fatal(e)
		}
		var plan string
		for rows.Next() {
			plan += rows.Text(3)
		}
		if e = rows.Close(); e != nil {
			t.Fatal(e)
		}
		if !strings.Contains(plan, "SEARCH prices USING") || !strings.Contains(plan, "prices_pair_date") || strings.Contains(plan, "TEMP") {
			t.Fatal(plan)
		}
		rows, e = i.db.Query("EXPLAIN "+q.sql, q.args...)
		if e != nil {
			t.Fatal(e)
		}
		for rows.Next() {
			op := rows.Text(1)
			if strings.Contains(op, "Sorter") || op == "OpenEphemeral" {
				t.Fatal(op)
			}
		}
		if e = rows.Close(); e != nil {
			t.Fatal(e)
		}
	}
	p := indexedPrices{i.db}
	after := ""
	for _, want := range []string{"A\x00Z", "Z\x00A", ""} {
		key, found, e := p.NextPair(context.Background(), after)
		if e != nil || key != want || found != (want != "") {
			t.Fatal(key, found, e)
		}
		after = key
	}
	// Statements close before a caller can perform another scalar lookup.
	v, found, e := p.Lookup(context.Background(), "A", "Z", "")
	if e != nil || !found || v != 200 {
		t.Fatal(v, found, e)
	}
}
func TestPriceProjectionTamperAndSchemaTwo(t *testing.T) {
	for _, sql := range []string{"UPDATE prices SET pair_key='BAD'", "UPDATE prices SET currency='BAD'", "UPDATE prices SET quantity='2'", "DROP INDEX prices_pair_date"} {
		path, m := buildText(t, makeStream(testHeader, priceRecord(1, "2025-01-01", "éur", "1.00", "usd")))
		db, e := sqlite.Open(path, true)
		if e != nil {
			t.Fatal(e)
		}
		e = db.Exec(sql)
		db.Close()
		if e != nil {
			t.Fatal(e)
		}
		_, e = Open(path, m)
		wantError(t, e, ErrCorrupt)
	}
	path, m := buildText(t, makeStream(testHeader, priceRecord(1, "2025-01-01", "A", "1", "B")))
	db, e := sqlite.Open(path, true)
	if e != nil {
		t.Fatal(e)
	}
	old := m
	old.SchemaVersion = 2
	raw, _ := json.Marshal(old)
	e = db.Exec("UPDATE manifest SET raw=?", string(raw))
	db.Close()
	if e != nil {
		t.Fatal(e)
	}
	_, e = Open(path, old)
	wantError(t, e, ErrCorrupt)
}
func TestValuationRequestsCancellationAndBounds(t *testing.T) {
	path, m := buildText(t, makeStream(testHeader, priceRecord(1, "2025-01-01", "A", "1", "B")))
	i := openIndex(t, path, m)
	ctx := context.Background()
	for _, r := range []PriceLookupRequest{{"A", "B", "2025-02-30"}, {"A\x00B", "T", ""}, {"A", string([]byte{0xff}), ""}, {strings.Repeat("x", 1025), "B", ""}} {
		_, e := i.PriceLookup(ctx, r)
		wantError(t, e, ErrInvalidRequest)
		_, e = i.ValueLegacyCents(ctx, valuationRequest(100, r.Base, r.Quote, r.Date))
		wantError(t, e, ErrInvalidRequest)
	}
	for _, basis := range []string{"", "native_nominal", "exact"} {
		r := valuationRequest(1, "A", "B", "")
		r.Basis = basis
		_, e := i.ValueLegacyCents(ctx, r)
		wantError(t, e, ErrInvalidRequest)
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	_, e := i.PriceLookup(canceled, PriceLookupRequest{})
	wantError(t, e, context.Canceled)
	_, e = i.ValueLegacyCents(canceled, valuationRequest(1, "A", "B", ""))
	wantError(t, e, context.Canceled)
	_, e = i.PriceLookup(nil, PriceLookupRequest{})
	wantError(t, e, ErrInvalidRequest)
	_, e = i.ValueLegacyCents(nil, valuationRequest(1, "A", "B", ""))
	wantError(t, e, ErrInvalidRequest)
	i.Close()
	_, e = i.PriceLookup(ctx, PriceLookupRequest{})
	wantError(t, e, ErrUnavailable)
	_, e = i.ValueLegacyCents(ctx, valuationRequest(1, "A", "B", ""))
	wantError(t, e, ErrUnavailable)
	for _, n := range []int{64, 65} {
		records := []string{testHeader}
		b := "A"
		for k := 1; k <= n; k++ {
			records = append(records, priceRecord(k, "2025-01-01", b, "1", b+"x"))
			b += "x"
		}
		path, m := buildText(t, makeStream(records...))
		idx := openIndex(t, path, m)
		r, e := idx.ValueLegacyCents(ctx, valuationRequest(100, "A", b, ""))
		if n == 64 {
			if e != nil || !r.Found || r.Amount != 100 {
				t.Fatal(r, e)
			}
		} else {
			wantError(t, e, ErrResourceLimit)
		}
	}
}

func TestIndexedValuationSearchBudget(t *testing.T) {
	// Dense cyclic component disconnected from target: missing cannot be asserted
	// until DFS exhausts all paths. Bounded work must instead return a resource error.
	records := []string{testHeader}
	id := 0
	for b := 0; b < 9; b++ {
		for q := 0; q < 9; q++ {
			id++
			records = append(records, priceRecord(id, "2025-01-01", fmt.Sprintf("A%d", b), "1", fmt.Sprintf("A%d", q)))
		}
	}
	path, m := buildText(t, makeStream(records...))
	i := openIndex(t, path, m)
	_, e := i.ValueLegacyCents(context.Background(), valuationRequest(100, "A0", "TARGET", ""))
	if e != ErrResourceLimit {
		t.Fatal(e)
	}
	// Cancellation during native-backed search is not a missing quote either.
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	_, e = i.ValueLegacyCents(ctx, valuationRequest(100, "A0", "TARGET", ""))
	cancel()
	wantError(t, e, context.DeadlineExceeded)
	// A rejected operation must release its statement and leave the reader reusable.
	r, e := i.ValueLegacyCents(context.Background(), valuationRequest(100, "A0", "A1", ""))
	if e != nil || !r.Found || r.Amount != 100 {
		t.Fatal(r, e)
	}
}

func TestPriceScalarResourceBoundsPreserveRaw(t *testing.T) {
	for _, tc := range []struct{ base, quantity string }{{"A", strings.Repeat("1", MaxResponseBytes/6)}, {strings.Repeat("A", 1025), "1"}, {"A\x00B", "1"}} {
		record := priceRecord(1, "2025-01-01", tc.base, tc.quantity, "T")
		path, m := buildText(t, makeStream(testHeader, record))
		i := openIndex(t, path, m)
		detail, e := i.Detail(context.Background(), 1)
		if e != nil || string(detail.Records[0]) != record {
			t.Fatal("raw was not preserved", e)
		}
		if tc.base == "A" {
			_, e = i.PriceLookup(context.Background(), PriceLookupRequest{"A", "T", ""})
			wantError(t, e, ErrResourceLimit)
		} else {
			_, e = i.ValueLegacyCents(context.Background(), valuationRequest(100, "MISSING", "T", ""))
			wantError(t, e, ErrResourceLimit)
		}
	}
}
