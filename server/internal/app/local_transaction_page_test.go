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

func TestLocalTransactionDetailRequiresExactSourceAndKeepsMetadata(t *testing.T) {
	cfg, snapshot := pageFixture(2)
	txn := snapshot.Transactions[0]
	query := map[string]string{"file": "main.bean", "line": fmt.Sprint(txn.Source.Line), "hash": txn.Source.Hash}
	status, raw, err := localTransactionDetailResponse(cfg, snapshot, query)
	if status != 200 || err != nil {
		t.Fatal(status, err)
	}
	var detail Transaction
	if err := json.Unmarshal(raw, &detail); err != nil {
		t.Fatal(err)
	}
	if detail.Source.File != "main.bean" || detail.Entry == nil || detail.Postings == nil {
		t.Fatal("invalid detail projection")
	}
	query["hash"] = "stale"
	if status, _, _ := localTransactionDetailResponse(cfg, snapshot, query); status != 409 {
		t.Fatal("stale detail accepted")
	}
	query["file"] = "../main.bean"
	if status, _, _ := localTransactionDetailResponse(cfg, snapshot, query); status != 400 {
		t.Fatal("path escape accepted")
	}
}

func TestLocalPageStructuredFiltersBindCursor(t *testing.T) {
	cfg, snapshot := pageFixture(3)
	_, raw, err := localTransactionPageResponse(cfg, snapshot, map[string]string{"limit": "1"})
	if err != nil {
		t.Fatal(err)
	}
	var page localTransactionPage
	_ = json.Unmarshal(raw, &page)
	for _, key := range []string{"account", "tag", "kind"} {
		value := "changed"
		if key == "kind" {
			value = "expense"
		}
		if status, _, _ := localTransactionPageResponse(cfg, snapshot, map[string]string{"cursor": page.NextCursor, key: value}); status != 409 {
			t.Fatalf("filter %s did not invalidate cursor", key)
		}
	}
}

func TestLocalHistoryEvidenceProjectionIsBoundedAndCursorScoped(t *testing.T) {
	cfg, snapshot := pageFixture(8)
	for i := range snapshot.Transactions {
		var metadata map[string]MetadataValue
		if err := json.Unmarshal([]byte(`{"method":"Synthetic payment","cardLast4":"1234","source":"wechat","private":"must-not-be-returned"}`), &metadata); err != nil {
			t.Fatal(err)
		}
		snapshot.Transactions[i].Metadata = metadata
	}
	// Fixture sorted views were created before metadata assignment.
	snapshot.transactionsAsc, snapshot.transactionsDesc = sortedTransactionIndices(snapshot.Transactions)
	q := map[string]string{"limit": "2"}
	status, data, err := localTransactionPageProjection(cfg, snapshot, q, true)
	if status != 200 || err != nil || len(data) > localTransactionPageBytes {
		t.Fatalf("status=%d err=%v", status, err)
	}
	var page localTransactionPage
	if err := json.Unmarshal(data, &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Transactions) != 2 || page.NextCursor == "" {
		t.Fatal("missing continuation")
	}
	for _, txn := range page.Transactions {
		if len(txn.Metadata) != 3 || txn.Entry != nil || filepath.IsAbs(txn.Source.File) {
			t.Fatal("wrong evidence projection")
		}
	}
	if strings.Contains(string(data), "must-not-be-returned") {
		t.Fatal("unneeded metadata leaked")
	}
	q["cursor"] = page.NextCursor
	if status, _, _ := localTransactionPageResponse(cfg, snapshot, q); status != 409 {
		t.Fatal("history cursor accepted by ordinary page")
	}
	if status, _, err := localTransactionPageProjection(cfg, snapshot, q, true); status != 200 || err != nil {
		t.Fatal("history cursor failed", status, err)
	}
	snapshot.Version = "changed"
	if status, _, _ := localTransactionPageProjection(cfg, snapshot, q, true); status != 409 {
		t.Fatal("stale history cursor accepted")
	}
}

func TestLocalHistoryMetadataEnforcesByteBudgetWithoutTruncation(t *testing.T) {
	cfg, snapshot := pageFixture(6)
	var value MetadataValue
	raw, _ := json.Marshal(strings.Repeat("m", 300000))
	if err := json.Unmarshal(raw, &value); err != nil {
		t.Fatal(err)
	}
	for i := range snapshot.Transactions {
		snapshot.Transactions[i].Metadata = map[string]MetadataValue{"method": value}
	}
	snapshot.transactionsAsc, snapshot.transactionsDesc = sortedTransactionIndices(snapshot.Transactions)
	seen := map[int]bool{}
	q := map[string]string{"limit": "500"}
	for {
		status, data, err := localTransactionPageProjection(cfg, snapshot, q, true)
		if status != 200 || err != nil || len(data) > localTransactionPageBytes {
			t.Fatal(status, len(data), err)
		}
		var page localTransactionPage
		if err := json.Unmarshal(data, &page); err != nil {
			t.Fatal(err)
		}
		if len(page.Transactions) > 3 {
			t.Fatal("byte budget not applied")
		}
		for _, txn := range page.Transactions {
			if seen[txn.Source.Line] {
				t.Fatal("duplicate")
			}
			seen[txn.Source.Line] = true
		}
		if page.NextCursor == "" {
			break
		}
		q["cursor"] = page.NextCursor
	}
	if len(seen) != 6 {
		t.Fatal("omission")
	}
	raw, _ = json.Marshal(strings.Repeat("m", localTransactionPageBytes))
	if err := json.Unmarshal(raw, &value); err != nil {
		t.Fatal(err)
	}
	snapshot.Transactions[snapshot.transactionsDesc[0]].Metadata = map[string]MetadataValue{"method": value}
	if status, _, _ := localTransactionPageProjection(cfg, snapshot, nil, true); status != 413 {
		t.Fatal("oversize evidence not rejected")
	}
}

func candidatePageQuery(values map[string]string) map[string]string {
	query := map[string]string{"dialect": localNativeCandidatesDialect}
	for key, value := range values {
		query[key] = value
	}
	return query
}

func readCandidatePage(t *testing.T, cfg Config, snapshot *LedgerSnapshot, query map[string]string) localTransactionPage {
	t.Helper()
	status, raw, err := localTransactionPageResponse(cfg, snapshot, candidatePageQuery(query))
	if status != http.StatusOK || err != nil || len(raw) > localTransactionPageBytes {
		t.Fatalf("candidate page: status=%d bytes=%d err=%v", status, len(raw), err)
	}
	var page localTransactionPage
	if err := json.Unmarshal(raw, &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Transactions) > localTransactionPageMax || page.Revision == "" || !page.SensitiveUnlocked {
		t.Fatal("invalid candidate envelope")
	}
	return page
}

func TestLocalCandidatePagePreservesExactUnicodeAndPresentation(t *testing.T) {
	// Candidates must not apply Unicode guards, normalization, Character
	// matching, case folding, or arithmetic classification.
	texts := []string{
		"✁\u200d✁", "\U00011a3aa", "a" + strings.Repeat("\u0301", 128),
		"Café", "Cafe\u0301", "क्\u200dष", "İΣ\u00a0\u200b", "\U0001fae9",
	}
	cfg, snapshot := pageFixture(len(texts))
	maxInt := int(^uint(0) >> 1)
	for i, text := range texts {
		txn := &snapshot.Transactions[i]
		txn.Payee, txn.Narration = text, "payee:literal "+text
		txn.Tags = []string{text, "Café", "Cafe\u0301", text}
		txn.Links = []string{text}
		txn.Postings = []Posting{
			{Account: "Income:" + text, Amount: maxInt, Currency: "CNY"},
			{Account: "Income:" + text, Amount: 1, Currency: "CNY"},
			{Account: "Expenses:" + text, Amount: -maxInt - 1, Currency: "CNY"},
			{Account: "Expenses:" + text, Amount: -1, Currency: "CNY"},
		}
		txn.Metadata = map[string]MetadataValue{"type": "商品退款 " + text, "private": "not for listing", "method": "history-only"}
		txn.Source.GitSHA = "exact-source-sha"
	}
	before, err := json.Marshal(snapshot.Transactions)
	if err != nil {
		t.Fatal(err)
	}
	page := readCandidatePage(t, cfg, snapshot, nil)
	if len(page.Transactions) != len(texts) || page.NextCursor != "" {
		t.Fatal("candidates were filtered")
	}
	for i, row := range page.Transactions {
		want := snapshot.Transactions[i]
		want.Entry = nil
		want.Source.File = "main.bean"
		want.Metadata = map[string]MetadataValue{"type": want.Metadata["type"]}
		gotJSON, _ := json.Marshal(row)
		wantJSON, _ := json.Marshal(want)
		if string(gotJSON) != string(wantJSON) {
			t.Fatalf("candidate %d was changed: got %s want %s", i, gotJSON, wantJSON)
		}
	}
	after, _ := json.Marshal(snapshot.Transactions)
	if string(before) != string(after) {
		t.Fatal("candidate projection mutated the read model")
	}
	for _, value := range []any{"", "商品退款", true, 123, map[string]any{"value": "退款"}, []any{"退款"}, nil} {
		snapshot.Transactions[0].Metadata["type"] = value
		page := readCandidatePage(t, cfg, snapshot, nil)
		row := page.Transactions[0]
		if text, ok := value.(string); ok {
			if len(row.Metadata) != 1 || row.Metadata["type"] != text {
				t.Fatalf("string evidence changed: %#v", row.Metadata)
			}
		} else if row.Metadata != nil {
			t.Fatalf("non-string evidence retained: %#v", row.Metadata)
		}
	}
	delete(snapshot.Transactions[0].Metadata, "type")
	page = readCandidatePage(t, cfg, snapshot, nil)
	if page.Transactions[0].Metadata != nil {
		t.Fatal("missing type must not be synthesized")
	}
}

func TestLocalCandidatePageDateOnlyCompletePagination(t *testing.T) {
	cfg, snapshot := pageFixture(1205)
	snapshot.Transactions[0].Date = "2026-08-31"
	snapshot.Transactions[1204].Date = "2026-10-01"
	snapshot.Transactions[1203].Date = "2026-09-30"
	snapshot.transactionsAsc, snapshot.transactionsDesc = sortedTransactionIndices(snapshot.Transactions)
	query := map[string]string{"start": "2026-09-01", "end": "2026-10-01", "limit": "500"}
	seen := map[int]bool{}
	for pageIndex, wantCount := range []int{500, 500, 203} {
		page := readCandidatePage(t, cfg, snapshot, query)
		if len(page.Transactions) != wantCount {
			t.Fatalf("page %d rows=%d want=%d", pageIndex, len(page.Transactions), wantCount)
		}
		for _, row := range page.Transactions {
			wantLine := len(seen) + 1
			if len(seen) == 0 {
				wantLine = 1204 // Latest day first; source lines ascend within each day.
			}
			if row.Source.Line != wantLine || seen[row.Source.Line] || row.Source.File != "main.bean" || row.Source.Hash != fmt.Sprint(wantLine-1) {
				t.Fatalf("missing/reordered/duplicate candidate or changed locator: %+v", row.Source)
			}
			if row.Entry != nil || row.Postings == nil {
				t.Fatal("invalid candidate projection")
			}
			seen[row.Source.Line] = true
		}
		if (page.NextCursor == "") != (pageIndex == 2) {
			t.Fatal("wrong continuation")
		}
		query["cursor"] = page.NextCursor
	}
	if len(seen) != 1203 {
		t.Fatal("incomplete range")
	}
	if page := readCandidatePage(t, cfg, snapshot, nil); len(page.Transactions) != localTransactionPageDefault || page.NextCursor == "" {
		t.Fatal("default limit changed")
	}
	if page := readCandidatePage(t, cfg, snapshot, map[string]string{"start": "2027-01-01"}); len(page.Transactions) != 0 || page.NextCursor != "" || page.Transactions == nil {
		t.Fatal("invalid empty range page")
	}
}

func TestLocalCandidatePageRejectsAllFilterPresenceAndInvalidBounds(t *testing.T) {
	cfg, snapshot := pageFixture(1)
	for _, key := range []string{"q", "account", "tag", "tags", "kind"} {
		for _, value := range []string{"", "all", "[]", "✁\u200d✁"} {
			t.Run(key+"/"+value, func(t *testing.T) {
				status, raw, err := localTransactionPageResponse(cfg, snapshot, candidatePageQuery(map[string]string{key: value}))
				if status != 400 || raw != nil || err == nil {
					t.Fatalf("filter accepted: status=%d err=%v", status, err)
				}
			})
		}
	}
	for _, values := range []map[string]string{
		{"limit": "501"}, {"limit": "0"}, {"limit": "-1"}, {"limit": "oops"},
		{"start": "2026-02-30"}, {"end": "bad"},
		{"start": "2026-10-01", "end": "2026-09-01"},
		{"start": "2026-09-01", "end": "2026-09-01"}, {"cursor": "forged"},
		{"dialect": ""}, {"dialect": "native-candidates-v2"},
	} {
		if status, raw, err := localTransactionPageResponse(cfg, snapshot, candidatePageQuery(values)); status != 400 || raw != nil || err == nil {
			t.Fatalf("invalid bounds accepted: %v status=%d err=%v", values, status, err)
		}
	}
	if status, raw, err := localTransactionPageProjection(cfg, snapshot, candidatePageQuery(nil), true); status != 400 || raw != nil || err == nil {
		t.Fatal("history accepted candidate dialect", status, err)
	}
}

func TestLocalCandidatePageCursorIdentityAndDialectIsolation(t *testing.T) {
	cfg, snapshot := pageFixture(6)
	page := readCandidatePage(t, cfg, snapshot, map[string]string{"limit": "1"})
	for _, change := range []map[string]string{{"start": "2026-09-01"}, {"end": "2026-10-01"}} {
		change["cursor"] = page.NextCursor
		if status, raw, err := localTransactionPageResponse(cfg, snapshot, candidatePageQuery(change)); status != 409 || raw != nil || err == nil {
			t.Fatal("range change accepted", change, status, err)
		}
	}
	query := candidatePageQuery(map[string]string{"cursor": page.NextCursor})
	for _, mutate := range []func(){func() { snapshot.Version += "-new" }, func() { snapshot.localReadModelID++ }, func() { cfg.LedgerRoot += "-new" }, func() { cfg.localEntrypoint = "other.bean" }} {
		oldCfg, oldVersion, oldID := cfg, snapshot.Version, snapshot.localReadModelID
		mutate()
		if status, raw, err := localTransactionPageResponse(cfg, snapshot, query); status != 409 || raw != nil || err == nil {
			t.Fatal("changed identity accepted", status, err)
		}
		cfg, snapshot.Version, snapshot.localReadModelID = oldCfg, oldVersion, oldID
	}
	_, replacement := pageFixture(6)
	if status, _, err := localTransactionPageResponse(cfg, replacement, query); status != 409 || err == nil {
		t.Fatal("same-source model replacement accepted", status, err)
	}
	// Page size is not part of identity; explicit default dates are equivalent.
	next := readCandidatePage(t, cfg, snapshot, map[string]string{"cursor": page.NextCursor, "limit": "2", "start": "0001-01-01", "end": "9999-12-31"})
	if len(next.Transactions) != 2 || next.Transactions[0].Source.Line != 2 {
		t.Fatal("valid continuation failed")
	}
	// The superseded matcher dialect is unsupported, even with a valid candidate
	// cursor; it must fail before attempting cursor scope validation.
	for _, cursor := range []string{"", page.NextCursor} {
		q := map[string]string{"dialect": "native-list-v1", "cursor": cursor}
		if status, raw, err := localTransactionPageResponse(cfg, snapshot, q); status != http.StatusBadRequest || raw != nil || err == nil || err.Error() != "unsupported transaction page dialect" {
			t.Fatal("removed native-list dialect was not rejected", status, err)
		}
	}
	for _, target := range []struct {
		name     string
		query    map[string]string
		evidence bool
	}{
		{"legacy", nil, false},
		{"history", nil, true},
	} {
		t.Run(target.name, func(t *testing.T) {
			q := map[string]string{"limit": "1"}
			for key, value := range target.query {
				q[key] = value
			}
			status, raw, err := localTransactionPageProjection(cfg, snapshot, q, target.evidence)
			if status != 200 || err != nil {
				t.Fatal(status, err)
			}
			var other localTransactionPage
			if err := json.Unmarshal(raw, &other); err != nil || other.NextCursor == "" {
				t.Fatal("missing foreign cursor", err)
			}
			if status, raw, err := localTransactionPageResponse(cfg, snapshot, candidatePageQuery(map[string]string{"cursor": other.NextCursor})); status != 409 || raw != nil || err == nil {
				t.Fatal("foreign cursor accepted by candidates", status, err)
			}
			q["cursor"] = page.NextCursor
			if status, raw, err := localTransactionPageProjection(cfg, snapshot, q, target.evidence); status != 409 || raw != nil || err == nil {
				t.Fatal("candidate cursor accepted by other projection", status, err)
			}
		})
	}
	for _, cursor := range []string{
		page.NextCursor + "tampered",
		signLocalCursor(localTransactionCursor{Scope: "wrong", Offset: 1}),
	} {
		if status, raw, err := localTransactionPageResponse(cfg, snapshot, candidatePageQuery(map[string]string{"cursor": cursor})); (status != 400 && status != 409) || raw != nil || err == nil {
			t.Fatal("invalid cursor accepted", status, err)
		}
	}
	decoded, err := decodeLocalCursor(page.NextCursor)
	if err != nil {
		t.Fatal(err)
	}
	decoded.Offset = len(snapshot.Transactions) + 1
	if status, raw, err := localTransactionPageResponse(cfg, snapshot, candidatePageQuery(map[string]string{"cursor": signLocalCursor(decoded)})); status != 400 || raw != nil || err == nil {
		t.Fatal("invalid cursor position accepted", status, err)
	}
}

func TestLocalCandidatePageByteBudgetIncludesEscapedEvidence(t *testing.T) {
	for _, field := range []string{"narration", "type"} {
		t.Run(field, func(t *testing.T) {
			cfg, snapshot := pageFixture(7)
			// JSON escapes each '<' to six bytes. Budget encoded bytes, not text length.
			text := strings.Repeat("<", 60000)
			for i := range snapshot.Transactions {
				if field == "type" {
					snapshot.Transactions[i].Metadata["type"] = text
				} else {
					snapshot.Transactions[i].Narration = text
				}
			}
			query := map[string]string{"limit": "500"}
			count := 0
			for pageIndex := 0; pageIndex < 4; pageIndex++ {
				page := readCandidatePage(t, cfg, snapshot, query)
				wantCount := 2
				if pageIndex == 3 {
					wantCount = 1
				}
				if len(page.Transactions) != wantCount {
					t.Fatal("wrong byte-limited row count", len(page.Transactions))
				}
				for _, txn := range page.Transactions {
					if txn.Source.Line != count+1 {
						t.Fatal("byte continuation skipped/repeated a candidate")
					}
					count++
					if (field == "type" && txn.Metadata["type"] != text) || (field == "narration" && txn.Narration != text) {
						t.Fatal("row truncated")
					}
				}
				if (page.NextCursor == "") != (pageIndex == 3) {
					t.Fatal("wrong byte continuation")
				}
				query["cursor"] = page.NextCursor
			}
			for _, oversized := range []string{strings.Repeat("<", localTransactionPageBytes/6), strings.Repeat("x", localTransactionPageBytes+1)} {
				cfg, snapshot := pageFixture(1)
				if field == "type" {
					snapshot.Transactions[0].Metadata["type"] = oversized
				} else {
					snapshot.Transactions[0].Narration = oversized
				}
				if status, raw, err := localTransactionPageResponse(cfg, snapshot, candidatePageQuery(nil)); status != 413 || raw != nil || err == nil {
					t.Fatal("oversized row accepted", status, err)
				}
			}
		})
	}
}

func TestLocalCandidatePageSourceAndLegacyProjectionUnchanged(t *testing.T) {
	cfg, snapshot := pageFixture(1)
	snapshot.Transactions[0].Metadata = map[string]MetadataValue{"type": "商品退款", "method": "cash", "private": "no"}
	for _, file := range []string{filepath.Join(cfg.LedgerRoot, "transactions", "2026.bean"), "relative.bean"} {
		snapshot.Transactions[0].Source.File = file
		page := readCandidatePage(t, cfg, snapshot, nil)
		want := "relative.bean"
		if filepath.IsAbs(file) {
			want = "transactions/2026.bean"
		}
		if page.Transactions[0].Source.File != want {
			t.Fatal("source behavior changed")
		}
	}
	for _, history := range []bool{false, true} {
		status, raw, err := localTransactionPageProjection(cfg, snapshot, nil, history)
		if status != 200 || err != nil {
			t.Fatal(status, err)
		}
		var page localTransactionPage
		if err := json.Unmarshal(raw, &page); err != nil || len(page.Transactions) != 1 {
			t.Fatal("missing legacy row", err)
		}
		row := page.Transactions[0]
		if history {
			if len(row.Metadata) != 1 || row.Metadata["method"] != "cash" {
				t.Fatal("history projection changed")
			}
		} else if row.Metadata != nil {
			t.Fatal("legacy listing gained candidate evidence")
		}
		if row.Entry != nil {
			t.Fatal("editor entry leaked")
		}
	}
	snapshot.Transactions[0].Source.File = filepath.Join(cfg.LedgerRoot+"-other", "main.bean")
	if status, raw, err := localTransactionPageResponse(cfg, snapshot, candidatePageQuery(nil)); status != 500 || raw != nil || err == nil {
		t.Fatal("outside-workspace source accepted", status, err)
	}
}

func TestLocalCandidatePageTransportAndHistoryRejection(t *testing.T) {
	input := localTestRequest(t)
	input.Path = "/api/ledger/transactions/page"
	input.Query = candidatePageQuery(nil)
	raw := localTestDispatch(t, input)
	var page localTransactionPage
	if err := json.Unmarshal(raw, &page); err != nil || len(page.Transactions) == 0 || page.Revision == "" {
		t.Fatal("missing transported candidates", err)
	}
	for _, key := range []string{"q", "account", "tag", "tags", "kind"} {
		input.Query = candidatePageQuery(map[string]string{key: ""})
		if status, raw, err := DispatchLocalRequest(input); status != 400 || raw != nil || err == nil {
			t.Fatal("transport accepted filter presence", key, status, err)
		}
	}
	input.Query = map[string]string{"dialect": "native-list-v1"}
	if status, raw, err := DispatchLocalRequest(input); status != http.StatusBadRequest || raw != nil || err == nil || err.Error() != "unsupported transaction page dialect" {
		t.Fatal("transport accepted removed native-list dialect", status, err)
	}
	input.Path = "/api/ledger/transactions/history-page"
	input.WorkspaceRoot = "does-not-exist"
	for _, dialect := range []string{"", localNativeCandidatesDialect, "native-list-v1", "other"} {
		input.Query = map[string]string{"dialect": dialect}
		if status, raw, err := DispatchLocalRequest(input); status != 400 || raw != nil || err == nil || err.Error() != "dialect is not valid on history-page" {
			t.Fatal("history did not reject dialect before workspace access", dialect, status, err)
		}
		if status, raw, err := localTransactionPageProjection(Config{}, nil, input.Query, true); status != 400 || raw != nil || err == nil || err.Error() != "dialect is not valid on history-page" {
			t.Fatal("history projection did not reject dialect before snapshot access", dialect, status, err)
		}
	}
}

func TestLocalSearchCandidatesPreserveAllMetadataWithoutChangingListDialect(t *testing.T) {
	cfg, snapshot := pageFixture(3)
	for i := range snapshot.Transactions {
		snapshot.Transactions[i].Metadata = map[string]MetadataValue{
			"type": "商品退款", "receipt": "ＣＡＦÉ Cafe\u0301 ✁\u200d✁", "number": 12.5,
			"bool": true, "null-key": nil, "method": "exact", "account": "Expenses:Food",
		}
	}
	before, _ := json.Marshal(snapshot.Transactions)
	page := readCandidatePage(t, cfg, snapshot, map[string]string{"dialect": localNativeSearchCandidatesDialect})
	for i, row := range page.Transactions {
		want := snapshot.Transactions[i]
		want.Entry = nil
		want.Postings = []Posting{}
		want.Source.File = "main.bean"
		gotJSON, _ := json.Marshal(row)
		wantJSON, _ := json.Marshal(want)
		if string(gotJSON) != string(wantJSON) {
			t.Fatalf("search candidate changed: %s != %s", gotJSON, wantJSON)
		}
	}
	after, _ := json.Marshal(snapshot.Transactions)
	if string(before) != string(after) {
		t.Fatal("projection mutated model")
	}
	list := readCandidatePage(t, cfg, snapshot, nil)
	if len(list.Transactions[0].Metadata) != 1 {
		t.Fatal("list dialect widened")
	}
}

func TestLocalSearchCandidatesRejectFiltersAndForeignCursors(t *testing.T) {
	cfg, snapshot := pageFixture(3)
	for _, key := range []string{"q", "account", "tag", "tags", "kind"} {
		for _, value := range []string{"", "Coffee"} {
			q := map[string]string{"dialect": localNativeSearchCandidatesDialect, key: value}
			if status, raw, err := localTransactionPageResponse(cfg, snapshot, q); status != 400 || raw != nil || err == nil {
				t.Fatal("filter accepted", key, value, status, err)
			}
		}
	}
	search := readCandidatePage(t, cfg, snapshot, map[string]string{"dialect": localNativeSearchCandidatesDialect, "limit": "1"})
	for _, dialect := range []string{"", localNativeCandidatesDialect} {
		q := map[string]string{"limit": "1"}
		if dialect != "" {
			q["dialect"] = dialect
		}
		status, raw, err := localTransactionPageResponse(cfg, snapshot, q)
		if status != 200 || err != nil {
			t.Fatal(status, err)
		}
		var other localTransactionPage
		if err := json.Unmarshal(raw, &other); err != nil {
			t.Fatal(err)
		}
		if status, _, err := localTransactionPageResponse(cfg, snapshot, map[string]string{"dialect": localNativeSearchCandidatesDialect, "cursor": other.NextCursor}); status != 409 || err == nil {
			t.Fatal("foreign cursor accepted", status, err)
		}
		q["cursor"] = search.NextCursor
		if status, _, err := localTransactionPageResponse(cfg, snapshot, q); status != 409 || err == nil {
			t.Fatal("search cursor escaped dialect", status, err)
		}
	}
	for _, mutate := range []func(){func() { snapshot.Version += "new" }, func() { snapshot.localReadModelID++ }, func() { cfg.LedgerRoot += "other" }, func() { cfg.localEntrypoint = "other.bean" }} {
		oldCfg, oldVersion, oldID := cfg, snapshot.Version, snapshot.localReadModelID
		mutate()
		if status, _, err := localTransactionPageResponse(cfg, snapshot, map[string]string{"dialect": localNativeSearchCandidatesDialect, "cursor": search.NextCursor}); status != 409 || err == nil {
			t.Fatal("stale search cursor accepted", status, err)
		}
		cfg, snapshot.Version, snapshot.localReadModelID = oldCfg, oldVersion, oldID
	}
	if status, _, err := localTransactionPageProjection(cfg, snapshot, map[string]string{"dialect": localNativeSearchCandidatesDialect}, true); status != 400 || err == nil {
		t.Fatal("history accepted search dialect")
	}
}

func TestLocalSearchCandidateMetadataByteBudgetAndContinuation(t *testing.T) {
	cfg, snapshot := pageFixture(7)
	text := strings.Repeat("<", 60000)
	for i := range snapshot.Transactions {
		snapshot.Transactions[i].Metadata["receipt"] = text
	}
	query := map[string]string{"dialect": localNativeSearchCandidatesDialect, "limit": "500"}
	count := 0
	for index := 0; index < 4; index++ {
		page := readCandidatePage(t, cfg, snapshot, query)
		want := 2
		if index == 3 {
			want = 1
		}
		if len(page.Transactions) != want {
			t.Fatal("wrong byte-limited count", len(page.Transactions))
		}
		for _, row := range page.Transactions {
			count++
			if row.Source.Line != count || row.Metadata["receipt"] != text {
				t.Fatal("missing, repeated or truncated candidate")
			}
		}
		if (page.NextCursor == "") != (index == 3) {
			t.Fatal("wrong continuation")
		}
		query["cursor"] = page.NextCursor
	}
	snapshot.Transactions[0].Metadata["receipt"] = strings.Repeat("<", localTransactionPageBytes/6+1)
	if status, raw, err := localTransactionPageResponse(cfg, snapshot, map[string]string{"dialect": localNativeSearchCandidatesDialect}); status != 413 || raw != nil || err == nil {
		t.Fatal("oversized search metadata accepted", status, err)
	}
}

func TestLocalPendingCandidatesPreserveClassifierEvidenceWithoutEditorDraft(t *testing.T) {
	cfg, snapshot := pageFixture(4)
	snapshot.Transactions[0].Entry = &LedgerEntry{Flag: "!"}
	snapshot.Transactions[1].Entry = &LedgerEntry{Flag: "*", NeedsReview: true}
	snapshot.Transactions[2].Entry = &LedgerEntry{Flag: "*"}
	snapshot.Transactions[3].Entry = nil
	for i := range snapshot.Transactions {
		snapshot.Transactions[i].Metadata = map[string]MetadataValue{"type": "退款", "needs_review": "TRUE", "status": "Pending", "receipt": "not classifier", "method": "not classifier"}
	}
	before, _ := json.Marshal(snapshot.Transactions)
	page := readCandidatePage(t, cfg, snapshot, map[string]string{"dialect": localNativePendingCandidatesDialect})
	for i, row := range page.Transactions {
		if row.PendingReviewFlag == nil || *row.PendingReviewFlag != (i < 2) || row.Entry != nil {
			t.Fatal("incorrect pending source evidence", i)
		}
		if len(row.Metadata) != 3 || row.Metadata["needs_review"] != "TRUE" || row.Metadata["status"] != "Pending" {
			t.Fatal("pending metadata changed")
		}
	}
	after, _ := json.Marshal(snapshot.Transactions)
	if string(before) != string(after) {
		t.Fatal("projection mutated model")
	}
	for _, dialect := range []string{localNativeCandidatesDialect, localNativeSearchCandidatesDialect} {
		other := readCandidatePage(t, cfg, snapshot, map[string]string{"dialect": dialect})
		if other.Transactions[0].PendingReviewFlag != nil {
			t.Fatal("evidence leaked to other dialect")
		}
	}
	for _, value := range []any{true, 123, nil, []any{"true"}} {
		snapshot.Transactions[0].Metadata["needs_review"] = value
		page := readCandidatePage(t, cfg, snapshot, map[string]string{"dialect": localNativePendingCandidatesDialect})
		if _, ok := page.Transactions[0].Metadata["needs_review"]; ok {
			t.Fatal("nonstring evidence was stringified")
		}
	}
}
func TestLocalPendingCandidatesScopesFiltersAndByteLimits(t *testing.T) {
	cfg, snapshot := pageFixture(3)
	first := readCandidatePage(t, cfg, snapshot, map[string]string{"dialect": localNativePendingCandidatesDialect, "limit": "1"})
	for _, dialect := range []string{localNativeCandidatesDialect, localNativeSearchCandidatesDialect} {
		if status, _, err := localTransactionPageResponse(cfg, snapshot, map[string]string{"dialect": dialect, "cursor": first.NextCursor}); status != 409 || err == nil {
			t.Fatal("pending cursor escaped scope")
		}
	}
	for _, key := range []string{"q", "account", "tag", "tags", "kind"} {
		if status, _, err := localTransactionPageResponse(cfg, snapshot, map[string]string{"dialect": localNativePendingCandidatesDialect, key: ""}); status != 400 || err == nil {
			t.Fatal("filter presence accepted")
		}
	}
	for i := range snapshot.Transactions {
		snapshot.Transactions[i].Metadata = map[string]MetadataValue{"status": strings.Repeat("<", 60000)}
	}
	q := map[string]string{"dialect": localNativePendingCandidatesDialect}
	first = readCandidatePage(t, cfg, snapshot, q)
	if len(first.Transactions) != 2 || first.NextCursor == "" {
		t.Fatal("pending bytes omitted from budget")
	}
	q["cursor"] = first.NextCursor
	last := readCandidatePage(t, cfg, snapshot, q)
	if len(last.Transactions) != 1 || last.Transactions[0].Source.Line != 3 || last.NextCursor != "" {
		t.Fatal("pending byte continuation invalid")
	}
	snapshot.Transactions[0].Metadata["status"] = strings.Repeat("<", localTransactionPageBytes/6+1)
	if status, _, err := localTransactionPageResponse(cfg, snapshot, map[string]string{"dialect": localNativePendingCandidatesDialect}); status != 413 || err == nil {
		t.Fatal("oversize pending evidence accepted")
	}
}
