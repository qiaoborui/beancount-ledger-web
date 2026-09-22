package ledger

import (
	"context"
	"errors"
	"math"
	"math/big"
	"strings"
)

const (
	LegacyCentsBasis  = "legacy_cents"
	MaxValuationDepth = 64
	MaxValuationWork  = 100000
)

var ErrValuationResource = errors.New("valuation resource limit exceeded")

// NormalizeValuationCurrency is the legacy Go normalization, not SQLite UPPER.
func NormalizeValuationCurrency(currency string) string {
	currency = strings.ToUpper(strings.TrimSpace(currency))
	if currency == "" {
		return "CNY"
	}
	return currency
}

func PricePairKey(base, quote string) string {
	return NormalizeValuationCurrency(base) + "\x00" + NormalizeValuationCurrency(quote)
}

// LegacyPriceCents deliberately uses BeanAmount.Cents' Rat -> float64 -> Round
// semantics, NOT exact decimal rounding. Canonical storage is never changed.
// Arithmetic inputs are bounded before constructing a rational; out-of-range,
// nonfinite and over-budget inputs are errors, never platform int wraparound.
func LegacyPriceCents(number string) (int64, error) {
	if number == "NaN" || number == "Inf" || number == "+Inf" || number == "-Inf" {
		return 0, ErrValuationResource
	}
	if _, _, err := decimalParts(number); err != nil {
		if errors.Is(err, ErrDecimalLimit) {
			return 0, ErrValuationResource
		}
		return 0, err
	}
	rat, ok := new(big.Rat).SetString(number)
	if !ok {
		return 0, ErrDecimalSyntax
	}
	rat.Mul(rat, big.NewRat(100, 1))
	v, _ := rat.Float64()
	v = math.Round(v)
	// float64(MaxInt64) is 2^63, so the upper bound is exclusive.
	if math.IsNaN(v) || math.IsInf(v, 0) || v < -0x1p63 || v >= 0x1p63 {
		return 0, ErrValuationResource
	}
	return int64(v), nil
}

// ValuationPrices owns no graph. Each method returns a scalar with no live row
// cursor. Lookup uses latest <= date (empty date means latest). NextPair returns
// the first normalized base+NUL+quote key strictly greater than after, in Go
// byte-lexicographic order. Providers must honor context and bound scalar sizes.
// Equal-date selection belongs to the provider: the old unstable sort gives no
// portable tie guarantee; source-sequence-last is deterministic, not tie parity.
type ValuationPrices interface {
	Lookup(ctx context.Context, base, quote, date string) (int64, bool, error)
	NextPair(ctx context.Context, after string) (string, bool, error)
}

func centsEdge(amount, price int64, inverse bool) (int64, error) {
	a, b, divisor := amount, price, int64(100)
	if inverse {
		b, divisor = 100, price
	}
	if divisor == 0 {
		return 0, ErrValuationResource
	}
	if (a == math.MinInt64 && b == -1) || (b == math.MinInt64 && a == -1) {
		return 0, ErrValuationResource
	}
	product := a * b
	if b != 0 && product/b != a {
		return 0, ErrValuationResource
	}
	if product == math.MinInt64 && divisor == -1 {
		return 0, ErrValuationResource
	}
	return product / divisor, nil // truncate toward zero at EVERY edge
}

// ValueLegacyCents preserves direct, inverse, then lexicographic DFS priority
// and path-local cycle detection, including direct/inverse before the seen test.
// Missing is (0,false,nil); budget/overflow/cancellation never becomes missing.
// At most 64 conversion edges and 100000 scalar lookup/iteration operations
// are allowed, including nonincident pairs and failed probes (no graph cache).
func ValueLegacyCents(ctx context.Context, prices ValuationPrices, amount int64, base, quote, date string) (int64, bool, error) {
	if ctx == nil || prices == nil {
		return 0, false, errors.New("invalid valuation request")
	}
	seen := make(map[string]bool, MaxValuationDepth)
	work := 0
	step := func() error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if work >= MaxValuationWork {
			return ErrValuationResource
		}
		work++
		return nil
	}
	lookup := func(base, quote string) (int64, bool, error) {
		if err := step(); err != nil {
			return 0, false, err
		}
		v, ok, err := prices.Lookup(ctx, base, quote, date)
		if ctx.Err() != nil {
			return 0, false, ctx.Err()
		}
		return v, ok, err
	}
	var visit func(int64, string, int) (int64, bool, error)
	target := NormalizeValuationCurrency(quote)
	visit = func(amount int64, currency string, depth int) (int64, bool, error) {
		if err := ctx.Err(); err != nil {
			return 0, false, err
		}
		if currency == target {
			return amount, true, nil
		}
		if depth >= MaxValuationDepth {
			return 0, false, ErrValuationResource
		}
		if p, ok, err := lookup(currency, target); err != nil {
			return 0, false, err
		} else if ok {
			v, err := centsEdge(amount, p, false)
			return v, err == nil, err
		}
		if p, ok, err := lookup(target, currency); err != nil {
			return 0, false, err
		} else if ok && p != 0 {
			v, err := centsEdge(amount, p, true)
			return v, err == nil, err
		}
		if seen[currency] {
			return 0, false, nil
		}
		seen[currency] = true
		defer delete(seen, currency)
		after := ""
		for {
			if err := step(); err != nil {
				return 0, false, err
			}
			key, ok, err := prices.NextPair(ctx, after)
			if ctx.Err() != nil {
				return 0, false, ctx.Err()
			}
			if err != nil || !ok {
				return 0, false, err
			}
			if key <= after {
				return 0, false, ErrValuationResource
			} // broken provider must not loop
			after = key
			b, q, _ := strings.Cut(key, "\x00")
			for _, inverse := range []bool{false, true} {
				next := q
				if inverse {
					if q != currency {
						continue
					}
					next = b
				} else if b != currency {
					continue
				}
				p, found, err := lookup(b, q)
				if err != nil {
					return 0, false, err
				}
				if !found || (inverse && p == 0) {
					continue
				}
				value, err := centsEdge(amount, p, inverse)
				if err != nil {
					return 0, false, err
				}
				result, found, err := visit(value, next, depth+1)
				if err != nil || found {
					return result, found, err
				}
			}
		}
	}
	return visit(amount, NormalizeValuationCurrency(base), 0)
}
