package readindex

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/borui/beancount-ledger-web/server/internal/ledger"
)

const MaxAccountFilterBytes = 1024

// Account is one explicitly opened account, ordered by binary account name.
// The first source open is authoritative even for synthetic duplicate opens.
// Closed accounts remain visible; posted-only/close-only accounts are NOT
// synthesized. OpenID locates scalar metadata via DetailRecords (posting=-1).
// OpenRecord retains currencies/booking verbatim. CloseDate is the latest
// explicit close, not an as-of active-status judgment.
type Account struct {
	Account    string          `json:"account"`
	OpenID     int64           `json:"open_id"`
	OpenDate   string          `json:"open_date"`
	CloseDate  string          `json:"close_date,omitempty"`
	OpenRecord json.RawMessage `json:"open_record"`
}
type AccountsPage struct {
	Revision   string    `json:"revision"`
	Accounts   []Account `json:"accounts"`
	NextCursor string    `json:"next_cursor,omitempty"`
}

// AccountBalancesRequest selects native nominal posting units for exactly one
// account. Start/End must both be absent or strict YYYY-MM-DD with start<end.
// The interval is [start,end). No lots, prices, costs, conversion, opening or
// running balances, or report valuation parity is implied.
type AccountBalancesRequest struct {
	Account string `json:"account"`
	Start   string `json:"start,omitempty"`
	End     string `json:"end,omitempty"`
	Limit   int    `json:"limit"`
	Cursor  string `json:"cursor,omitempty"`
}
type NativeBalance struct {
	Currency string `json:"currency"`
	Quantity string `json:"quantity"` // exact sum, normalized plain decimal
}
type AccountBalancesPage struct {
	Revision   string          `json:"revision"`
	Basis      string          `json:"basis"` // always native_nominal
	Account    string          `json:"account"`
	Start      string          `json:"start,omitempty"`
	End        string          `json:"end,omitempty"`
	Balances   []NativeBalance `json:"balances"`
	NextCursor string          `json:"next_cursor,omitempty"`
}

type accountCursor struct {
	Operation string `json:"operation"`
	Revision  string `json:"revision"`
	Filter    string `json:"filter"`
	Seq       int64  `json:"seq"`
}

func encodeAccountCursor(c accountCursor) string {
	b, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(b)
}
func decodeAccountCursor(raw, operation, revision, filter string) (accountCursor, error) {
	var c accountCursor
	if len(raw) > maxCursorBytes {
		return c, ErrInvalidCursor
	}
	b, err := base64.RawURLEncoding.Strict().DecodeString(raw)
	if err != nil || json.Unmarshal(b, &c) != nil || encodeAccountCursor(c) != raw || c.Operation != operation || c.Filter != filter || c.Seq <= 0 || len(c.Revision) != 64 {
		return accountCursor{}, ErrInvalidCursor
	}
	if _, err = hex.DecodeString(c.Revision); err != nil || strings.ToLower(c.Revision) != c.Revision {
		return accountCursor{}, ErrInvalidCursor
	}
	if c.Revision != revision {
		return accountCursor{}, ErrRevisionMismatch
	}
	return c, nil
}
func balancesFilter(r AccountBalancesRequest) string {
	raw, _ := json.Marshal([3]string{r.Account, r.Start, r.End})
	h := sha256.Sum256(raw)
	return hex.EncodeToString(h[:])
}
func pageLimit(n int) (int, error) {
	if n == 0 {
		n = DefaultPageSize
	}
	if n < 1 || n > MaxPageSize {
		return 0, ErrInvalidRequest
	}
	return n, nil
}
func validDate(s string) bool {
	if len(s) != 10 {
		return false
	}
	t, e := time.Parse("2006-01-02", s)
	return e == nil && t.Year() >= 1 && t.Format("2006-01-02") == s
}
func validBalancesRequest(r AccountBalancesRequest) bool {
	if len(r.Account) == 0 || len(r.Account) > MaxAccountFilterBytes || !utf8.ValidString(r.Account) || strings.TrimSpace(r.Account) != r.Account {
		return false
	}
	for _, c := range r.Account {
		if unicode.IsControl(c) {
			return false
		}
	}
	return r.Start == "" && r.End == "" || validDate(r.Start) && validDate(r.End) && r.Start < r.End
}

// NOT EXISTS selects one open per account without GROUP BY, a seen-account map,
// or a temp sort. All supporting indexes are created before stream ingestion.
const firstOpen = "NOT EXISTS (SELECT 1 FROM account_events AS earlier INDEXED BY account_events_catalog WHERE earlier.kind='open' AND earlier.account=a.account AND earlier.entry_id<a.entry_id)"
const accountsSelect = "SELECT a.seq, a.entry_id, a.account, a.date, r.raw, (SELECT c.date FROM account_events AS c INDEXED BY account_events_latest WHERE c.account=a.account AND c.kind='close' ORDER BY c.date DESC, c.entry_id DESC LIMIT 1) FROM account_events AS a INDEXED BY account_events_catalog JOIN records AS r ON r.seq=a.seq WHERE a.kind='open' AND "
const accountsQuery = accountsSelect + "a.account>? AND " + firstOpen + " ORDER BY a.account, a.entry_id LIMIT ?"

// Include empty account strings allowed by the canonical directive verifier.
const accountsFirstQuery = accountsSelect + firstOpen + " ORDER BY a.account, a.entry_id LIMIT ?"

func (i *Index) Accounts(ctx context.Context, request PageRequest) (AccountsPage, error) {
	if ctx == nil {
		return AccountsPage{}, ErrInvalidRequest
	}
	limit, err := pageLimit(request.Limit)
	if err != nil {
		return AccountsPage{}, err
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if err = ctx.Err(); err != nil {
		return AccountsPage{}, err
	}
	if i.db == nil {
		return AccountsPage{}, ErrUnavailable
	}
	join := cancelSQLite(ctx, i.db)
	defer join()
	query, args := accountsFirstQuery, []any{limit + 1}
	if request.Cursor != "" {
		c, e := decodeAccountCursor(request.Cursor, "accounts", i.manifest.Revision, "")
		if e != nil {
			return AccountsPage{}, e
		}
		row, e := i.db.Query("SELECT a.account FROM account_events AS a WHERE a.seq=? AND a.kind='open' AND "+firstOpen, c.Seq)
		if e != nil {
			return AccountsPage{}, dbError(ctx, e, ErrCorrupt)
		}
		valid := row.Next()
		last := ""
		if valid {
			last = row.Text(0)
		}
		e = row.Close()
		if e != nil {
			return AccountsPage{}, dbError(ctx, e, ErrCorrupt)
		}
		if !valid {
			return AccountsPage{}, ErrInvalidCursor
		}
		query, args = accountsQuery, []any{last, limit + 1}
	}
	rows, err := i.db.Query(query, args...)
	if err != nil {
		return AccountsPage{}, dbError(ctx, err, ErrCorrupt)
	}
	defer rows.Close()
	page := AccountsPage{Revision: i.manifest.Revision, Accounts: []Account{}}
	itemBytes, retainedBytes := 0, 0
	present := rows.Next()
	for present && len(page.Accounts) < limit {
		if err = ctx.Err(); err != nil {
			return AccountsPage{}, err
		}
		seq := rows.Int64(0)
		item := Account{OpenID: rows.Int64(1), Account: rows.Text(2), OpenDate: rows.Text(3), OpenRecord: json.RawMessage(rows.Text(4))}
		if !rows.IsNull(5) {
			item.CloseDate = rows.Text(5)
		}
		raw, e := json.Marshal(item)
		if e != nil {
			return AccountsPage{}, ErrCorrupt
		}
		present = rows.Next()
		if e = rows.Err(); e != nil {
			return AccountsPage{}, dbError(ctx, e, ErrCorrupt)
		}
		cursor := ""
		if present {
			cursor = encodeAccountCursor(accountCursor{"accounts", page.Revision, "", seq})
		}
		shell, _ := json.Marshal(AccountsPage{Revision: page.Revision, Accounts: []Account{}, NextCursor: cursor})
		if len(shell)+itemBytes+len(raw)+len(page.Accounts) > MaxResponseBytes || retainedBytes+len(item.OpenRecord) > MaxResponseBytes {
			if len(page.Accounts) == 0 {
				return AccountsPage{}, ErrResourceLimit
			}
			break
		}
		page.Accounts = append(page.Accounts, item)
		itemBytes += len(raw)
		retainedBytes += len(item.OpenRecord)
		page.NextCursor = cursor
	}
	if err = rows.Close(); err != nil {
		return AccountsPage{}, dbError(ctx, err, ErrCorrupt)
	}
	if err = ctx.Err(); err != nil {
		return AccountsPage{}, err
	}
	return page, nil
}

const balancesQuery = "SELECT seq, currency, quantity FROM postings INDEXED BY postings_account_currency_date WHERE account=? AND currency>? AND date>=? AND date<? ORDER BY currency, date, seq"

// AccountBalances also works for posted-but-not-open accounts. Unknown accounts
// and empty ranges return an empty page. Zero sums are retained for currencies
// posted in the interval. Memory is one exact accumulator, one row of lookahead,
// and the capped response; work may scan many postings.
func (i *Index) AccountBalances(ctx context.Context, request AccountBalancesRequest) (AccountBalancesPage, error) {
	if ctx == nil || !validBalancesRequest(request) {
		return AccountBalancesPage{}, ErrInvalidRequest
	}
	limit, err := pageLimit(request.Limit)
	if err != nil {
		return AccountBalancesPage{}, err
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if err = ctx.Err(); err != nil {
		return AccountBalancesPage{}, err
	}
	if i.db == nil {
		return AccountBalancesPage{}, ErrUnavailable
	}
	join := cancelSQLite(ctx, i.db)
	defer join()
	filter := balancesFilter(request)
	last := ""
	start, end := request.Start, request.End
	if start == "" {
		start, end = "0001-01-01", "9999-12-32"
	}
	if request.Cursor != "" {
		c, e := decodeAccountCursor(request.Cursor, "account_balances", i.manifest.Revision, filter)
		if e != nil {
			return AccountBalancesPage{}, e
		}
		row, e := i.db.Query("SELECT currency FROM postings WHERE seq=? AND account=? AND date>=? AND date<?", c.Seq, request.Account, start, end)
		if e != nil {
			return AccountBalancesPage{}, dbError(ctx, e, ErrCorrupt)
		}
		valid := row.Next()
		if valid {
			last = row.Text(0)
		}
		e = row.Close()
		if e != nil {
			return AccountBalancesPage{}, dbError(ctx, e, ErrCorrupt)
		}
		if !valid {
			return AccountBalancesPage{}, ErrInvalidCursor
		}
	}
	rows, err := i.db.Query(balancesQuery, request.Account, last, start, end)
	if err != nil {
		return AccountBalancesPage{}, dbError(ctx, err, ErrCorrupt)
	}
	defer rows.Close()
	page := AccountBalancesPage{Revision: i.manifest.Revision, Basis: "native_nominal", Account: request.Account, Start: request.Start, End: request.End, Balances: []NativeBalance{}}
	itemBytes := 0
	present := rows.Next()
	for present && len(page.Balances) < limit {
		currency := rows.Text(1)
		var sum ledger.ExactDecimal
		var seq int64
		for present && rows.Text(1) == currency {
			if err = ctx.Err(); err != nil {
				return AccountBalancesPage{}, err
			}
			seq = rows.Int64(0)
			if err = sum.Add(rows.Text(2)); err != nil {
				if errors.Is(err, ledger.ErrDecimalLimit) {
					return AccountBalancesPage{}, ErrResourceLimit
				}
				return AccountBalancesPage{}, ErrCorrupt
			}
			present = rows.Next()
		}
		if err = rows.Err(); err != nil {
			return AccountBalancesPage{}, dbError(ctx, err, ErrCorrupt)
		}
		item := NativeBalance{Currency: currency, Quantity: sum.String()}
		raw, _ := json.Marshal(item)
		cursor := ""
		if present {
			cursor = encodeAccountCursor(accountCursor{"account_balances", page.Revision, filter, seq})
		}
		shell := page
		shell.Balances = []NativeBalance{}
		shell.NextCursor = cursor
		encoded, _ := json.Marshal(shell)
		if len(encoded)+itemBytes+len(raw)+len(page.Balances) > MaxResponseBytes {
			if len(page.Balances) == 0 {
				return AccountBalancesPage{}, ErrResourceLimit
			}
			break
		}
		page.Balances = append(page.Balances, item)
		itemBytes += len(raw)
		page.NextCursor = cursor
	}
	if err = rows.Close(); err != nil {
		return AccountBalancesPage{}, dbError(ctx, err, ErrCorrupt)
	}
	if err = ctx.Err(); err != nil {
		return AccountBalancesPage{}, err
	}
	return page, nil
}
