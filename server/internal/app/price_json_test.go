package app

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPriceJSONKeepsCentsAndCarriesExactDecimal(t *testing.T) {
	for _, tc := range []struct {
		name   string
		price  Price
		want   string
		amount int
	}{
		{"sub-cent rate", Price{Date: "2026-09-01", Currency: "JPY", Amount: 5, AmountValue: BeanAmount{Number: "0.0478", Currency: "CNY"}, QuoteCurrency: "CNY"},
			`{"date":"2026-09-01","currency":"JPY","amount":5,"amountValue":"0.0478","quoteCurrency":"CNY"}`, 5},
		{"rounds to zero cents", Price{Date: "2026-09-01", Currency: "IDR", Amount: 0, AmountValue: BeanAmount{Number: "0.00045", Currency: "CNY"}, QuoteCurrency: "CNY"},
			`{"date":"2026-09-01","currency":"IDR","amount":0,"amountValue":"0.00045","quoteCurrency":"CNY"}`, 0},
		{"digit groups", Price{Date: "2026-09-01", Currency: "BTC", Amount: 45_000_000, AmountValue: BeanAmount{Number: "450,000.00"}, QuoteCurrency: "CNY"},
			`{"date":"2026-09-01","currency":"BTC","amount":45000000,"amountValue":"450000.00","quoteCurrency":"CNY"}`, 45_000_000},
		// Rows rebuilt from the Postgres read model carry only cents.
		{"no decimal", Price{Date: "2026-09-01", Currency: "USD", Amount: 713, QuoteCurrency: "CNY"},
			`{"date":"2026-09-01","currency":"USD","amount":713,"quoteCurrency":"CNY"}`, 713},
		{"not a plain decimal", Price{Date: "2026-09-01", Currency: "USD", Amount: 713, AmountValue: BeanAmount{Number: "1/3"}, QuoteCurrency: "CNY"},
			`{"date":"2026-09-01","currency":"USD","amount":713,"quoteCurrency":"CNY"}`, 713},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw, err := json.Marshal(tc.price)
			if err != nil || string(raw) != tc.want {
				t.Fatalf("marshal = %s, %v; want %s", raw, err, tc.want)
			}
			var decoded Price
			if err := json.Unmarshal(raw, &decoded); err != nil || decoded.Amount != tc.amount {
				t.Fatalf("unmarshal = %+v, %v", decoded, err)
			}
			if again, _ := json.Marshal(decoded); string(again) != tc.want {
				t.Fatalf("round trip = %s", again)
			}
		})
	}
	// Envelopes that hold prices use the same encoding.
	raw, err := json.Marshal(struct {
		Prices []Price `json:"prices"`
	}{[]Price{{Currency: "JPY", Amount: 5, AmountValue: BeanAmount{Number: "0.0478"}, QuoteCurrency: "CNY"}}})
	if err != nil || !strings.Contains(string(raw), `"amountValue":"0.0478"`) {
		t.Fatalf("envelope = %s, %v", raw, err)
	}
}
