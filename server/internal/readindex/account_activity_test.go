package readindex

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"math/rand"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/borui/beancount-ledger-web/server/internal/ledger"
)

func activityFixture() string {
	return makeStream(testHeader,
		transaction(1, "2026-02-01", "same date first"), posting(1, 0, "Assets:Cash", "-2", "USD"), posting(1, 1, "Assets:Cash", "-.25", "USD"),
		transaction(2, "2025-01-01", "prefix"), posting(2, 0, "Assets:Cash", "10.000000000000000000000001", "USD"),
		transaction(3, "2026-02-01", "zero matched"), posting(3, 0, "Assets:Cash", "3", "USD"), posting(3, 1, "Assets:Cash", "-3", "USD"),
		transaction(4, "2026-02-01", "same date last"), posting(4, 0, "Assets:Cash", ".250000000000000000000009", "USD"), posting(4, 1, "Assets:Cash", "999", "EUR"), posting(4, 2, "Assets:Other", "999", "USD"),
		transaction(5, "2026-03-01", "exclusive end"), posting(5, 0, "Assets:Cash", "-1", "USD"),
		transaction(6, "9999-12-31", "all dates"), posting(6, 0, "Assets:Cash", "-20", "USD"))
}
func TestAccountSummaryAndActivityExact(t *testing.T) {
	path, m := buildText(t, activityFixture())
	i := openIndex(t, path, m)
	ctx := context.Background()
	r := AccountSummaryRequest{Account: "Assets:Cash", Currency: "USD", Start: "2026-02-01", End: "2026-03-01"}
	s, e := i.AccountSummary(ctx, r)
	want := AccountSummary{Revision: m.Revision, Basis: "native_nominal", Account: r.Account, Currency: r.Currency, Start: r.Start, End: r.End, CurrentBalance: "-12.99999999999999999999999", OpeningBalance: "10.000000000000000000000001", ClosingBalance: "8.00000000000000000000001", PeriodChange: "-1.999999999999999999999991"}
	if e != nil || s != want {
		t.Fatalf("%+v %v", s, e)
	}
	req := AccountActivityRequest{Account: r.Account, Currency: r.Currency, Start: r.Start, End: r.End, Limit: 1}
	balances := []string{"7.750000000000000000000001", "7.750000000000000000000001", "8.00000000000000000000001"}
	changes := []string{"-2.25", "0", "0.250000000000000000000009"}
	for n, id := range []int64{1, 3, 4} {
		p, e := i.AccountActivity(ctx, req)
		if e != nil || len(p.Rows) != 1 {
			t.Fatalf("%+v %v", p, e)
		}
		row := p.Rows[0]
		if row.ID != id || row.Balance != balances[n] || row.Change != changes[n] || !strings.Contains(string(row.Record), `"File":"main.bean"`) {
			t.Fatalf("%+v", row)
		}
		if p.Revision != m.Revision || p.Basis != "native_nominal" || p.Account != r.Account || p.Currency != r.Currency || p.Start != r.Start || p.End != r.End {
			t.Fatalf("%+v", p)
		}
		if (p.NextCursor == "") != (n == 2) {
			t.Fatal("cursor", p.NextCursor)
		}
		req.Cursor = p.NextCursor
	}
	for _, tc := range []struct{ start, end, opening, closing, change string }{
		{"", "", "0", want.CurrentBalance, want.CurrentBalance},
		{"2025-02-01", "2025-03-01", want.OpeningBalance, want.OpeningBalance, "0"},
		{"0001-01-01", "2025-01-01", "0", "0", "0"},
	} {
		r.Start, r.End = tc.start, tc.end
		s, e = i.AccountSummary(ctx, r)
		if e != nil || s.OpeningBalance != tc.opening || s.ClosingBalance != tc.closing || s.PeriodChange != tc.change || s.CurrentBalance != want.CurrentBalance {
			t.Fatalf("%+v %v", s, e)
		}
	}
	for _, r := range []AccountSummaryRequest{{Account: "Unknown", Currency: "USD"}, {Account: "Assets:Cash", Currency: "UNKNOWN"}} {
		s, e := i.AccountSummary(ctx, r)
		p, pe := i.AccountActivity(ctx, AccountActivityRequest{Account: r.Account, Currency: r.Currency})
		if e != nil || pe != nil || s.CurrentBalance != "0" || s.OpeningBalance != "0" || s.ClosingBalance != "0" || s.PeriodChange != "0" || len(p.Rows) != 0 || p.Rows == nil || p.NextCursor != "" {
			t.Fatalf("%+v %+v %v %v", s, p, e, pe)
		}
	}
}

func TestAccountActivityValidationAndCursors(t *testing.T) {
	path, m := buildText(t, activityFixture())
	i := openIndex(t, path, m)
	ctx := context.Background()
	base := AccountActivityRequest{Account: "Assets:Cash", Currency: "USD", Limit: 1}
	p, e := i.AccountActivity(ctx, base)
	if e != nil {
		t.Fatal(e)
	}
	cursor, e := decodeActivityCursor(p.NextCursor, m.Revision, AccountSummaryRequest{Account: base.Account, Currency: base.Currency})
	if e != nil {
		t.Fatal(e)
	}
	for _, v := range []string{"", " USD", "USD ", "a\nb", string([]byte{0xff}), strings.Repeat("中", 342)} {
		for _, field := range []string{"account", "currency"} {
			r := base
			if field == "account" {
				r.Account = v
			} else {
				r.Currency = v
			}
			_, e = i.AccountActivity(ctx, r)
			wantError(t, e, ErrInvalidRequest)
			_, e = i.AccountSummary(ctx, AccountSummaryRequest{Account: r.Account, Currency: r.Currency})
			wantError(t, e, ErrInvalidRequest)
		}
	}
	for _, pair := range [][2]string{{"2026-01-01", ""}, {"", "2027-01-01"}, {"0000-01-01", "2027-01-01"}, {"2026-02-30", "2027-01-01"}, {"2026-2-01", "2027-01-01"}, {"2027-01-01", "2027-01-01"}, {"2028-01-01", "2027-01-01"}} {
		r := base
		r.Start, r.End = pair[0], pair[1]
		_, e = i.AccountActivity(ctx, r)
		wantError(t, e, ErrInvalidRequest)
		_, e = i.AccountSummary(ctx, AccountSummaryRequest{Account: r.Account, Currency: r.Currency, Start: r.Start, End: r.End})
		wantError(t, e, ErrInvalidRequest)
	}
	for _, n := range []int{-1, 501} {
		r := base
		r.Limit = n
		_, e = i.AccountActivity(ctx, r)
		wantError(t, e, ErrInvalidRequest)
	}
	for _, edit := range []func(*activityCursor){func(c *activityCursor) { c.Operation = "accounts" }, func(c *activityCursor) { c.Filter = "" }, func(c *activityCursor) { c.ID = 99 }, func(c *activityCursor) { c.ID = 1 }, func(c *activityCursor) { c.Date = "2025-02-01" }, func(c *activityCursor) { c.Revision = strings.Repeat("z", 64) }, func(c *activityCursor) { c.ID = 0 }} {
		c := cursor
		edit(&c)
		r := base
		r.Cursor = encodeActivityCursor(c)
		_, e = i.AccountActivity(ctx, r)
		wantError(t, e, ErrInvalidCursor)
	}
	c := cursor
	c.Revision = strings.Repeat("b", 64)
	r := base
	r.Cursor = encodeActivityCursor(c)
	_, e = i.AccountActivity(ctx, r)
	wantError(t, e, ErrRevisionMismatch)
	for _, edit := range []func(*AccountActivityRequest){func(r *AccountActivityRequest) { r.Account = "Assets:Other" }, func(r *AccountActivityRequest) { r.Currency = "EUR" }, func(r *AccountActivityRequest) { r.Start = "2026-01-01"; r.End = "2027-01-01" }} {
		r := base
		r.Cursor = p.NextCursor
		edit(&r)
		_, e = i.AccountActivity(ctx, r)
		wantError(t, e, ErrInvalidCursor)
	}
	b, _ := json.Marshal(cursor)
	for _, raw := range []string{p.NextCursor + "=", strings.Repeat("a", 513), encodeAccountCursor(accountCursor{Operation: "accounts", Revision: m.Revision, Seq: 1}), base64.RawURLEncoding.EncodeToString(append(b, byte(' '))), base64.RawURLEncoding.EncodeToString([]byte(strings.TrimSuffix(string(b), "}") + `,"balance":"999"}`)), base64.RawURLEncoding.EncodeToString([]byte(strings.TrimSuffix(string(b), "}") + `,"id":2}`))} {
		r := base
		r.Cursor = raw
		_, e = i.AccountActivity(ctx, r)
		wantError(t, e, ErrInvalidCursor)
	}
	// A real boundary matching the pair is accepted even if not previously emitted;
	// tokens are opaque selectors, not authentication. Prefix is always recomputed.
	c = cursor
	c.ID = 3
	c.Date = "2026-02-01"
	r = base
	r.Cursor = encodeActivityCursor(c)
	p, e = i.AccountActivity(ctx, r)
	if e != nil || len(p.Rows) != 1 || p.Rows[0].ID != 4 || p.Rows[0].Balance != "8.00000000000000000000001" {
		t.Fatalf("%+v %v", p, e)
	}
	_, e = i.AccountActivity(nil, base)
	wantError(t, e, ErrInvalidRequest)
	_, e = i.AccountSummary(nil, AccountSummaryRequest{Account: base.Account, Currency: base.Currency})
	wantError(t, e, ErrInvalidRequest)
	i.Close()
	_, e = i.AccountActivity(ctx, base)
	wantError(t, e, ErrUnavailable)
	_, e = i.AccountSummary(ctx, AccountSummaryRequest{Account: base.Account, Currency: base.Currency})
	wantError(t, e, ErrUnavailable)
}

func TestAccountActivityManyPostingsAndLimits(t *testing.T) {
	records := []string{testHeader}
	for id := 1; id <= 503; id++ {
		records = append(records, transaction(id, "2026-01-01", ""))
		n := 1
		if id == 1 {
			n = 2000
		}
		for j := 0; j < n; j++ {
			records = append(records, posting(id, j, "Assets:Cash", ".000000000000000000000001", "USD"))
		}
	}
	path, m := buildText(t, makeStream(records...))
	i := openIndex(t, path, m)
	ctx := context.Background()
	for _, limit := range []int{0, 1, 100, 500} {
		r := AccountActivityRequest{Account: "Assets:Cash", Currency: "USD", Limit: limit}
		count := 0
		for {
			p, e := i.AccountActivity(ctx, r)
			if e != nil {
				t.Fatal(e)
			}
			n := limit
			if n == 0 {
				n = 100
			}
			if len(p.Rows) != min(n, 503-count) {
				t.Fatal("limit", len(p.Rows))
			}
			for _, row := range p.Rows {
				count++
				if row.ID != int64(count) {
					t.Fatal("order", row.ID, count)
				}
			}
			if p.NextCursor == "" {
				break
			}
			r.Cursor = p.NextCursor
		}
		if count != 503 {
			t.Fatal(count)
		}
	}
	s, e := i.AccountSummary(ctx, AccountSummaryRequest{Account: "Assets:Cash", Currency: "USD"})
	if e != nil || s.CurrentBalance != "0.000000000000000000002502" {
		t.Fatalf("%+v %v", s, e)
	}
	for _, quantity := range []string{"1E999999999", strings.Repeat("9", 4096) + "0"} {
		path, m = buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", ""), posting(1, 0, "Assets:Cash", quantity, "USD")))
		i = openIndex(t, path, m)
		p, e := i.AccountActivity(ctx, AccountActivityRequest{Account: "Assets:Cash", Currency: "USD"})
		wantError(t, e, ErrResourceLimit)
		if !reflect.DeepEqual(p, AccountActivityPage{}) {
			t.Fatal("partial")
		}
		s, e := i.AccountSummary(ctx, AccountSummaryRequest{Account: "Assets:Cash", Currency: "USD"})
		wantError(t, e, ErrResourceLimit)
		if s != (AccountSummary{}) {
			t.Fatal("partial")
		}
	}
}

func TestAccountActivityByteCaps(t *testing.T) {
	for _, tc := range []struct {
		name, text  string
		count, want int
		pad         bool
	}{
		{"wire", strings.Repeat("x", 270000), 5, 3, false},
		{"escaping", strings.Repeat("<", 100000), 3, 1, false},
		{"retained", "x", 3, 1, true},
		{"oversize", strings.Repeat("<", 180000), 1, 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			records := []string{testHeader}
			for id := 1; id <= tc.count; id++ {
				raw := strings.ReplaceAll(transaction(id, "2026-01-01", tc.text), `\u003c`, "<")
				if tc.pad {
					raw = strings.TrimSuffix(raw, "}") + strings.Repeat(" ", 600000) + "}"
				}
				records = append(records, raw, posting(id, 0, "Assets:Cash", "1", "USD"))
			}
			path, m := buildText(t, makeStream(records...))
			i := openIndex(t, path, m)
			r := AccountActivityRequest{Account: "Assets:Cash", Currency: "USD"}
			p, e := i.AccountActivity(context.Background(), r)
			if tc.want == 0 {
				wantError(t, e, ErrResourceLimit)
				if !reflect.DeepEqual(p, AccountActivityPage{}) {
					t.Fatal("partial")
				}
				return
			}
			if e != nil || len(p.Rows) != tc.want || p.NextCursor == "" {
				t.Fatalf("count %d cursor %t %v", len(p.Rows), p.NextCursor != "", e)
			}
			count := 0
			for {
				for _, row := range p.Rows {
					count++
					if row.ID != int64(count) || string(row.Record) != records[1+(count-1)*2] || row.Balance != fmt.Sprint(count) {
						t.Fatal("raw/balance changed")
					}
				}
				raw, _ := json.Marshal(p)
				if len(raw) > MaxResponseBytes {
					t.Fatal("cap")
				}
				if p.NextCursor == "" {
					break
				}
				r.Cursor = p.NextCursor
				p, e = i.AccountActivity(context.Background(), r)
				if e != nil {
					t.Fatal(e)
				}
			}
			if count != tc.count {
				t.Fatal(count)
			}
		})
	}
}

func TestAccountActivityQueryPlans(t *testing.T) {
	path, m := buildText(t, activityFixture())
	i := openIndex(t, path, m)
	for _, q := range []string{activityPostingsQuery, activityRowsQuery} {
		rows, e := i.db.Query("EXPLAIN QUERY PLAN "+q, "Assets:Cash", "USD", "9999-12-32")
		if e != nil {
			t.Fatal(e)
		}
		plan := ""
		for rows.Next() {
			plan += rows.Text(3) + "\n"
		}
		if e = rows.Close(); e != nil {
			t.Fatal(e)
		}
		if strings.Contains(strings.ToUpper(plan), "TEMP B-TREE") || !strings.Contains(plan, "postings_account_currency_date") {
			t.Fatal(plan)
		}
		t.Log(plan)
		rows, e = i.db.Query("EXPLAIN "+q, "Assets:Cash", "USD", "9999-12-32")
		if e != nil {
			t.Fatal(e)
		}
		for rows.Next() {
			op := rows.Text(1)
			if strings.Contains(op, "Sorter") || op == "OpenEphemeral" || op == "OpenAutoindex" {
				t.Fatal("unbounded worktable", op)
			}
		}
		if e = rows.Close(); e != nil {
			t.Fatal(e)
		}
	}
}

func TestAccountActivityCancellationAndConcurrency(t *testing.T) {
	records := []string{testHeader, transaction(1, "2025-01-01", "")}
	for n := 0; n < 500; n++ {
		records = append(records, posting(1, n, "Assets:Cash", "1", "USD"))
	}
	records = append(records, transaction(2, "2026-01-01", ""), posting(2, 0, "Assets:Cash", "1", "USD"))
	path, m := buildText(t, makeStream(records...))
	i := openIndex(t, path, m)
	for _, at := range []int64{1, 2, 20, 200} {
		for _, summary := range []bool{false, true} {
			ctx, cancel := context.WithCancel(context.Background())
			cc := &detailCancelContext{Context: ctx, cancel: cancel, at: at}
			if summary {
				s, e := i.AccountSummary(cc, AccountSummaryRequest{Account: "Assets:Cash", Currency: "USD"})
				wantError(t, e, context.Canceled)
				if s != (AccountSummary{}) {
					t.Fatal("partial")
				}
			} else {
				p, e := i.AccountActivity(cc, AccountActivityRequest{Account: "Assets:Cash", Currency: "USD", Start: "2026-01-01", End: "2027-01-01"})
				wantError(t, e, context.Canceled)
				if !reflect.DeepEqual(p, AccountActivityPage{}) {
					t.Fatal("partial")
				}
			}
			cancel()
			p, e := i.AccountActivity(context.Background(), AccountActivityRequest{Account: "Assets:Cash", Currency: "USD"})
			if e != nil || len(p.Rows) != 2 || p.Rows[1].Balance != "501" {
				t.Fatal("reuse", e)
			}
		}
	}
	var wg sync.WaitGroup
	for n := 0; n < 8; n++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, e := i.AccountSummary(context.Background(), AccountSummaryRequest{Account: "Assets:Cash", Currency: "USD"})
			if e != nil {
				t.Error(e)
			}
			_, e = i.AccountActivity(context.Background(), AccountActivityRequest{Account: "Assets:Cash", Currency: "USD"})
			if e != nil {
				t.Error(e)
			}
		}()
	}
	wg.Wait()
}

func TestAccountActivityRationalOracle(t *testing.T) {
	rng := rand.New(rand.NewSource(71))
	records := []string{testHeader}
	deltas := map[int]*big.Rat{}
	dates := map[int]string{}
	for id := 1; id <= 90; id++ {
		date := fmt.Sprintf("2026-01-%02d", 1+rng.Intn(9))
		dates[id] = date
		records = append(records, transaction(id, date, "oracle"))
		d := new(big.Rat)
		deltas[id] = d
		for n := 0; n < 1+rng.Intn(15); n++ {
			q := fmt.Sprintf("%d.%06d", rng.Intn(201)-100, rng.Intn(1000000))
			records = append(records, posting(id, n, "Assets:Cash", q, "USD"))
			v, _ := new(big.Rat).SetString(q)
			d.Add(d, v)
		}
	}
	path, m := buildText(t, makeStream(records...))
	i := openIndex(t, path, m)
	r := AccountActivityRequest{Account: "Assets:Cash", Currency: "USD", Start: "2026-01-03", End: "2026-01-08", Limit: 7}
	balance, opening, closing, current := new(big.Rat), new(big.Rat), new(big.Rat), new(big.Rat)
	var ids []int
	want := map[int]string{}
	for day := 1; day <= 9; day++ {
		date := fmt.Sprintf("2026-01-%02d", day)
		for id := 1; id <= 90; id++ {
			if dates[id] != date {
				continue
			}
			d := deltas[id]
			balance.Add(balance, d)
			current.Add(current, d)
			if date < r.Start {
				opening.Add(opening, d)
			}
			if date < r.End {
				closing.Add(closing, d)
			}
			if date >= r.Start && date < r.End {
				ids = append(ids, id)
				want[id] = balance.RatString()
			}
		}
	}
	count := 0
	for {
		p, e := i.AccountActivity(context.Background(), r)
		if e != nil {
			t.Fatal(e)
		}
		for _, row := range p.Rows {
			id := int(row.ID)
			v, ok := new(big.Rat).SetString(row.Balance)
			d, dok := new(big.Rat).SetString(row.Change)
			if !ok || !dok || count >= len(ids) || id != ids[count] || v.RatString() != want[id] || d.Cmp(deltas[id]) != 0 {
				t.Fatalf("%+v", row)
			}
			count++
		}
		if p.NextCursor == "" {
			break
		}
		r.Cursor = p.NextCursor
	}
	if count != len(ids) {
		t.Fatal(count)
	}
	s, e := i.AccountSummary(context.Background(), AccountSummaryRequest{Account: r.Account, Currency: r.Currency, Start: r.Start, End: r.End})
	if e != nil {
		t.Fatal(e)
	}
	for got, want := range map[string]*big.Rat{s.CurrentBalance: current, s.OpeningBalance: opening, s.ClosingBalance: closing, s.PeriodChange: new(big.Rat).Sub(closing, opening)} {
		v, ok := new(big.Rat).SetString(got)
		if !ok || v.Cmp(want) != 0 {
			t.Fatal(got, want)
		}
	}
}

func TestSynthetic100KAccountActivity(t *testing.T) {
	if os.Getenv("READINDEX_SCALE") != "1" {
		t.Skip("set READINDEX_SCALE=1")
	}
	// Reuse the bounded streaming fixture generator rather than retaining inputs.
	path := destination(t)
	stream := syntheticActivityStream(100000)
	defer stream.Close()
	m, e := Build(context.Background(), stream, path)
	if e != nil {
		t.Fatal(e)
	}
	i := openIndex(t, path, m)
	ctx := context.Background()
	s, e := i.AccountSummary(ctx, AccountSummaryRequest{Account: "Assets:Cash", Currency: "USD"})
	if e != nil || s.CurrentBalance != "0.0000000000001" {
		t.Fatalf("%+v %v", s, e)
	}
	r := AccountActivityRequest{Account: "Assets:Cash", Currency: "USD", Limit: 500}
	p, e := i.AccountActivity(ctx, r)
	if e != nil || len(p.Rows) != 500 {
		t.Fatal(e)
	}
	c := activityCursor{Operation: "account_activity", Revision: m.Revision, Filter: activityFilter(AccountSummaryRequest{Account: r.Account, Currency: r.Currency}), Date: "2026-01-01", ID: 99500}
	r.Cursor = encodeActivityCursor(c)
	p, e = i.AccountActivity(ctx, r)
	if e != nil || len(p.Rows) != 500 || p.Rows[0].ID != 99501 || p.Rows[499].Balance != s.CurrentBalance || p.NextCursor != "" {
		t.Fatalf("tail %d %v", len(p.Rows), e)
	}
}

func syntheticActivityStream(count int) *io.PipeReader {
	r, w := io.Pipe()
	go func() {
		hash := sha256.New()
		out := io.MultiWriter(w, hash)
		_, e := fmt.Fprintln(out, testHeader)
		for id := 1; id <= count && e == nil; id++ {
			_, e = fmt.Fprintln(out, transaction(id, "2026-01-01", ""))
			if e != nil {
				break
			}
			_, e = fmt.Fprintln(out, posting(id, 0, "Assets:Cash", ".000000000000000001", "USD"))
		}
		if e == nil {
			_, e = fmt.Fprintf(w, `{"type":"footer","records":%d,"directives":%d,"postings":%d,"sha256":"%s"}`+"\n", 1+2*count, count, count, hex.EncodeToString(hash.Sum(nil)))
		}
		w.CloseWithError(e)
	}()
	return r
}

func TestAccountActivityUnicodeAndDirectiveFidelity(t *testing.T) {
	account, currency := "Assets:现金", strings.Repeat("币", 341)+"X" // 1024 UTF-8 bytes
	raw := strings.Replace(transaction(1, "2026-01-01", "描述 <>& 零"), `"Flag":"*"`, `"Flag":"*","Payee":"商家"`, 1)
	path, m := buildText(t, makeStream(testHeader, raw, posting(1, 0, account, "-0.000", currency)))
	i := openIndex(t, path, m)
	p, e := i.AccountActivity(context.Background(), AccountActivityRequest{Account: account, Currency: currency})
	if e != nil || len(p.Rows) != 1 || string(p.Rows[0].Record) != raw || p.Rows[0].Change != "0" || p.Rows[0].Balance != "0" {
		t.Fatalf("%+v %v", p, e)
	}
	s, e := i.AccountSummary(context.Background(), AccountSummaryRequest{Account: account, Currency: currency})
	if e != nil || s.CurrentBalance != "0" {
		t.Fatalf("%+v %v", s, e)
	}
}

func TestAccountActivityBoundaryAndArithmeticFailures(t *testing.T) {
	records := []string{testHeader, transaction(1, "2026-01-01", ""), posting(1, 0, "Assets:Cash", "1", "USD"), transaction(2, "2026-01-01", "wrong currency"), posting(2, 0, "Assets:Cash", "2", "EUR"), transaction(3, "2026-01-01", "wrong account"), posting(3, 0, "Assets:Other", "3", "USD"), transaction(4, "2026-01-02", "last"), posting(4, 0, "Assets:Cash", "-1", "USD")}
	path, m := buildText(t, makeStream(records...))
	i := openIndex(t, path, m)
	ctx := context.Background()
	r := AccountSummaryRequest{Account: "Assets:Cash", Currency: "USD", Start: "2026-01-01", End: "2026-02-01"}
	c := activityCursor{Operation: "account_activity", Revision: m.Revision, Filter: activityFilter(r), Date: "2026-01-01", ID: 2}
	request := AccountActivityRequest{Account: r.Account, Currency: r.Currency, Start: r.Start, End: r.End}
	for _, id := range []int64{2, 3} {
		c.ID = id
		request.Cursor = encodeActivityCursor(c)
		_, e := i.AccountActivity(ctx, request)
		wantError(t, e, ErrInvalidCursor)
	}
	c.Date = "2025-12-31"
	c.ID = 1
	request.Cursor = encodeActivityCursor(c)
	_, e := i.AccountActivity(ctx, request)
	wantError(t, e, ErrInvalidCursor)
	c.Date = "2026-02-01"
	request.Cursor = encodeActivityCursor(c)
	_, e = i.AccountActivity(ctx, request)
	wantError(t, e, ErrInvalidCursor)
	c.Date = "2026-01-02"
	c.ID = 4
	request.Cursor = encodeActivityCursor(c)
	p, e := i.AccountActivity(ctx, request)
	if e != nil || len(p.Rows) != 0 || p.Rows == nil || p.NextCursor != "" {
		t.Fatalf("%+v %v", p, e)
	}
	// Budget overflow both within one repeated-posting group and across groups.
	for _, same := range []bool{false, true} {
		records = []string{testHeader, transaction(1, "2026-01-01", ""), posting(1, 0, "Assets:Cash", strings.Repeat("9", 4096), "USD")}
		if same {
			records = append(records, posting(1, 1, "Assets:Cash", "1", "USD"))
		} else {
			records = append(records, transaction(2, "2026-01-01", ""), posting(2, 0, "Assets:Cash", "1", "USD"))
		}
		path, m = buildText(t, makeStream(records...))
		i = openIndex(t, path, m)
		p, e = i.AccountActivity(ctx, AccountActivityRequest{Account: r.Account, Currency: r.Currency})
		wantError(t, e, ErrResourceLimit)
		if !reflect.DeepEqual(p, AccountActivityPage{}) {
			t.Fatal("partial overflow")
		}
		s, e := i.AccountSummary(ctx, AccountSummaryRequest{Account: r.Account, Currency: r.Currency})
		wantError(t, e, ErrResourceLimit)
		if s != (AccountSummary{}) {
			t.Fatal("partial overflow")
		}
	}
}

func TestAccountActivityLookaheadDoesNotAccumulateNextPage(t *testing.T) {
	path, m := buildText(t, makeStream(testHeader,
		transaction(1, "2026-01-01", "fits"), posting(1, 0, "Assets:Cash", "1", "USD"),
		transaction(2, "2026-01-02", "over budget"), posting(2, 0, "Assets:Cash", "1E999999999", "USD")))
	i := openIndex(t, path, m)
	r := AccountActivityRequest{Account: "Assets:Cash", Currency: "USD", Limit: 1}
	p, e := i.AccountActivity(context.Background(), r)
	if e != nil || len(p.Rows) != 1 || p.Rows[0].Balance != "1" || p.NextCursor == "" {
		t.Fatalf("%+v %v", p, e)
	}
	r.Cursor = p.NextCursor
	p, e = i.AccountActivity(context.Background(), r)
	wantError(t, e, ErrResourceLimit)
	if !reflect.DeepEqual(p, AccountActivityPage{}) {
		t.Fatal("partial")
	}
}

// Normalizing a maximal-scale fraction adds a leading zero. It is a valid
// accumulated value, but deliberately exceeds the raw-input digit budget.
func TestAccountSummaryActivityMaxScale(t *testing.T) {
	for _, sign := range []string{"", "-"} {
		for _, count := range []int{1, 2} {
			t.Run(fmt.Sprintf("sign=%q/postings=%d", sign, count), func(t *testing.T) {
				tiny := "." + strings.Repeat("0", ledger.MaxExactDecimalDigits-1) + "1"
				opposite := "-"
				if sign == "-" {
					opposite = ""
				}
				value := func(n int) string {
					return sign + "0." + strings.Repeat("0", ledger.MaxExactDecimalDigits-1) + fmt.Sprint(n)
				}
				records := []string{transaction(1, "2026-01-01", "prefix")}
				for n := 0; n < count; n++ {
					records = append(records, posting(1, n, "Assets:Cash", sign+tiny, "USD"))
				}
				records = append(records, transaction(2, "2026-02-01", "range"), posting(2, 0, "Assets:Cash", sign+tiny, "USD"), transaction(3, "2026-03-01", "exclusive end"), posting(3, 0, "Assets:Cash", opposite+tiny, "USD"))
				path, manifest := buildText(t, makeStream(append([]string{testHeader}, records...)...))
				index := openIndex(t, path, manifest)
				ctx := context.Background()
				summaryRequest := AccountSummaryRequest{Account: "Assets:Cash", Currency: "USD"}
				summary, err := index.AccountSummary(ctx, summaryRequest)
				if err != nil {
					t.Fatal(err)
				}
				if summary.CurrentBalance != value(count) || summary.OpeningBalance != "0" || summary.ClosingBalance != value(count) || summary.PeriodChange != value(count) {
					t.Fatal("unexpected unbounded summary")
				}
				request := AccountActivityRequest{Account: summaryRequest.Account, Currency: summaryRequest.Currency, Limit: 1}
				changes := []string{value(count), value(1), opposite + "0" + tiny}
				balances := []string{value(count), value(count + 1), value(count)}
				for n := range 3 {
					page, err := index.AccountActivity(ctx, request)
					if err != nil {
						t.Fatalf("page %d: %v", n+1, err)
					}
					if len(page.Rows) != 1 || page.Rows[0].ID != int64(n+1) || page.Rows[0].Change != changes[n] || page.Rows[0].Balance != balances[n] {
						t.Fatalf("page %d: unexpected exact activity", n+1)
					}
					if (page.NextCursor == "") != (n == 2) {
						t.Fatalf("page %d: unexpected cursor", n+1)
					}
					request.Cursor = page.NextCursor
				}
				summaryRequest.Start, summaryRequest.End = "2026-02-01", "2026-03-01"
				summary, err = index.AccountSummary(ctx, summaryRequest)
				if err != nil {
					t.Fatal(err)
				}
				if summary.CurrentBalance != value(count) || summary.OpeningBalance != value(count) || summary.ClosingBalance != value(count+1) || summary.PeriodChange != value(1) {
					t.Fatal("unexpected ranged summary")
				}
				request.Start, request.End = summaryRequest.Start, summaryRequest.End
				page, err := index.AccountActivity(ctx, request)
				if err != nil {
					t.Fatal(err)
				}
				if len(page.Rows) != 1 || page.Rows[0].ID != 2 || page.Rows[0].Change != summary.PeriodChange || page.Rows[0].Balance != summary.ClosingBalance || page.NextCursor != "" {
					t.Fatal("ranged activity disagrees with summary")
				}
			})
		}
	}
}
