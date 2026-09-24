package app

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestLocalBootstrapPageMatchesCompleteLegacyAccountingAndExplicitPage(t *testing.T) {
	cfg := testLedger(t)
	snapshot, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	query := map[string]string{"start": "2026-05-01", "end": "2026-06-01", "today": "2026-05-31", "valuationCurrency": "CNY", "limit": "1"}
	before, _ := json.Marshal(snapshot.Transactions)
	status, raw, err := localBootstrapPageResponse(cfg, snapshot, query)
	if status != 200 || err != nil || len(raw) > localTransactionPageBytes-4096 {
		t.Fatal(status, err, len(raw))
	}
	var got localBootstrapPage
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	legacy := BuildLedgerBootstrap(snapshot, query["start"], query["end"], true, "CNY", query["today"])
	if len(legacy.Transactions) < 2 {
		t.Fatal("fixture must span pages")
	}
	legacy.Transactions = []Transaction{}
	// JSON parity avoids map number representation differences in metadata.
	wantJSON, _ := json.Marshal(legacy)
	var nativeLegacy any
	decoder := json.NewDecoder(bytes.NewReader(wantJSON))
	decoder.UseNumber()
	if err := decoder.Decode(&nativeLegacy); err != nil {
		t.Fatal(err)
	}
	wantJSON, _ = json.Marshal(normalizeLocalResponseCollections(nativeLegacy, "/api/ledger/bootstrap"))
	// Inspect the actual native wire shape, not a struct re-encoding that can
	// turn normalized empty collections back into nil.
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(raw, &envelope); err != nil {
		t.Fatal(err)
	}
	var nativeBootstrap any
	decoder = json.NewDecoder(bytes.NewReader(envelope["bootstrap"]))
	decoder.UseNumber()
	if err := decoder.Decode(&nativeBootstrap); err != nil {
		t.Fatal(err)
	}
	gotJSON, _ := json.Marshal(nativeBootstrap)
	if string(gotJSON) != string(wantJSON) {
		t.Fatal("accounting fields differ from legacy")
	}
	var page localTransactionPage
	if err := json.Unmarshal(got.TransactionPage, &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Transactions) != 1 || page.NextCursor == "" || page.Revision == "" || !page.SensitiveUnlocked {
		t.Fatal("missing explicit continuation")
	}
	next := readCandidatePage(t, cfg, snapshot, map[string]string{"start": query["start"], "end": query["end"], "cursor": page.NextCursor})
	if len(next.Transactions) != 1 || next.NextCursor != "" {
		t.Fatal("bootstrap cursor cannot continue native candidates")
	}
	after, _ := json.Marshal(snapshot.Transactions)
	if string(before) != string(after) {
		t.Fatal("bootstrap mutated model")
	}
}

func TestLocalBootstrapPageHundredThousandDoesNotMaterializeLegacyTransactions(t *testing.T) {
	cfg, snapshot := accountPageFixture(100000)
	snapshot.Commodities = []string{"CNY", "USD"}
	q := map[string]string{"start": "2026-09-01", "end": "2026-10-01", "today": "2026-09-24", "limit": "100"}
	status, raw, err := localBootstrapPageResponse(cfg, snapshot, q)
	if status != 200 || err != nil || len(raw) > localTransactionPageBytes-4096 {
		t.Fatal(status, err, len(raw))
	}
	var got localBootstrapPage
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if got.Bootstrap.Transactions == nil || len(got.Bootstrap.Transactions) != 0 {
		t.Fatal("summary retained legacy transaction array")
	}
	var page localTransactionPage
	if err := json.Unmarshal(got.TransactionPage, &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Transactions) != 100 || page.NextCursor == "" {
		t.Fatal("not bounded first page")
	}
	for _, row := range page.Transactions {
		if row.Entry != nil {
			t.Fatal("bootstrap page leaked editor drafts")
		}
	}
	if !reflect.DeepEqual(got.Bootstrap.Summary, scopedLedgerSummary(snapshot, q["start"], q["end"], true, got.Bootstrap.ValuationCurrency)) {
		t.Fatal("summary totals incomplete")
	}
}

func TestLocalBootstrapPageRejectsUnsupportedInputAndOversizedAccounting(t *testing.T) {
	cfg, snapshot := accountPageFixture(1)
	base := map[string]string{"start": "2026-09-01", "end": "2026-10-01", "today": "2026-09-24"}
	for _, change := range []map[string]string{{"q": ""}, {"cursor": ""}, {"lite": "1"}, {"today": "bad"}, {"start": ""}, {"limit": "501"}, {"end": "2026-09-01"}} {
		q := map[string]string{}
		for k, v := range base {
			q[k] = v
		}
		for k, v := range change {
			q[k] = v
		}
		if status, raw, err := localBootstrapPageResponse(cfg, snapshot, q); status != 400 || raw != nil || err == nil {
			t.Fatal("invalid request accepted", change, status, err)
		}
	}
	snapshot.Accounts[0].Metadata = map[string]MetadataValue{"description": strings.Repeat("x", localTransactionPageBytes)}
	if status, raw, err := localBootstrapPageResponse(cfg, snapshot, base); status != 413 || raw != nil || err == nil {
		t.Fatal("oversized accounting/catalog silently returned", status, err)
	}
}

func TestLocalBootstrapPageNativeRouteRejectsStagingAndImportFile(t *testing.T) {
	input := localTestRequest(t)
	input.Path = "/api/ledger/bootstrap/page"
	input.Query = map[string]string{"start": "2026-05-01", "end": "2026-06-01", "today": "2026-05-31", "limit": "1"}
	raw := localTestDispatch(t, input)
	var got localBootstrapPage
	if err := json.Unmarshal(raw, &got); err != nil || len(got.TransactionPage) == 0 {
		t.Fatal(err)
	}
	for _, stage := range []bool{true, false} {
		test := input
		if stage {
			test.Staging = true
		} else {
			test.ImportFile = &LocalImportFile{Name: "fixture.csv"}
		}
		if status, _, err := DispatchLocalRequest(test); status != 400 || err == nil {
			t.Fatal("invalid generation input accepted")
		}
	}
	root := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(input.WorkspaceRoot))), "staging", "candidate", "workspace")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	input.WorkspaceRoot = root
	if status, _, err := DispatchLocalRequest(input); status != 400 || err == nil || !strings.Contains(err.Error(), "committed generation directory") {
		t.Fatal("unflagged staging accepted", status, err)
	}
}

func TestLocalBootstrapPageNormalizesCollectionsWithoutRoundingMoney(t *testing.T) {
	cfg, snapshot := accountPageFixture(1)
	const precise = 9007199254740993
	snapshot.Transactions[0].Postings = []Posting{{Account: "Assets:Cash", Currency: "CNY", Amount: precise}}
	snapshot.RawBalances = CurrentBalances(snapshot.Transactions)
	snapshot.Balances = nativeAccountBalances(snapshot.RawBalances, snapshotAccountMap(snapshot))
	snapshot.AccountBalances = AccountBalanceRowsWithPriceIndex(snapshot.RawBalances, snapshotPriceIndex(snapshot), "")
	snapshot.Accounts[0].Metadata = nil
	q := map[string]string{"start": "2026-09-01", "end": "2026-10-01", "today": "2026-09-24"}
	status, raw, err := localBootstrapPageResponse(cfg, snapshot, q)
	if status != 200 || err != nil {
		t.Fatal(status, err)
	}
	var result localBootstrapPage
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	var page localTransactionPage
	if err := json.Unmarshal(result.TransactionPage, &page); err != nil {
		t.Fatal(err)
	}
	if page.Transactions[0].Postings[0].Amount != precise {
		t.Fatal("page money rounded by normalization")
	}
	if result.Bootstrap.Balances["Assets:Cash"] != precise {
		t.Fatal("summary money rounded by normalization")
	}
	if result.Bootstrap.Accounts == nil || result.Bootstrap.AccountBalances == nil || result.Bootstrap.Prices == nil || result.Bootstrap.Transactions == nil || result.Bootstrap.Commodities == nil {
		t.Fatal("required collections remain null")
	}
	// Account metadata is optional/omitempty: absence stays absent, matching
	// the existing normalization contract rather than inventing a field.
	if result.Bootstrap.IncomeStatement.Income == nil || result.Bootstrap.IncomeStatement.Expense == nil {
		t.Fatal("nested required arrays remain null")
	}
}

func TestLocalBootstrapPageCombinedEnvelopeBudget(t *testing.T) {
	cfg, snapshot := accountPageFixture(1)
	snapshot.Transactions[0].Narration = strings.Repeat("x", 600000)
	snapshot.Accounts[0].Metadata = map[string]MetadataValue{"note": strings.Repeat("y", 500000)}
	q := map[string]string{"start": "2026-09-01", "end": "2026-10-01", "today": "2026-09-24"}
	status, page, err := localTransactionPageResponse(cfg, snapshot, map[string]string{"dialect": localNativeCandidatesDialect, "start": q["start"], "end": q["end"]})
	if status != 200 || err != nil || len(page) > localTransactionPageBytes {
		t.Fatal("page alone must fit", status, err)
	}
	accounting, _ := json.Marshal(buildLedgerBootstrap(snapshot, q["start"], q["end"], true, "CNY", q["today"], false))
	if len(accounting) > localTransactionPageBytes-4096 {
		t.Fatal("accounting alone must fit")
	}
	if status, raw, err := localBootstrapPageResponse(cfg, snapshot, q); status != 413 || raw != nil || err == nil {
		t.Fatal("combined overflow accepted", status, err)
	}
}
