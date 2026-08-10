package app

import (
	"strings"
	"testing"
)

func bqlTestSnapshot() *LedgerSnapshot {
	return &LedgerSnapshot{
		Commodities: []string{"CNY"},
		Transactions: []Transaction{
			{
				Date: "2026-01-10", Payee: "Cafe", Narration: "Coffee", Tags: []string{"coffee", "food"}, Links: []string{"receipt-1"},
				Postings: []Posting{{Account: "Expenses:Food:Coffee", Amount: 1234, Currency: "CNY"}, {Account: "Assets:Bank", Amount: -1234, Currency: "CNY"}},
			},
			{
				Date: "2026-01-11", Payee: "Store", Narration: "Book", Tags: []string{"books"},
				Postings: []Posting{{Account: "Expenses:Books", Amount: 3200, Currency: "CNY"}, {Account: "Assets:Bank", Amount: -3200, Currency: "CNY"}},
			},
			{
				Date: "2026-01-12", Payee: "Cafe", Narration: "Tea", Tags: []string{"tea", "food"},
				Postings: []Posting{{Account: "Expenses:Food:Tea", Amount: 800, Currency: "CNY"}, {Account: "Assets:Bank", Amount: -800, Currency: "CNY"}},
			},
			{
				Date: "2026-02-01", Payee: "Employer", Narration: "Salary", Tags: []string{"salary"},
				Postings: []Posting{{Account: "Assets:Bank", Amount: 200000, Currency: "CNY"}, {Account: "Income:Salary", Amount: -200000, Currency: "CNY"}},
			},
		},
	}
}

func TestExecuteBQLAggregatesPostings(t *testing.T) {
	result, err := ExecuteBQL(bqlTestSnapshot(), `SELECT month, account, sum(value) AS total
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
	if len(result.Rows) != 3 {
		t.Fatalf("expected 3 rows, got %d: %#v", len(result.Rows), result.Rows)
	}
	if result.Rows[0][1] != "Expenses:Books" || result.Rows[0][2] != 3200 {
		t.Fatalf("unexpected first row: %#v", result.Rows[0])
	}
	if result.Rows[1][1] != "Expenses:Food:Coffee" || result.Rows[1][2] != 1234 {
		t.Fatalf("unexpected second row: %#v", result.Rows[1])
	}
}

func TestExecuteBQLSupportsBooleanExpressions(t *testing.T) {
	result, err := ExecuteBQL(bqlTestSnapshot(), `SELECT date, payee, narration
FROM transactions
WHERE NOT (payee = 'Store' OR (payee = 'Cafe' AND narration = 'Tea'))
ORDER BY date`, "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Rows) != 2 || result.Rows[0][1] != "Cafe" || result.Rows[1][1] != "Employer" {
		t.Fatalf("unexpected boolean expression result: %#v", result.Rows)
	}

	precedence, err := ExecuteBQL(bqlTestSnapshot(), `SELECT narration FROM transactions
WHERE payee = 'Cafe' OR payee = 'Store' AND narration = 'Missing'
ORDER BY narration`, "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if len(precedence.Rows) != 2 || precedence.Rows[0][0] != "Coffee" || precedence.Rows[1][0] != "Tea" {
		t.Fatalf("AND should bind more tightly than OR: %#v", precedence.Rows)
	}
}

func TestExecuteBQLSupportsAdvancedPredicates(t *testing.T) {
	result, err := ExecuteBQL(bqlTestSnapshot(), `SELECT date, payee, narration
FROM transactions
WHERE (payee ~ '^ca' OR payee IN ('Store', 'Missing'))
  AND date BETWEEN 2026-01-01 AND 2026-01-31
  AND narration NOT LIKE '%Tea%'
  AND payee NOT IN ('Employer')
ORDER BY 1`, "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Rows) != 2 || result.Rows[0][1] != "Cafe" || result.Rows[1][1] != "Store" {
		t.Fatalf("unexpected advanced predicate result: %#v", result.Rows)
	}

	collection, err := ExecuteBQL(bqlTestSnapshot(), `SELECT payee FROM transactions WHERE 'coffee' IN tags AND 'receipt-1' IN links`, "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if len(collection.Rows) != 1 || collection.Rows[0][0] != "Cafe" {
		t.Fatalf("unexpected collection predicate result: %#v", collection.Rows)
	}

	money, err := ExecuteBQL(bqlTestSnapshot(), `SELECT payee FROM transactions WHERE value > ¥1,000`, "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if len(money.Rows) != 1 || money.Rows[0][0] != "Employer" {
		t.Fatalf("thousands-separated money literals should remain supported: %#v", money.Rows)
	}
}

func TestExecuteBQLSupportsDistinctWildcardHavingAndOrdinals(t *testing.T) {
	distinct, err := ExecuteBQL(bqlTestSnapshot(), `SELECT DISTINCT payee FROM transactions ORDER BY 1`, "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if len(distinct.Rows) != 3 {
		t.Fatalf("expected 3 distinct payees, got %#v", distinct.Rows)
	}

	wildcard, err := ExecuteBQL(bqlTestSnapshot(), `SELECT * FROM transactions ORDER BY 1 LIMIT 1`, "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if len(wildcard.Columns) != len(bqlFieldOrder("transactions")) || wildcard.Columns[5].Name != "accounts" {
		t.Fatalf("unexpected wildcard columns: %#v", wildcard.Columns)
	}

	having, err := ExecuteBQL(bqlTestSnapshot(), `SELECT payee, count(*) AS tx_count, sum(value) AS total
FROM transactions
GROUP BY 1
HAVING tx_count >= 2 OR total > 1000
ORDER BY 2 DESC, payee`, "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if len(having.Rows) != 2 || having.Rows[0][0] != "Cafe" || having.Rows[1][0] != "Employer" {
		t.Fatalf("unexpected HAVING result: %#v", having.Rows)
	}
}

func TestExecuteBQLSupportsComparableMinAndEmptyCount(t *testing.T) {
	result, err := ExecuteBQL(bqlTestSnapshot(), `SELECT min(payee) AS first_payee FROM transactions`, "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Rows) != 1 || result.Rows[0][0] != "Cafe" {
		t.Fatalf("unexpected string min: %#v", result.Rows)
	}

	empty, err := ExecuteBQL(bqlTestSnapshot(), `SELECT count(*) AS total FROM transactions WHERE date < '2000-01-01'`, "CNY")
	if err != nil {
		t.Fatal(err)
	}
	if len(empty.Rows) != 1 || empty.Rows[0][0] != 0 {
		t.Fatalf("empty aggregate should return one zero-count row: %#v", empty.Rows)
	}
}

func TestParseBQLRejectsMalformedAdvancedSyntax(t *testing.T) {
	for _, query := range []string{
		`SELECT date FROM transactions WHERE payee ~ '['`,
		`SELECT date FROM transactions WHERE payee IN ()`,
		`SELECT date FROM transactions WHERE (payee = 'Cafe'`,
		`SELECT date FROM transactions WHERE payee = 'Cafe' WHERE narration = 'Tea'`,
		`SELECT date FROM transactions HAVING date IS NOT NULL`,
	} {
		if _, err := parseBQL(query); err == nil {
			t.Fatalf("expected query to fail: %s", query)
		}
	}

	_, err := parseBQL(`SELECT date FROM transactions WHERE payee = 'Bob''s Cafe'`)
	if err != nil && strings.Contains(err.Error(), "结束引号") {
		t.Fatalf("doubled quotes should be accepted: %v", err)
	}
}

func TestParseBQLLimitsExpressionComplexity(t *testing.T) {
	queries := []string{
		"SELECT date FROM transactions WHERE " + strings.Repeat("(", bqlMaxExpressionDepth+1) + "payee = 'Cafe'" + strings.Repeat(")", bqlMaxExpressionDepth+1),
		"SELECT date FROM transactions WHERE " + strings.Repeat("NOT ", bqlMaxExpressionTokens+1) + "payee = 'Cafe'",
		"SELECT date FROM transactions WHERE payee IN (" + strings.TrimSuffix(strings.Repeat("'Cafe',", bqlMaxInValues+1), ",") + ")",
		"SELECT date FROM transactions WHERE payee = '" + strings.Repeat("x", bqlMaxQueryLength) + "'",
	}
	for _, query := range queries {
		if _, err := parseBQL(query); err == nil {
			t.Fatalf("expected complexity limit rejection for query length %d", len(query))
		}
	}
}

func TestBQLDistinctRowsUsesUnambiguousKeys(t *testing.T) {
	rows := []bqlProjectedRow{{cells: []any{"a\x00string:b"}}, {cells: []any{"a", "b"}}}
	if distinct := bqlDistinctRows(rows); len(distinct) != 2 {
		t.Fatalf("distinct rows with delimiter-like values collided: %#v", distinct)
	}
}

func TestBQLFieldDefinitionsMatchExtractedRows(t *testing.T) {
	for _, table := range []string{"postings", "transactions"} {
		rows, err := bqlRows(bqlTestSnapshot(), table, "CNY")
		if err != nil {
			t.Fatal(err)
		}
		definitions := bqlFieldDefinitions(table)
		for _, row := range rows {
			if len(row.values) != len(definitions) {
				t.Fatalf("%s schema has %d fields but row has %d: %#v", table, len(definitions), len(row.values), row.values)
			}
			for _, definition := range definitions {
				value, ok := row.values[definition.name]
				if !ok || value.typ != definition.typ {
					t.Fatalf("%s field %s mismatch: definition=%#v value=%#v", table, definition.name, definition, value)
				}
			}
		}
	}
}
