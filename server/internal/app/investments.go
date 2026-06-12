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

type InvestmentHolding struct {
	Commodity           string               `json:"commodity"`
	CommodityName       string               `json:"commodityName"`
	LatestPrice         *CommodityPrice      `json:"latestPrice,omitempty"`
	PriceHistory        []CommodityPrice     `json:"priceHistory"`
	TotalQuantity       float64              `json:"totalQuantity"`
	TotalMarketValue    *float64             `json:"totalMarketValue,omitempty"`
	MarketCurrency      string               `json:"marketCurrency,omitempty"`
	TotalMarketValueCNY *int                 `json:"totalMarketValueCny,omitempty"`
	AccountCount        int                  `json:"accountCount"`
	Positions           []InvestmentPosition `json:"positions"`
}

type InvestmentSummary struct {
	TotalMarketValueCNY int                  `json:"totalMarketValueCny"`
	Holdings            []InvestmentHolding  `json:"holdings"`
	Positions           []InvestmentPosition `json:"positions"`
	Quotes              []InvestmentQuote    `json:"quotes"`
	UpdatedAt           string               `json:"updatedAt,omitempty"`
}

var (
	commodityDetailRe   = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})\s+commodity\s+(` + commodityPattern + `)\b`)
	investmentPostingRe = regexp.MustCompile(`^\s+([A-Z][A-Za-z0-9-:]+)\s+(-?\d+(?:\.\d+)?)\s+(` + commodityPattern + `)\b`)
)

var fiatCommodities = map[string]bool{
	"CNY": true,
	"USD": true,
	"HKD": true,
	"GBP": true,
	"EUR": true,
	"JPY": true,
}

func BuildInvestmentSummary(lines []BeanLine, accounts []Account, prices []Price) InvestmentSummary {
	commodities := parseCommodityDetails(lines)
	commodityMap := map[string]Commodity{}
	securities := map[string]bool{}
	for _, commodity := range commodities {
		commodityMap[commodity.Symbol] = commodity
		if !fiatCommodities[commodity.Symbol] {
			securities[commodity.Symbol] = true
		}
	}
	for _, price := range prices {
		if !fiatCommodities[price.Currency] {
			securities[price.Currency] = true
		}
	}
	accountMap := map[string]Account{}
	for _, account := range accounts {
		accountMap[account.Account] = account
		if !fiatCommodities[account.Currency] {
			securities[account.Currency] = true
		}
	}

	priceIndex := NewPriceIndex(prices)
	latestPrices := latestInvestmentPrices(prices)
	priceHistory := investmentPriceHistory(prices)
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
			if cny := marketValueCNY(value, position.LatestPrice.Currency, priceIndex); cny != nil {
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
				if cny := marketValueCNY(value, quote.LatestPrice.Currency, priceIndex); cny != nil {
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

	holdings := investmentHoldings(securities, commodityMap, latestPrices, priceHistory, positions, quoteQuantity, priceIndex)
	return InvestmentSummary{TotalMarketValueCNY: totalCNY, Holdings: holdings, Positions: positions, Quotes: quotes, UpdatedAt: updatedAt}
}

func parseCommodityDetails(lines []BeanLine) []Commodity {
	commodities := map[string]*Commodity{}
	var current string
	for _, line := range lines {
		if m := commodityDetailRe.FindStringSubmatch(strings.TrimSpace(line.Text)); m != nil {
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

func latestInvestmentPrices(prices []Price) map[string]*CommodityPrice {
	latest := map[string]*CommodityPrice{}
	for _, price := range prices {
		candidate := CommodityPrice{Date: price.Date, Commodity: price.Currency, Amount: float64(price.Amount) / 100, Currency: price.QuoteCurrency}
		current := latest[candidate.Commodity]
		if current == nil || candidate.Date >= current.Date {
			latest[candidate.Commodity] = &candidate
		}
	}
	return latest
}

func investmentPriceHistory(prices []Price) map[string][]CommodityPrice {
	history := map[string][]CommodityPrice{}
	for _, price := range prices {
		point := CommodityPrice{Date: price.Date, Commodity: price.Currency, Amount: float64(price.Amount) / 100, Currency: price.QuoteCurrency}
		history[point.Commodity] = append(history[point.Commodity], point)
	}
	for commodity := range history {
		sort.Slice(history[commodity], func(i, j int) bool {
			if history[commodity][i].Date == history[commodity][j].Date {
				return history[commodity][i].Currency < history[commodity][j].Currency
			}
			return history[commodity][i].Date < history[commodity][j].Date
		})
	}
	return history
}

func investmentHoldings(securities map[string]bool, commodityMap map[string]Commodity, latestPrices map[string]*CommodityPrice, priceHistory map[string][]CommodityPrice, positions []InvestmentPosition, quantities map[string]float64, priceIndex PriceIndex) []InvestmentHolding {
	byCommodity := map[string]*InvestmentHolding{}
	for commodity := range securities {
		byCommodity[commodity] = &InvestmentHolding{
			Commodity:     commodity,
			CommodityName: commodityName(commodityMap, commodity),
			LatestPrice:   latestPrices[commodity],
			PriceHistory:  append([]CommodityPrice(nil), priceHistory[commodity]...),
			TotalQuantity: quantities[commodity],
			Positions:     []InvestmentPosition{},
		}
	}
	for _, position := range positions {
		holding := byCommodity[position.Commodity]
		if holding == nil {
			holding = &InvestmentHolding{
				Commodity:     position.Commodity,
				CommodityName: position.CommodityName,
				LatestPrice:   latestPrices[position.Commodity],
				PriceHistory:  append([]CommodityPrice(nil), priceHistory[position.Commodity]...),
				TotalQuantity: quantities[position.Commodity],
				Positions:     []InvestmentPosition{},
			}
			byCommodity[position.Commodity] = holding
		}
		holding.Positions = append(holding.Positions, position)
	}
	holdings := make([]InvestmentHolding, 0, len(byCommodity))
	for _, holding := range byCommodity {
		sort.Slice(holding.Positions, func(i, j int) bool {
			left, right := cnyValue(holding.Positions[i].MarketValueCNY), cnyValue(holding.Positions[j].MarketValueCNY)
			if left != right {
				return left > right
			}
			return holding.Positions[i].Account < holding.Positions[j].Account
		})
		holding.AccountCount = len(holding.Positions)
		if holding.LatestPrice != nil && !roundedZero(holding.TotalQuantity) {
			value := holding.TotalQuantity * holding.LatestPrice.Amount
			holding.TotalMarketValue = &value
			holding.MarketCurrency = holding.LatestPrice.Currency
			if cny := marketValueCNY(value, holding.LatestPrice.Currency, priceIndex); cny != nil {
				holding.TotalMarketValueCNY = cny
			}
		}
		holdings = append(holdings, *holding)
	}
	sort.Slice(holdings, func(i, j int) bool {
		left, right := cnyValue(holdings[i].TotalMarketValueCNY), cnyValue(holdings[j].TotalMarketValueCNY)
		if left != right {
			return left > right
		}
		if holdings[i].AccountCount != holdings[j].AccountCount {
			return holdings[i].AccountCount > holdings[j].AccountCount
		}
		return holdings[i].Commodity < holdings[j].Commodity
	})
	return holdings
}

func investmentQuantities(lines []BeanLine, securities map[string]bool) map[string]float64 {
	positions := map[string]float64{}
	currentTxn := false
	for _, line := range lines {
		if txnRe.MatchString(line.Text) {
			currentTxn = true
			continue
		}
		if directiveRe.MatchString(line.Text) {
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

func marketValueCNY(value float64, currency string, priceIndex PriceIndex) *int {
	if currency == "CNY" {
		cny := int(math.Round(value * 100))
		return &cny
	}
	cny, ok := priceIndex.Valuation(int(math.Round(value*100)), currency, "CNY", "")
	if !ok {
		return nil
	}
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
