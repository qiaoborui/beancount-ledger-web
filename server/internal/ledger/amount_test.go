package ledger

import "testing"

func TestBeanAmountPreservesExactCentsBehavior(t *testing.T) {
	tests := []struct {
		name   string
		amount BeanAmount
		want   int
	}{
		{name: "empty", amount: BeanAmount{}, want: 0},
		{name: "decimal", amount: BeanAmount{Number: "12.34", Currency: "CNY"}, want: 1234},
		{name: "half cent rounds away from zero", amount: BeanAmount{Number: "1.005", Currency: "CNY"}, want: 101},
		{name: "negative half cent", amount: BeanAmount{Number: "-1.005", Currency: "CNY"}, want: -101},
		{name: "formatted fallback", amount: BeanAmount{Number: "¥1,234.56", Currency: "CNY"}, want: 123456},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := test.amount.Cents(); got != test.want {
				t.Fatalf("Cents() = %d, want %d", got, test.want)
			}
		})
	}
	if got := (BeanAmount{Number: "12.34", Currency: "CNY"}).String(); got != "12.34 CNY" {
		t.Fatalf("String() = %q", got)
	}
}
