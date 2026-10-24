package app

import (
	"encoding/json"
	"testing"
)

// investmentHeavySnapshot returns a snapshot whose investment lot detail dwarfs
// every other bootstrap field: the shape that pushed synthetic 10k ledgers past
// the page byte budget (838 KiB of 990 KiB in the measured case).
func investmentHeavySnapshot(t *testing.T, lots int) (Config, *LedgerSnapshot) {
	t.Helper()
	cfg, snapshot := pageFixture(4)
	snapshot.Accounts = []Account{
		{Account: "Assets:Broker", Active: true, Currency: "NVDA"},
		{Account: "Assets:Cash", Active: true, Currency: "USD"},
	}
	snapshot.Prices = make([]Price, 0, lots)
	for i := 0; i < lots; i++ {
		snapshot.Prices = append(snapshot.Prices, Price{
			Date: "2026-09-01", Currency: "NVDA", Amount: 200 + i, QuoteCurrency: "USD",
		})
	}
	prepareLedgerSnapshot(snapshot)
	return cfg, snapshot
}

// The native bootstrap page feeds Swift, whose LedgerBootstrap has no member for
// investment detail: the iOS app fetches it from its own endpoint. Serializing it
// here spent the page byte budget on bytes the client discarded.
func TestLocalBootstrapPageOmitsInvestmentDetail(t *testing.T) {
	cfg, snapshot := investmentHeavySnapshot(t, 400)
	status, raw, err := localBootstrapPageResponse(cfg, snapshot, map[string]string{
		"start": "2026-09-01", "end": "2026-10-01", "today": "2026-09-15",
	})
	if err != nil {
		t.Fatalf("bootstrap page: %v", err)
	}
	if status != 200 {
		t.Fatalf("status = %d, want 200", status)
	}
	var payload struct {
		Bootstrap json.RawMessage `json:"bootstrap"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(payload.Bootstrap, &fields); err != nil {
		t.Fatalf("decode bootstrap: %v", err)
	}
	if value, ok := fields["investments"]; ok {
		t.Fatalf("native bootstrap carries investments (%d bytes): %s", len(value), value)
	}
	if len(raw) > localTransactionPageBytes-4096 {
		t.Fatalf("page size %d exceeds the %d byte budget", len(raw), localTransactionPageBytes-4096)
	}
}

// The legacy /api/ledger/bootstrap contract is what the web client reads
// (`useLedgerData.ts` caches `data.investments`), so it must keep the field.
func TestLegacyBootstrapKeepsInvestmentDetail(t *testing.T) {
	cfg, snapshot := investmentHeavySnapshot(t, 400)
	result := buildLedgerBootstrap(snapshot, "2026-09-01", "2026-10-01", true, "", "2026-09-15", true, true, false)
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &fields); err != nil {
		t.Fatalf("decode: %v", err)
	}
	value, ok := fields["investments"]
	if !ok {
		t.Fatal("legacy bootstrap lost its investments field")
	}
	if len(value) == 0 {
		t.Fatal("legacy bootstrap investments is empty")
	}
	_ = cfg
}
