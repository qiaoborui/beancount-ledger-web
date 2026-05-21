package app

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

func cents(value string) int {
	n, _ := strconv.ParseFloat(strings.TrimSpace(strings.TrimPrefix(strings.ReplaceAll(value, ",", ""), "¥")), 64)
	return int(math.Round(n * 100))
}

func fromCents(value int) string {
	return fmt.Sprintf("%.2f", float64(value)/100)
}
