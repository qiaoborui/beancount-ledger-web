package app

import (
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
)

func pageFixture(n int) (Config, *LedgerSnapshot) {
	cfg := Config{LedgerRoot: filepath.Join(string(filepath.Separator), "fixture", "generations", "one", "workspace"), localEntrypoint: "main.bean"}
	snapshot := &LedgerSnapshot{LedgerVersion: LedgerVersion{Version: "revision-one"}, Transactions: make([]Transaction, n)}
	for i := range snapshot.Transactions {
		snapshot.Transactions[i] = Transaction{Date: "2026-09-01", Payee: fmt.Sprintf("row-%06d", i), Narration: "Synthetic", Source: TransactionSource{File: filepath.Join(cfg.LedgerRoot, "main.bean"), Line: i + 1, Hash: fmt.Sprint(i)}, Entry: &LedgerEntry{}, Metadata: map[string]MetadataValue{}}
	}
	prepareLedgerSnapshot(snapshot)
	return cfg, snapshot
}

func TestLocalPage100kHasCompleteStablePagination(t *testing.T) {
	cfg, snapshot := pageFixture(100000)
	q := map[string]string{"limit": "500"}
	seen := map[int]bool{}
	for pages := 0; pages < 201; pages++ {
		status, data, err := localTransactionPageResponse(cfg, snapshot, q)
		if err != nil || status != 200 || len(data) > localTransactionPageBytes {
			t.Fatalf("page status=%d bytes=%d err=%v", status, len(data), err)
		}
		var page localTransactionPage
		if err := json.Unmarshal(data, &page); err != nil {
			t.Fatal(err)
		}
		for _, row := range page.Transactions {
			if seen[row.Source.Line] {
				t.Fatal("duplicate row")
			}
			seen[row.Source.Line] = true
			if row.Entry != nil || row.Metadata != nil || filepath.IsAbs(row.Source.File) {
				t.Fatal("listing leaked rich draft or absolute locator")
			}
		}
		if page.NextCursor == "" {
			break
		}
		q["cursor"] = page.NextCursor
	}
	if len(seen) != 100000 {
		t.Fatalf("rows=%d", len(seen))
	}
}

func TestLocalPageCursorScopesAndBounds(t *testing.T) {
	cfg, snapshot := pageFixture(5)
	_, data, _ := localTransactionPageResponse(cfg, snapshot, map[string]string{"limit": "1"})
	var page localTransactionPage
	_ = json.Unmarshal(data, &page)
	for _, q := range []map[string]string{{"cursor": page.NextCursor, "q": "payee:other"}, {"cursor": page.NextCursor, "start": "2026-09-02"}} {
		status, _, _ := localTransactionPageResponse(cfg, snapshot, q)
		if status != 409 {
			t.Fatalf("scope status=%d", status)
		}
	}
	snapshot.Version = "revision-two"
	if status, _, _ := localTransactionPageResponse(cfg, snapshot, map[string]string{"cursor": page.NextCursor}); status != 409 {
		t.Fatal("stale revision accepted")
	}
	snapshot.Version = "revision-one"
	cfg.LedgerRoot += "-other"
	if status, _, _ := localTransactionPageResponse(cfg, snapshot, map[string]string{"cursor": page.NextCursor}); status != 409 {
		t.Fatal("cross-workspace cursor accepted")
	}
	cfg, _ = pageFixture(1)
	for _, q := range []map[string]string{{"limit": "501"}, {"limit": "0"}, {"limit": "oops"}, {"cursor": "forged"}, {"start": "bad"}, {"start": "2026-10-01", "end": "2026-01-01"}} {
		status, _, err := localTransactionPageResponse(cfg, snapshot, q)
		if status != 400 || err == nil {
			t.Fatalf("invalid query accepted: %v", q)
		}
	}
}

func TestLocalPageByteBudgetAndFilter(t *testing.T) {
	cfg, snapshot := pageFixture(6)
	for i := range snapshot.Transactions {
		snapshot.Transactions[i].Narration = strings.Repeat("x", 350000)
	}
	snapshot.transactionsAsc = nil
	snapshot.transactionsDesc = nil
	prepareLedgerSnapshot(snapshot)
	status, data, err := localTransactionPageResponse(cfg, snapshot, nil)
	if status != 200 || err != nil {
		t.Fatal(status, err)
	}
	var page localTransactionPage
	_ = json.Unmarshal(data, &page)
	if len(page.Transactions) != 2 || page.NextCursor == "" {
		t.Fatal("byte-limited page missing continuation")
	}
	status, _, err = localTransactionPageResponse(cfg, snapshot, map[string]string{"q": "payee:absent"})
	if status != 200 || err != nil {
		t.Fatal(status, err)
	}
	cfg, snapshot = pageFixture(1)
	snapshot.Transactions[0].Narration = strings.Repeat("x", localTransactionPageBytes)
	snapshot.transactionsAsc = nil
	snapshot.transactionsDesc = nil
	prepareLedgerSnapshot(snapshot)
	if status, _, _ := localTransactionPageResponse(cfg, snapshot, nil); status != http.StatusRequestEntityTooLarge {
		t.Fatal("oversized record not rejected")
	}
}

func TestLocalPageNativeTransportRoute(t *testing.T) {
	input := localTestRequest(t)
	input.Path = "/api/ledger/transactions/page"
	data := localTestDispatch(t, input)
	var page localTransactionPage
	if err := json.Unmarshal(data, &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Transactions) == 0 || page.Revision == "" || !page.SensitiveUnlocked {
		t.Fatal("missing native page")
	}
}

func TestLocalPageRejectsReplacedCanonicalModelWithSameSourceVersion(t *testing.T) {
	cfg, first := pageFixture(5)
	_, data, err := localTransactionPageResponse(cfg, first, map[string]string{"limit": "1"})
	if err != nil {
		t.Fatal(err)
	}
	var page localTransactionPage
	if err := json.Unmarshal(data, &page); err != nil {
		t.Fatal(err)
	}
	_, replacement := pageFixture(6)
	if replacement.Version != first.Version {
		t.Fatal("fixture source versions differ")
	}
	status, _, err := localTransactionPageResponse(cfg, replacement, map[string]string{"cursor": page.NextCursor})
	if status != 409 || err == nil {
		t.Fatal("cursor accepted across transformed model replacement")
	}
}
