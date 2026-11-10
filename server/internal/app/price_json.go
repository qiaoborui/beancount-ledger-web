package app

import (
	"encoding/json"
	"strings"
)

// priceJSON is the wire shape of Price. `amount` stays the whole-cent value
// that existing clients read; `amountValue` carries the exact decimal from the
// price directive, because a sub-cent rate such as `price JPY 0.0478 CNY` or
// `price IDR 0.00045 CNY` rounds to 5 or 0 cents. It is omitted when the
// decimal is unknown (for example rows rebuilt from the Postgres read model).
type priceJSON struct {
	Date          string `json:"date"`
	Currency      string `json:"currency"`
	Amount        int    `json:"amount"`
	AmountValue   string `json:"amountValue,omitempty"`
	QuoteCurrency string `json:"quoteCurrency"`
}

func (price Price) MarshalJSON() ([]byte, error) {
	return json.Marshal(priceJSON{
		Date: price.Date, Currency: price.Currency, Amount: price.Amount,
		AmountValue: priceDecimalString(price.AmountValue.Number), QuoteCurrency: price.QuoteCurrency,
	})
}

func (price *Price) UnmarshalJSON(data []byte) error {
	var wire priceJSON
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	*price = Price{Date: wire.Date, Currency: wire.Currency, Amount: wire.Amount, QuoteCurrency: wire.QuoteCurrency}
	if number := priceDecimalString(wire.AmountValue); number != "" {
		price.AmountValue = BeanAmount{Number: number, Currency: wire.QuoteCurrency}
	}
	return nil
}

// priceDecimalString returns a plain decimal ("1234.5", "-0.0478") that any
// client can parse, dropping digit-group commas, or "" when it is not a number.
func priceDecimalString(raw string) string {
	number := strings.ReplaceAll(strings.TrimSpace(raw), ",", "")
	digits := strings.TrimPrefix(strings.TrimPrefix(number, "-"), "+")
	whole, fraction, _ := strings.Cut(digits, ".")
	if whole+fraction == "" || strings.Trim(whole+fraction, "0123456789") != "" {
		return ""
	}
	return number
}
