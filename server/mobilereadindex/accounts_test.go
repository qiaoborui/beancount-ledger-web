//go:build cgo

package mobilereadindex

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/borui/beancount-ledger-web/server/internal/readindex"
)

func accountsBridgeFixture(t *testing.T) *Bridge {
	t.Helper()
	b := newTestBridge(t)
	b.Unlock()
	manifest, m := buildFixture(t, b, "accounts", stream(
		`{"type":"directive","id":1,"value":{"Kind":"open","Date":"2025-01-01","File":"main.bean","Line":1,"Account":"Assets:Cash","Currencies":["USD","EUR"],"Booking":"STRICT"}}`,
		`{"type":"metadata","entry_id":1,"posting":-1,"key":"alias","value":{"type":"str","value":"Cash"}}`,
		`{"type":"directive","id":2,"value":{"Kind":"open","Date":"2025-01-01","File":"main.bean","Line":1,"Account":"Assets:Other"}}`,
		tx(3, "exact native units"),
		`{"type":"posting","entry_id":3,"ordinal":0,"value":{"account":"Assets:Cash","Quantity":{"Number":"12345678901234567890.000000000000000000001","Currency":"USD"},"Cost":{"Number":"1E-99999999","Currency":"EUR"}}}`,
		`{"type":"posting","entry_id":3,"ordinal":1,"value":{"account":"Assets:Cash","Quantity":{"Number":"-1.25","Currency":"EUR"}}}`,
		`{"type":"posting","entry_id":3,"ordinal":2,"value":{"account":"Assets:Huge","Quantity":{"Number":"1E999999999","Currency":"USD"}}}`))
	if m.SchemaVersion != 2 {
		t.Fatal("schema2 required")
	}
	openFixture(t, b, "accounts", manifest, m)
	return b
}

func TestAccountsBridgeExactPages(t *testing.T) {
	b := accountsBridgeFixture(t)
	raw := b.Accounts(`{"limit":1}`)
	var p readindex.AccountsPage
	if e := json.Unmarshal([]byte(raw), &p); e != nil || len(p.Accounts) != 1 || p.Accounts[0].OpenID != 1 || p.NextCursor == "" {
		t.Fatalf("%s %v", raw, e)
	}
	direct, e := b.reader.Accounts(context.Background(), readindex.PageRequest{Limit: 1})
	if e != nil {
		t.Fatal(e)
	}
	encoded, _ := json.Marshal(direct)
	if string(encoded) != raw {
		t.Fatal("not direct JSON")
	}
	req, _ := json.Marshal(readindex.PageRequest{Cursor: p.NextCursor})
	raw = b.Accounts(string(req))
	if e = json.Unmarshal([]byte(raw), &p); e != nil || len(p.Accounts) != 1 || p.Accounts[0].Account != "Assets:Other" || strings.Contains(raw, "next_cursor") {
		t.Fatal(raw)
	}
	// Use a fresh target since omitempty fields retain old values on Unmarshal.
	raw = b.AccountBalances(`{"account":"Assets:Cash","limit":1}`)
	var bp readindex.AccountBalancesPage
	if e = json.Unmarshal([]byte(raw), &bp); e != nil || len(bp.Balances) != 1 || bp.Balances[0].Currency != "EUR" || bp.Balances[0].Quantity != "-1.25" || bp.NextCursor == "" || bp.Basis != "native_nominal" {
		t.Fatal(raw)
	}
	directB, e := b.reader.AccountBalances(context.Background(), readindex.AccountBalancesRequest{Account: "Assets:Cash", Limit: 1})
	if e != nil {
		t.Fatal(e)
	}
	encoded, _ = json.Marshal(directB)
	if string(encoded) != raw {
		t.Fatal("balance differs")
	}
	wantCode(t, b.Accounts(`{"cursor":"`+bp.NextCursor+`"}`), "invalid_cursor")
	req, _ = json.Marshal(readindex.AccountBalancesRequest{Account: "Assets:Cash", Cursor: bp.NextCursor})
	raw = b.AccountBalances(string(req))
	bp = readindex.AccountBalancesPage{}
	if e = json.Unmarshal([]byte(raw), &bp); e != nil || len(bp.Balances) != 1 || bp.Balances[0].Quantity != "12345678901234567890.000000000000000000001" || bp.NextCursor != "" {
		t.Fatal(raw)
	}
	wantCode(t, b.AccountBalances(`{"account":"Assets:Huge"}`), "resource_limit")
	if len(raw) > readindex.MaxResponseBytes || strings.HasSuffix(raw, "\n") {
		t.Fatal("wire contract")
	}
	b.Cancel() // selected reader remains usable
	if strings.Contains(b.Accounts(`{}`), `"error"`) {
		t.Fatal("cancel poisoned catalog")
	}
	b.Lock()
	wantCode(t, b.Accounts(`{}`), "unavailable")
	wantCode(t, b.AccountBalances(`{"account":"Assets:Cash"}`), "unavailable")
	b.Unlock()
	wantCode(t, b.Accounts(`{}`), "unavailable")
	wantCode(t, b.AccountBalances(`{"account":"Assets:Cash"}`), "unavailable")
}

func TestAccountsBridgeStrictRequests(t *testing.T) {
	b := accountsBridgeFixture(t)
	for _, raw := range []string{"", `null`, `[]`, `{"limit":null}`, `{"limit":1.0}`, `{"limit":"1"}`, `{"limit":true}`, `{"limit":-1}`, `{"limit":501}`, `{"limit":1,"limit":1}`, `{"Limit":1}`, `{"limit":9223372036854775808}`, `{"unknown":0}`, `{"cursor":null}`, `{"cursor":1}`, `{"Cursor":""}`, `{"cursor":"","cursor":""}`, `{} {}`, `{} false`, strings.Repeat(" ", 4097) + `{}`, `{"cursor":"` + string([]byte{255}) + `"}`} {
		wantCode(t, b.Accounts(raw), "invalid_request")
	}
	for _, raw := range []string{"", `null`, `[]`, `{}`, `{"account":""}`, `{"account":null}`, `{"account":1}`, `{"Account":"A"}`, `{"account":"A","account":"B"}`, `{"account":"A","unknown":0}`, `{"account":"A","start":null}`, `{"account":"A","start":2026}`, `{"account":"A","end":false}`, `{"account":"A","Start":"2026-01-01"}`, `{"account":"A","start":"2026-01-01","start":"2026-01-01"}`, `{"account":"A","start":"2026-01-01"}`, `{"account":"A","start":"2026-1-1","end":"2027-01-01"}`, `{"account":"A","limit":null}`, `{"account":"A","limit":501}`, `{"account":"A","limit":1.5}`, `{"account":"A","cursor":null}`, `{"account":"A","cursor":false}`, `{"account":"A","cursor":"","cursor":""}`, `{"account":"A"} {}`, `{"account":"` + strings.Repeat("a", 1025) + `"}`, `{"account":"A\n"}`, `{"account":"` + string([]byte{255}) + `"}`} {
		wantCode(t, b.AccountBalances(raw), "invalid_request")
	}
	for _, call := range []struct {
		fn      func(string) string
		request string
	}{{b.Accounts, `{}`}, {b.AccountBalances, `{"account":"Assets:Cash"}`}} {
		padded := strings.Repeat(" ", maxRequestBytes-len(call.request)) + call.request
		if strings.Contains(call.fn(padded), `"error"`) {
			t.Fatal("exact request cap")
		}
		wantCode(t, call.fn(" "+padded), "invalid_request")
		b.op.Lock()
		wantCode(t, call.fn(call.request), "busy")
		b.op.Unlock()
	}
	wantCode(t, b.Accounts(`{"cursor":"!"}`), "invalid_cursor")
	wantCode(t, b.AccountBalances(`{"account":"Assets:Cash","cursor":"!"}`), "invalid_cursor")
}

func TestAccountBridgeCancellationAndUnavailable(t *testing.T) {
	var absent *Bridge
	wantCode(t, absent.Accounts(`{}`), "unavailable")
	wantCode(t, absent.AccountBalances(`{"account":"Assets:A"}`), "unavailable")
	b := accountsBridgeFixture(t)
	b.mu.Lock()
	b.cancel()
	b.mu.Unlock()
	wantCode(t, b.Accounts(`{}`), "canceled")
	wantCode(t, b.AccountBalances(`{"account":"Assets:Cash"}`), "canceled")
	b.Cancel()
	if strings.Contains(b.AccountBalances(`{"account":"Assets:Cash"}`), `"error"`) {
		t.Fatal("cancellation poisoned reader")
	}
	b.Close()
	b.Unlock()
	wantCode(t, b.Accounts(`{}`), "unavailable")
	wantCode(t, b.AccountBalances(`{"account":"Assets:Cash"}`), "unavailable")
}
