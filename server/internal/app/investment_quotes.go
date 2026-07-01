package app

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/net/websocket"
)

type InvestmentLiveQuote struct {
	Commodity      string  `json:"commodity"`
	CommodityName  string  `json:"commodityName"`
	Amount         float64 `json:"amount"`
	Currency       string  `json:"currency"`
	Source         string  `json:"source"`
	Status         string  `json:"status"`
	Symbol         string  `json:"symbol,omitempty"`
	PreviousClose  float64 `json:"previousClose,omitempty"`
	Change         float64 `json:"change,omitempty"`
	ChangePercent  float64 `json:"changePercent,omitempty"`
	MarketValue    float64 `json:"marketValue,omitempty"`
	MarketValueCNY *int    `json:"marketValueCny,omitempty"`
	UpdatedAt      string  `json:"updatedAt"`
	Error          string  `json:"error,omitempty"`
}

type investmentQuoteStreamMessage struct {
	Type string                `json:"type"`
	At   string                `json:"at"`
	Data []InvestmentLiveQuote `json:"data,omitempty"`
}

type investmentQuoteRequest struct {
	Holdings []InvestmentHolding
	Symbols  map[string]string
}

type investmentQuoteProvider interface {
	Quotes(context.Context, investmentQuoteRequest) ([]InvestmentLiveQuote, error)
}

func (s *Server) investmentQuotesWS(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	websocket.Handler(func(conn *websocket.Conn) {
		defer conn.Close()
		interval := investmentQuoteInterval()
		provider := s.investmentQuoteProvider()
		send := func() bool {
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			quotes, err := s.currentInvestmentQuotes(ctx, provider)
			if err != nil {
				_ = websocket.JSON.Send(conn, investmentQuoteStreamMessage{Type: "error", At: time.Now().UTC().Format(time.RFC3339Nano), Data: []InvestmentLiveQuote{{Source: "server", Status: "error", Error: err.Error(), UpdatedAt: time.Now().UTC().Format(time.RFC3339)}}})
				return true
			}
			return websocket.JSON.Send(conn, investmentQuoteStreamMessage{Type: "quotes", At: time.Now().UTC().Format(time.RFC3339Nano), Data: quotes}) == nil
		}
		if !send() {
			return
		}
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
			if !send() {
				return
			}
		}
	}).ServeHTTP(c.Writer, c.Request)
}

func (s *Server) currentInvestmentQuotes(ctx context.Context, provider investmentQuoteProvider) ([]InvestmentLiveQuote, error) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return nil, err
	}
	summary := BuildInvestmentSummaryFromBeanEntries(snapshot.BeanEntries, snapshot.Accounts, snapshot.Prices)
	holdings := visibleInvestmentHoldings(summary.Holdings)
	request := investmentQuoteRequest{Holdings: holdings, Symbols: investmentQuoteSymbols(snapshot.BeanEntries)}
	priceIndex := newInvestmentPriceIndex(snapshot.Prices)
	fallback := ledgerInvestmentQuoteProvider{}
	quotes, err := fallback.Quotes(ctx, request)
	if err != nil {
		return nil, err
	}
	if provider == nil {
		return enrichInvestmentQuotes(quotes, holdings, priceIndex), nil
	}
	live, err := provider.Quotes(ctx, request)
	if err != nil {
		return enrichInvestmentQuotes(quotesWithProviderError(quotes, err), holdings, priceIndex), nil
	}
	return enrichInvestmentQuotes(mergeInvestmentQuotes(quotes, live), holdings, priceIndex), nil
}

func visibleInvestmentHoldings(holdings []InvestmentHolding) []InvestmentHolding {
	out := []InvestmentHolding{}
	for _, holding := range holdings {
		if strings.TrimSpace(holding.Commodity) != "" && !roundedZero(holding.TotalQuantity) {
			out = append(out, holding)
		}
	}
	return out
}

func investmentQuoteSymbols(entries []BeanEntry) map[string]string {
	out := map[string]string{}
	for _, commodity := range parseCommodityDetails(entries) {
		symbol := investmentQuoteSymbol(commodity)
		if symbol != "" {
			out[commodity.Symbol] = symbol
		}
	}
	return out
}

func investmentQuoteSymbol(commodity Commodity) string {
	for _, key := range []string{"quote_symbol", "quoteSymbol", "finnhub_symbol", "ticker"} {
		if value, ok := commodity.Metadata[key].(string); ok && strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return commodity.Symbol
}

type ledgerInvestmentQuoteProvider struct{}

func (ledgerInvestmentQuoteProvider) Quotes(_ context.Context, request investmentQuoteRequest) ([]InvestmentLiveQuote, error) {
	now := time.Now().UTC().Format(time.RFC3339)
	quotes := make([]InvestmentLiveQuote, 0, len(request.Holdings))
	for _, holding := range request.Holdings {
		if holding.LatestPrice == nil {
			continue
		}
		quotes = append(quotes, InvestmentLiveQuote{
			Commodity:     holding.Commodity,
			CommodityName: holding.CommodityName,
			Amount:        holding.LatestPrice.Amount,
			Currency:      holding.LatestPrice.Currency,
			Source:        "ledger",
			Status:        "ledger",
			Symbol:        request.Symbols[holding.Commodity],
			UpdatedAt:     now,
		})
	}
	return quotes, nil
}

type mockInvestmentQuoteProvider struct{}

func (mockInvestmentQuoteProvider) Quotes(_ context.Context, request investmentQuoteRequest) ([]InvestmentLiveQuote, error) {
	now := time.Now().UTC()
	quotes := make([]InvestmentLiveQuote, 0, len(request.Holdings))
	for index, holding := range request.Holdings {
		if holding.LatestPrice == nil {
			continue
		}
		wave := math.Sin(float64(now.UnixNano()/int64(time.Millisecond))/1300 + float64(index))
		amount := holding.LatestPrice.Amount * (1 + wave*0.0025)
		previous := holding.LatestPrice.Amount
		quotes = append(quotes, InvestmentLiveQuote{
			Commodity:     holding.Commodity,
			CommodityName: holding.CommodityName,
			Amount:        amount,
			Currency:      holding.LatestPrice.Currency,
			Source:        "mock",
			Status:        "live",
			Symbol:        request.Symbols[holding.Commodity],
			PreviousClose: previous,
			Change:        amount - previous,
			ChangePercent: (amount - previous) / previous,
			UpdatedAt:     now.Format(time.RFC3339),
		})
	}
	return quotes, nil
}

type finnhubInvestmentQuoteProvider struct {
	token  string
	client *http.Client
}

type finnhubQuoteResponse struct {
	Current       float64 `json:"c"`
	Change        float64 `json:"d"`
	ChangePercent float64 `json:"dp"`
	PreviousClose float64 `json:"pc"`
	Timestamp     int64   `json:"t"`
}

func (provider finnhubInvestmentQuoteProvider) Quotes(ctx context.Context, request investmentQuoteRequest) ([]InvestmentLiveQuote, error) {
	if strings.TrimSpace(provider.token) == "" {
		return nil, fmt.Errorf("INVESTMENT_QUOTE_FINNHUB_TOKEN is required")
	}
	client := provider.client
	if client == nil {
		client = &http.Client{Timeout: 6 * time.Second}
	}
	out := []InvestmentLiveQuote{}
	for _, holding := range request.Holdings {
		if holding.LatestPrice == nil {
			continue
		}
		symbol := request.Symbols[holding.Commodity]
		if symbol == "" {
			symbol = holding.Commodity
		}
		quote, err := provider.fetch(ctx, client, symbol)
		if err != nil {
			return out, err
		}
		if quote.Current <= 0 {
			continue
		}
		updatedAt := time.Now().UTC()
		if quote.Timestamp > 0 {
			updatedAt = time.Unix(quote.Timestamp, 0).UTC()
		}
		status := "close"
		if time.Since(updatedAt) < 20*time.Minute {
			status = "live"
		}
		out = append(out, InvestmentLiveQuote{
			Commodity:     holding.Commodity,
			CommodityName: holding.CommodityName,
			Amount:        quote.Current,
			Currency:      holding.LatestPrice.Currency,
			Source:        "finnhub",
			Status:        status,
			Symbol:        symbol,
			PreviousClose: quote.PreviousClose,
			Change:        quote.Change,
			ChangePercent: quote.ChangePercent / 100,
			UpdatedAt:     updatedAt.Format(time.RFC3339),
		})
	}
	return out, nil
}

func (provider finnhubInvestmentQuoteProvider) fetch(ctx context.Context, client *http.Client, symbol string) (finnhubQuoteResponse, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://finnhub.io/api/v1/quote", nil)
	if err != nil {
		return finnhubQuoteResponse{}, err
	}
	query := req.URL.Query()
	query.Set("symbol", symbol)
	query.Set("token", provider.token)
	req.URL.RawQuery = query.Encode()
	res, err := client.Do(req)
	if err != nil {
		return finnhubQuoteResponse{}, err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return finnhubQuoteResponse{}, fmt.Errorf("finnhub quote %s failed: %s", symbol, res.Status)
	}
	var quote finnhubQuoteResponse
	if err := json.NewDecoder(res.Body).Decode(&quote); err != nil {
		return finnhubQuoteResponse{}, err
	}
	return quote, nil
}

func (s *Server) investmentQuoteProvider() investmentQuoteProvider {
	switch strings.ToLower(strings.TrimSpace(env("INVESTMENT_QUOTE_PROVIDER", ""))) {
	case "mock":
		return mockInvestmentQuoteProvider{}
	case "finnhub":
		return finnhubInvestmentQuoteProvider{token: os.Getenv("INVESTMENT_QUOTE_FINNHUB_TOKEN")}
	default:
		return nil
	}
}

func investmentQuoteInterval() time.Duration {
	raw := strings.TrimSpace(env("INVESTMENT_QUOTE_INTERVAL_SECONDS", "15"))
	seconds, err := strconv.ParseFloat(raw, 64)
	if err != nil || seconds <= 0 {
		seconds = 15
	}
	if seconds < 3 {
		seconds = 3
	}
	return time.Duration(seconds * float64(time.Second))
}

func mergeInvestmentQuotes(fallback []InvestmentLiveQuote, live []InvestmentLiveQuote) []InvestmentLiveQuote {
	byCommodity := map[string]InvestmentLiveQuote{}
	order := []string{}
	for _, quote := range fallback {
		if _, ok := byCommodity[quote.Commodity]; !ok {
			order = append(order, quote.Commodity)
		}
		byCommodity[quote.Commodity] = quote
	}
	for _, quote := range live {
		if quote.Amount <= 0 || quote.Currency == "" {
			continue
		}
		if _, ok := byCommodity[quote.Commodity]; !ok {
			order = append(order, quote.Commodity)
		}
		byCommodity[quote.Commodity] = quote
	}
	out := make([]InvestmentLiveQuote, 0, len(order))
	for _, commodity := range order {
		out = append(out, byCommodity[commodity])
	}
	return out
}

func quotesWithProviderError(quotes []InvestmentLiveQuote, err error) []InvestmentLiveQuote {
	out := append([]InvestmentLiveQuote{}, quotes...)
	for index := range out {
		out[index].Status = "ledger"
		out[index].Error = err.Error()
	}
	return out
}

func enrichInvestmentQuotes(quotes []InvestmentLiveQuote, holdings []InvestmentHolding, priceIndex investmentPriceIndex) []InvestmentLiveQuote {
	quantityByCommodity := map[string]float64{}
	for _, holding := range holdings {
		quantityByCommodity[holding.Commodity] = holding.TotalQuantity
	}
	out := append([]InvestmentLiveQuote{}, quotes...)
	for index := range out {
		quantity := quantityByCommodity[out[index].Commodity]
		if roundedZero(quantity) || out[index].Amount <= 0 || out[index].Currency == "" {
			continue
		}
		value := quantity * out[index].Amount
		out[index].MarketValue = value
		out[index].MarketValueCNY = marketValueCNY(value, out[index].Currency, priceIndex)
	}
	return out
}
