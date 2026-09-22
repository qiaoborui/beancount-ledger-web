package readindex

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/borui/beancount-ledger-web/server/internal/ledger"
	"github.com/borui/beancount-ledger-web/server/internal/readindex/sqlite"
)

func accountEvent(id int, kind, account, date string) string {
	return fmt.Sprintf(`{"type":"directive","id":%d,"value":{"Kind":%q,"Date":%q,"File":"main.bean","Line":1,"Account":%q}}`, id, kind, date, account)
}
func posting(id, ordinal int, account, quantity, currency string) string {
	return fmt.Sprintf(`{"type":"posting","entry_id":%d,"ordinal":%d,"value":{"account":%q,"Quantity":{"Number":%q,"Currency":%q}}}`, id, ordinal, account, quantity, currency)
}
func accountFixture() string {
	return makeStream(testHeader,
		accountEvent(1, "open", "Assets:Zero", "2025-01-01"),
		accountEvent(2, "open", "Assets:Cash", "2025-01-01"),
		`{"type":"metadata","entry_id":2,"posting":-1,"key":"alias","value":{"type":"str","value":"Cash label"}}`,
		accountEvent(3, "open", "Assets:Cash", "2025-02-01"), // duplicate does not multiply catalog
		accountEvent(4, "close", "Assets:Cash", "2027-01-01"),
		accountEvent(5, "close", "Assets:CloseOnly", "2025-01-01"),
		transaction(6, "2026-01-01", ""),
		posting(6, 0, "Assets:Cash", "12345678901234567890.000000000000000000000001", "USD"),
		posting(6, 1, "Assets:Cash", "-.000000000000000000000002", "USD"),
		posting(6, 2, "Assets:Cash", "-2.5e+2", "EUR"),
		posting(6, 3, "Assets:PostedOnly", "4", "CNY"),
		transaction(7, "2026-02-01", ""),
		posting(7, 0, "Assets:Cash", "1E-24", "USD"),
		posting(7, 1, "Assets:Cash", "250.000", "EUR"),
		posting(7, 2, "Assets:Cash", "-7.75", "JPY"),
		transaction(8, "2026-03-01", ""),
		posting(8, 0, "Assets:Cash", "1", "USD"))
}

func TestAccountsAndNativeBalances(t *testing.T) {
	path, m := buildText(t, accountFixture())
	i := openIndex(t, path, m)
	ctx := context.Background()
	a, e := i.Accounts(ctx, PageRequest{Limit: 1})
	if e != nil {
		t.Fatal(e)
	}
	if len(a.Accounts) != 1 || a.Accounts[0].Account != "Assets:Cash" || a.Accounts[0].OpenID != 2 || a.Accounts[0].CloseDate != "2027-01-01" || a.NextCursor == "" {
		t.Fatalf("catalog: %+v", a)
	}
	if string(a.Accounts[0].OpenRecord) != accountEvent(2, "open", "Assets:Cash", "2025-01-01") {
		t.Fatal("open changed")
	}
	detail, e := i.DetailRecords(ctx, DetailPageRequest{ID: a.Accounts[0].OpenID})
	if e != nil || len(detail.Records) != 2 {
		t.Fatal("metadata locator", e)
	}
	next, e := i.Accounts(ctx, PageRequest{Cursor: a.NextCursor})
	if e != nil || len(next.Accounts) != 1 || next.Accounts[0].Account != "Assets:Zero" || next.NextCursor != "" {
		t.Fatal("catalog keyset", e)
	}
	req := AccountBalancesRequest{Account: "Assets:Cash", Limit: 1}
	var got []NativeBalance
	var first string
	for {
		p, e := i.AccountBalances(ctx, req)
		if e != nil {
			t.Fatal(e)
		}
		if p.Basis != "native_nominal" || p.Account != req.Account || p.Revision != m.Revision || len(p.Balances) != 1 {
			t.Fatalf("balance page %+v", p)
		}
		got = append(got, p.Balances...)
		if first == "" {
			first = p.NextCursor
		}
		if p.NextCursor == "" {
			break
		}
		req.Cursor = p.NextCursor
	}
	want := []NativeBalance{{"EUR", "0"}, {"JPY", "-7.75"}, {"USD", "12345678901234567891"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%+v", got)
	}
	p, e := i.AccountBalances(ctx, AccountBalancesRequest{Account: "Assets:Cash", Start: "2026-01-01", End: "2026-02-01"})
	if e != nil || !reflect.DeepEqual(p.Balances, []NativeBalance{{"EUR", "-250"}, {"USD", "12345678901234567889.999999999999999999999999"}}) {
		t.Fatalf("exclusive end %+v %v", p, e)
	}
	p, e = i.AccountBalances(ctx, AccountBalancesRequest{Account: "Assets:Cash", Start: "2026-02-01", End: "2026-03-01"})
	if e != nil || len(p.Balances) != 3 || p.Balances[2].Quantity != "0.000000000000000000000001" {
		t.Fatalf("inclusive start %+v %v", p, e)
	}
	for _, account := range []string{"Assets:Zero", "Assets:Missing"} {
		p, e = i.AccountBalances(ctx, AccountBalancesRequest{Account: account})
		if e != nil || p.Balances == nil || len(p.Balances) != 0 {
			t.Fatal("empty account", e)
		}
	}
	p, e = i.AccountBalances(ctx, AccountBalancesRequest{Account: "Assets:PostedOnly"})
	if e != nil || !reflect.DeepEqual(p.Balances, []NativeBalance{{"CNY", "4"}}) {
		t.Fatal("posted only", e)
	}
	// Operation/filter/revision binding; a cursor is not transferable between APIs.
	_, e = i.Accounts(ctx, PageRequest{Cursor: first})
	wantError(t, e, ErrInvalidCursor)
	for _, r := range []AccountBalancesRequest{
		{Account: "Assets:PostedOnly", Cursor: first},
		{Account: "Assets:Cash", Start: "2026-01-01", End: "2026-02-01", Cursor: first},
		{Account: "Assets:Cash", Cursor: a.NextCursor},
	} {
		_, e = i.AccountBalances(ctx, r)
		wantError(t, e, ErrInvalidCursor)
	}
	c, e := decodeAccountCursor(first, "account_balances", m.Revision, balancesFilter(AccountBalancesRequest{Account: "Assets:Cash"}))
	if e != nil {
		t.Fatal(e)
	}
	c.Revision = strings.Repeat("b", 64)
	_, e = i.AccountBalances(ctx, AccountBalancesRequest{Account: "Assets:Cash", Cursor: encodeAccountCursor(c)})
	wantError(t, e, ErrRevisionMismatch)
	c.Revision = m.Revision
	c.Seq = 999999
	_, e = i.AccountBalances(ctx, AccountBalancesRequest{Account: "Assets:Cash", Cursor: encodeAccountCursor(c)})
	wantError(t, e, ErrInvalidCursor)
	_, e = i.Accounts(ctx, PageRequest{Cursor: encodeAccountCursor(accountCursor{"accounts", m.Revision, "", 999999})})
	wantError(t, e, ErrInvalidCursor)
}

func TestAccountValidationLimitsAndLifecycle(t *testing.T) {
	path, m := buildText(t, accountFixture())
	i := openIndex(t, path, m)
	ctx := context.Background()
	for _, r := range []AccountBalancesRequest{
		{}, {Account: " "}, {Account: " Assets:A"}, {Account: "A\n"}, {Account: strings.Repeat("x", MaxAccountFilterBytes+1)}, {Account: string([]byte{255})},
		{Account: "A", Start: "2026-01-01"}, {Account: "A", End: "2026-01-01"},
		{Account: "A", Start: "2026-01-01", End: "2026-01-01"}, {Account: "A", Start: "2026-02-01", End: "2026-01-01"},
		{Account: "A", Start: "2026-02-30", End: "2026-03-01"}, {Account: "A", Start: "2026-1-01", End: "2026-03-01"},
		{Account: "A", Start: "0000-01-01", End: "2026-03-01"},
		{Account: "A", Limit: -1}, {Account: "A", Limit: 501},
	} {
		_, e := i.AccountBalances(ctx, r)
		wantError(t, e, ErrInvalidRequest)
	}
	for _, r := range []PageRequest{{Limit: -1}, {Limit: 501}} {
		_, e := i.Accounts(ctx, r)
		wantError(t, e, ErrInvalidRequest)
	}
	_, e := i.Accounts(nil, PageRequest{})
	wantError(t, e, ErrInvalidRequest)
	_, e = i.AccountBalances(nil, AccountBalancesRequest{Account: "A"})
	wantError(t, e, ErrInvalidRequest)
	cancelCtx, cancel := context.WithCancel(ctx)
	cancel()
	_, e = i.Accounts(cancelCtx, PageRequest{})
	wantError(t, e, context.Canceled)
	_, e = i.AccountBalances(cancelCtx, AccountBalancesRequest{Account: "A"})
	wantError(t, e, context.Canceled)
	for _, cursor := range []string{"!", strings.Repeat("x", 513), encodeAccountCursor(accountCursor{"accounts", m.Revision, "", 0})} {
		_, e = i.Accounts(ctx, PageRequest{Cursor: cursor})
		wantError(t, e, ErrInvalidCursor)
	}
	i.Close()
	_, e = i.Accounts(ctx, PageRequest{})
	wantError(t, e, ErrUnavailable)
	_, e = i.AccountBalances(ctx, AccountBalancesRequest{Account: "A"})
	wantError(t, e, ErrUnavailable)
	for _, quantity := range []string{"1E-99999999", strings.Repeat("9", 4097)} {
		path, m = buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", ""), posting(1, 0, "Assets:A", quantity, "USD")))
		idx := openIndex(t, path, m) // preserve exact canonical values even outside arithmetic budget
		_, e = idx.AccountBalances(ctx, AccountBalancesRequest{Account: "Assets:A"})
		wantError(t, e, ErrResourceLimit)
	}
}

func TestAccountQueryPlans(t *testing.T) {
	path, m := buildText(t, accountFixture())
	i := openIndex(t, path, m)
	for _, q := range []struct {
		sql   string
		args  []any
		index string
	}{
		{accountsFirstQuery, []any{501}, "account_events_catalog"},
		{accountsQuery, []any{"Assets:A", 501}, "account_events_catalog"},
		{balancesQuery, []any{"Assets:Cash", "EUR", "2026-01-01", "2027-01-01"}, "postings_account_currency_date"},
		{projectionReplayQuery(), nil, ""},
	} {
		rows, e := i.db.Query("EXPLAIN QUERY PLAN "+q.sql, q.args...)
		if e != nil {
			t.Fatal(e)
		}
		var plans []string
		for rows.Next() {
			plans = append(plans, rows.Text(3))
		}
		if e = rows.Close(); e != nil {
			t.Fatal(e)
		}
		plan := strings.Join(plans, "\n")
		if strings.Contains(strings.ToUpper(plan), "TEMP B-TREE") || q.index != "" && !strings.Contains(plan, q.index) {
			t.Fatal(plan)
		}
		t.Log(plan)
	}
}

func TestAccountsAndBalancesBoundedPages(t *testing.T) {
	ctx := context.Background()
	records := []string{testHeader}
	for n := 1; n <= 503; n++ {
		records = append(records, accountEvent(n, "open", fmt.Sprintf("Assets:%04d", n), "2026-01-01"))
	}
	records = append(records, transaction(504, "2026-01-01", ""))
	for n := 0; n < 503; n++ {
		records = append(records, posting(504, n, "Assets:0001", ".00000000000000000001", fmt.Sprintf("C%04d", n)))
	}
	path, m := buildText(t, makeStream(records...))
	i := openIndex(t, path, m)
	a, e := i.Accounts(ctx, PageRequest{Limit: 500})
	if e != nil || len(a.Accounts) != 500 || a.NextCursor == "" {
		t.Fatal("500 accounts", e)
	}
	a, e = i.Accounts(ctx, PageRequest{Limit: 500, Cursor: a.NextCursor})
	if e != nil || len(a.Accounts) != 3 || a.NextCursor != "" {
		t.Fatal("remaining accounts", e)
	}
	b, e := i.AccountBalances(ctx, AccountBalancesRequest{Account: "Assets:0001", Limit: 500})
	if e != nil || len(b.Balances) != 500 || b.NextCursor == "" {
		t.Fatal("500 balances", e)
	}
	b, e = i.AccountBalances(ctx, AccountBalancesRequest{Account: "Assets:0001", Limit: 500, Cursor: b.NextCursor})
	if e != nil || len(b.Balances) != 3 || b.NextCursor != "" {
		t.Fatal("remaining balances", e)
	}
	// Raw whitespace retention is bounded, not just compacted JSON wire size.
	padded := func(s string) string { return s[:len(s)-1] + strings.Repeat(" ", 600000) + "}" }
	path, m = buildText(t, makeStream(testHeader, padded(accountEvent(1, "open", "A", "2026-01-01")), padded(accountEvent(2, "open", "B", "2026-01-01"))))
	i = openIndex(t, path, m)
	a, e = i.Accounts(ctx, PageRequest{})
	if e != nil || len(a.Accounts) != 1 || a.NextCursor == "" {
		t.Fatal("retained cap", e)
	}
	a, e = i.Accounts(ctx, PageRequest{Cursor: a.NextCursor})
	if e != nil || len(a.Accounts) != 1 || a.NextCursor != "" {
		t.Fatal("retained next", e)
	}
	// Large source names/currencies are preserved; cursor uses a scalar locator,
	// not a potentially oversized string. Wire response stops at 1MiB.
	long := strings.Repeat("x", 270000)
	records = []string{testHeader}
	for n := 1; n <= 3; n++ {
		records = append(records, accountEvent(n, "open", fmt.Sprint(n)+long, "2026-01-01"))
	}
	records = append(records, transaction(4, "2026-01-01", ""))
	for n := 0; n < 5; n++ {
		records = append(records, posting(4, n, "Assets:A", "1", fmt.Sprint(n)+long))
	}
	path, m = buildText(t, makeStream(records...))
	i = openIndex(t, path, m)
	a, e = i.Accounts(ctx, PageRequest{})
	if e != nil || len(a.Accounts) != 1 || a.NextCursor == "" {
		t.Fatal("wire catalog", e)
	}
	encoded, _ := json.Marshal(a)
	if len(encoded) > MaxResponseBytes {
		t.Fatal("catalog cap")
	}
	b, e = i.AccountBalances(ctx, AccountBalancesRequest{Account: "Assets:A"})
	if e != nil || len(b.Balances) != 3 || b.NextCursor == "" {
		t.Fatal("wire balances", e)
	}
	encoded, _ = json.Marshal(b)
	if len(encoded) > MaxResponseBytes {
		t.Fatal("balances cap")
	}
	b, e = i.AccountBalances(ctx, AccountBalancesRequest{Account: "Assets:A", Cursor: b.NextCursor})
	if e != nil || len(b.Balances) != 2 || b.NextCursor != "" {
		t.Fatal("wire next", e)
	}
	path, m = buildText(t, makeStream(testHeader, accountEvent(1, "open", strings.Repeat("x", 600000), "2026-01-01")))
	i = openIndex(t, path, m)
	_, e = i.Accounts(ctx, PageRequest{})
	wantError(t, e, ErrResourceLimit)
}

func projectionFixture() string {
	return makeStream(testHeader, transaction(1, "2026-01-01", ""), testPosting,
		accountEvent(2, "open", "Assets:Stock", "2025-01-01"),
		accountEvent(3, "close", "Assets:Stock", "2027-01-01"),
		`{"type":"directive","id":4,"value":{"Kind":"price","Date":"2026-02-01","File":"main.bean","Line":1,"Currency":"XYZ","QuoteCurrency":"USD","AmountValue":{"Number":"1.000000000000000000000000001E-99999999","Currency":"USD"}}}`)
}
func TestTypedProjectionExactAndTamper(t *testing.T) {
	path, m := buildText(t, projectionFixture())
	i := openIndex(t, path, m)
	rows, e := i.db.Query("SELECT quantity, cost_number, price_number, cost_date, cost_label, flag FROM postings")
	if e != nil {
		t.Fatal(e)
	}
	if !rows.Next() || rows.Text(0) != "-12345678901234567890.000000000000000000000001E-20" || rows.Text(1) != "12.34000000000000000000000001" || rows.Text(2) != "1E-99999999" || rows.Text(3) != "2025-12-31" || rows.Text(4) != "lot <A> \\ 中" || rows.Text(5) != "!" {
		t.Fatal("exact projection")
	}
	if e = rows.Close(); e != nil {
		t.Fatal(e)
	}
	i.Close()
	// Every projected column (including optional NULL vs empty), missing and
	// orphan/extra rows are checked against the verified raw replay.
	var mutations []string
	for _, table := range projectionTables {
		columns := strings.Split(table.columns, ", ")
		for _, column := range columns {
			value := "'tampered'"
			if column == "seq" || column == "entry_id" || column == "ordinal" {
				value = "999999"
			}
			mutations = append(mutations, "UPDATE "+table.name+" SET "+column+"="+value+" WHERE seq=(SELECT min(seq) FROM "+table.name+")")
		}
		mutations = append(mutations, "DELETE FROM "+table.name)
		selectCols := append([]string(nil), columns...)
		selectCols[0] = "999999"
		mutations = append(mutations, "INSERT INTO "+table.name+" SELECT "+strings.Join(selectCols, ",")+" FROM "+table.name+" LIMIT 1")
	}
	mutations = append(mutations, "UPDATE postings SET cost_number=NULL", "UPDATE postings SET cost_label=''", "UPDATE postings SET flag=NULL", "DROP INDEX postings_account_currency_date", "CREATE TABLE unapproved (id INTEGER)")
	for _, sql := range mutations {
		t.Run(sql, func(t *testing.T) {
			path, m := buildText(t, projectionFixture())
			db, e := sqlite.Open(path, true)
			if e != nil {
				t.Fatal(e)
			}
			if e = db.Exec(sql); e != nil {
				db.Close()
				t.Fatal(e)
			}
			if e = db.Close(); e != nil {
				t.Fatal(e)
			}
			_, e = Open(path, m)
			wantError(t, e, ErrCorrupt)
		})
	}
	path, m = buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", ""), posting(1, 0, "Assets:A", "1", "USD")))
	db, e := sqlite.Open(path, true)
	if e != nil {
		t.Fatal(e)
	}
	e = db.Exec("UPDATE postings SET cost_label=''")
	db.Close()
	if e != nil {
		t.Fatal(e)
	}
	_, e = Open(path, m)
	wantError(t, e, ErrCorrupt)
}

func TestSynthetic100KAccountsBalances(t *testing.T) {
	if os.Getenv("READINDEX_SCALE") != "1" {
		t.Skip("set READINDEX_SCALE=1")
	}
	reader, writer := io.Pipe()
	done := make(chan error, 1)
	go func() {
		hash := sha256.New()
		out := io.MultiWriter(writer, hash)
		_, e := fmt.Fprintln(out, testHeader)
		for n := 1; e == nil && n <= 100000; n++ {
			_, e = fmt.Fprintln(out, accountEvent(n, "open", fmt.Sprintf("Assets:%06d", n), "2025-01-01"))
		}
		for n := 1; e == nil && n <= 100000; n++ {
			_, e = fmt.Fprintln(out, transaction(n+100000, "2026-01-01", ""))
			if e != nil {
				break
			}
			_, e = fmt.Fprintln(out, posting(n+100000, 0, "Assets:000001", "0.00000000000000000001", "USD"))
		}
		if e == nil {
			_, e = fmt.Fprintf(writer, `{"type":"footer","records":300001,"directives":200000,"postings":100000,"sha256":"%s"}`+"\n", hex.EncodeToString(hash.Sum(nil)))
		}
		writer.CloseWithError(e)
		done <- e
	}()
	path := destination(t)
	m, e := Build(context.Background(), reader, path)
	reader.CloseWithError(e)
	we := <-done
	if e != nil || we != nil {
		t.Fatalf("build %v writer %v", e, we)
	}
	i := openIndex(t, path, m)
	count := 0
	cursor := ""
	for {
		p, e := i.Accounts(context.Background(), PageRequest{Limit: 500, Cursor: cursor})
		if e != nil {
			t.Fatal(e)
		}
		for _, a := range p.Accounts {
			count++
			if a.Account != fmt.Sprintf("Assets:%06d", count) {
				t.Fatal("scale gap")
			}
		}
		if p.NextCursor == "" {
			break
		}
		cursor = p.NextCursor
	}
	if count != 100000 {
		t.Fatal(count)
	}
	p, e := i.AccountBalances(context.Background(), AccountBalancesRequest{Account: "Assets:000001"})
	if e != nil || !reflect.DeepEqual(p.Balances, []NativeBalance{{"USD", "0.000000000000001"}}) {
		t.Fatalf("scale sum %+v %v", p, e)
	}
}

func TestAccountWireBoundaryAndEmptyCatalog(t *testing.T) {
	ctx := context.Background()
	path, m := buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", "")))
	i := openIndex(t, path, m)
	a, e := i.Accounts(ctx, PageRequest{})
	if e != nil || a.Accounts == nil || len(a.Accounts) != 0 || a.NextCursor != "" {
		t.Fatal("empty catalog", e)
	}
	// Empty canonical name is unusual but permitted by the verifier; preserve it.
	path, m = buildText(t, makeStream(testHeader, accountEvent(1, "open", "", "2026-01-01"), accountEvent(2, "open", "A", "2026-01-01")))
	i = openIndex(t, path, m)
	a, e = i.Accounts(ctx, PageRequest{Limit: 1})
	if e != nil || len(a.Accounts) != 1 || a.Accounts[0].Account != "" || a.NextCursor == "" {
		t.Fatal("empty canonical name", e)
	}
	a, e = i.Accounts(ctx, PageRequest{Cursor: a.NextCursor})
	if e != nil || len(a.Accounts) != 1 || a.Accounts[0].Account != "A" {
		t.Fatal("empty name cursor", e)
	}
	// Exact wire cap for catalog including duplicate account name in raw record.
	raw := accountEvent(1, "open", "A", "2026-01-01")
	probe, _ := json.Marshal(AccountsPage{Revision: strings.Repeat("0", 64), Accounts: []Account{{Account: "A", OpenID: 1, OpenDate: "2026-01-01", OpenRecord: json.RawMessage(raw)}}})
	// Pad Booking-independent raw currencies string so each byte occurs once.
	overhead := len(`,"Currencies":[""]`)
	raw = strings.TrimSuffix(raw, "}}") + `,"Currencies":["` + strings.Repeat("x", MaxResponseBytes-len(probe)-overhead) + `"]}}`
	path, m = buildText(t, makeStream(testHeader, raw))
	i = openIndex(t, path, m)
	a, e = i.Accounts(ctx, PageRequest{})
	if e != nil {
		t.Fatal(e)
	}
	encoded, _ := json.Marshal(a)
	if len(encoded) != MaxResponseBytes {
		t.Fatal("exact catalog cap", len(encoded))
	}
	path, m = buildText(t, makeStream(testHeader, raw, accountEvent(2, "open", "B", "2026-01-01")))
	i = openIndex(t, path, m)
	_, e = i.Accounts(ctx, PageRequest{Limit: 1})
	wantError(t, e, ErrResourceLimit) // continuation cursor must fit too
	// A short source spelling may expand on JSON encoding. Never emit >1MiB.
	largeCurrency := strings.Repeat("<", 180000)
	raw = strings.ReplaceAll(posting(1, 0, "Assets:A", "1", largeCurrency), `\u003c`, "<")
	path, m = buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", ""), raw))
	i = openIndex(t, path, m)
	_, e = i.AccountBalances(ctx, AccountBalancesRequest{Account: "Assets:A"})
	wantError(t, e, ErrResourceLimit)
}

func TestSchemaOneAndWrongRecordProjectionRejected(t *testing.T) {
	path, m := buildText(t, projectionFixture())
	db, e := sqlite.Open(path, true)
	if e != nil {
		t.Fatal(e)
	}
	old := m
	old.SchemaVersion = 1
	raw, _ := json.Marshal(old)
	e = db.Exec("UPDATE manifest SET raw=?", string(raw))
	db.Close()
	if e != nil {
		t.Fatal(e)
	}
	_, e = Open(path, old)
	wantError(t, e, ErrCorrupt)
	// A projection attached to a real non-matching record is not merely an orphan.
	path, m = buildText(t, projectionFixture())
	db, e = sqlite.Open(path, true)
	if e != nil {
		t.Fatal(e)
	}
	e = db.Exec("INSERT INTO prices SELECT 1,entry_id,date,currency,quantity,quote_currency,pair_key FROM prices")
	db.Close()
	if e != nil {
		t.Fatal(e)
	}
	_, e = Open(path, m)
	wantError(t, e, ErrCorrupt)
}

func TestAccountBalancesDecimalNormalization(t *testing.T) {
	large := "1" + strings.Repeat("0", ledger.MaxExactDecimalDigits-1)
	tiny := "." + strings.Repeat("0", ledger.MaxExactDecimalDigits-1) + "1"
	complement := "." + strings.Repeat("9", ledger.MaxExactDecimalDigits)
	for _, sign := range []string{"", "-"} {
		for _, tc := range []struct {
			name  string
			parts []string
			want  string
		}{
			{"fractional history", []string{".1", ".9", large}, "1" + strings.Repeat("0", ledger.MaxExactDecimalDigits-2) + "1"},
			{"direct integer", []string{"1", large}, "1" + strings.Repeat("0", ledger.MaxExactDecimalDigits-2) + "1"},
			{"boundary carry", []string{tiny, complement}, "1"},
			{"boundary carry then large", []string{tiny, complement, large}, "1" + strings.Repeat("0", ledger.MaxExactDecimalDigits-2) + "1"},
		} {
			t.Run(sign+tc.name, func(t *testing.T) {
				records := []string{testHeader}
				for n, part := range tc.parts {
					records = append(records, transaction(n+1, "2026-01-01", ""), posting(n+1, 0, "Assets:A", sign+part, "USD"))
				}
				path, m := buildText(t, makeStream(records...))
				i := openIndex(t, path, m)
				page, err := i.AccountBalances(context.Background(), AccountBalancesRequest{Account: "Assets:A"})
				if err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(page.Balances, []NativeBalance{{Currency: "USD", Quantity: sign + tc.want}}) || page.NextCursor != "" {
					t.Fatal("incorrect normalized native balance")
				}
			})
		}
	}
}
