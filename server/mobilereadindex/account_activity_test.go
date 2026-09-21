//go:build cgo

package mobilereadindex

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/readindex"
)

func TestAccountActivityBridgeExact(t *testing.T) {
	b := accountsBridgeFixture(t)
	for _, summary := range []bool{false, true} {
		var raw string
		var direct any
		var e error
		if summary {
			raw = b.AccountSummary(`{"account":"Assets:Cash","currency":"USD"}`)
			direct, e = b.reader.AccountSummary(context.Background(), readindex.AccountSummaryRequest{Account: "Assets:Cash", Currency: "USD"})
		} else {
			raw = b.AccountActivity(`{"account":"Assets:Cash","currency":"USD","limit":1}`)
			direct, e = b.reader.AccountActivity(context.Background(), readindex.AccountActivityRequest{Account: "Assets:Cash", Currency: "USD", Limit: 1})
		}
		encoded, _ := json.Marshal(direct)
		if e != nil || raw != string(encoded) || !strings.Contains(raw, "12345678901234567890.000000000000000000001") || !strings.Contains(raw, `"basis":"native_nominal"`) {
			t.Fatalf("%s %v", raw, e)
		}
	}
	p := b.AccountActivity(`{"account":"Assets:Other","currency":"USD"}`)
	if !strings.Contains(p, `"rows":[]`) {
		t.Fatal(p)
	}
	s := b.AccountSummary(`{"account":"Assets:Other","currency":"USD"}`)
	if !strings.Contains(s, `"current_balance":"0"`) {
		t.Fatal(s)
	}
	for _, query := range []func(string) string{b.AccountSummary, b.AccountActivity} {
		raw := query(`{"account":"Assets:Huge","currency":"USD"}`)
		wantCode(t, raw, "resource_limit")
	}
}

func TestAccountActivityBridgeStrict(t *testing.T) {
	b := accountsBridgeFixture(t)
	for _, query := range []func(string) string{b.AccountSummary, b.AccountActivity} {
		for _, raw := range []string{
			`{}`, `null`, `[]`, `{"account":"Assets:Cash"}`, `{"currency":"USD"}`,
			`{"account":"Assets:Cash","currency":null}`, `{"account":"Assets:Cash","currency":1}`,
			`{"account":"Assets:Cash","currency":"USD","currency":"EUR"}`,
			`{"account":"Assets:Cash","Currency":"USD"}`, `{"Account":"Assets:Cash","currency":"USD"}`,
			`{"account":"Assets:Cash","currency":"USD","unknown":0}`,
			`{"account":"Assets:Cash","currency":"USD"} {}`,
			`{"account":"Assets:Cash","currency":" USD"}`,
			`{"account":"Assets:Cash","currency":"USD","start":"2026-01-01"}`,
			`{"account":"Assets:Cash","currency":"USD","start":"2026-02-30","end":"2027-01-01"}`,
			`{"account":"Assets:Cash","currency":"USD","end":null}`,
			`{"account":"Assets:Cash","currency":"USD","balance":"999"}`,
			`{"account":"Assets:Cash","currency":"` + strings.Repeat("A", 1025) + `"}`,
			`{"account":"Assets:Cash","currency":"` + string([]byte{0xff}) + `"}`,
			strings.Repeat(" ", 4097),
		} {
			wantCode(t, query(raw), "invalid_request")
		}
	}
	for _, raw := range []string{`{"account":"Assets:Cash","currency":"USD","limit":-1}`, `{"account":"Assets:Cash","currency":"USD","limit":501}`, `{"account":"Assets:Cash","currency":"USD","limit":1.5}`, `{"account":"Assets:Cash","currency":"USD","limit":null}`, `{"account":"Assets:Cash","currency":"USD","cursor":null}`, `{"account":"Assets:Cash","currency":"USD","cursor":2}`} {
		wantCode(t, b.AccountActivity(raw), "invalid_request")
	}
	for _, raw := range []string{`{"account":"Assets:Cash","currency":"USD","limit":1}`, `{"account":"Assets:Cash","currency":"USD","cursor":"x"}`} {
		wantCode(t, b.AccountSummary(raw), "invalid_request")
	}
	wantCode(t, b.AccountActivity(`{"account":"Assets:Cash","currency":"USD","cursor":"bad"}`), "invalid_cursor")
}

func TestAccountActivityBridgePrivacy(t *testing.T) {
	b := accountsBridgeFixture(t)
	request := `{"account":"Assets:Cash","currency":"USD"}`
	b.Cancel()
	for _, query := range []func(string) string{b.AccountSummary, b.AccountActivity} {
		if !strings.Contains(query(request), "native_nominal") {
			t.Fatal("cancel damaged reader")
		}
	}
	b.Lock()
	for _, query := range []func(string) string{b.AccountSummary, b.AccountActivity} {
		wantCode(t, query(request), "unavailable")
	}
	b.Unlock()
	for _, query := range []func(string) string{b.AccountSummary, b.AccountActivity} {
		wantCode(t, query(request), "unavailable")
	}
	b.Close()
	for _, query := range []func(string) string{b.AccountSummary, b.AccountActivity} {
		wantCode(t, query(request), "unavailable")
	}
}

func TestAccountActivityBridgeBusyAndCanceled(t *testing.T) {
	b := accountsBridgeFixture(t)
	r := `{"account":"Assets:Cash","currency":"USD"}`
	b.op.Lock()
	wantCode(t, b.AccountSummary(r), "busy")
	wantCode(t, b.AccountActivity(r), "busy")
	b.op.Unlock()
	b.mu.Lock()
	b.cancel()
	b.mu.Unlock()
	wantCode(t, b.AccountSummary(r), "canceled")
	wantCode(t, b.AccountActivity(r), "canceled")
	b.Cancel()
	if !strings.Contains(b.AccountSummary(r), "native_nominal") || !strings.Contains(b.AccountActivity(r), "native_nominal") {
		t.Fatal("reader not reusable")
	}
}

func TestAccountActivityBridgeCursorRoundTrip(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	manifest, m := buildFixture(t, b, "activity", stream(
		tx(1, "first"), `{"type":"posting","entry_id":1,"ordinal":0,"value":{"account":"Assets:Cash","Quantity":{"Number":"1.123456789012345678901","Currency":"USD"}}}`,
		tx(2, "zero"), `{"type":"posting","entry_id":2,"ordinal":0,"value":{"account":"Assets:Cash","Quantity":{"Number":"0","Currency":"USD"}}}`,
		tx(3, "negative"), `{"type":"posting","entry_id":3,"ordinal":0,"value":{"account":"Assets:Cash","Quantity":{"Number":"-2","Currency":"USD"}}}`))
	openFixture(t, b, "activity", manifest, m)
	var first readindex.AccountActivityPage
	raw := b.AccountActivity(`{"account":"Assets:Cash","currency":"USD","limit":1}`)
	if e := json.Unmarshal([]byte(raw), &first); e != nil || len(first.Rows) != 1 || first.NextCursor == "" {
		t.Fatal(raw, e)
	}
	req := readindex.AccountActivityRequest{Account: "Assets:Cash", Currency: "USD", Limit: 1, Cursor: first.NextCursor}
	encoded, _ := json.Marshal(req)
	raw = b.AccountActivity(string(encoded))
	var second readindex.AccountActivityPage
	if e := json.Unmarshal([]byte(raw), &second); e != nil || len(second.Rows) != 1 || second.Rows[0].ID != 2 || second.Rows[0].Change != "0" || second.Rows[0].Balance != "1.123456789012345678901" {
		t.Fatal(raw, e)
	}
	req.Cursor = second.NextCursor
	encoded, _ = json.Marshal(req)
	raw = b.AccountActivity(string(encoded))
	var third readindex.AccountActivityPage
	if e := json.Unmarshal([]byte(raw), &third); e != nil || len(third.Rows) != 1 || third.Rows[0].ID != 3 || third.Rows[0].Balance != "-0.876543210987654321099" || third.NextCursor != "" {
		t.Fatal(raw, e)
	}
	req.Currency = "EUR"
	encoded, _ = json.Marshal(req)
	wantCode(t, b.AccountActivity(string(encoded)), "invalid_cursor")
}

func TestAccountActivityBridgeSuppressesInFlight(t *testing.T) {
	for _, summary := range []bool{false, true} {
		for _, action := range []string{"cancel", "lock", "close"} {
			t.Run(fmtActivityCase(summary, action), func(t *testing.T) {
				b := accountsBridgeFixture(t)
				started, release := make(chan context.Context, 1), make(chan struct{})
				output := make(chan string, 1)
				go func() {
					output <- b.run(func(ctx context.Context) (string, error) {
						var result any
						var err error
						if summary {
							result, err = b.reader.AccountSummary(ctx, readindex.AccountSummaryRequest{Account: "Assets:Cash", Currency: "USD"})
						} else {
							result, err = b.reader.AccountActivity(ctx, readindex.AccountActivityRequest{Account: "Assets:Cash", Currency: "USD"})
						}
						raw, encodeErr := encode(result, readindex.MaxResponseBytes)
						started <- ctx
						<-release
						if err != nil {
							return "", err
						}
						return raw, encodeErr
					})
				}()
				ctx := <-started
				request := `{"account":"Assets:Cash","currency":"USD"}`
				wantCode(t, b.AccountActivity(request), "busy")
				wantCode(t, b.AccountSummary(request), "busy")
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
					if !strings.Contains(b.AccountSummary(request), "native_nominal") {
						t.Fatal("reuse")
					}
				} else {
					wantCode(t, raw, "unavailable")
					if b.reader != nil {
						t.Fatal("reader retained")
					}
				}
			})
		}
	}
}
func fmtActivityCase(summary bool, action string) string {
	if summary {
		return "summary/" + action
	}
	return "activity/" + action
}
