package readindex

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"

	"github.com/borui/beancount-ledger-web/server/internal/ledger"
	"github.com/borui/beancount-ledger-web/server/internal/readindex/sqlite"
)

// AccountSummaryRequest requires an exact account and currency (no inference,
// descendants, prices, costs or cents conversion). Start/End are both absent or
// a strict [start,end) interval, as in AccountBalancesRequest.
type AccountSummaryRequest struct {
	Account  string `json:"account"`
	Currency string `json:"currency"`
	Start    string `json:"start,omitempty"`
	End      string `json:"end,omitempty"`
}

type AccountSummary struct {
	Revision       string `json:"revision"`
	Basis          string `json:"basis"`
	Account        string `json:"account"`
	Currency       string `json:"currency"`
	Start          string `json:"start,omitempty"`
	End            string `json:"end,omitempty"`
	CurrentBalance string `json:"current_balance"`
	OpeningBalance string `json:"opening_balance"`
	ClosingBalance string `json:"closing_balance"`
	PeriodChange   string `json:"period_change"`
}

// Flat wire object, intentionally not embedded: the bridge rejects unknown keys.
type AccountActivityRequest struct {
	Account  string `json:"account"`
	Currency string `json:"currency"`
	Start    string `json:"start,omitempty"`
	End      string `json:"end,omitempty"`
	Limit    int    `json:"limit"`
	Cursor   string `json:"cursor,omitempty"`
}

type AccountActivityRow struct {
	ID      int64  `json:"id"`
	Date    string `json:"date"`
	Change  string `json:"change"`
	Balance string `json:"balance"`
	// Complete canonical directive: includes File/Line, Payee/Narration when
	// present. Never substituted with a lossy summary. ID locates detail pages.
	Record json.RawMessage `json:"record"`
}

type AccountActivityPage struct {
	Revision   string               `json:"revision"`
	Basis      string               `json:"basis"`
	Account    string               `json:"account"`
	Currency   string               `json:"currency"`
	Start      string               `json:"start,omitempty"`
	End        string               `json:"end,omitempty"`
	Rows       []AccountActivityRow `json:"rows"`
	NextCursor string               `json:"next_cursor,omitempty"`
}

// Currency has the same bounded UTF-8, nonblank, no-padding/control rules as
// account. No currency catalog lookup/guessing: missing pairs return zeros/[]
// (including posted-only accounts), consistently with AccountBalances.
const MaxCurrencyFilterBytes = MaxAccountFilterBytes

func validSummaryRequest(r AccountSummaryRequest) bool {
	return validBalancesRequest(AccountBalancesRequest{Account: r.Account, Start: r.Start, End: r.End}) &&
		validBalancesRequest(AccountBalancesRequest{Account: r.Currency})
}
func activityFilter(r AccountSummaryRequest) string {
	raw, _ := json.Marshal([4]string{r.Account, r.Currency, r.Start, r.End})
	h := sha256.Sum256(raw)
	return hex.EncodeToString(h[:])
}

type activityCursor struct {
	Operation string `json:"operation"`
	Revision  string `json:"revision"`
	Filter    string `json:"filter"` // SHA-256 of exact account, currency, start, end
	Date      string `json:"date"`
	ID        int64  `json:"id"`
}

func encodeActivityCursor(c activityCursor) string {
	b, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(b)
}
func decodeActivityCursor(raw, revision string, r AccountSummaryRequest) (activityCursor, error) {
	var c activityCursor
	if len(raw) > maxCursorBytes {
		return c, ErrInvalidCursor
	}
	b, e := base64.RawURLEncoding.Strict().DecodeString(raw)
	if e != nil || json.Unmarshal(b, &c) != nil || encodeActivityCursor(c) != raw || c.Operation != "account_activity" || c.Filter != activityFilter(r) || c.ID <= 0 || !validDate(c.Date) || len(c.Revision) != 64 || (r.Start != "" && (c.Date < r.Start || c.Date >= r.End)) {
		return activityCursor{}, ErrInvalidCursor
	}
	if _, e = hex.DecodeString(c.Revision); e != nil || strings.ToLower(c.Revision) != c.Revision {
		return activityCursor{}, ErrInvalidCursor
	}
	if c.Revision != revision {
		return activityCursor{}, ErrRevisionMismatch
	}
	return c, nil
}

// Schema 2 orders by date,seq, not date,entry_id. Verified streams require
// strictly increasing directive IDs and contiguous postings per directive;
// therefore this indexed order is exactly ASC(date,entry_id,posting ordinal).
// Do NOT ORDER BY entry_id: SQLite would introduce an unbounded temporary sort.
const activityPostingsQuery = "SELECT entry_id, date, quantity FROM postings INDEXED BY postings_account_currency_date WHERE account=? AND currency=? AND date<? ORDER BY date, seq"

// CROSS JOIN pins postings as the driving ordered scan; primary-key lookups
// cannot introduce a sort. Only one native Rows may be live on this adapter.
const activityRowsQuery = "SELECT p.entry_id, p.date, p.quantity, r.raw FROM postings AS p INDEXED BY postings_account_currency_date CROSS JOIN transactions AS t ON t.id=p.entry_id CROSS JOIN records AS r ON r.seq=t.seq WHERE p.account=? AND p.currency=? AND p.date<? ORDER BY p.date, p.seq"

func addNominal(sum *ledger.ExactDecimal, quantity string) error {
	if e := sum.Add(quantity); e != nil {
		if errors.Is(e, ledger.ErrDecimalLimit) {
			return ErrResourceLimit
		}
		return ErrCorrupt
	}
	return nil
}

// AccountSummary scans all matching postings with four bounded exact decimal
// accumulators. Current includes ALL dates, not just the selected interval.
// Absent range: opening=0, closing=current, change=current. With a range:
// opening sums dates<start, closing dates<end, change sums [start,end).
func (i *Index) AccountSummary(ctx context.Context, r AccountSummaryRequest) (AccountSummary, error) {
	if ctx == nil || !validSummaryRequest(r) {
		return AccountSummary{}, ErrInvalidRequest
	}
	if e := ctx.Err(); e != nil {
		return AccountSummary{}, e
	}
	if i == nil {
		return AccountSummary{}, ErrUnavailable
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if e := ctx.Err(); e != nil {
		return AccountSummary{}, e
	}
	if i.db == nil {
		return AccountSummary{}, ErrUnavailable
	}
	join := cancelSQLite(ctx, i.db)
	defer join()
	rows, e := i.db.Query(activityPostingsQuery, r.Account, r.Currency, "9999-12-32")
	if e != nil {
		return AccountSummary{}, dbError(ctx, e, ErrCorrupt)
	}
	defer rows.Close()
	var current, opening, closing, change ledger.ExactDecimal
	for rows.Next() {
		if e = ctx.Err(); e != nil {
			return AccountSummary{}, e
		}
		date, q := rows.Text(1), rows.Text(2)
		if e = addNominal(&current, q); e != nil {
			return AccountSummary{}, e
		}
		if r.Start != "" && date < r.Start {
			if e = addNominal(&opening, q); e != nil {
				return AccountSummary{}, e
			}
		}
		if r.End == "" || date < r.End {
			if e = addNominal(&closing, q); e != nil {
				return AccountSummary{}, e
			}
		}
		if (r.Start == "" || date >= r.Start) && (r.End == "" || date < r.End) {
			if e = addNominal(&change, q); e != nil {
				return AccountSummary{}, e
			}
		}
	}
	if e = rows.Close(); e != nil {
		return AccountSummary{}, dbError(ctx, e, ErrCorrupt)
	}
	if e = ctx.Err(); e != nil {
		return AccountSummary{}, e
	}
	return AccountSummary{Revision: i.manifest.Revision, Basis: "native_nominal", Account: r.Account, Currency: r.Currency, Start: r.Start, End: r.End, CurrentBalance: current.String(), OpeningBalance: opening.String(), ClosingBalance: closing.String(), PeriodChange: change.String()}, nil
}

// nominalGroups retains one SQLite row and one bounded transaction sum, never
// a posting array/map. A transaction may have arbitrarily many matching postings.
type nominalGroups struct {
	ctx     context.Context
	rows    *sqlite.Rows
	present bool
	// delta is the exact value for the last returned row. Its normalized wire
	// spelling can exceed the raw input digit budget (a leading zero is added).
	delta ledger.ExactDecimal
}

func (g *nominalGroups) next() (AccountActivityRow, bool, error) {
	if e := g.ctx.Err(); e != nil {
		return AccountActivityRow{}, false, e
	}
	if !g.present {
		return AccountActivityRow{}, false, dbError(g.ctx, g.rows.Err(), ErrCorrupt)
	}
	item := AccountActivityRow{ID: g.rows.Int64(0), Date: g.rows.Text(1), Record: json.RawMessage(g.rows.Text(3))}
	g.delta = ledger.ExactDecimal{}
	for g.present && g.rows.Int64(0) == item.ID && g.rows.Text(1) == item.Date {
		if e := g.ctx.Err(); e != nil {
			return AccountActivityRow{}, false, e
		}
		if e := addNominal(&g.delta, g.rows.Text(2)); e != nil {
			return AccountActivityRow{}, false, e
		}
		g.present = g.rows.Next()
	}
	if e := g.rows.Err(); e != nil {
		return AccountActivityRow{}, false, dbError(g.ctx, e, ErrCorrupt)
	}
	item.Change = g.delta.String()
	return item, true, nil
}

// AccountActivity returns ASC(date,entry_id) transaction-level keyset pages.
// Repeated matching postings are summed; matched zero-delta transactions remain
// visible, like AccountDetailFromSortedInCurrency. Amounts are native_nominal,
// NOT the legacy cents/valuation projection. Running balances include all prior
// rows, including before the range/page. Cursors never supply trusted balances:
// every request recomputes the prefix and validates the actual cursor boundary.
// Latency is O(matching prefix + page postings + one posting lookahead),
// potentially O(N) per page, with constant accumulator memory and a capped page.
// Neither GROUP BY nor a worktable/sort nor an accounting snapshot is used.
func (i *Index) AccountActivity(ctx context.Context, request AccountActivityRequest) (AccountActivityPage, error) {
	r := AccountSummaryRequest{Account: request.Account, Currency: request.Currency, Start: request.Start, End: request.End}
	if ctx == nil || !validSummaryRequest(r) {
		return AccountActivityPage{}, ErrInvalidRequest
	}
	limit, e := pageLimit(request.Limit)
	if e != nil {
		return AccountActivityPage{}, e
	}
	if e = ctx.Err(); e != nil {
		return AccountActivityPage{}, e
	}
	if i == nil {
		return AccountActivityPage{}, ErrUnavailable
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if e = ctx.Err(); e != nil {
		return AccountActivityPage{}, e
	}
	if i.db == nil {
		return AccountActivityPage{}, ErrUnavailable
	}
	join := cancelSQLite(ctx, i.db)
	defer join()
	var boundary activityCursor
	if request.Cursor != "" {
		boundary, e = decodeActivityCursor(request.Cursor, i.manifest.Revision, r)
		if e != nil {
			return AccountActivityPage{}, e
		}
	}
	end := r.End
	if end == "" {
		end = "9999-12-32"
	}
	rows, e := i.db.Query(activityRowsQuery, r.Account, r.Currency, end)
	if e != nil {
		return AccountActivityPage{}, dbError(ctx, e, ErrCorrupt)
	}
	defer rows.Close()
	groups := nominalGroups{ctx: ctx, rows: rows, present: rows.Next()}
	page := AccountActivityPage{Revision: i.manifest.Revision, Basis: "native_nominal", Account: r.Account, Currency: r.Currency, Start: r.Start, End: r.End, Rows: []AccountActivityRow{}}
	var running ledger.ExactDecimal
	found := request.Cursor == ""
	itemBytes, retained := 0, 0
	item, present, e := groups.next()
	for present && e == nil {
		if e = running.AddDecimal(&groups.delta); e != nil {
			// Both operands are validated decimals; only arithmetic limits remain.
			return AccountActivityPage{}, ErrResourceLimit
		}
		if !found {
			if item.Date == boundary.Date && item.ID == boundary.ID {
				found = true
			} else if item.Date > boundary.Date || item.Date == boundary.Date && item.ID > boundary.ID {
				return AccountActivityPage{}, ErrInvalidCursor
			}
			item, present, e = groups.next()
			continue
		}
		if r.Start != "" && item.Date < r.Start {
			item, present, e = groups.next()
			continue
		}
		item.Balance = running.String()
		raw, err := json.Marshal(item)
		if err != nil {
			return AccountActivityPage{}, ErrCorrupt
		}
		// Grouping already advanced to one posting of the next transaction.
		// Its existence is sufficient for a cursor; do not accumulate a group
		// outside this page (which may itself exceed the arithmetic budget).
		cursor := ""
		if groups.present {
			cursor = encodeActivityCursor(activityCursor{Operation: "account_activity", Revision: page.Revision, Filter: activityFilter(r), Date: item.Date, ID: item.ID})
		}
		shell := page
		shell.Rows = []AccountActivityRow{}
		shell.NextCursor = cursor
		encoded, _ := json.Marshal(shell)
		if len(encoded)+itemBytes+len(raw)+len(page.Rows) > MaxResponseBytes || retained+len(item.Record) > MaxResponseBytes {
			if len(page.Rows) == 0 {
				return AccountActivityPage{}, ErrResourceLimit
			}
			break // previous row reserved its cursor; no partial directive
		}
		page.Rows = append(page.Rows, item)
		page.NextCursor = cursor
		itemBytes += len(raw)
		retained += len(item.Record)
		if len(page.Rows) == limit {
			break
		}
		item, present, e = groups.next()
	}
	if e != nil {
		return AccountActivityPage{}, e
	}
	if !found {
		return AccountActivityPage{}, ErrInvalidCursor
	}
	if e = rows.Close(); e != nil {
		return AccountActivityPage{}, dbError(ctx, e, ErrCorrupt)
	}
	encoded, e := json.Marshal(page)
	if e != nil {
		return AccountActivityPage{}, ErrCorrupt
	}
	if len(encoded) > MaxResponseBytes {
		return AccountActivityPage{}, ErrResourceLimit
	}
	if e = ctx.Err(); e != nil {
		return AccountActivityPage{}, e
	}
	return page, nil
}
