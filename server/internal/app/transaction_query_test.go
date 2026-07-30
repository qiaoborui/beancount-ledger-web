package app

import "testing"

func TestTransactionQueryBooleanFieldsAndComparisons(t *testing.T) {
	rows := []Transaction{
		{
			Date:      "2026-05-03",
			Payee:     "Blue Coffee",
			Narration: "latte",
			Metadata:  map[string]MetadataValue{"platform": "alipay"},
			Tags:      []string{"work"},
			Postings: []Posting{
				{Account: "Expenses:Food:Coffee", Amount: 3200, Currency: "CNY"},
				{Account: "Assets:CN:CMB", Amount: -3200, Currency: "CNY"},
			},
		},
		{
			Date:      "2026-05-04",
			Payee:     "KFC",
			Narration: "lunch",
			Metadata:  map[string]MetadataValue{"platform": "wechat"},
			Tags:      []string{"family"},
			Postings: []Posting{
				{Account: "Expenses:Food:FastFood", Amount: 4600, Currency: "CNY"},
				{Account: "Assets:CN:CMB", Amount: -4600, Currency: "CNY"},
			},
		},
		{
			Date:      "2026-05-05",
			Payee:     "Employer",
			Narration: "salary",
			Tags:      []string{"payroll"},
			Postings: []Posting{
				{Account: "Assets:CN:CMB", Amount: 1000000, Currency: "CNY"},
				{Account: "Income:Salary", Amount: -1000000, Currency: "CNY"},
			},
		},
	}

	cases := []struct {
		query string
		want  []string
	}{
		{"coffee", []string{"Blue Coffee"}},
		{"account:Expenses:Food AND NOT tag:family", []string{"Blue Coffee"}},
		{"payee:KFC OR meta.platform:alipay", []string{"Blue Coffee", "KFC"}},
		{"(payee:KFC OR payee:Blue) AND amount>40", []string{"KFC"}},
		{"date>=2026-05-04 AND type:income", []string{"Employer"}},
	}

	for _, tc := range cases {
		parsed, err := ParseTransactionQuery(tc.query)
		if err != nil {
			t.Fatalf("ParseTransactionQuery(%q): %v", tc.query, err)
		}
		gotRows := FilterTransactionsByQuery(rows, parsed)
		got := make([]string, 0, len(gotRows))
		for _, row := range gotRows {
			got = append(got, row.Payee)
		}
		if !equalStringSlices(got, tc.want) {
			t.Fatalf("FilterTransactionsByQuery(%q) = %#v, want %#v", tc.query, got, tc.want)
		}
	}
}

func TestTransactionQueryRejectsUnknownFields(t *testing.T) {
	if _, err := ParseTransactionQuery("sql:drop"); err == nil {
		t.Fatal("expected unknown field to fail")
	}
}

func equalStringSlices(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
