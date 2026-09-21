//go:build cgo

package mobilereadindex

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/readindex"
)

func recordPage(t *testing.T, b *Bridge, req readindex.DetailPageRequest) (readindex.DetailPage, string) {
	t.Helper()
	input, _ := json.Marshal(req)
	raw := b.DetailRecords(string(input))
	var page readindex.DetailPage
	if err := json.Unmarshal([]byte(raw), &page); err != nil || page.Revision == "" {
		t.Fatalf("page: %.200s (%v)", raw, err)
	}
	if len(raw) > readindex.MaxResponseBytes || strings.HasSuffix(raw, "\n") {
		t.Fatal("wire cap/newline")
	}
	canonical, _ := json.Marshal(page)
	if string(canonical) != raw {
		t.Fatal("unexpected response envelope/encoding")
	}
	return page, raw
}

func TestDetailRecordsBridgePages(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	records := []string{tx(1, "precision 中文 \\\" <>&"),
		`{"type":"metadata","entry_id":1,"posting":-1,"key":"precise","value":{"type":"decimal","value":"123456789012345678901234567890.000000000000000000001"}}`}
	for n := 0; n < 605; n++ {
		records = append(records, fmt.Sprintf(`{"type":"posting","entry_id":1,"ordinal":%d,"value":{"account":"Assets:%s","Quantity":{"Number":"1E-99999999","Currency":"USD"}}}`, n, strings.Repeat("x", 1900)))
	}
	manifest, m := buildFixture(t, b, "many", stream(records...))
	openFixture(t, b, "many", manifest, m)
	wantCode(t, b.Detail(1), "resource_limit")
	for _, limit := range []int{0, 1, 500} {
		req := readindex.DetailPageRequest{ID: 1, Limit: limit}
		offset, pages := 0, 0
		for {
			p, raw := recordPage(t, b, req)
			bound := limit
			if bound == 0 {
				bound = 100
			}
			if p.ID != 1 || p.Revision != m.Revision || len(p.Records) == 0 || len(p.Records) > bound {
				t.Fatal("page shape")
			}
			for _, record := range p.Records {
				if offset >= len(records) {
					t.Fatal("extra records")
				}
				// Bridge encoding compacts/escapes exactly as encoding/json; raw numeric
				// and string contents survive without float conversion or re-parsing.
				want, _ := json.Marshal(json.RawMessage(records[offset]))
				if string(record) != string(want) {
					t.Fatalf("record %d changed", offset)
				}
				offset++
			}
			direct, err := b.reader.DetailRecords(context.Background(), req)
			if err != nil {
				t.Fatal(err)
			}
			want, _ := json.Marshal(direct)
			if raw != string(want) {
				t.Fatal("bridge differs from index")
			}
			pages++
			if p.NextCursor == "" {
				break
			}
			if p.NextCursor == req.Cursor || offset >= len(records) {
				t.Fatal("cursor did not advance")
			}
			req.Cursor = p.NextCursor
		}
		if offset != len(records) || pages < 2 {
			t.Fatal("incomplete paging")
		}
	}
	wantCode(t, b.Detail(1), "resource_limit") // old API remains all-or-error
}

func TestDetailRecordsBridgeStrictRequestAndCursors(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	manifest, m := buildFixture(t, b, "one", stream(tx(1, "one"), `{"type":"metadata","entry_id":1,"posting":-1,"key":"k","value":{"type":"str","value":"v"}}`, tx(2, "two")))
	openFixture(t, b, "one", manifest, m)
	for _, raw := range []string{"", `null`, `[]`, `{}`, `{"id":0}`, `{"id":-1}`, `{"id":1,"limit":-1}`, `{"id":1,"limit":501}`,
		`{"id":1,"id":1}`, `{"ID":1}`, `{"id":1,"extra":0}`, `{"id":null}`, `{"id":"1"}`, `{"id":1.0}`, `{"id":true}`, `{"id":9223372036854775808}`,
		`{"id":1,"limit":null}`, `{"id":1,"limit":"1"}`, `{"id":1,"limit":1.5}`, `{"id":1,"limit":1,"limit":1}`,
		`{"id":1,"cursor":null}`, `{"id":1,"cursor":1}`, `{"id":1,"Cursor":""}`, `{"id":1,"cursor":"","cursor":""}`,
		`{"id":1} {}`, `{"id":1} false`, `{"id":1,"cursor":"` + string([]byte{0xff}) + `"}`, strings.Repeat(" ", 4096) + `{"id":1}`,
	} {
		wantCode(t, b.DetailRecords(raw), "invalid_request")
	}
	// Exact request cap is allowed, one more byte is rejected before work.
	padded := strings.Repeat(" ", maxRequestBytes-len(`{"id":1}`)) + `{"id":1}`
	if got := b.DetailRecords(padded); strings.Contains(got, `"error"`) {
		t.Fatal(got)
	}
	wantCode(t, b.DetailRecords(" "+padded), "invalid_request")
	p, _ := recordPage(t, b, readindex.DetailPageRequest{ID: 1, Limit: 1})
	cursor := p.NextCursor
	request := func(id int64, cursor string) string {
		raw, _ := json.Marshal(readindex.DetailPageRequest{ID: id, Cursor: cursor})
		return string(raw)
	}
	wantCode(t, b.DetailRecords(request(2, cursor)), "invalid_cursor")
	wantCode(t, b.DetailRecords(request(1, strings.Repeat("a", 513))), "invalid_cursor")
	wantCode(t, b.DetailRecords(request(1, cursor+"=")), "invalid_cursor")
	decoded, _ := base64.RawURLEncoding.DecodeString(cursor)
	tampered := strings.Replace(string(decoded), `"last_seq":2`, `"last_seq":4`, 1) // entry 2
	wantCode(t, b.DetailRecords(request(1, base64.RawURLEncoding.EncodeToString([]byte(tampered)))), "invalid_cursor")
	txRaw := b.Transactions(`{"limit":1}`)
	var txPage readindex.Page
	if err := json.Unmarshal([]byte(txRaw), &txPage); err != nil || txPage.NextCursor == "" {
		t.Fatal("transaction cursor fixture", err)
	}
	wantCode(t, b.DetailRecords(request(1, txPage.NextCursor)), "invalid_cursor")
	wantCode(t, b.Transactions(fmt.Sprintf(`{"cursor":%q}`, cursor)), "invalid_cursor")
	wantCode(t, b.DetailRecords(`{"id":999}`), "not_found")
	manifest, m = buildFixture(t, b, "two", stream(tx(1, "new revision")))
	openFixture(t, b, "two", manifest, m)
	wantCode(t, b.DetailRecords(request(1, cursor)), "revision_mismatch")
	manifest, m = buildFixture(t, b, "empty", stream())
	openFixture(t, b, "empty", manifest, m)
	wantCode(t, b.DetailRecords(`{"id":1}`), "not_found")
}

func TestDetailRecordsBridgeEncodingBounds(t *testing.T) {
	for _, mode := range []string{"escaped", "retained", "oversized", "exact"} {
		t.Run(mode, func(t *testing.T) {
			b := newTestBridge(t)
			b.Unlock()
			records := []string{tx(1, "")}
			switch mode {
			case "escaped":
				for n := 0; n < 4; n++ {
					records = append(records, fmt.Sprintf(`{"type":"posting","entry_id":1,"ordinal":%d,"value":{"account":"Assets:%s","Quantity":{"Number":"1","Currency":"USD"}}}`, n, strings.Repeat("<>&\u2028\u2029", 18000)))
				}
			case "retained":
				records[0] = strings.TrimSuffix(records[0], "}") + strings.Repeat(" ", 600000) + "}"
				records = append(records, `{"type":"metadata","entry_id":1,"posting":-1,"key":"k","value":{"type":"str","value":"v"}}`)
				records[1] = strings.TrimSuffix(records[1], "}") + strings.Repeat(" ", 600000) + "}"
			case "oversized":
				records = []string{strings.ReplaceAll(tx(1, strings.Repeat("<", 180000)), `\u003c`, "<")}
			case "exact":
				probe, _ := json.Marshal(readindex.DetailPage{Revision: strings.Repeat("0", 64), ID: 1, Records: []json.RawMessage{json.RawMessage(records[0])}})
				records[0] = tx(1, strings.Repeat("x", readindex.MaxResponseBytes-len(probe)))
			}
			manifest, m := buildFixture(t, b, "bounds", stream(records...))
			openFixture(t, b, "bounds", manifest, m)
			if mode == "oversized" {
				wantCode(t, b.DetailRecords(`{"id":1}`), "resource_limit")
				return
			}
			cursor, offset, pages := "", 0, 0
			for {
				p, raw := recordPage(t, b, readindex.DetailPageRequest{ID: 1, Cursor: cursor})
				if mode == "exact" && len(raw) != readindex.MaxResponseBytes {
					t.Fatal("not exact bound")
				}
				for _, r := range p.Records {
					if offset >= len(records) {
						t.Fatal("extra row")
					}
					want, _ := json.Marshal(json.RawMessage(records[offset]))
					if string(want) != string(r) {
						t.Fatal("lost record")
					}
					offset++
				}
				pages++
				if p.NextCursor == "" {
					break
				}
				if p.NextCursor == cursor {
					t.Fatal("stuck cursor")
				}
				cursor = p.NextCursor
			}
			if offset != len(records) || (mode != "exact" && pages < 2) {
				t.Fatal("incorrect chunking")
			}
		})
	}
}

func TestDetailRecordsBridgeLifecycle(t *testing.T) {
	var absent *Bridge
	wantCode(t, absent.DetailRecords(`{"id":1}`), "unavailable")
	b := newTestBridge(t)
	wantCode(t, b.DetailRecords(`{"id":1}`), "unavailable")
	b.Unlock()
	wantCode(t, b.DetailRecords(`{"id":1}`), "unavailable")
	manifest, m := buildFixture(t, b, "one", stream(tx(1, "one")))
	openFixture(t, b, "one", manifest, m)
	b.op.Lock()
	wantCode(t, b.DetailRecords(`{"id":1}`), "busy")
	b.op.Unlock()
	b.mu.Lock()
	b.cancel()
	b.mu.Unlock()
	wantCode(t, b.DetailRecords(`{"id":1}`), "canceled")
	b.Cancel()
	recordPage(t, b, readindex.DetailPageRequest{ID: 1})
	b.Lock()
	wantCode(t, b.DetailRecords(`{"id":1}`), "unavailable")
	b.Unlock()
	wantCode(t, b.DetailRecords(`{"id":1}`), "unavailable")
	openFixture(t, b, "one", manifest, m)
	recordPage(t, b, readindex.DetailPageRequest{ID: 1})
	b.Close()
	b.Unlock()
	wantCode(t, b.DetailRecords(`{"id":1}`), "unavailable")
}

func TestDetailRecordsBridgeSuppressesInFlight(t *testing.T) {
	for _, action := range []string{"cancel", "lock", "close"} {
		t.Run(action, func(t *testing.T) {
			b := newTestBridge(t)
			b.Unlock()
			manifest, m := buildFixture(t, b, "one", stream(tx(1, "one")))
			openFixture(t, b, "one", manifest, m)
			started, release := make(chan context.Context, 1), make(chan struct{})
			output := make(chan string, 1)
			go func() {
				output <- b.run(func(ctx context.Context) (string, error) {
					p, err := b.reader.DetailRecords(ctx, readindex.DetailPageRequest{ID: 1})
					raw, encodeErr := encode(p, readindex.MaxResponseBytes)
					started <- ctx
					<-release
					if err != nil {
						return "", err
					}
					return raw, encodeErr
				})
			}()
			ctx := <-started
			wantCode(t, b.DetailRecords(`{"id":1}`), "busy")
			done := make(chan struct{})
			go func() {
				switch action {
				case "cancel":
					b.Cancel()
				case "lock":
					b.Lock()
				case "close":
					b.Close()
				}
				close(done)
			}()
			select {
			case <-ctx.Done():
			case <-time.After(5 * time.Second):
				close(release)
				t.Fatal("control blocked")
			}
			close(release)
			raw := <-output
			<-done
			if action == "cancel" {
				wantCode(t, raw, "canceled")
				recordPage(t, b, readindex.DetailPageRequest{ID: 1})
			} else {
				wantCode(t, raw, "unavailable")
				if b.reader != nil {
					t.Fatal("reader retained")
				}
			}
		})
	}
}

func TestDetailRecordsBridgeMethodType(t *testing.T) {
	method, ok := reflect.TypeOf((*Bridge)(nil)).MethodByName("DetailRecords")
	if !ok || method.Type.NumIn() != 2 || method.Type.In(1).Kind() != reflect.String || method.Type.NumOut() != 1 || method.Type.Out(0).Kind() != reflect.String {
		t.Fatal("gomobile signature")
	}
}
