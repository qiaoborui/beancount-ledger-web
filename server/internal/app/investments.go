package app

import (
	"math"
	"sort"
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
	AverageCost    *float64        `json:"averageCost,omitempty"`
	CostValue      *float64        `json:"costValue,omitempty"`
	CostCurrency   string          `json:"costCurrency,omitempty"`
	MarketValue    *float64        `json:"marketValue,omitempty"`
	MarketCurrency string          `json:"marketCurrency,omitempty"`
	MarketValueCNY *int            `json:"marketValueCny,omitempty"`
	Lots           []InvestmentLot `json:"lots"`
}

type InvestmentLot struct {
	Date          string   `json:"date"`
	Account       string   `json:"account"`
	AccountLabel  string   `json:"accountLabel"`
	Commodity     string   `json:"commodity"`
	CommodityName string   `json:"commodityName"`
	Quantity      float64  `json:"quantity"`
	UnitCost      *float64 `json:"unitCost,omitempty"`
	CostValue     *float64 `json:"costValue,omitempty"`
	CostCurrency  string   `json:"costCurrency,omitempty"`
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
	AverageCost         *float64             `json:"averageCost,omitempty"`
	TotalCostValue      *float64             `json:"totalCostValue,omitempty"`
	CostCurrency        string               `json:"costCurrency,omitempty"`
	TotalMarketValue    *float64             `json:"totalMarketValue,omitempty"`
	MarketCurrency      string               `json:"marketCurrency,omitempty"`
	TotalMarketValueCNY *int                 `json:"totalMarketValueCny,omitempty"`
	AccountCount        int                  `json:"accountCount"`
	Positions           []InvestmentPosition `json:"positions"`
	Lots                []InvestmentLot      `json:"lots"`
}

type InvestmentSummary struct {
	TotalMarketValueCNY int                  `json:"totalMarketValueCny"`
	Holdings            []InvestmentHolding  `json:"holdings"`
	Positions           []InvestmentPosition `json:"positions"`
	Lots                []InvestmentLot      `json:"lots"`
	Quotes              []InvestmentQuote    `json:"quotes"`
	UpdatedAt           string               `json:"updatedAt,omitempty"`
}

var fiatCommodities = map[string]bool{
	"CNY": true,
	"USD": true,
	"HKD": true,
	"GBP": true,
	"EUR": true,
	"JPY": true,
}

func BuildInvestmentSummary(lines []BeanLine, accounts []Account, prices []Price) InvestmentSummary {
	return BuildInvestmentSummaryFromBeanEntries(ParseBeanLines(lines).Entries, accounts, prices)
}

func BuildInvestmentSummaryFromBeanEntries(entries []BeanEntry, accounts []Account, prices []Price) InvestmentSummary {
	commodities := parseCommodityDetails(entries)
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
	positionQuantities := investmentQuantities(entries, securities)
	positionCosts := investmentCosts(entries, securities)
	positionLots := investmentLots(entries, securities, accountMap, commodityMap)
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
			Lots:          positionLots[key],
		}
		if cost := positionCosts[key]; cost.valid() && !roundedZero(quantity) {
			value := cost.value
			average := cost.value / quantity
			position.CostValue = &value
			position.AverageCost = &average
			position.CostCurrency = cost.currency
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

	quotes := make([]InvestmentQuote, 0, len(quoteQuantity))
	updatedAt := ""
	for commodity := range quoteQuantity {
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

	lots := summaryLots(positionLots, positions)
	holdings := investmentHoldings(commodityMap, latestPrices, priceHistory, positions, quoteQuantity, priceIndex)
	return InvestmentSummary{TotalMarketValueCNY: totalCNY, Holdings: holdings, Positions: positions, Lots: lots, Quotes: quotes, UpdatedAt: updatedAt}
}

func parseCommodityDetails(entries []BeanEntry) []Commodity {
	commodities := map[string]*Commodity{}
	for _, entry := range entries {
		if entry.Kind != "commodity" || entry.Currency == "" {
			continue
		}
		item := &Commodity{Date: entry.Date, Symbol: entry.Currency, Name: entry.Currency, Metadata: map[string]MetadataValue{}}
		for key, value := range entry.Metadata {
			item.Metadata[key] = value
			if key == "name" {
				if name, ok := value.(string); ok && strings.TrimSpace(name) != "" {
					item.Name = strings.TrimSpace(name)
				}
			}
		}
		commodities[item.Symbol] = item
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

func investmentHoldings(commodityMap map[string]Commodity, latestPrices map[string]*CommodityPrice, priceHistory map[string][]CommodityPrice, positions []InvestmentPosition, quantities map[string]float64, priceIndex PriceIndex) []InvestmentHolding {
	byCommodity := map[string]*InvestmentHolding{}
	for _, position := range positions {
		holding := byCommodity[position.Commodity]
		if holding == nil {
			holding = &InvestmentHolding{
				Commodity:     position.Commodity,
				CommodityName: position.CommodityName,
				LatestPrice:   latestPrices[position.Commodity],
				PriceHistory:  commodityPriceHistory(priceHistory, position.Commodity),
				TotalQuantity: quantities[position.Commodity],
				Positions:     []InvestmentPosition{},
			}
			byCommodity[position.Commodity] = holding
		}
		holding.Positions = append(holding.Positions, position)
		holding.Lots = append(holding.Lots, position.Lots...)
		addPositionCost(holding, position)
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
		if holding.TotalCostValue != nil && !roundedZero(holding.TotalQuantity) {
			average := *holding.TotalCostValue / holding.TotalQuantity
			holding.AverageCost = &average
		}
		if holding.LatestPrice != nil && !roundedZero(holding.TotalQuantity) {
			value := holding.TotalQuantity * holding.LatestPrice.Amount
			holding.TotalMarketValue = &value
			holding.MarketCurrency = holding.LatestPrice.Currency
			if cny := marketValueCNY(value, holding.LatestPrice.Currency, priceIndex); cny != nil {
				holding.TotalMarketValueCNY = cny
			}
		}
		sortInvestmentLots(holding.Lots)
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

func summaryLots(positionLots map[string][]InvestmentLot, positions []InvestmentPosition) []InvestmentLot {
	held := map[string]bool{}
	for _, position := range positions {
		held[position.Account+"\x00"+position.Commodity] = true
	}
	lots := []InvestmentLot{}
	for key, rows := range positionLots {
		if held[key] {
			lots = append(lots, rows...)
		}
	}
	sortInvestmentLots(lots)
	return lots
}

func addPositionCost(holding *InvestmentHolding, position InvestmentPosition) {
	if position.CostValue == nil || position.CostCurrency == "" {
		return
	}
	if holding.CostCurrency != "" && holding.CostCurrency != position.CostCurrency {
		holding.TotalCostValue = nil
		holding.AverageCost = nil
		holding.CostCurrency = ""
		return
	}
	holding.CostCurrency = position.CostCurrency
	total := 0.0
	if holding.TotalCostValue != nil {
		total = *holding.TotalCostValue
	}
	total += *position.CostValue
	holding.TotalCostValue = &total
}

func commodityPriceHistory(priceHistory map[string][]CommodityPrice, commodity string) []CommodityPrice {
	return append([]CommodityPrice{}, priceHistory[commodity]...)
}

func investmentQuantities(entries []BeanEntry, securities map[string]bool) map[string]float64 {
	positions := map[string]float64{}
	for _, entry := range entries {
		if entry.Kind != "transaction" {
			continue
		}
		for _, posting := range entry.Postings {
			if !strings.HasPrefix(posting.Account, "Assets:") || !securities[posting.Currency] {
				continue
			}
			positions[posting.Account+"\x00"+posting.Currency] += float64(posting.Amount) / 100
		}
	}
	return positions
}

type investmentCost struct {
	value    float64
	currency string
	mixed    bool
}

func (cost investmentCost) valid() bool {
	return cost.currency != "" && !cost.mixed && !roundedZero(cost.value)
}

func investmentCosts(entries []BeanEntry, securities map[string]bool) map[string]investmentCost {
	costs := map[string]investmentCost{}
	for _, entry := range entries {
		if entry.Kind != "transaction" {
			continue
		}
		for _, posting := range entry.Postings {
			if posting.CostCurrency == "" || !strings.HasPrefix(posting.Account, "Assets:") || !securities[posting.Currency] {
				continue
			}
			key := posting.Account + "\x00" + posting.Currency
			current := costs[key]
			currency := posting.CostCurrency
			if current.currency != "" && current.currency != currency {
				current.mixed = true
				costs[key] = current
				continue
			}
			current.currency = currency
			if posting.TotalCost {
				current.value += float64(posting.CostAmount) / 100
			} else {
				current.value += (float64(posting.Amount) / 100) * (float64(posting.CostAmount) / 100)
			}
			costs[key] = current
		}
	}
	return costs
}

func investmentLots(entries []BeanEntry, securities map[string]bool, accountMap map[string]Account, commodityMap map[string]Commodity) map[string][]InvestmentLot {
	lots := map[string][]InvestmentLot{}
	for _, entry := range entries {
		if entry.Kind != "transaction" {
			continue
		}
		for _, posting := range entry.Postings {
			if !strings.HasPrefix(posting.Account, "Assets:") || !securities[posting.Currency] {
				continue
			}
			quantity := float64(posting.Amount) / 100
			if quantity <= 0 || roundedZero(quantity) {
				continue
			}
			accountName, commodity := posting.Account, posting.Currency
			label := accountName
			if acct := accountMap[accountName]; acct.Label != "" {
				label = acct.Label
			}
			lot := InvestmentLot{
				Date:          entry.Date,
				Account:       accountName,
				AccountLabel:  label,
				Commodity:     commodity,
				CommodityName: commodityName(commodityMap, commodity),
				Quantity:      quantity,
			}
			if posting.CostCurrency != "" {
				if posting.TotalCost {
					value := float64(posting.CostAmount) / 100
					unit := value / quantity
					lot.UnitCost = &unit
					lot.CostValue = &value
				} else {
					unit := float64(posting.CostAmount) / 100
					value := quantity * unit
					lot.UnitCost = &unit
					lot.CostValue = &value
				}
				lot.CostCurrency = posting.CostCurrency
			}
			key := accountName + "\x00" + commodity
			lots[key] = append(lots[key], lot)
		}
	}
	for key := range lots {
		sortInvestmentLots(lots[key])
	}
	return lots
}

func sortInvestmentLots(lots []InvestmentLot) {
	sort.Slice(lots, func(i, j int) bool {
		if lots[i].Date != lots[j].Date {
			return lots[i].Date > lots[j].Date
		}
		if lots[i].Commodity != lots[j].Commodity {
			return lots[i].Commodity < lots[j].Commodity
		}
		return lots[i].Account < lots[j].Account
	})
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
