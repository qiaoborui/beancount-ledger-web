package ledger

import (
	"math"
	"math/big"
	"strconv"
	"strings"
)

type BeanAmount struct {
	Number   string
	Currency string
}

func (amount BeanAmount) String() string {
	if amount.Currency == "" {
		return amount.Number
	}
	return strings.TrimSpace(amount.Number + " " + amount.Currency)
}

func (amount BeanAmount) Cents() int {
	if amount.Number == "" {
		return 0
	}
	rat, ok := new(big.Rat).SetString(amount.Number)
	if !ok {
		return parseCents(amount.Number)
	}
	rat.Mul(rat, big.NewRat(100, 1))
	value, _ := rat.Float64()
	return int(math.Round(value))
}

func parseCents(value string) int {
	number, _ := strconv.ParseFloat(strings.TrimSpace(strings.TrimPrefix(strings.ReplaceAll(value, ",", ""), "¥")), 64)
	return int(math.Round(number * 100))
}
