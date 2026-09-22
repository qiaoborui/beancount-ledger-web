package readindex

import (
	"context"
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/borui/beancount-ledger-web/server/internal/ledger"
	"github.com/borui/beancount-ledger-web/server/internal/readindex/sqlite"
)

// Schema 3 projects Go-normalized pair keys at ingestion and verifies them on
// reopen. SQL UPPER is NOT equivalent to Unicode strings.ToUpper. Both queries
// seek directly into the same index, with no DISTINCT, sort, graph or temp spill.
const latestPriceQuery = "SELECT seq, entry_id, date, currency, quantity, quote_currency FROM prices INDEXED BY prices_pair_date WHERE pair_key=? AND date<=? ORDER BY date DESC, seq DESC LIMIT 1"
const nextPricePairQuery = "SELECT pair_key FROM prices INDEXED BY prices_pair_date WHERE pair_key>? ORDER BY pair_key LIMIT 1"

// Last source sequence wins equal dates. Legacy sort.Slice is unstable, so tie
// compatibility is ambiguous; this policy does not claim legacy equal-date parity.
const PriceTiePolicy = "source_sequence_last"

type PriceLookupRequest struct {
	Base  string `json:"base"`
	Quote string `json:"quote"`
	Date  string `json:"date,omitempty"` // inclusive; empty = latest
}

type PriceQuote struct {
	Sequence      int64  `json:"sequence"`
	EntryID       int64  `json:"entry_id"`
	Date          string `json:"date"`
	Currency      string `json:"currency"`
	Quantity      string `json:"quantity"` // exact canonical spelling, never cents
	QuoteCurrency string `json:"quote_currency"`
}

type PriceLookupResult struct {
	Revision  string      `json:"revision"`
	TiePolicy string      `json:"tie_policy"`
	Found     bool        `json:"found"`
	Price     *PriceQuote `json:"price,omitempty"`
}

// LegacyCentsRequest is explicitly not a nominal-unit conversion. Both input
// and output are signed int64 cents. Every conversion edge truncates separately.
type LegacyCentsRequest struct {
	Basis  string `json:"basis"` // must be legacy_cents, never inferred
	Amount int64  `json:"amount"`
	Base   string `json:"base"`
	Quote  string `json:"quote"`
	Date   string `json:"date,omitempty"`
}

type LegacyCentsResult struct {
	Revision  string `json:"revision"`
	Basis     string `json:"basis"`
	TiePolicy string `json:"tie_policy"`
	Amount    int64  `json:"amount"`
	Found     bool   `json:"found"`
}

func validValuationCurrency(s string) bool {
	if len(s) > MaxCurrencyFilterBytes || !utf8.ValidString(s) {
		return false
	}
	s = ledger.NormalizeValuationCurrency(s)
	if len(s) > MaxCurrencyFilterBytes {
		return false
	}
	return !strings.ContainsFunc(s, unicode.IsControl)
}
func validPriceLookup(r PriceLookupRequest) bool {
	return validValuationCurrency(r.Base) && validValuationCurrency(r.Quote) && (r.Date == "" || validDate(r.Date))
}

// All statements close before returning scalars; DFS never nests native Rows.
type indexedPrices struct{ db *sqlite.DB }

func (p indexedPrices) quote(ctx context.Context, base, quote, date string) (PriceQuote, bool, error) {
	if e := ctx.Err(); e != nil {
		return PriceQuote{}, false, e
	}
	if date == "" {
		date = "9999-12-32"
	}
	rows, e := p.db.Query(latestPriceQuery, ledger.PricePairKey(base, quote), date)
	if e != nil {
		return PriceQuote{}, false, dbError(ctx, e, ErrCorrupt)
	}
	var result PriceQuote
	found := rows.Next()
	if found {
		result = PriceQuote{rows.Int64(0), rows.Int64(1), rows.Text(2), rows.Text(3), rows.Text(4), rows.Text(5)}
	}
	e = rows.Close()
	if e != nil || ctx.Err() != nil {
		return PriceQuote{}, false, dbError(ctx, e, ErrCorrupt)
	}
	// Bound retained scalar and JSON expansion independently of canonical storage.
	if found && (len(result.Currency) > MaxCurrencyFilterBytes || len(result.QuoteCurrency) > MaxCurrencyFilterBytes || len(result.Quantity) > MaxResponseBytes/6-4096) {
		return PriceQuote{}, false, ErrResourceLimit
	}
	return result, found, nil
}
func (p indexedPrices) Lookup(ctx context.Context, base, quote, date string) (int64, bool, error) {
	price, found, e := p.quote(ctx, base, quote, date)
	if e != nil || !found {
		return 0, false, e
	}
	cents, e := ledger.LegacyPriceCents(price.Quantity)
	if errors.Is(e, ledger.ErrValuationResource) {
		return 0, false, ErrResourceLimit
	}
	if e != nil {
		return 0, false, ErrCorrupt
	}
	return cents, true, nil
}
func (p indexedPrices) NextPair(ctx context.Context, after string) (string, bool, error) {
	if e := ctx.Err(); e != nil {
		return "", false, e
	}
	rows, e := p.db.Query(nextPricePairQuery, after)
	if e != nil {
		return "", false, dbError(ctx, e, ErrCorrupt)
	}
	found := rows.Next()
	key := ""
	if found {
		key = rows.Text(0)
	}
	e = rows.Close()
	if e != nil || ctx.Err() != nil {
		return "", false, dbError(ctx, e, ErrCorrupt)
	}
	// Canonical strings may contain controls or NUL. Preserve them in raw
	// storage, but never let an ambiguous separator silently change the graph.
	base, quote, separated := strings.Cut(key, "\x00")
	if found && (!separated || strings.Contains(quote, "\x00") || !validValuationCurrency(base) || !validValuationCurrency(quote)) {
		return "", false, ErrResourceLimit
	}
	if len(key) > 2*MaxCurrencyFilterBytes+1 {
		return "", false, ErrResourceLimit
	}
	return key, found, nil
}

func (i *Index) PriceLookup(ctx context.Context, r PriceLookupRequest) (PriceLookupResult, error) {
	if ctx == nil || !validPriceLookup(r) {
		return PriceLookupResult{}, ErrInvalidRequest
	}
	if e := ctx.Err(); e != nil {
		return PriceLookupResult{}, e
	}
	if i == nil {
		return PriceLookupResult{}, ErrUnavailable
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if e := ctx.Err(); e != nil {
		return PriceLookupResult{}, e
	}
	if i.db == nil {
		return PriceLookupResult{}, ErrUnavailable
	}
	join := cancelSQLite(ctx, i.db)
	defer join()
	price, found, e := (indexedPrices{i.db}).quote(ctx, r.Base, r.Quote, r.Date)
	if e != nil {
		return PriceLookupResult{}, e
	}
	result := PriceLookupResult{Revision: i.manifest.Revision, TiePolicy: PriceTiePolicy, Found: found}
	if found {
		result.Price = &price
	}
	return result, nil
}

func (i *Index) ValueLegacyCents(ctx context.Context, r LegacyCentsRequest) (LegacyCentsResult, error) {
	if ctx == nil || r.Basis != ledger.LegacyCentsBasis || !validPriceLookup(PriceLookupRequest{r.Base, r.Quote, r.Date}) {
		return LegacyCentsResult{}, ErrInvalidRequest
	}
	if e := ctx.Err(); e != nil {
		return LegacyCentsResult{}, e
	}
	if i == nil {
		return LegacyCentsResult{}, ErrUnavailable
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if e := ctx.Err(); e != nil {
		return LegacyCentsResult{}, e
	}
	if i.db == nil {
		return LegacyCentsResult{}, ErrUnavailable
	}
	join := cancelSQLite(ctx, i.db)
	defer join()
	amount, found, e := ledger.ValueLegacyCents(ctx, indexedPrices{i.db}, r.Amount, r.Base, r.Quote, r.Date)
	if errors.Is(e, ledger.ErrValuationResource) {
		e = ErrResourceLimit
	}
	if e != nil {
		return LegacyCentsResult{}, e
	}
	return LegacyCentsResult{i.manifest.Revision, ledger.LegacyCentsBasis, PriceTiePolicy, amount, found}, nil
}
