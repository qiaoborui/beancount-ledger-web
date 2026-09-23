package app

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func accountPageFixture(n int) (Config, *LedgerSnapshot) {
	cfg, snapshot := pageFixture(n)
	snapshot.Accounts = []Account{{Account: "Assets:Cash", Currency: "CNY", Label: "Synthetic cash", Active: true}, {Account: "Assets:Other", Currency: "USD", Label: "Other"}}
	for i := range snapshot.Transactions {
		snapshot.Transactions[i].Postings = []Posting{{Account: "Assets:Cash", Currency: "CNY", Amount: 10}, {Account: "Assets:Cash", Currency: "USD", Amount: 20}, {Account: "Expenses:Food", Currency: "CNY", Amount: -10}}
		snapshot.Transactions[i].Metadata = map[string]MetadataValue{"type": "退款", "receipt": "not listing"}
	}
	snapshot.RawBalances = nil
	snapshot.AccountMap = nil
	prepareLedgerSnapshot(snapshot)
	return cfg, snapshot
}
func readAccountPage(t *testing.T, cfg Config, snapshot *LedgerSnapshot, q map[string]string) localAccountPage {
	t.Helper()
	status, raw, err := localAccountPageResponse(cfg, snapshot, q)
	if status != 200 || err != nil || len(raw) > localTransactionPageBytes {
		t.Fatalf("status=%d bytes=%d err=%v", status, len(raw), err)
	}
	var page localAccountPage
	if err := json.Unmarshal(raw, &page); err != nil {
		t.Fatal(err)
	}
	if page.Revision == "" || !page.SensitiveUnlocked || page.Detail.Rows == nil || len(page.Detail.Rows) > 500 {
		t.Fatal("invalid page envelope")
	}
	return page
}
func TestLocalAccountPageCompleteBalancesAndLegacyParity(t *testing.T) {
	cfg, snapshot := accountPageFixture(9)
	for i := range snapshot.Transactions {
		snapshot.Transactions[i].Date = fmt.Sprintf("2026-09-%02d", i+1)
	}
	snapshot.Transactions[3].Postings = append(snapshot.Transactions[3].Postings, Posting{Account: "Assets:Cash", Amount: -10}) // zero net change still a row; blank means CNY.
	snapshot.transactionsAsc, snapshot.transactionsDesc = sortedTransactionIndices(snapshot.Transactions)
	snapshot.RawBalances = CurrentBalances(snapshot.Transactions)
	service := NewAccountServiceWithSnapshot(nil, nil, func() (*LedgerSnapshot, error) { return snapshot, nil })
	before, _ := json.Marshal(snapshot.Transactions)
	for _, currency := range []string{"CNY", "USD"} {
		for _, bounds := range [][2]string{{"", ""}, {"2026-09-03", "2026-09-07"}, {"2027-01-01", "2027-02-01"}, {"2020-01-01", "2020-02-01"}} {
			expected, err := service.Detail("Assets:Cash", currency, bounds[0], bounds[1])
			if err != nil {
				t.Fatal(err)
			}
			q := map[string]string{"account": "Assets:Cash", "currency": currency, "start": bounds[0], "end": bounds[1], "limit": "2"}
			var rows []AccountDetailRow
			for attempts := 0; attempts < 10; attempts++ {
				page := readAccountPage(t, cfg, snapshot, q)
				if page.RowCount != len(expected.Rows) || page.Detail.CurrentBalance != expected.CurrentBalance || page.Detail.OpeningBalance != expected.OpeningBalance || page.Detail.ClosingBalance != expected.ClosingBalance || page.Detail.PeriodChange != expected.PeriodChange {
					t.Fatalf("wrong whole history facts: %+v want %+v", page, expected)
				}
				rows = append(rows, page.Detail.Rows...)
				if page.NextCursor == "" {
					break
				}
				q["cursor"] = page.NextCursor
			}
			if len(rows) != len(expected.Rows) {
				t.Fatal("incomplete history")
			}
			for i, row := range rows {
				want := expected.Rows[i]
				want.Txn.Entry = nil
				want.Txn.Metadata = map[string]MetadataValue{"type": "退款"}
				want.Txn.Source.File = "main.bean"
				if !reflect.DeepEqual(row, want) {
					t.Fatalf("row changed: %+v want %+v", row, want)
				}
			}
		}
	}
	after, _ := json.Marshal(snapshot.Transactions)
	if string(before) != string(after) {
		t.Fatal("projection mutated model")
	}
}
func TestLocalAccountPageHundredThousandRows(t *testing.T) {
	cfg, snapshot := accountPageFixture(100000)
	q := map[string]string{"account": "Assets:Cash", "limit": "500"}
	count := 0
	for index := 0; index < 200; index++ {
		page := readAccountPage(t, cfg, snapshot, q)
		if len(page.Detail.Rows) != 500 || page.RowCount != 100000 || page.Detail.CurrentBalance != 1000000 || page.Detail.ClosingBalance != 1000000 {
			t.Fatal("incorrect full totals")
		}
		for _, row := range page.Detail.Rows {
			count++
			if row.Txn.Source.Line != count || row.Balance != count*10 {
				t.Fatal("missing/repeated/reordered row or reset balance")
			}
		}
		if (page.NextCursor == "") != (index == 199) {
			t.Fatal("incorrect EOF")
		}
		q["cursor"] = page.NextCursor
	}
	if count != 100000 {
		t.Fatal(count)
	}
}
func TestLocalAccountPageScopeAndValidation(t *testing.T) {
	cfg, snapshot := accountPageFixture(5)
	first := readAccountPage(t, cfg, snapshot, map[string]string{"account": "Assets:Cash", "limit": "1"})
	for _, change := range []map[string]string{{"account": "Assets:Other"}, {"currency": "USD"}, {"start": "2026-09-01", "end": "2026-10-01"}} {
		q := map[string]string{"account": "Assets:Cash", "cursor": first.NextCursor}
		for k, v := range change {
			q[k] = v
		}
		if status, raw, err := localAccountPageResponse(cfg, snapshot, q); status != 409 || raw != nil || err == nil {
			t.Fatal("scope accepted", change, status, err)
		}
	}
	for _, mutate := range []func(){func() { snapshot.Version += "new" }, func() { snapshot.localReadModelID++ }, func() { cfg.LedgerRoot += "other" }, func() { cfg.localEntrypoint = "other.bean" }} {
		c, v, id := cfg, snapshot.Version, snapshot.localReadModelID
		mutate()
		if status, _, err := localAccountPageResponse(cfg, snapshot, map[string]string{"account": "Assets:Cash", "cursor": first.NextCursor}); status != 409 || err == nil {
			t.Fatal("stale cursor accepted")
		}
		cfg, snapshot.Version, snapshot.localReadModelID = c, v, id
	}
	for _, change := range []map[string]string{{"account": ""}, {"currency": "EUR"}, {"limit": "0"}, {"limit": "501"}, {"limit": "oops"}, {"start": "bad", "end": "2026-10-01"}, {"start": "2026-10-01", "end": "2026-09-01"}, {"q": ""}, {"cursor": "forged"}} {
		q := map[string]string{"account": "Assets:Cash"}
		for k, v := range change {
			q[k] = v
		}
		if status, raw, err := localAccountPageResponse(cfg, snapshot, q); status != 400 || raw != nil || err == nil {
			t.Fatal("invalid request accepted", change, status, err)
		}
	}
	candidate := readCandidatePage(t, cfg, snapshot, map[string]string{"limit": "1"})
	if status, _, err := localAccountPageResponse(cfg, snapshot, map[string]string{"account": "Assets:Cash", "cursor": candidate.NextCursor}); status != 409 || err == nil {
		t.Fatal("foreign cursor accepted")
	}
	if status, _, err := localTransactionPageResponse(cfg, snapshot, map[string]string{"cursor": first.NextCursor}); status != 409 || err == nil {
		t.Fatal("account cursor escaped")
	}
}
func TestLocalAccountPageByteBoundsAndArithmetic(t *testing.T) {
	cfg, snapshot := accountPageFixture(7)
	for i := range snapshot.Transactions {
		snapshot.Transactions[i].Narration = strings.Repeat("<", 30000)
	}
	q := map[string]string{"account": "Assets:Cash", "limit": "500"}
	count := 0
	for index := 0; index < 4; index++ {
		page := readAccountPage(t, cfg, snapshot, q)
		for _, row := range page.Detail.Rows {
			count++
			if row.Txn.Source.Line != count {
				t.Fatal("byte continuation omitted row")
			}
		}
		if page.NextCursor == "" {
			break
		}
		q["cursor"] = page.NextCursor
	}
	if count != 7 {
		t.Fatal(count)
	}
	snapshot.Transactions[0].Narration = strings.Repeat("<", localTransactionPageBytes/6)
	if status, raw, err := localAccountPageResponse(cfg, snapshot, map[string]string{"account": "Assets:Cash"}); status != 413 || raw != nil || err == nil {
		t.Fatal("oversize row accepted")
	}
	maxInt := int(^uint(0) >> 1)
	for _, amounts := range [][]int{{maxInt, 1}, {-maxInt - 1, -1}} {
		cfg, snapshot = accountPageFixture(2)
		for i, amount := range amounts {
			snapshot.Transactions[i].Postings = []Posting{{Account: "Assets:Cash", Currency: "CNY", Amount: amount}}
		}
		if status, raw, err := localAccountPageResponse(cfg, snapshot, map[string]string{"account": "Assets:Cash"}); status != 413 || raw != nil || err == nil {
			t.Fatal("overflow accepted")
		}
	}
}
func TestLocalAccountPageNativeRouteAndCommittedOnly(t *testing.T) {
	input := localTestRequest(t)
	input.Path = "/api/ledger/accounts/detail/page"
	input.Query = map[string]string{"account": "Assets:Cash"}
	raw := localTestDispatch(t, input)
	var page localAccountPage
	if err := json.Unmarshal(raw, &page); err != nil || page.RowCount == 0 {
		t.Fatal("native account route failed", err)
	}
	input.Staging = true
	if status, raw, err := DispatchLocalRequest(input); status != http.StatusBadRequest || raw != nil || err == nil {
		t.Fatal("staging accepted")
	}
	input.Staging = false
	input.ImportFile = &LocalImportFile{Name: "fixture.csv"}
	if status, raw, err := DispatchLocalRequest(input); status != http.StatusBadRequest || raw != nil || err == nil {
		t.Fatal("import file accepted")
	}
}

func TestLocalAccountPageRejectsUnflaggedStagingDirectory(t *testing.T) {
	input := localTestRequest(t)
	input.Path = "/api/ledger/accounts/detail/page"
	input.Query = map[string]string{"account": "Assets:Cash"}
	root := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(input.WorkspaceRoot))), "staging", "candidate", "workspace")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	input.WorkspaceRoot = root
	input.Staging = false
	if status, raw, err := DispatchLocalRequest(input); status != 400 || raw != nil || err == nil || !strings.Contains(err.Error(), "committed generation directory") {
		t.Fatal("unflagged staging accepted", status, err)
	}
}
func TestLocalAccountPagePreEncodingBudgets(t *testing.T) {
	huge := strings.Repeat("x", localTransactionPageBytes+1)
	for _, mutate := range []func(*Transaction){
		func(txn *Transaction) { txn.Narration = huge },
		func(txn *Transaction) { txn.Metadata["type"] = huge },
		func(txn *Transaction) { txn.Tags = []string{huge} },
		func(txn *Transaction) { txn.Postings[0].Flag = huge },
		func(txn *Transaction) { txn.Links = []string{huge} },
		func(txn *Transaction) { txn.Postings = make([]Posting, localTransactionPageBytes/128+1) },
	} {
		_, snapshot := accountPageFixture(1)
		mutate(&snapshot.Transactions[0])
		if localAccountRowFitsEncodingBudget(snapshot.Transactions[0]) {
			t.Fatal("oversized input accepted before encoding")
		}
	}
	cfg, snapshot := accountPageFixture(1)
	snapshot.AccountMap["Assets:Cash"] = Account{Account: "Assets:Cash", Currency: "CNY", Label: huge}
	if status, raw, err := localAccountPageResponse(cfg, snapshot, map[string]string{"account": "Assets:Cash"}); status != 413 || raw != nil || err == nil {
		t.Fatal("oversized header accepted")
	}
}
