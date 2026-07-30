package app

import "testing"

func TestExecuteBQLAggregatesPostings(t *testing.T) {
	snapshot := &LedgerSnapshot{
		Commodities: []string{"CNY"},
		Transactions: []Transaction{
			{
				Date:      "2026-01-10",
				Payee:     "Cafe",
				Narration: "Coffee",
				Postings: []Posting{
					{Account: "Expenses:Food:Coffee", Amount: 1234, Currency: "CNY"},
					{Account: "Assets:Bank", Amount: -1234, Currency: "CNY"},
				},
			},
			{
				Date:      "2026-01-11",
				Payee:     "Store",
				Narration: "Book",
				Postings: []Posting{
					{Account: "Expenses:Books", Amount: 3200, Currency: "CNY"},
					{Account: "Assets:Bank", Amount: -3200, Currency: "CNY"},
				},
			},
		},
	}

	result, err := ExecuteBQL(snapshot, `SELECT month, account, sum(value) AS total
FROM postings
WHERE date >= '2026-01-01' AND account LIKE 'Expenses:%'
GROUP BY month, account
ORDER BY total DESC
LIMIT 10`, "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Columns) != 3 || result.Columns[2].Name != "total" || result.Columns[2].Type != "money" {
		t.Fatalf("unexpected columns: %#v", result.Columns)
	}
	if len(result.Rows) != 2 {
		t.Fatalf("expected 2 rows, got %d: %#v", len(result.Rows), result.Rows)
	}
	if result.Rows[0][1] != "Expenses:Books" || result.Rows[0][2] != 3200 {
		t.Fatalf("unexpected first row: %#v", result.Rows[0])
	}
	if result.Rows[1][1] != "Expenses:Food:Coffee" || result.Rows[1][2] != 1234 {
		t.Fatalf("unexpected second row: %#v", result.Rows[1])
	}
}

func TestParseBQLRejectsOrWhere(t *testing.T) {
	_, err := parseBQL("SELECT date FROM transactions WHERE date = '2026-01-01' OR payee = 'Cafe'")
	if err == nil {
		t.Fatal("expected OR rejection")
	}
}
