package app

import (
	"fmt"
	"math/rand"
	"reflect"
	"sort"
	"testing"
)

// Keep the original rich-copy algorithm as an independent ordering oracle,
// especially for equal dates/lines in different included files.
func richTransactionOrdersForTest(txns []Transaction) ([]Transaction, []Transaction) {
	asc, desc := append([]Transaction(nil), txns...), append([]Transaction(nil), txns...)
	sort.Slice(asc, func(i, j int) bool {
		if asc[i].Date == asc[j].Date {
			return asc[i].Source.Line < asc[j].Source.Line
		}
		return asc[i].Date < asc[j].Date
	})
	sort.Slice(desc, func(i, j int) bool {
		if desc[i].Date == desc[j].Date {
			return desc[i].Source.Line < desc[j].Source.Line
		}
		return desc[i].Date > desc[j].Date
	})
	return asc, desc
}

func TestTransactionOrderReferenceParity(t *testing.T) {
	random := rand.New(rand.NewSource(42))
	for _, n := range []int{0, 1, 17, 1200} {
		txns := make([]Transaction, n)
		for i := range txns {
			txns[i] = Transaction{Date: fmt.Sprintf("2026-09-%02d", 1+random.Intn(28)), Payee: fmt.Sprint(i), Source: TransactionSource{File: fmt.Sprintf("part-%d.bean", i%4), Line: random.Intn(30)}}
		}
		asc, desc := sortedTransactionViews(txns)
		wantAsc, wantDesc := richTransactionOrdersForTest(txns)
		for _, pair := range []struct {
			got  transactionOrder
			want []Transaction
		}{{asc, wantAsc}, {desc, wantDesc}} {
			if pair.got.Len() != len(pair.want) {
				t.Fatal("count changed")
			}
			seen := 0
			for txn := range pair.got.All() {
				if !reflect.DeepEqual(txn, pair.want[seen]) || !reflect.DeepEqual(pair.got.At(seen), txn) {
					t.Fatalf("n=%d index=%d order changed", n, seen)
				}
				seen++
			}
			if seen != n {
				t.Fatal("iteration omitted rows")
			}
			seen = 0
			for range pair.got.All() {
				seen++
				break
			}
			if n > 0 && seen != 1 {
				t.Fatal("early stop not respected")
			}
		}
		// The order references the primary array, rather than copied rich headers.
		if n > 0 {
			txns[asc.indices[0]].Narration = "primary"
			if asc.At(0).Narration != "primary" {
				t.Fatal("duplicated primary model")
			}
		}
	}
}

func TestTransactionOrderConsumersPreserveAccounting(t *testing.T) {
	txns := []Transaction{
		{Date: "2026-09-03", Payee: "Refund", Source: TransactionSource{Line: 20}, Postings: []Posting{{Account: "Assets:Cash", Amount: 300, Currency: "CNY"}}},
		{Date: "2026-09-01", Payee: "Opening", Source: TransactionSource{Line: 10}, Postings: []Posting{{Account: "Assets:Cash", Amount: 1000, Currency: "CNY"}, {Account: "Assets:Cash", Amount: 200, Currency: "USD"}}},
		{Date: "2026-09-03", Payee: "Expense", Source: TransactionSource{Line: 5}, Postings: []Posting{{Account: "Assets:Cash", Amount: -600, Currency: "CNY"}, {Account: "Assets:Cash", Amount: -100, Currency: "CNY"}}},
	}
	asc, _ := sortedTransactionViews(txns)
	want, _ := richTransactionOrdersForTest(txns)
	for _, currency := range []string{"", "CNY", "USD"} {
		got := accountDetailFromSequenceInCurrency("Assets:Cash", currency, asc.All())
		expected := AccountDetailFromSortedInCurrency("Assets:Cash", currency, want)
		if !reflect.DeepEqual(got, expected) {
			t.Fatal("account ordering changed")
		}
		if currency == "CNY" && (len(got) != 3 || got[0].Balance != 1000 || got[1].Balance != 300 || got[2].Balance != 600) {
			t.Fatal("running balance changed")
		}
	}
	if !reflect.DeepEqual(netWorthHistoryInCurrencySequence(asc.All(), nil, "CNY"), netWorthHistoryInCurrencyAsc(want, nil, "CNY")) {
		t.Fatal("net worth changed")
	}
}

func BenchmarkTransactionOrders100k(b *testing.B) {
	txns := make([]Transaction, 100000)
	for i := range txns {
		txns[i] = Transaction{Date: fmt.Sprintf("2026-09-%02d", 1+i%28), Source: TransactionSource{Line: i % 100}, Payee: "Synthetic"}
	}
	b.Run("rich-copies", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			a, d := richTransactionOrdersForTest(txns)
			if len(a) != 100000 || len(d) != 100000 {
				b.Fatal("missing")
			}
		}
	})
	b.Run("indices", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			a, d := sortedTransactionViews(txns)
			if a.Len() != 100000 || d.Len() != 100000 {
				b.Fatal("missing")
			}
		}
	})
}
