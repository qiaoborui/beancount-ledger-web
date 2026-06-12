package app

import (
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type Commodity struct {
	Date     string                   `json:"date"`
	Symbol   string                   `json:"symbol"`
	Name     string                   `json:"name"`
	Metadata map[string]MetadataValue `json:"metadata,omitempty"`
}

type CommodityPrice struct {
	Date      string  `json:"date"`
	Commodity string  `json:"commodity"`
	Amount    float64 `json:"amount"`
	Currency  string  `json:"currency"`
}

type InvestmentPosition struct {
	Account        string          `json:"account"`
	AccountLabel   string          `json:"accountLabel"`
	Commodity      string          `json:"commodity"`
	CommodityName  string          `json:"commodityName"`
	Quantity       float64         `json:"quantity"`
	LatestPrice    *CommodityPrice `json:"latestPrice,omitempty"`
	MarketValue    *float64        `json:"marketValue,omitempty"`
	MarketCurrency string          `json:"marketCurrency,omitempty"`
	MarketValueCNY *int            `json:"marketValueCny,omitempty"`
}

type InvestmentQuote struct {
	Commodity        string          `json:"commodity"`
	CommodityName    string          `json:"commodityName"`
	LatestPrice      *CommodityPrice `json:"latestPrice,omitempty"`
	MarketCurrency   string          `json:"marketCurrency,omitempty"`
	MarketValueCNY   *int            `json:"marketValueCny,omitempty"`
	PositionCount    int             `json:"positionCount"`
	PositionQuantity float64         `json:"positionQuantity"`
}

type InvestmentSummary struct {
	TotalMarketValueCNY int                  `json:"totalMarketValueCny"`
	Positions           []InvestmentPosition `json:"positions"`
	Quotes              []InvestmentQuote    `json:"quotes"`
	UpdatedAt           string               `json:"updatedAt,omitempty"`
}

var (
	commodityRe         = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})\s+commodity\s+([A-Z][A-Z0-9._-]*)\b`)
	priceRe             = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})\s+price\s+([A-Z][A-Z0-9._-]*)\s+(-?\d+(?:\.\d+)?)\s+([A-Z][A-Z0-9._-]*)\b`)
	investmentPostingRe = regexp.MustCompile(`^\s+([A-Z][A-Za-z0-9-:]+)\s+(-?\d+(?:\.\d+)?)\s+([A-Z][A-Z0-9._-]*)\b`)
)

var fiatCommodities = map[string]bool{
	"CNY": true,
	"USD": true,
	"HKD": true,
	"GBP": true,
	"EUR": true,
	"JPY": true,
}

func ParseCommodities(lines []BeanLine) []Commodity {
	commodities := map[string]*Commodity{}
	var current string
	for _, line := range lines {
		if m := commodityRe.FindStringSubmatch(strings.TrimSpace(line.Text)); m != nil {
			item := &Commodity{Date: m[1], Symbol: m[2], Name: m[2], Metadata: map[string]MetadataValue{}}
			commodities[item.Symbol] = item
			current = item.Symbol
			continue
		}
		if m := metaRe.FindStringSubmatch(line.Text); m != nil && current != "" {
			item := commodities[current]
			if item == nil {
				continue
			}
			value := parseMetadataValue(m[2])
			item.Metadata[m[1]] = value
			if m[1] == "name" {
				if name, ok := value.(string); ok && strings.TrimSpace(name) != "" {
					item.Name = strings.TrimSpace(name)
				}
			}
			continue
		}
		if strings.TrimSpace(line.Text) != "" && !strings.HasPrefix(line.Text, " ") {
			current = ""
		}
	}
	out := make([]Commodity, 0, len(commodities))
	for _, item := range commodities {
		out = append(out, *item)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Symbol < out[j].Symbol })
	return out
}

func ParsePrices(lines []BeanLine) []CommodityPrice {
	out := []CommodityPrice{}
	for _, line := range lines {
		if m := priceRe.FindStringSubmatch(strings.TrimSpace(line.Text)); m != nil {
			out = append(out, CommodityPrice{Date: m[1], Commodity: m[2], Amount: decimal(m[3]), Currency: m[4]})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Commodity != out[j].Commodity {
			return out[i].Commodity < out[j].Commodity
		}
		return out[i].Date < out[j].Date
	})
	return out
}

func BuildInvestmentSummary(lines []BeanLine, accounts []Account) InvestmentSummary {
	commodities := ParseCommodities(lines)
	prices := ParsePrices(lines)
	commodityMap := map[string]Commodity{}
	securities := map[string]bool{}
	for _, commodity := range commodities {
		commodityMap[commodity.Symbol] = commodity
		if !fiatCommodities[commodity.Symbol] {
			securities[commodity.Symbol] = true
		}
	}
	for _, price := range prices {
		if !fiatCommodities[price.Commodity] {
			securities[price.Commodity] = true
		}
	}
	accountMap := map[string]Account{}
	for _, account := range accounts {
		accountMap[account.Account] = account
		if !fiatCommodities[account.Currency] {
			securities[account.Currency] = true
		}
	}

	latestPrices := latestCommodityPrices(prices)
	positionQuantities := investmentQuantities(lines, securities)
	positions := make([]InvestmentPosition, 0, len(positionQuantities))
	quoteQuantity := map[string]float64{}
	quotePositionCount := map[string]int{}
	totalCNY := 0
	for key, quantity := range positionQuantities {
		if roundedZero(quantity) {
			continue
		}
		parts := strings.SplitN(key, "\x00", 2)
		accountName, commodity := parts[0], parts[1]
		acct := accountMap[accountName]
		label := accountName
		if acct.Label != "" {
			label = acct.Label
		}
		position := InvestmentPosition{
			Account:       accountName,
			AccountLabel:  label,
			Commodity:     commodity,
			CommodityName: commodityName(commodityMap, commodity),
			Quantity:      quantity,
			LatestPrice:   latestPrices[commodity],
		}
		if position.LatestPrice != nil {
			value := quantity * position.LatestPrice.Amount
			position.MarketValue = &value
			position.MarketCurrency = position.LatestPrice.Currency
			if cny := marketValueCNY(value, position.LatestPrice.Currency, latestPrices); cny != nil {
				position.MarketValueCNY = cny
				totalCNY += *cny
			}
		}
		positions = append(positions, position)
		quoteQuantity[commodity] += quantity
		quotePositionCount[commodity]++
		securities[commodity] = true
	}
	sort.Slice(positions, func(i, j int) bool {
		left, right := cnyValue(positions[i].MarketValueCNY), cnyValue(positions[j].MarketValueCNY)
		if left != right {
			return left > right
		}
		if positions[i].Commodity != positions[j].Commodity {
			return positions[i].Commodity < positions[j].Commodity
		}
		return positions[i].Account < positions[j].Account
	})

	quotes := make([]InvestmentQuote, 0, len(securities))
	updatedAt := ""
	for commodity := range securities {
		quote := InvestmentQuote{
			Commodity:        commodity,
			CommodityName:    commodityName(commodityMap, commodity),
			LatestPrice:      latestPrices[commodity],
			PositionCount:    quotePositionCount[commodity],
			PositionQuantity: quoteQuantity[commodity],
		}
		if quote.LatestPrice != nil {
			quote.MarketCurrency = quote.LatestPrice.Currency
			if quote.LatestPrice.Date > updatedAt {
				updatedAt = quote.LatestPrice.Date
			}
			if !roundedZero(quote.PositionQuantity) {
				value := quote.PositionQuantity * quote.LatestPrice.Amount
				if cny := marketValueCNY(value, quote.LatestPrice.Currency, latestPrices); cny != nil {
					quote.MarketValueCNY = cny
				}
			}
		}
		quotes = append(quotes, quote)
	}
	sort.Slice(quotes, func(i, j int) bool {
		left, right := cnyValue(quotes[i].MarketValueCNY), cnyValue(quotes[j].MarketValueCNY)
		if left != right {
			return left > right
		}
		return quotes[i].Commodity < quotes[j].Commodity
	})

	return InvestmentSummary{TotalMarketValueCNY: totalCNY, Positions: positions, Quotes: quotes, UpdatedAt: updatedAt}
}

func latestCommodityPrices(prices []CommodityPrice) map[string]*CommodityPrice {
	latest := map[string]*CommodityPrice{}
	for i := range prices {
		price := prices[i]
		current := latest[price.Commodity]
		if current == nil || price.Date >= current.Date {
			latest[price.Commodity] = &price
		}
	}
	return latest
}

func investmentQuantities(lines []BeanLine, securities map[string]bool) map[string]float64 {
	positions := map[string]float64{}
	currentTxn := false
	for _, line := range lines {
		if txnRe.MatchString(line.Text) {
			currentTxn = true
			continue
		}
		if regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\s+`).MatchString(line.Text) {
			currentTxn = false
			continue
		}
		if !currentTxn {
			continue
		}
		m := investmentPostingRe.FindStringSubmatch(line.Text)
		if m == nil || !strings.HasPrefix(m[1], "Assets:") || !securities[m[3]] {
			continue
		}
		positions[m[1]+"\x00"+m[3]] += decimal(m[2])
	}
	return positions
}

func marketValueCNY(value float64, currency string, latest map[string]*CommodityPrice) *int {
	if currency == "CNY" {
		cny := int(math.Round(value * 100))
		return &cny
	}
	fx := latest[currency]
	if fx == nil || fx.Currency != "CNY" {
		return nil
	}
	cny := int(math.Round(value * fx.Amount * 100))
	return &cny
}

func commodityName(commodities map[string]Commodity, symbol string) string {
	if commodity, ok := commodities[symbol]; ok && strings.TrimSpace(commodity.Name) != "" {
		return commodity.Name
	}
	return symbol
}

func cnyValue(value *int) int {
	if value == nil {
		return math.MinInt
	}
	return *value
}

func roundedZero(value float64) bool {
	return math.Abs(value) < 0.00000001
}

func decimal(value string) float64 {
	n, _ := strconv.ParseFloat(strings.TrimSpace(strings.ReplaceAll(value, ",", "")), 64)
	return n
}
