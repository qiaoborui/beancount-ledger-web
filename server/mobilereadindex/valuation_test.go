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

func valuationBridgeFixture(t *testing.T) *Bridge {
	b := newTestBridge(t)
	b.Unlock()
	manifest, m := buildFixture(t, b, "valuation", stream(
		`{"type":"directive","id":1,"value":{"Kind":"price","Date":"2026-01-01","File":"main.bean","Line":1,"Currency":"EUR","QuoteCurrency":"USD","AmountValue":{"Number":"1.0050000000000000000001","Currency":"USD"}}}`))
	openFixture(t, b, "valuation", manifest, m)
	return b
}
func TestValuationBridgeScalarExactAndCents(t *testing.T) {
	b := valuationBridgeFixture(t)
	p, e := b.reader.PriceLookup(context.Background(), readindex.PriceLookupRequest{Base: "EUR", Quote: "USD"})
	raw, _ := json.Marshal(p)
	got := b.PriceLookup(`{"base":"EUR","quote":"USD"}`)
	if e != nil || got != string(raw) || !strings.Contains(got, "1.0050000000000000000001") {
		t.Fatal(got, e)
	}
	r := readindex.LegacyCentsRequest{Basis: "legacy_cents", Amount: 123, Base: "EUR", Quote: "USD"}
	v, e := b.reader.ValueLegacyCents(context.Background(), r)
	raw, _ = json.Marshal(v)
	got = b.ValueLegacyCents(`{"basis":"legacy_cents","amount":123,"base":"EUR","quote":"USD"}`)
	if e != nil || got != string(raw) || v.Amount != 124 || !v.Found {
		t.Fatal(got, e)
	}
	got = b.ValueLegacyCents(`{"basis":"legacy_cents","amount":9223372036854775807,"base":"USD","quote":"USD"}`)
	if !strings.Contains(got, `"amount":9223372036854775807`) {
		t.Fatal(got)
	}
	wantCode(t, b.ValueLegacyCents(`{"basis":"legacy_cents","amount":9223372036854775807,"base":"EUR","quote":"USD"}`), "resource_limit")

	got = b.PriceLookup(`{"base":"MISSING","quote":"USD"}`)
	if !strings.Contains(got, `"found":false`) || strings.Contains(got, `"error"`) {
		t.Fatal(got)
	}
	got = b.ValueLegacyCents(`{"basis":"legacy_cents","amount":0,"base":"MISSING","quote":"USD"}`)
	if !strings.Contains(got, `"found":false`) || strings.Contains(got, `"error"`) {
		t.Fatal(got)
	}
}
func TestValuationBridgeStrict(t *testing.T) {
	b := valuationBridgeFixture(t)
	for _, raw := range []string{`{}`, `null`, `[]`, `{"basis":"legacy_cents"}`, `{"basis":"native_nominal","amount":1}`, `{"basis":"legacy_cents","amount":null}`, `{"basis":"legacy_cents","amount":1.5}`, `{"basis":"legacy_cents","amount":"1"}`, `{"basis":"legacy_cents","amount":9223372036854775808}`, `{"basis":"legacy_cents","amount":1,"amount":2}`, `{"basis":"legacy_cents","Amount":1}`, `{"basis":"legacy_cents","amount":1,"foo":0}`, `{"basis":"legacy_cents","amount":1} {}`, `{"basis":"legacy_cents","amount":1,"date":"2026-02-30"}`} {
		wantCode(t, b.ValueLegacyCents(raw), "invalid_request")
	}
	for _, raw := range []string{`null`, `[]`, `{"base":null}`, `{"base":1}`, `{"Base":"EUR"}`, `{"base":"A","base":"B"}`, `{"base":"A","amount":1}`, `{"date":"2026-02-30"}`, `{"base":"A\u0000B"}`, strings.Repeat(" ", 4097)} {
		wantCode(t, b.PriceLookup(raw), "invalid_request")
	}
}
func TestValuationBridgeLifecycle(t *testing.T) {
	b := valuationBridgeFixture(t)
	for _, tc := range []struct {
		query func(string) string
		req   string
	}{{b.PriceLookup, `{"base":"EUR","quote":"USD"}`}, {b.ValueLegacyCents, `{"basis":"legacy_cents","amount":123,"base":"EUR","quote":"USD"}`}} {
		b.op.Lock()
		wantCode(t, tc.query(tc.req), "busy")
		b.op.Unlock()
		b.mu.Lock()
		b.cancel()
		b.mu.Unlock()
		wantCode(t, tc.query(tc.req), "canceled")
		b.Cancel()
		if strings.Contains(tc.query(tc.req), `"error"`) {
			t.Fatal("cancel poisoned reader")
		}
	}
	b.Lock()
	wantCode(t, b.PriceLookup(`{}`), "unavailable")
	wantCode(t, b.ValueLegacyCents(`{}`), "unavailable")
	b.Unlock()
	wantCode(t, b.PriceLookup(`{}`), "unavailable")
	b.Close()
	wantCode(t, b.ValueLegacyCents(`{}`), "unavailable")
}

func TestValuationBridgeSuppressesInFlight(t *testing.T) {
	for _, valuation := range []bool{false, true} {
		for _, action := range []string{"cancel", "lock", "close"} {
			b := valuationBridgeFixture(t)
			started, release := make(chan context.Context, 1), make(chan struct{})
			output := make(chan string, 1)
			go func() {
				output <- b.run(func(ctx context.Context) (string, error) {
					var result any
					var err error
					if valuation {
						result, err = b.reader.ValueLegacyCents(ctx, readindex.LegacyCentsRequest{Basis: "legacy_cents", Amount: 123, Base: "EUR", Quote: "USD"})
					} else {
						result, err = b.reader.PriceLookup(ctx, readindex.PriceLookupRequest{Base: "EUR", Quote: "USD"})
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
				t.Fatal("privacy transition blocked")
			}
			close(release)
			raw := <-output
			<-done
			if action == "cancel" {
				wantCode(t, raw, "canceled")
				if strings.Contains(b.PriceLookup(`{"base":"EUR","quote":"USD"}`), `"error"`) {
					t.Fatal("reader poisoned")
				}
			} else {
				wantCode(t, raw, "unavailable")
				if b.reader != nil {
					t.Fatal("reader retained")
				}
			}
		}
	}
}
