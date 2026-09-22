package ledger

import (
	"context"
	"errors"
	"fmt"
	"math"
	"strings"
	"testing"
)

type testPrices map[string]int64

func (p testPrices) Lookup(ctx context.Context, b, q, d string) (int64, bool, error) {
	v, ok := p[PricePairKey(b, q)]
	return v, ok, ctx.Err()
}
func (p testPrices) NextPair(ctx context.Context, after string) (string, bool, error) {
	next := ""
	for key := range p {
		if key > after && (next == "" || key < next) {
			next = key
		}
	}
	return next, next != "", ctx.Err()
}
func TestLegacyPriceCentsCompatibility(t *testing.T) {
	for _, s := range []string{"0", "1.005", "-1.005", ".005", "-.005", "2.675", "1.234567890123456789", "1e-1024", "90071992547409.91", "-92233720368547758.08", "92233720368547740", "1E+2"} {
		got, e := LegacyPriceCents(s)
		want := int64((BeanAmount{Number: s}).Cents())
		if e != nil || got != want {
			t.Fatalf("%s: %d != %d (%v)", s, got, want, e)
		}
	}
	// Exact rounding would yield 9007199254740991, unlike the float pipeline.
	v, _ := LegacyPriceCents("90071992547409.905")
	if v == 9007199254740991 {
		t.Fatal("unexpected exact nominal rounding")
	}
	for _, s := range []string{"92233720368547758.07", "-92233720368547780", "1e309", "NaN", "Inf", "-Inf", "1e999999999", strings.Repeat("1", 4097)} {
		if _, e := LegacyPriceCents(s); e != ErrValuationResource {
			t.Fatalf("%s: %v", s, e)
		}
	}
	if _, e := LegacyPriceCents("not a number"); e != ErrDecimalSyntax {
		t.Fatal(e)
	}
}
func TestCentsEdgeOverflowAndTruncation(t *testing.T) {
	for _, tc := range []struct {
		a, p    int64
		inverse bool
		want    int64
		fail    bool
	}{
		{123, 155, false, 190, false}, {-123, 155, false, -190, false}, {123, -155, false, -190, false},
		{123, 155, true, 79, false}, {-123, 155, true, -79, false}, {math.MaxInt64, 100, false, 0, true},
		{math.MinInt64, -1, false, 0, true}, {-1, math.MinInt64, false, 0, true},
		{math.MaxInt64, 100, true, 0, true}, {math.MinInt64, 1, false, math.MinInt64 / 100, false},
		{1, 0, false, 0, false}, {1, 0, true, 0, true},
	} {
		v, e := centsEdge(tc.a, tc.p, tc.inverse)
		if tc.fail {
			if e != ErrValuationResource {
				t.Fatal(tc, e)
			}
		} else if e != nil || v != tc.want {
			t.Fatal(tc, v, e)
		}
	}
}
func TestValuationOrderAndCycles(t *testing.T) {
	p := testPrices{PricePairKey("A", "B"): 155, PricePairKey("B", "T"): 155}
	v, ok, e := ValueLegacyCents(context.Background(), p, 123, " a ", "t", "")
	if e != nil || !ok || v != 294 {
		t.Fatal(v, ok, e)
	}
	p[PricePairKey("T", "A")] = 200
	v, ok, e = ValueLegacyCents(context.Background(), p, 123, "A", "T", "")
	if e != nil || !ok || v != 61 {
		t.Fatal(v, ok, e)
	}
	p[PricePairKey("A", "T")] = 0
	v, ok, e = ValueLegacyCents(context.Background(), p, 123, "A", "T", "")
	if e != nil || !ok || v != 0 {
		t.Fatal(v, ok, e)
	}
	delete(p, PricePairKey("A", "T"))
	delete(p, PricePairKey("T", "A"))
	delete(p, PricePairKey("B", "T"))
	v, ok, e = ValueLegacyCents(context.Background(), p, 123, "A", "T", "")
	if e != nil || ok || v != 0 {
		t.Fatal(v, ok, e)
	}
	if NormalizeValuationCurrency(" \téur\u2003") != "ÉUR" || NormalizeValuationCurrency("") != "CNY" {
		t.Fatal("normalization")
	}
}

type generatedPrices struct {
	calls  int
	cancel context.CancelFunc
}

func (p *generatedPrices) Lookup(ctx context.Context, b, q, d string) (int64, bool, error) {
	p.calls++
	if p.cancel != nil {
		p.cancel()
	}
	return 0, false, nil
}
func (p *generatedPrices) NextPair(ctx context.Context, after string) (string, bool, error) {
	p.calls++
	return fmt.Sprintf("Z%09d\x00Q", p.calls), true, nil
}
func TestValuationLimitsAndCancellation(t *testing.T) {
	p := &generatedPrices{}
	_, ok, e := ValueLegacyCents(context.Background(), p, 100, "A", "T", "")
	if e != ErrValuationResource || ok || p.calls != MaxValuationWork {
		t.Fatal(ok, e, p.calls)
	}
	for _, length := range []int{64, 65} {
		p := testPrices{}
		b := "A"
		for n := 0; n < length; n++ {
			p[PricePairKey(b, b+"x")] = 100
			b += "x"
		}
		v, ok, e := ValueLegacyCents(context.Background(), p, 100, "A", b, "")
		if length == 64 {
			if e != nil || !ok || v != 100 {
				t.Fatal(length, v, ok, e)
			}
		} else if e != ErrValuationResource || ok {
			t.Fatal(length, ok, e)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, ok, e = ValueLegacyCents(ctx, testPrices{}, 100, "A", "A", "")
	if !errors.Is(e, context.Canceled) || ok {
		t.Fatal(ok, e)
	}
	ctx, cancel = context.WithCancel(context.Background())
	p = &generatedPrices{cancel: cancel}
	_, ok, e = ValueLegacyCents(ctx, p, 100, "A", "T", "")
	if !errors.Is(e, context.Canceled) || ok || p.calls != 1 {
		t.Fatal(ok, e, p.calls)
	}
}

func TestValuationLexicographicChoice(t *testing.T) {
	// AB sorts before B, including the NUL separator. The first path wins even
	// when the later path has a better rate. No best-rate/BFS interpretation.
	p := testPrices{PricePairKey("A", "AB"): 155, PricePairKey("AB", "T"): 155, PricePairKey("A", "B"): 200, PricePairKey("B", "T"): 200}
	v, ok, e := ValueLegacyCents(context.Background(), p, 123, "A", "T", "")
	if e != nil || !ok || v != 294 {
		t.Fatal(v, ok, e)
	}
}

type failingPrices struct {
	err      error
	failPair bool
}

func (p failingPrices) Lookup(context.Context, string, string, string) (int64, bool, error) {
	if !p.failPair {
		return 0, false, p.err
	}
	return 0, false, nil
}
func (p failingPrices) NextPair(context.Context, string) (string, bool, error) {
	return "", false, p.err
}
func TestValuationProviderErrorIsNotMissing(t *testing.T) {
	sentinel := errors.New("provider failure")
	for _, pairs := range []bool{false, true} {
		_, ok, e := ValueLegacyCents(context.Background(), failingPrices{sentinel, pairs}, 1, "A", "T", "")
		if e != sentinel || ok {
			t.Fatal(ok, e)
		}
	}
}
