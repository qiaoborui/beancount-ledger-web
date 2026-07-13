package app

import (
	"math"
	"math/big"
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
	Account          string                    `json:"account"`
	AccountLabel     string                    `json:"accountLabel"`
	Commodity        string                    `json:"commodity"`
	CommodityName    string                    `json:"commodityName"`
	Quantity         float64                   `json:"quantity"`
	LatestPrice      *CommodityPrice           `json:"latestPrice,omitempty"`
	AverageCost      *float64                  `json:"averageCost,omitempty"`
	CostValue        *float64                  `json:"costValue,omitempty"`
	CostCurrency     string                    `json:"costCurrency,omitempty"`
	CostValueCNY     *int                      `json:"costValueCny,omitempty"`
	MarketValue      *float64                  `json:"marketValue,omitempty"`
	MarketCurrency   string                    `json:"marketCurrency,omitempty"`
	MarketValueCNY   *int                      `json:"marketValueCny,omitempty"`
	Lots             []InvestmentLot           `json:"lots"`
	RealizedTrades   []InvestmentRealizedTrade `json:"realizedTrades"`
	RealizedPnL      *float64                  `json:"realizedPnl,omitempty"`
	RealizedCurrency string                    `json:"realizedCurrency,omitempty"`
	RealizedPnLCNY   *int                      `json:"realizedPnlCny,omitempty"`
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

type InvestmentRealizedTrade struct {
	Date             string   `json:"date"`
	Account          string   `json:"account"`
	AccountLabel     string   `json:"accountLabel"`
	Commodity        string   `json:"commodity"`
	CommodityName    string   `json:"commodityName"`
	Quantity         float64  `json:"quantity"`
	ProceedsValue    *float64 `json:"proceedsValue,omitempty"`
	ProceedsCurrency string   `json:"proceedsCurrency,omitempty"`
	CostValue        *float64 `json:"costValue,omitempty"`
	CostCurrency     string   `json:"costCurrency,omitempty"`
	RealizedPnL      *float64 `json:"realizedPnl,omitempty"`
	RealizedCurrency string   `json:"realizedCurrency,omitempty"`
	RealizedPnLCNY   *int     `json:"realizedPnlCny,omitempty"`
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
	Commodity           string                    `json:"commodity"`
	CommodityName       string                    `json:"commodityName"`
	LatestPrice         *CommodityPrice           `json:"latestPrice,omitempty"`
	PriceHistory        []CommodityPrice          `json:"priceHistory"`
	TotalQuantity       float64                   `json:"totalQuantity"`
	AverageCost         *float64                  `json:"averageCost,omitempty"`
	TotalCostValue      *float64                  `json:"totalCostValue,omitempty"`
	CostCurrency        string                    `json:"costCurrency,omitempty"`
	TotalCostValueCNY   *int                      `json:"totalCostValueCny,omitempty"`
	TotalMarketValue    *float64                  `json:"totalMarketValue,omitempty"`
	MarketCurrency      string                    `json:"marketCurrency,omitempty"`
	TotalMarketValueCNY *int                      `json:"totalMarketValueCny,omitempty"`
	AccountCount        int                       `json:"accountCount"`
	Positions           []InvestmentPosition      `json:"positions"`
	Lots                []InvestmentLot           `json:"lots"`
	RealizedTrades      []InvestmentRealizedTrade `json:"realizedTrades"`
	RealizedPnL         *float64                  `json:"realizedPnl,omitempty"`
	RealizedCurrency    string                    `json:"realizedCurrency,omitempty"`
	RealizedPnLCNY      *int                      `json:"realizedPnlCny,omitempty"`
}

type InvestmentSummary struct {
	TotalMarketValueCNY int                  `json:"totalMarketValueCny"`
	RealizedPnLCNY      *int                 `json:"realizedPnlCny,omitempty"`
	Holdings            []InvestmentHolding  `json:"holdings"`
	ClosedHoldings      []InvestmentHolding  `json:"closedHoldings,omitempty"`
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

func BuildInvestmentSummaryFromSnapshot(snapshot *LedgerSnapshot) InvestmentSummary {
	if snapshot == nil {
		return InvestmentSummary{}
	}
	if len(snapshot.BeanEntries) > 0 {
		return BuildInvestmentSummaryFromBeanEntries(snapshot.BeanEntries, snapshot.Accounts, snapshot.Prices)
	}
	return BuildInvestmentSummaryFromTransactions(snapshot.Transactions, snapshot.Accounts, snapshot.Prices, snapshot.Commodities)
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

	priceIndex := newInvestmentPriceIndex(prices)
	latestPrices := latestInvestmentPrices(prices)
	priceHistory := investmentPriceHistory(prices)
	positionQuantities := investmentQuantities(entries, securities)
	activity := investmentActivityFromEntries(entries, securities, accountMap, commodityMap, priceIndex)
	positionLots := activity.Lots
	positionCosts := investmentCostsFromLots(positionLots)
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
			Account:        accountName,
			AccountLabel:   label,
			Commodity:      commodity,
			CommodityName:  commodityName(commodityMap, commodity),
			Quantity:       quantity,
			LatestPrice:    latestPrices[commodity],
			Lots:           positionLots[key],
			RealizedTrades: activity.Realized[key],
		}
		if cost := positionCosts[key]; cost.valid() && !roundedZero(quantity) {
			value := cost.value
			average := cost.value / quantity
			position.CostValue = &value
			position.AverageCost = &average
			position.CostCurrency = cost.currency
			if cny := marketValueCNY(value, cost.currency, priceIndex); cny != nil {
				position.CostValueCNY = cny
			}
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
		addPositionRealized(&position, priceIndex)
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
	closedHoldings := closedInvestmentHoldings(commodityMap, latestPrices, priceHistory, positionQuantities, activity.Realized, accountMap, priceIndex)
	realizedPnLCNY := realizedTradesCNY(activity.Realized)
	return InvestmentSummary{TotalMarketValueCNY: totalCNY, RealizedPnLCNY: realizedPnLCNY, Holdings: holdings, ClosedHoldings: closedHoldings, Positions: positions, Lots: lots, Quotes: quotes, UpdatedAt: updatedAt}
}

func BuildInvestmentSummaryFromTransactions(txns []Transaction, accounts []Account, prices []Price, commodities []string) InvestmentSummary {
	commodityMap := map[string]Commodity{}
	securities := map[string]bool{}
	for _, commodity := range commodities {
		if !fiatCommodities[commodity] {
			securities[commodity] = true
			commodityMap[commodity] = Commodity{Symbol: commodity, Name: commodity}
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

	priceIndex := newInvestmentPriceIndex(prices)
	latestPrices := latestInvestmentPrices(prices)
	priceHistory := investmentPriceHistory(prices)
	positionQuantities := investmentQuantitiesFromTransactions(txns, securities)
	positionLots := investmentLotsFromTransactions(txns, securities, accountMap, commodityMap)
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
		candidate := CommodityPrice{Date: price.Date, Commodity: price.Currency, Amount: investmentPriceAmount(price), Currency: price.QuoteCurrency}
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
		point := CommodityPrice{Date: price.Date, Commodity: price.Currency, Amount: investmentPriceAmount(price), Currency: price.QuoteCurrency}
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

func investmentHoldings(commodityMap map[string]Commodity, latestPrices map[string]*CommodityPrice, priceHistory map[string][]CommodityPrice, positions []InvestmentPosition, quantities map[string]float64, priceIndex investmentPriceIndex) []InvestmentHolding {
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
		holding.RealizedTrades = append(holding.RealizedTrades, position.RealizedTrades...)
		addPositionCost(holding, position)
		addPositionRealizedToHolding(holding, position)
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
		sortInvestmentRealizedTrades(holding.RealizedTrades)
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

func closedInvestmentHoldings(commodityMap map[string]Commodity, latestPrices map[string]*CommodityPrice, priceHistory map[string][]CommodityPrice, quantities map[string]float64, realized map[string][]InvestmentRealizedTrade, accountMap map[string]Account, priceIndex investmentPriceIndex) []InvestmentHolding {
	positions := []InvestmentPosition{}
	commodityQuantities := map[string]float64{}
	for key, trades := range realized {
		if len(trades) == 0 || !roundedZero(quantities[key]) {
			continue
		}
		parts := strings.SplitN(key, "\x00", 2)
		if len(parts) != 2 {
			continue
		}
		accountName, commodity := parts[0], parts[1]
		label := accountName
		if acct := accountMap[accountName]; acct.Label != "" {
			label = acct.Label
		}
		position := InvestmentPosition{
			Account:        accountName,
			AccountLabel:   label,
			Commodity:      commodity,
			CommodityName:  commodityName(commodityMap, commodity),
			LatestPrice:    latestPrices[commodity],
			RealizedTrades: trades,
		}
		addPositionRealized(&position, priceIndex)
		positions = append(positions, position)
		commodityQuantities[commodity] += quantities[key]
	}
	return investmentHoldings(commodityMap, latestPrices, priceHistory, positions, commodityQuantities, priceIndex)
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

func realizedTradesCNY(realized map[string][]InvestmentRealizedTrade) *int {
	total := 0
	count := 0
	for _, trades := range realized {
		for _, trade := range trades {
			if trade.RealizedPnLCNY == nil {
				continue
			}
			total += *trade.RealizedPnLCNY
			count++
		}
	}
	if count == 0 {
		return nil
	}
	return &total
}

func addPositionCost(holding *InvestmentHolding, position InvestmentPosition) {
	if position.CostValue == nil || position.CostCurrency == "" {
		return
	}
	if position.CostValueCNY != nil {
		totalCNY := 0
		if holding.TotalCostValueCNY != nil {
			totalCNY = *holding.TotalCostValueCNY
		}
		totalCNY += *position.CostValueCNY
		holding.TotalCostValueCNY = &totalCNY
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

func addPositionRealized(position *InvestmentPosition, priceIndex investmentPriceIndex) {
	addRealizedTotals(position.RealizedTrades, func(value float64, currency string, cny *int) {
		position.RealizedPnL = &value
		position.RealizedCurrency = currency
		position.RealizedPnLCNY = cny
	}, priceIndex)
}

func addPositionRealizedToHolding(holding *InvestmentHolding, position InvestmentPosition) {
	if position.RealizedPnLCNY != nil {
		totalCNY := 0
		if holding.RealizedPnLCNY != nil {
			totalCNY = *holding.RealizedPnLCNY
		}
		totalCNY += *position.RealizedPnLCNY
		holding.RealizedPnLCNY = &totalCNY
	}
	if position.RealizedPnL == nil || position.RealizedCurrency == "" {
		return
	}
	if holding.RealizedCurrency != "" && holding.RealizedCurrency != position.RealizedCurrency {
		holding.RealizedPnL = nil
		holding.RealizedCurrency = ""
		return
	}
	holding.RealizedCurrency = position.RealizedCurrency
	total := 0.0
	if holding.RealizedPnL != nil {
		total = *holding.RealizedPnL
	}
	total += *position.RealizedPnL
	holding.RealizedPnL = &total
}

func addRealizedTotals(trades []InvestmentRealizedTrade, set func(float64, string, *int), priceIndex investmentPriceIndex) {
	currency := ""
	value := 0.0
	cnyTotal := 0
	cnyCount := 0
	for _, trade := range trades {
		if trade.RealizedPnL == nil || trade.RealizedCurrency == "" {
			continue
		}
		if currency != "" && currency != trade.RealizedCurrency {
			return
		}
		currency = trade.RealizedCurrency
		value += *trade.RealizedPnL
		if trade.RealizedPnLCNY != nil {
			cnyTotal += *trade.RealizedPnLCNY
			cnyCount++
		}
	}
	if currency == "" {
		return
	}
	var cny *int
	if cnyCount > 0 {
		cny = &cnyTotal
	} else {
		cny = marketValueCNY(value, currency, priceIndex)
	}
	set(value, currency, cny)
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
			positions[posting.Account+"\x00"+posting.Currency] += investmentPostingQuantity(posting)
		}
	}
	return positions
}

func investmentQuantitiesFromTransactions(txns []Transaction, securities map[string]bool) map[string]float64 {
	positions := map[string]float64{}
	for _, txn := range txns {
		for _, posting := range txn.Postings {
			if !strings.HasPrefix(posting.Account, "Assets:") || !securities[posting.Currency] {
				continue
			}
			positions[posting.Account+"\x00"+posting.Currency] += investmentTransactionPostingQuantity(posting)
		}
	}
	return positions
}

type investmentCost struct {
	value    float64
	currency string
	mixed    bool
}

type investmentActivity struct {
	Lots     map[string][]InvestmentLot
	Realized map[string][]InvestmentRealizedTrade
}

func (cost investmentCost) valid() bool {
	return cost.currency != "" && !cost.mixed && !roundedZero(cost.value)
}

func investmentCostsFromLots(lots map[string][]InvestmentLot) map[string]investmentCost {
	costs := map[string]investmentCost{}
	for key, rows := range lots {
		current := investmentCost{}
		for _, lot := range rows {
			if lot.CostCurrency == "" {
				continue
			}
			if current.currency != "" && current.currency != lot.CostCurrency {
				current.mixed = true
				continue
			}
			current.currency = lot.CostCurrency
			if lot.CostValue != nil {
				current.value += *lot.CostValue
			} else if lot.UnitCost != nil {
				current.value += lot.Quantity * *lot.UnitCost
			}
		}
		costs[key] = current
	}
	return costs
}

func investmentActivityFromEntries(entries []BeanEntry, securities map[string]bool, accountMap map[string]Account, commodityMap map[string]Commodity, priceIndex investmentPriceIndex) investmentActivity {
	activity := investmentActivity{Lots: map[string][]InvestmentLot{}, Realized: map[string][]InvestmentRealizedTrade{}}
	for _, entry := range entries {
		if entry.Kind != "transaction" {
			continue
		}
		for _, posting := range entry.Postings {
			if !strings.HasPrefix(posting.Account, "Assets:") || !securities[posting.Currency] {
				continue
			}
			quantity := investmentPostingQuantity(posting)
			if roundedZero(quantity) {
				continue
			}
			accountName, commodity := posting.Account, posting.Currency
			key := accountName + "\x00" + commodity
			if quantity > 0 {
				activity.Lots[key] = append(activity.Lots[key], investmentLotFromPosting(entry.Date, posting, accountMap, commodityMap))
				continue
			}
			trade := investmentRealizedTradeFromPosting(entry.Date, posting, entry.Postings, securities, accountMap, commodityMap, priceIndex, activity.Lots[key])
			activity.Lots[key] = consumeInvestmentLots(activity.Lots[key], -quantity)
			activity.Realized[key] = append(activity.Realized[key], trade)
		}
	}
	for key := range activity.Lots {
		sortInvestmentLots(activity.Lots[key])
	}
	for key := range activity.Realized {
		sortInvestmentRealizedTrades(activity.Realized[key])
	}
	return activity
}

func investmentLotFromPosting(date string, posting parsedPosting, accountMap map[string]Account, commodityMap map[string]Commodity) InvestmentLot {
	accountName, commodity := posting.Account, posting.Currency
	label := accountName
	if acct := accountMap[accountName]; acct.Label != "" {
		label = acct.Label
	}
	quantity := investmentPostingQuantity(posting)
	lot := InvestmentLot{
		Date:          date,
		Account:       accountName,
		AccountLabel:  label,
		Commodity:     commodity,
		CommodityName: commodityName(commodityMap, commodity),
		Quantity:      quantity,
	}
	if posting.CostCurrency != "" {
		if posting.TotalCost {
			value := investmentBeanAmountValue(posting.Cost, posting.CostAmount)
			unit := value / quantity
			lot.UnitCost = &unit
			lot.CostValue = &value
		} else {
			unit := investmentBeanAmountValue(posting.Cost, posting.CostAmount)
			value := quantity * unit
			lot.UnitCost = &unit
			lot.CostValue = &value
		}
		lot.CostCurrency = posting.CostCurrency
	}
	return lot
}

func investmentRealizedTradeFromPosting(date string, posting parsedPosting, postings []parsedPosting, securities map[string]bool, accountMap map[string]Account, commodityMap map[string]Commodity, priceIndex investmentPriceIndex, lots []InvestmentLot) InvestmentRealizedTrade {
	accountName, commodity := posting.Account, posting.Currency
	label := accountName
	if acct := accountMap[accountName]; acct.Label != "" {
		label = acct.Label
	}
	quantity := -investmentPostingQuantity(posting)
	trade := InvestmentRealizedTrade{
		Date:          date,
		Account:       accountName,
		AccountLabel:  label,
		Commodity:     commodity,
		CommodityName: commodityName(commodityMap, commodity),
		Quantity:      quantity,
	}
	if proceeds, currency := investmentSaleProceeds(posting, quantity, postings, securities); proceeds != nil {
		trade.ProceedsValue = proceeds
		trade.ProceedsCurrency = currency
	}
	if cost, currency := investmentConsumedCost(lots, quantity); cost != nil {
		trade.CostValue = cost
		trade.CostCurrency = currency
	}
	if trade.ProceedsValue != nil && trade.CostValue != nil && trade.ProceedsCurrency != "" && trade.ProceedsCurrency == trade.CostCurrency {
		pnl := *trade.ProceedsValue - *trade.CostValue
		trade.RealizedPnL = &pnl
		trade.RealizedCurrency = trade.ProceedsCurrency
		trade.RealizedPnLCNY = marketValueCNY(pnl, trade.RealizedCurrency, priceIndex)
	}
	return trade
}

func investmentSaleProceeds(posting parsedPosting, quantity float64, postings []parsedPosting, securities map[string]bool) (*float64, string) {
	if roundedZero(quantity) {
		return nil, ""
	}
	if posting.PriceCurrency == "" {
		return investmentSaleProceedsFromCashPostings(postings, securities)
	}
	value := investmentBeanAmountValue(posting.Price, posting.PriceAmount)
	if posting.TotalPrice {
		value = math.Abs(value)
	} else {
		value *= quantity
	}
	return &value, posting.PriceCurrency
}

func investmentSaleProceedsFromCashPostings(postings []parsedPosting, securities map[string]bool) (*float64, string) {
	saleCount := 0
	for _, candidate := range postings {
		if !strings.HasPrefix(candidate.Account, "Assets:") || !securities[candidate.Currency] {
			continue
		}
		if investmentPostingQuantity(candidate) < 0 {
			saleCount++
		}
	}
	if saleCount != 1 {
		return nil, ""
	}
	totals := map[string]float64{}
	for _, candidate := range postings {
		if !strings.HasPrefix(candidate.Account, "Assets:") || securities[candidate.Currency] {
			continue
		}
		amount := investmentPostingQuantity(candidate)
		if amount <= 0 || roundedZero(amount) {
			continue
		}
		totals[candidate.Currency] += amount
	}
	if len(totals) != 1 {
		return nil, ""
	}
	for currency, total := range totals {
		if roundedZero(total) {
			return nil, ""
		}
		return &total, currency
	}
	return nil, ""
}

func investmentConsumedCost(lots []InvestmentLot, quantity float64) (*float64, string) {
	remaining := quantity
	total := 0.0
	currency := ""
	covered := 0.0
	for _, lot := range lots {
		if roundedZero(remaining) {
			break
		}
		consume := math.Min(lot.Quantity, remaining)
		if roundedZero(consume) {
			continue
		}
		if lot.CostCurrency == "" {
			remaining -= consume
			continue
		}
		if currency != "" && currency != lot.CostCurrency {
			return nil, ""
		}
		currency = lot.CostCurrency
		if lot.CostValue != nil && !roundedZero(lot.Quantity) {
			total += *lot.CostValue * consume / lot.Quantity
			covered += consume
		} else if lot.UnitCost != nil {
			total += *lot.UnitCost * consume
			covered += consume
		}
		remaining -= consume
	}
	if currency == "" || math.Abs(covered-quantity) > 0.00000001 {
		return nil, ""
	}
	return &total, currency
}

func consumeInvestmentLots(lots []InvestmentLot, quantity float64) []InvestmentLot {
	remaining := quantity
	out := make([]InvestmentLot, 0, len(lots))
	for _, lot := range lots {
		if roundedZero(remaining) {
			out = append(out, lot)
			continue
		}
		if lot.Quantity <= remaining || roundedZero(lot.Quantity-remaining) {
			remaining -= lot.Quantity
			continue
		}
		originalQuantity := lot.Quantity
		consume := remaining
		remaining = 0
		lot.Quantity -= consume
		if lot.CostValue != nil && !roundedZero(originalQuantity) {
			value := *lot.CostValue * lot.Quantity / originalQuantity
			lot.CostValue = &value
		} else if lot.UnitCost != nil {
			value := *lot.UnitCost * lot.Quantity
			lot.CostValue = &value
		}
		out = append(out, lot)
	}
	return out
}

func investmentLotsFromTransactions(txns []Transaction, securities map[string]bool, accountMap map[string]Account, commodityMap map[string]Commodity) map[string][]InvestmentLot {
	lots := map[string][]InvestmentLot{}
	for _, txn := range txns {
		for _, posting := range txn.Postings {
			if !strings.HasPrefix(posting.Account, "Assets:") || !securities[posting.Currency] {
				continue
			}
			quantity := investmentTransactionPostingQuantity(posting)
			if quantity <= 0 || roundedZero(quantity) {
				continue
			}
			accountName, commodity := posting.Account, posting.Currency
			label := accountName
			if acct := accountMap[accountName]; acct.Label != "" {
				label = acct.Label
			}
			key := accountName + "\x00" + commodity
			lots[key] = append(lots[key], InvestmentLot{
				Date:          txn.Date,
				Account:       accountName,
				AccountLabel:  label,
				Commodity:     commodity,
				CommodityName: commodityName(commodityMap, commodity),
				Quantity:      quantity,
			})
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

func sortInvestmentRealizedTrades(trades []InvestmentRealizedTrade) {
	sort.Slice(trades, func(i, j int) bool {
		if trades[i].Date != trades[j].Date {
			return trades[i].Date > trades[j].Date
		}
		if trades[i].Commodity != trades[j].Commodity {
			return trades[i].Commodity < trades[j].Commodity
		}
		return trades[i].Account < trades[j].Account
	})
}

func marketValueCNY(value float64, currency string, priceIndex investmentPriceIndex) *int {
	value, ok := priceIndex.Valuation(value, currency, "CNY", "")
	if !ok {
		return nil
	}
	cny := int(math.Round(value * 100))
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

func investmentPostingQuantity(posting parsedPosting) float64 {
	return investmentBeanAmountValue(posting.Quantity, posting.Amount)
}

func investmentTransactionPostingQuantity(posting Posting) float64 {
	return float64(posting.Amount) / 100
}

func investmentPriceAmount(price Price) float64 {
	return investmentBeanAmountValue(price.AmountValue, price.Amount)
}

func investmentBeanAmountValue(amount BeanAmount, fallbackCents int) float64 {
	if value, ok := investmentDecimalValue(amount.Number); ok {
		return value
	}
	return float64(fallbackCents) / 100
}

func investmentDecimalValue(raw string) (float64, bool) {
	if strings.TrimSpace(raw) == "" {
		return 0, false
	}
	rat, ok := new(big.Rat).SetString(strings.ReplaceAll(strings.TrimSpace(raw), ",", ""))
	if !ok {
		return 0, false
	}
	value, _ := rat.Float64()
	return value, true
}

type investmentPriceIndex struct {
	byPair   map[string][]Price
	pairKeys []string
}

func newInvestmentPriceIndex(prices []Price) investmentPriceIndex {
	index := investmentPriceIndex{byPair: map[string][]Price{}}
	for _, price := range prices {
		key := pricePairKey(price.Currency, price.QuoteCurrency)
		if _, ok := index.byPair[key]; !ok {
			index.pairKeys = append(index.pairKeys, key)
		}
		index.byPair[key] = append(index.byPair[key], price)
	}
	sort.Strings(index.pairKeys)
	for key := range index.byPair {
		rows := index.byPair[key]
		sort.Slice(rows, func(i, j int) bool { return rows[i].Date < rows[j].Date })
		index.byPair[key] = rows
	}
	return index
}

func (index investmentPriceIndex) Valuation(amount float64, currency, targetCurrency string, date string) (float64, bool) {
	return index.valuation(amount, currency, targetCurrency, date, map[string]bool{})
}

func (index investmentPriceIndex) valuation(amount float64, currency, targetCurrency string, date string, seen map[string]bool) (float64, bool) {
	currency = normalizeValuationCurrency(currency)
	targetCurrency = normalizeValuationCurrency(targetCurrency)
	if currency == targetCurrency {
		return amount, true
	}
	if price, ok := index.latestPrice(currency, targetCurrency, date); ok {
		return amount * investmentPriceAmount(*price), true
	}
	if price, ok := index.latestPrice(targetCurrency, currency, date); ok {
		rate := investmentPriceAmount(*price)
		if rate != 0 {
			return amount / rate, true
		}
	}
	if seen[currency] {
		return 0, false
	}
	seen[currency] = true
	for _, key := range index.pairKeys {
		base, quote := splitPricePairKey(key)
		if base == currency {
			price, ok := index.latestPrice(base, quote, date)
			if ok {
				value := amount * investmentPriceAmount(*price)
				if converted, ok := index.valuation(value, quote, targetCurrency, date, cloneSeenCurrencies(seen)); ok {
					return converted, true
				}
			}
		}
		if quote == currency {
			price, ok := index.latestPrice(base, quote, date)
			if ok {
				rate := investmentPriceAmount(*price)
				if rate != 0 {
					value := amount / rate
					if converted, ok := index.valuation(value, base, targetCurrency, date, cloneSeenCurrencies(seen)); ok {
						return converted, true
					}
				}
			}
		}
	}
	return 0, false
}

func (index investmentPriceIndex) latestPrice(currency, quoteCurrency string, date string) (*Price, bool) {
	prices := index.byPair[pricePairKey(currency, quoteCurrency)]
	if len(prices) == 0 {
		return nil, false
	}
	if date == "" {
		return &prices[len(prices)-1], true
	}
	i := sort.Search(len(prices), func(i int) bool { return prices[i].Date > date })
	if i > 0 {
		return &prices[i-1], true
	}
	return nil, false
}
