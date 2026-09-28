package app

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"
)

func TestLocalReconciliationSnapshotStatusesUseSameSnapshotAndPreserveLegacy(t *testing.T) {
	today := time.Now().Format("2006-01-02")
	yesterday := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
	tomorrow := time.Now().AddDate(0, 0, 1).Format("2006-01-02")
	stale := time.Now().AddDate(0, 0, -90).Format("2006-01-02")
	snapshot := &LedgerSnapshot{LedgerVersion: LedgerVersion{Version: "synthetic"}, Accounts: []Account{
		{Account: "Assets:Red", Currency: "CNY", Active: true},
		{Account: "Assets:Green", Currency: "CNY", Active: true},
		{Account: "Assets:Yellow", Currency: "CNY", Active: true},
		{Account: "Assets:Stale", Currency: "CNY", Active: true},
		{Account: "Assets:Empty", Currency: "CNY", Active: true},
	}, Transactions: []Transaction{{Date: yesterday, Postings: []Posting{
		{Account: "Assets:Red", Currency: "CNY", Amount: 100},
		{Account: "Assets:Green", Currency: "CNY", Amount: 100},
		{Account: "Assets:Yellow", Currency: "CNY", Amount: 100},
	}}}, BalanceAssertions: []BalanceAssertion{
		{Account: "Assets:Red", Date: today, Currency: "CNY", Amount: 200},
		{Account: "Assets:Green", Date: today, Currency: "CNY", Amount: 100},
		{Account: "Assets:Yellow", Date: stale, Currency: "CNY", Amount: 0},
		{Account: "Assets:Stale", Date: stale, Currency: "CNY", Amount: 10},
	}}
	prepareLedgerSnapshot(snapshot)
	wantStatuses := AccountStatusIndicators(snapshot.Transactions, snapshot.BalanceAssertions, snapshot.Accounts)
	status, raw, err := localReconciliationSnapshotResponse(snapshot, map[string]string{"start": yesterday, "end": tomorrow})
	if status != 200 || err != nil {
		t.Fatal(status, err)
	}
	var got localReconciliationSnapshot
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	wantColors := []string{"red", "green", "yellow", "grey", "grey"}
	legacy := buildReconciliationRows(snapshot, yesterday, tomorrow)
	for i, row := range got.Rows {
		if row.SnapshotStatus == nil || row.StatusError == nil {
			t.Fatal("missing status evidence")
		}
		if row.SnapshotStatus.Status != wantColors[i] || *row.StatusError != (wantColors[i] == "red") {
			t.Fatalf("wrong status: %+v", row)
		}
		if !reflect.DeepEqual(*row.SnapshotStatus, wantStatuses[i]) {
			t.Fatal("different accounting status")
		}
		if legacy[i].SnapshotStatus != nil || legacy[i].StatusError != nil {
			t.Fatal("legacy contract widened")
		}
		row.SnapshotStatus = nil
		row.StatusError = nil
		if !reflect.DeepEqual(row, legacy[i]) {
			t.Fatal("range row semantics changed")
		}
	}
	if got.Rows[0].Status != "asserted" || got.Rows[1].Status != "asserted" {
		t.Fatal("range assertion status changed")
	}
	if len(raw) > localTransactionPageBytes-4096 {
		t.Fatal("status evidence escaped wire budget")
	}
	// Exactly the same data can have an out-of-range assertion while still green;
	// preserve this distinction instead of collapsing row status into health.
	_, raw, err = localReconciliationSnapshotResponse(snapshot, map[string]string{"start": stale, "end": yesterday})
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if got.Rows[1].Status != "pending" || got.Rows[1].SnapshotStatus.Status != "green" {
		t.Fatal("health was derived from range marker")
	}
}
