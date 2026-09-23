package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func TestLocalBQLMatchesExistingSemantics(t *testing.T) {
	queries := []string{
		"SELECT * FROM transactions ORDER BY date LIMIT 2",
		"SELECT date,account,amount,value FROM postings WHERE account LIKE 'Expenses:%' ORDER BY amount DESC",
		"SELECT month,account,sum(value) AS total FROM postings WHERE account LIKE 'Expenses:%' GROUP BY month,account HAVING total > 0 ORDER BY total DESC",
		"SELECT count(*),sum(amount),avg(amount),min(amount),max(amount) FROM postings",
		"SELECT payee,min(narration),max(narration),count(*) AS n FROM transactions GROUP BY payee ORDER BY payee",
		"SELECT count(*),sum(amount),avg(amount),min(amount),max(amount) FROM postings WHERE payee = 'Absent'",
		"SELECT DISTINCT payee FROM transactions ORDER BY payee",
		"SELECT payee FROM transactions WHERE 'food' IN tags ORDER BY payee",
		"SELECT payee FROM transactions WHERE NOT (payee = 'Store' OR narration = 'Tea') ORDER BY date", // unsupported unselected order tested separately
		"SELECT payee FROM transactions GROUP BY payee ORDER BY payee",
	}
	for _, q := range queries {
		t.Run(q, func(t *testing.T) {
			want, wantErr := ExecuteBQL(bqlTestSnapshot(), q, "CNY")
			got, err := executeLocalBQL(bqlTestSnapshot(), q, "CNY")
			if wantErr != nil {
				if err == nil || err.Error() != wantErr.Error() {
					t.Fatal("validation changed", err, wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("changed semantics\ngot=%#v\nwant=%#v", got, want)
			}
		})
	}
}

func localBQL100kSnapshot() *LedgerSnapshot {
	snapshot := &LedgerSnapshot{Commodities: []string{"CNY"}, Transactions: make([]Transaction, 100000)}
	for i := range snapshot.Transactions {
		snapshot.Transactions[i] = Transaction{Date: "2026-09-01", Payee: fmt.Sprint(i), Postings: []Posting{{Account: "Expenses:Food", Amount: 123, Currency: "CNY"}, {Account: "Assets:Cash", Amount: -123, Currency: "CNY"}}}
	}
	return snapshot
}

func TestLocalBQL100kFullAggregateWithoutPartialTotals(t *testing.T) {
	snapshot := localBQL100kSnapshot()
	result, err := executeLocalBQL(snapshot, "SELECT count(*),sum(amount),avg(amount),min(amount),max(amount) FROM postings WHERE account = 'Expenses:Food'", "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(result.Rows, [][]any{{100000, 12300000, 123, 123, 123}}) {
		t.Fatal("partial totals", result.Rows)
	}
	for _, q := range []string{"SELECT payee FROM transactions ORDER BY payee LIMIT 1", "SELECT payee,count(*) FROM transactions GROUP BY payee LIMIT 1"} {
		result, err := executeLocalBQL(snapshot, q, "CNY")
		if !errors.Is(err, errLocalBQLCapacity) || len(result.Rows) != 0 {
			t.Fatal("capacity silently returned partial result", err)
		}
	}
}

func TestLocalBQLByteBudgets(t *testing.T) {
	for _, grouped := range []bool{false, true} {
		snapshot := &LedgerSnapshot{Transactions: make([]Transaction, 20)}
		for i := range snapshot.Transactions {
			snapshot.Transactions[i] = Transaction{Date: "2026-09-01", Payee: fmt.Sprint(i), Narration: strings.Repeat("m", 500000)}
		}
		q := "SELECT narration FROM transactions"
		if grouped {
			q = "SELECT narration,count(*) FROM transactions GROUP BY narration,payee"
		}
		if result, err := executeLocalBQL(snapshot, q, "CNY"); !errors.Is(err, errLocalBQLCapacity) || len(result.Rows) != 0 {
			t.Fatal("working/response bytes ignored", err)
		}
	}
	// JSON escape expansion must also fit the final1MiB response budget.
	snapshot := &LedgerSnapshot{Transactions: []Transaction{{Date: "2026-09-01", Narration: strings.Repeat("\x01", 200000)}}}
	if _, err := executeLocalBQL(snapshot, "SELECT narration FROM transactions", "CNY"); !errors.Is(err, errLocalBQLCapacity) {
		t.Fatal("JSON expansion ignored", err)
	}
	snapshot.Transactions[0].Narration = strings.Repeat("x", localTransactionPageBytes+1)
	if _, err := executeLocalBQL(snapshot, "SELECT count(*) FROM transactions", "CNY"); !errors.Is(err, errLocalBQLCapacity) {
		t.Fatal("oversize transient row accepted", err)
	}
}

func TestLocalBQLNativeRoute(t *testing.T) {
	input := localTestRequest(t)
	input.Method = "POST"
	input.Path = "/api/ledger/bql"
	input.Body = json.RawMessage(`{"query":"SELECT count(*) FROM transactions"}`)
	status, data, err := DispatchLocalRequest(input)
	if err != nil || status != 200 || len(data) > localTransactionPageBytes {
		t.Fatal(status, err)
	}
	var result BQLResult
	if err := json.Unmarshal(data, &result); err != nil || result.RowCount != 1 {
		t.Fatal("invalid response", err)
	}
	input.Body = json.RawMessage(strings.Repeat(" ", bqlMaxRequestBodyLength+1))
	if status, _, err := DispatchLocalRequest(input); status != 413 || err == nil {
		t.Fatal("request budget ignored")
	}
	input.Body = json.RawMessage(`{"query":"DELETE FROM transactions"}`)
	if status, _, err := DispatchLocalRequest(input); status != 400 || err == nil {
		t.Fatal("invalid query accepted")
	}
}

func TestLocalBQLProjectionFanoutAndBoundedGrouping(t *testing.T) {
	snapshot := bqlTestSnapshot()
	snapshot.Transactions[0].Narration = strings.Repeat("n", 100000)
	columns := make([]string, 128)
	for i := range columns {
		columns[i] = fmt.Sprintf("narration AS n%d", i)
	}
	if _, err := executeLocalBQL(snapshot, "SELECT "+strings.Join(columns, ",")+" FROM transactions", "CNY"); !errors.Is(err, errLocalBQLCapacity) {
		t.Fatal("fanout not bounded", err)
	}
	for i := range columns {
		columns[i] = fmt.Sprintf("max(narration) AS n%d", i)
	}
	if _, err := executeLocalBQL(snapshot, "SELECT "+strings.Join(columns, ",")+" FROM transactions", "CNY"); !errors.Is(err, errLocalBQLCapacity) {
		t.Fatal("aggregate fanout not bounded", err)
	}
	snapshot = localBQL100kSnapshot()
	got, err := executeLocalBQL(snapshot, "SELECT account,count(*),sum(amount),min(amount),max(amount) FROM postings GROUP BY account ORDER BY account", "CNY")
	if err != nil {
		t.Fatal(err)
	}
	want := [][]any{{"Assets:Cash", 100000, -12300000, -123, -123}, {"Expenses:Food", 100000, 12300000, 123, 123}}
	if !reflect.DeepEqual(got.Rows, want) {
		t.Fatal("bounded grouping lost full totals", got.Rows)
	}
}
