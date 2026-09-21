package readindex

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

func detailPosting(n, size int) string {
	return fmt.Sprintf(`{"type":"posting","entry_id":1,"ordinal":%d,"value":{"account":"Assets:%s","Quantity":{"Number":"1.000000000000000000000001","Currency":"USD"}}}`, n, strings.Repeat("x", size))
}

// Assert each returned page independently; no production entry-wide collection.
func checkDetailPages(t *testing.T, i *Index, limit int, want []string) int {
	t.Helper()
	cursor, offset, pages := "", 0, 0
	for {
		p, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Limit: limit, Cursor: cursor})
		if err != nil {
			t.Fatal(err)
		}
		bound := limit
		if bound == 0 {
			bound = DefaultPageSize
		}
		if p.ID != 1 || p.Revision != i.manifest.Revision || len(p.Records) == 0 || len(p.Records) > bound {
			t.Fatal("invalid page shape")
		}
		wire, err := json.Marshal(p)
		if err != nil || len(wire) > MaxResponseBytes {
			t.Fatal("encoded cap", err)
		}
		retained := 0
		for _, raw := range p.Records {
			retained += len(raw)
			if offset >= len(want) || string(raw) != want[offset] {
				t.Fatalf("record %d changed or skipped", offset)
			}
			offset++
		}
		if retained > MaxResponseBytes {
			t.Fatal("retained cap")
		}
		pages++
		if p.NextCursor == "" {
			break
		}
		if p.NextCursor == cursor || len(p.NextCursor) > maxCursorBytes || offset >= len(want) {
			t.Fatal("invalid continuation")
		}
		c, err := decodeDetailCursor(p.NextCursor, p.Revision, 1)
		if err != nil || c.LastSeq != int64(offset+1) {
			t.Fatal("incorrect boundary", err)
		}
		cursor = p.NextCursor
	}
	if offset != len(want) {
		t.Fatalf("received %d/%d records", offset, len(want))
	}
	return pages
}

func TestDetailRecordsOversizeExactAndCountBounds(t *testing.T) {
	records := []string{strings.Replace(transaction(1, "2026-01-01", "precision <>& 中文"), `"value":{`, `"value": { `, 1), testMetadata, testPosting,
		`{"type":"metadata","entry_id":1,"posting":0,"key":"nested","value":{"type":"list","value":[{"type":"int","value":9007199254740993},{"type":"str","value":"x\\u00e9"}]}}`}
	for n := 1; n <= 1001; n++ {
		records = append(records, detailPosting(n, 1800))
	}
	path, m := buildText(t, makeStream(append([]string{testHeader}, records...)...))
	i := openIndex(t, path, m)
	d, err := i.Detail(context.Background(), 1)
	wantError(t, err, ErrResourceLimit)
	if !reflect.DeepEqual(d, Detail{}) {
		t.Fatal("Detail returned partial data")
	}
	for _, limit := range []int{0, 1, 100, 500} {
		if got := checkDetailPages(t, i, limit, records); got < 3 {
			t.Fatal("not paginated")
		}
	}
	p, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	clear(p.Records[0])
	again, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Limit: 1})
	if err != nil || string(again.Records[0]) != records[0] {
		t.Fatal("caller mutation changed index")
	}
}

func TestDetailRecordsByteBoundaries(t *testing.T) {
	for _, mode := range []string{"raw", "escaping", "retained"} {
		t.Run(mode, func(t *testing.T) {
			records := []string{transaction(1, "2026-01-01", "small")}
			for n := 0; n < 7; n++ {
				raw := detailPosting(n, 300000)
				switch mode {
				case "escaping":
					raw = strings.ReplaceAll(detailPosting(n, 18000), "x", "<>&\u2028\u2029")
				case "retained":
					raw = strings.TrimSuffix(detailPosting(n, 0), "}") + strings.Repeat(" ", 600000) + "}"
				}
				records = append(records, raw)
			}
			path, m := buildText(t, makeStream(append([]string{testHeader}, records...)...))
			i := openIndex(t, path, m)
			if checkDetailPages(t, i, 500, records) < 3 {
				t.Fatal("byte cap did not chunk")
			}
		})
	}
}

func TestDetailRecordsSingleOversizeAndExactCap(t *testing.T) {
	raw := transaction(1, "2026-01-01", "")
	probe, _ := json.Marshal(DetailPage{Revision: strings.Repeat("0", 64), ID: 1, Records: []json.RawMessage{json.RawMessage(raw)}})
	exact := transaction(1, "2026-01-01", strings.Repeat("x", MaxResponseBytes-len(probe)))
	for _, tc := range []struct {
		name    string
		records []string
		wantErr bool
	}{
		{"exact", []string{exact}, false},
		{"wrapper", []string{transaction(1, "2026-01-01", strings.Repeat("x", MaxResponseBytes-len(raw)-1))}, true},
		{"cursor-overhead", []string{exact, testMetadata}, true},
		{"escape", []string{strings.ReplaceAll(transaction(1, "2026-01-01", strings.Repeat("<", 180000)), `\u003c`, "<")}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path, m := buildText(t, makeStream(append([]string{testHeader}, tc.records...)...))
			i := openIndex(t, path, m)
			p, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Limit: 1})
			if tc.wantErr {
				wantError(t, err, ErrResourceLimit)
				if !reflect.DeepEqual(p, DetailPage{}) {
					t.Fatal("partial resource result")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				wire, _ := json.Marshal(p)
				if len(wire) != MaxResponseBytes || p.NextCursor != "" {
					t.Fatal("exact cap")
				}
			}
		})
	}
	// A later oversized row must not be silently skipped or terminate the prior page.
	huge := strings.ReplaceAll(detailPosting(0, 180000), "x", "<")
	path, m := buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", "small"), huge))
	i := openIndex(t, path, m)
	p, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1})
	if err != nil || len(p.Records) != 1 || p.NextCursor == "" {
		t.Fatal("lost oversized continuation", err)
	}
	p, err = i.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Cursor: p.NextCursor})
	wantError(t, err, ErrResourceLimit)
	if !reflect.DeepEqual(p, DetailPage{}) {
		t.Fatal("partial oversize continuation")
	}
}

func TestDetailRecordsCursors(t *testing.T) {
	path, m := buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", "one"), testMetadata, testPosting, transaction(2, "2026-01-01", "two")))
	i := openIndex(t, path, m)
	first, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	c, err := decodeDetailCursor(first.NextCursor, m.Revision, 1)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(c)
	invalid := []string{"!", strings.Repeat("a", 513), first.NextCursor + "=", first.NextCursor + "\n", base64Cursor(string(b) + " "), base64Cursor(string(b) + "{}"), base64Cursor("null"), base64Cursor("{}"),
		base64Cursor(strings.Replace(string(b), `"id":1`, `"id":1,"id":1`, 1)),
		base64Cursor(strings.Replace(string(b), `"id":1`, `"ID":1`, 1)),
		base64Cursor(strings.Replace(string(b), `"id":1`, `"id":1,"extra":0`, 1)),
		encodeCursor(pageCursor{Revision: m.Revision, Date: "2026-01-01", ID: 1})}
	for _, edit := range []func(*detailCursor){
		func(c *detailCursor) { c.Operation = "transactions" }, func(c *detailCursor) { c.Operation = "" },
		func(c *detailCursor) { c.ID = 2 }, func(c *detailCursor) { c.LastSeq = 0 }, func(c *detailCursor) { c.LastSeq = -1 },
		func(c *detailCursor) { c.LastSeq = 1 }, // header
		func(c *detailCursor) { c.LastSeq = 5 }, // other entry
		func(c *detailCursor) { c.LastSeq = 6 }, // footer
		func(c *detailCursor) { c.LastSeq = 999 },
		func(c *detailCursor) { c.Revision = strings.Repeat("z", 64) }, func(c *detailCursor) { c.Revision = strings.ToUpper(c.Revision) },
	} {
		changed := c
		edit(&changed)
		invalid = append(invalid, encodeDetailCursor(changed))
	}
	for n, cursor := range invalid {
		p, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Cursor: cursor})
		if err != ErrInvalidCursor || !reflect.DeepEqual(p, DetailPage{}) {
			t.Fatalf("invalid cursor %d: %v", n, err)
		}
	}
	_, err = i.DetailRecords(context.Background(), DetailPageRequest{ID: 2, Cursor: first.NextCursor})
	wantError(t, err, ErrInvalidCursor)
	_, err = i.Transactions(context.Background(), PageRequest{Cursor: first.NextCursor})
	wantError(t, err, ErrInvalidCursor)
	changed := c
	changed.Revision = strings.Repeat("b", 64)
	_, err = i.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Cursor: encodeDetailCursor(changed)})
	wantError(t, err, ErrRevisionMismatch)
	path, m = buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", "changed")))
	j := openIndex(t, path, m)
	_, err = j.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Cursor: first.NextCursor})
	wantError(t, err, ErrRevisionMismatch)
	// Canonical cursors are boundary validators, not signatures: any existing
	// record in this entry is valid, including the last (empty terminal page).
	c.LastSeq = 4
	p, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Cursor: encodeDetailCursor(c)})
	if err != nil || p.Records == nil || len(p.Records) != 0 || p.NextCursor != "" || p.ID != 1 || p.Revision != i.manifest.Revision {
		t.Fatal("terminal boundary", err)
	}
}

func TestDetailRecordsEmptyMissingNontransactionAndArguments(t *testing.T) {
	path, m := buildText(t, makeStream(testHeader))
	i := openIndex(t, path, m)
	_, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1})
	wantError(t, err, ErrNotFound)
	raw := `{"type":"directive","id":1,"value":{"Kind":"open","Date":"2026-01-01","File":"main.bean","Line":1,"Account":"Assets:Cash","Currencies":["USD"]}}`
	path, m = buildText(t, makeStream(testHeader, raw))
	i = openIndex(t, path, m)
	checkDetailPages(t, i, 0, []string{raw})
	for _, req := range []DetailPageRequest{{}, {ID: -1}, {ID: 1, Limit: -1}, {ID: 1, Limit: 501}} {
		_, err = i.DetailRecords(context.Background(), req)
		wantError(t, err, ErrInvalidRequest)
	}
	_, err = i.DetailRecords(context.Background(), DetailPageRequest{ID: 999})
	wantError(t, err, ErrNotFound)
	_, err = i.DetailRecords(nil, DetailPageRequest{ID: 1})
	wantError(t, err, ErrInvalidRequest)
	var absent *Index
	_, err = absent.DetailRecords(context.Background(), DetailPageRequest{ID: 1})
	wantError(t, err, ErrUnavailable)
	if err = i.Close(); err != nil {
		t.Fatal(err)
	}
	_, err = i.DetailRecords(context.Background(), DetailPageRequest{ID: 1})
	wantError(t, err, ErrUnavailable)
}

type detailCancelContext struct {
	context.Context
	cancel context.CancelFunc
	polls  atomic.Int64
	at     int64
}

func (c *detailCancelContext) Err() error {
	if c.polls.Add(1) == c.at {
		c.cancel()
	}
	return c.Context.Err()
}

func TestDetailRecordsCancelAndConcurrency(t *testing.T) {
	records := []string{testHeader, transaction(1, "2026-01-01", "")}
	for n := 0; n < 200; n++ {
		records = append(records, detailPosting(n, 10))
	}
	path, m := buildText(t, makeStream(records...))
	i := openIndex(t, path, m)
	for _, at := range []int64{1, 2, 20} {
		ctx, cancel := context.WithCancel(context.Background())
		cc := &detailCancelContext{Context: ctx, cancel: cancel, at: at}
		p, err := i.DetailRecords(cc, DetailPageRequest{ID: 1, Limit: 500})
		cancel()
		wantError(t, err, context.Canceled)
		if !reflect.DeepEqual(p, DetailPage{}) {
			t.Fatal("partial canceled response")
		}
		checkDetailPages(t, i, 100, records[1:])
	}
	var wg sync.WaitGroup
	for n := 0; n < 8; n++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for k := 0; k < 10; k++ {
				if _, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1}); err != nil {
					t.Error(err)
				}
				if _, err := i.Detail(context.Background(), 1); err != nil {
					t.Error(err)
				}
			}
		}()
	}
	wg.Wait()
}

func TestDetailRecordsQueryPlan(t *testing.T) {
	path, m := buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", "")))
	i := openIndex(t, path, m)
	for _, seq := range []int64{0, 2} {
		rows, err := i.db.Query("EXPLAIN QUERY PLAN "+detailRecordsQuery, int64(1), seq, 101)
		if err != nil {
			t.Fatal(err)
		}
		indexed := false
		for rows.Next() {
			plan := strings.ToUpper(rows.Text(3))
			if strings.Contains(plan, "TEMP B-TREE") || strings.Contains(plan, "SCAN ") {
				t.Fatal("unbounded/sorting plan", plan)
			}
			indexed = indexed || strings.Contains(plan, "SEARCH RECORDS USING INDEX RECORDS_ENTRY")
		}
		if err = rows.Close(); err != nil {
			t.Fatal(err)
		}
		if !indexed {
			t.Fatal("not using records_entry")
		}
	}
}

func TestDetailRecordsMetadataHeavyAndExactCounts(t *testing.T) {
	records := []string{transaction(1, "2026-01-01", "metadata-heavy")}
	for n := 0; n < 1200; n++ {
		records = append(records, fmt.Sprintf(`{"type":"metadata","entry_id":1,"posting":-1,"key":"key%04d","value":{"type":"str","value":"%s"}}`, n, strings.Repeat("x", 1000)))
	}
	path, m := buildText(t, makeStream(append([]string{testHeader}, records...)...))
	i := openIndex(t, path, m)
	_, err := i.Detail(context.Background(), 1)
	wantError(t, err, ErrResourceLimit)
	for _, tc := range []struct{ limit, count, pages int }{{0, 100, 13}, {1, 1, 1201}, {500, 500, 3}} {
		p, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Limit: tc.limit})
		if err != nil || len(p.Records) != tc.count || p.NextCursor == "" {
			t.Fatal("count limit/default not honored", tc, err)
		}
		if pages := checkDetailPages(t, i, tc.limit, records); pages != tc.pages {
			t.Fatal("incorrect count pages", pages, tc)
		}
	}
}

func TestDetailRecordsExactCapWithCursor(t *testing.T) {
	raw := transaction(1, "2026-01-01", "")
	c := detailCursor{Operation: detailRecordsOperation, Revision: strings.Repeat("0", 64), ID: 1, LastSeq: 2}
	probe, _ := json.Marshal(DetailPage{Revision: c.Revision, ID: 1, Records: []json.RawMessage{json.RawMessage(raw)}, NextCursor: encodeDetailCursor(c)})
	raw = transaction(1, "2026-01-01", strings.Repeat("x", MaxResponseBytes-len(probe)))
	path, m := buildText(t, makeStream(testHeader, raw, testPosting))
	i := openIndex(t, path, m)
	p, err := i.DetailRecords(context.Background(), DetailPageRequest{ID: 1})
	if err != nil {
		t.Fatal(err)
	}
	wire, _ := json.Marshal(p)
	if len(wire) != MaxResponseBytes || len(p.Records) != 1 || p.NextCursor == "" {
		t.Fatal("exact bound with cursor")
	}
	p, err = i.DetailRecords(context.Background(), DetailPageRequest{ID: 1, Cursor: p.NextCursor})
	if err != nil || len(p.Records) != 1 || string(p.Records[0]) != testPosting || p.NextCursor != "" {
		t.Fatal("next row dropped", err)
	}
}
