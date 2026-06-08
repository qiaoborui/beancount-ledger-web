package app

import (
	"sort"
	"strings"

	"github.com/gin-gonic/gin"
)

type LedgerReadService struct {
	cache *LedgerCache
}

func NewLedgerReadService(cache *LedgerCache) *LedgerReadService {
	return &LedgerReadService{cache: cache}
}

func (s *LedgerReadService) Bootstrap(start, end string, unlocked bool, rawValuationCurrency ...string) (gin.H, error) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return nil, err
	}
	return BuildLedgerBootstrap(snapshot, start, end, unlocked, firstValuationCurrency(rawValuationCurrency)), nil
}

func (s *LedgerReadService) Summary(start, end string, unlocked bool, rawValuationCurrency ...string) (gin.H, error) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return nil, err
	}
	return BuildLedgerSummary(snapshot, start, end, unlocked, firstValuationCurrency(rawValuationCurrency)), nil
}

func (s *LedgerReadService) Transactions(start, end string, unlocked bool) (gin.H, error) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return nil, err
	}
	return BuildLedgerTransactions(snapshot, start, end, unlocked), nil
}

func firstValuationCurrency(values []string) string {
	if len(values) == 0 {
		return ""
	}
	return values[0]
}

func (s *LedgerReadService) IncomeStatement(start, end string, unlocked bool) (gin.H, error) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return nil, err
	}
	return BuildLedgerIncomeStatement(snapshot, start, end, unlocked), nil
}

func BuildLedgerBootstrap(snapshot *LedgerSnapshot, start, end string, unlocked bool, rawValuationCurrency string) gin.H {
	valuationCurrency := ValidValuationCurrency(rawValuationCurrency, snapshot.Commodities)
	summary := scopedLedgerSummary(snapshot, start, end, unlocked, valuationCurrency)
	netWorthRows, monthEndRows, windows, creditCards := scopedNetWorthSummary(snapshot, start, end, unlocked, valuationCurrency)
	accountBalances := AccountBalanceRowsInCurrency(CurrentBalances(snapshot.Transactions), snapshot.Prices, "", valuationCurrency)
	reconciliationRows := []gin.H{}
	accountStatuses := []AccountStatus{}
	if unlocked {
		reconciliationRows = buildReconciliationRows(snapshot, start, end)
		accountStatuses = AccountStatusIndicators(snapshot.Transactions, snapshot.BalanceAssertions, snapshot.Accounts)
	}
	incomeStatement := buildLedgerIncomeStatementFields(snapshot, start, end, unlocked, valuationCurrency)
	return gin.H{
		"start":              start,
		"end":                end,
		"summary":            summary,
		"balances":           statusMap(unlocked, snapshot.Balances),
		"accountBalances":    statusAccountBalances(unlocked, accountBalances),
		"netWorthHistory":    netWorthRows,
		"monthEndNetWorth":   monthEndRows,
		"netWorthWindows":    windows,
		"creditCards":        creditCards,
		"transactions":       FilterLedgerTransactions(snapshot.Transactions, start, end, unlocked),
		"budgetRows":         buildBudgetRows(snapshot, start, end, valuationCurrency),
		"reconciliationRows": reconciliationRows,
		"accounts":           snapshot.Accounts,
		"commodities":        snapshot.Commodities,
		"valuationCurrency":  valuationCurrency,
		"incomeStatement":    incomeStatement,
		"accountStatuses":    accountStatuses,
		"ledgerVersion":      snapshot.LedgerVersion,
		"sensitiveUnlocked":  unlocked,
	}
}

func BuildLedgerSummary(snapshot *LedgerSnapshot, start, end string, unlocked bool, rawValuationCurrency string) gin.H {
	valuationCurrency := ValidValuationCurrency(rawValuationCurrency, snapshot.Commodities)
	summary := scopedLedgerSummary(snapshot, start, end, unlocked, valuationCurrency)
	netWorthRows, monthEndRows, windows, creditCards := scopedNetWorthSummary(snapshot, start, end, unlocked, valuationCurrency)
	accountBalances := AccountBalanceRowsInCurrency(CurrentBalances(snapshot.Transactions), snapshot.Prices, "", valuationCurrency)
	return gin.H{"start": start, "end": end, "summary": summary, "balances": statusMap(unlocked, snapshot.Balances), "accountBalances": statusAccountBalances(unlocked, accountBalances), "netWorthHistory": netWorthRows, "monthEndNetWorth": monthEndRows, "netWorthWindows": windows, "creditCards": creditCards, "commodities": snapshot.Commodities, "valuationCurrency": valuationCurrency, "sensitiveUnlocked": unlocked}
}

func BuildLedgerTransactions(snapshot *LedgerSnapshot, start, end string, unlocked bool) gin.H {
	return gin.H{"start": start, "end": end, "transactions": FilterLedgerTransactions(snapshot.Transactions, start, end, unlocked), "sensitiveUnlocked": unlocked}
}

func BuildLedgerIncomeStatement(snapshot *LedgerSnapshot, start, end string, unlocked bool) gin.H {
	payload := buildLedgerIncomeStatementFields(snapshot, start, end, unlocked, "CNY")
	payload["start"] = start
	payload["end"] = end
	payload["sensitiveUnlocked"] = unlocked
	return payload
}

func buildLedgerIncomeStatementFields(snapshot *LedgerSnapshot, start, end string, unlocked bool, valuationCurrency string) gin.H {
	expense, topPayees, topAccounts := ExpenseAnalyticsInCurrency(snapshot.Transactions, start, end, snapshot.Accounts, snapshot.Prices, valuationCurrency)
	allIncomeNodes, expenseNodes, totalIncome, totalExpense, netIncome := IncomeStatementTreeInCurrency(start, end, snapshot.Transactions, snapshot.Prices, valuationCurrency)
	allIncomeNodes = ApplyIncomeStatementAccountLabels(allIncomeNodes, snapshot.Accounts)
	expenseNodes = ApplyIncomeStatementAccountLabels(expenseNodes, snapshot.Accounts)
	incomeNodes := []IncomeStatementNode{}
	if unlocked {
		incomeNodes = allIncomeNodes
	}
	return gin.H{"income": incomeNodes, "expense": expenseNodes, "totalIncome": statusInt(unlocked, totalIncome), "totalExpense": totalExpense, "expenseAnalytics": expense, "topPayees": topPayees, "topPaymentAccounts": topAccounts, "netIncome": statusInt(unlocked, netIncome)}
}

func FilterLedgerTransactions(txns []Transaction, start, end string, unlocked bool) []Transaction {
	sorted := append([]Transaction(nil), txns...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Date > sorted[j].Date })
	filtered := []Transaction{}
	for _, txn := range sorted {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		if !unlocked && transactionHasIncome(txn) {
			continue
		}
		filtered = append(filtered, txn)
	}
	return filtered
}

func transactionHasIncome(txn Transaction) bool {
	for _, posting := range txn.Postings {
		if strings.HasPrefix(posting.Account, "Income:") {
			return true
		}
	}
	return false
}

func scopedLedgerSummary(snapshot *LedgerSnapshot, start, end string, unlocked bool, valuationCurrency string) Summary {
	summary := MonthSummaryInCurrency(start, end, snapshot.Transactions, snapshot.Prices, valuationCurrency)
	if unlocked {
		return summary
	}
	for day, value := range summary.Days {
		value["income"] = 0
		summary.Days[day] = value
	}
	summary.Income, summary.Net = 0, 0
	return summary
}

func scopedNetWorthSummary(snapshot *LedgerSnapshot, start, end string, unlocked bool, valuationCurrency string) ([]NetWorthPoint, []NetWorthPoint, any, []CreditCardAnalytics) {
	netWorthRows := []NetWorthPoint{}
	monthEndRows := []NetWorthPoint{}
	var windows any
	creditCards := []CreditCardAnalytics{}
	if !unlocked {
		return netWorthRows, monthEndRows, windows, creditCards
	}
	allRows := NetWorthHistoryInCurrency(snapshot.Transactions, snapshot.Prices, valuationCurrency)
	for _, row := range allRows {
		if row.Date >= start && row.Date < end {
			netWorthRows = append(netWorthRows, row)
		}
	}
	monthEndRows = MonthEndNetWorth(netWorthRows)
	windows = NetWorthChangeWindows(allRows)
	creditCards = CreditCardsInCurrency(snapshot.Transactions, snapshot.Balances, snapshot.Accounts, start, end, snapshot.Prices, valuationCurrency)
	return netWorthRows, monthEndRows, windows, creditCards
}
