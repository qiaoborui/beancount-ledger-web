package app

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type LedgerReadService struct {
	cache      *LedgerCache
	indexStore *LedgerIndexStore
	indexErr   error
	strict     bool
}

func NewLedgerReadService(cache *LedgerCache) *LedgerReadService {
	return &LedgerReadService{cache: cache}
}

func NewLedgerReadServiceWithIndex(cache *LedgerCache, indexStore *LedgerIndexStore, indexErr error, strict bool) *LedgerReadService {
	return &LedgerReadService{cache: cache, indexStore: indexStore, indexErr: indexErr, strict: strict}
}

func (s *LedgerReadService) Snapshot(ctx context.Context) (*LedgerSnapshot, error) {
	if s.indexErr != nil {
		return nil, s.indexErr
	}
	if s.indexStore != nil {
		indexCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		snapshot, ok, err := s.indexStore.ActiveSnapshot(indexCtx)
		if err != nil {
			return nil, err
		}
		if ok {
			return snapshot, nil
		}
		if s.strict {
			return nil, ErrLedgerReadModelUnavailable
		}
	}
	if s.strict {
		return nil, ErrLedgerReadModelUnavailable
	}
	return s.cache.Snapshot()
}

func (s *LedgerReadService) Version(ctx context.Context) (LedgerVersion, error) {
	if s.indexErr != nil {
		return LedgerVersion{}, s.indexErr
	}
	if s.indexStore != nil {
		indexCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		revision, ok, err := s.indexStore.ActiveRevision(indexCtx)
		if err != nil {
			return LedgerVersion{}, err
		}
		if ok {
			return revision.LedgerVersion, nil
		}
		if s.strict {
			return LedgerVersion{}, ErrLedgerReadModelUnavailable
		}
	}
	if s.strict {
		return LedgerVersion{}, ErrLedgerReadModelUnavailable
	}
	return s.cache.Version()
}

var ErrLedgerReadModelUnavailable = errors.New("ledger read model has no active revision; run ledger-indexer first")

func (s *LedgerReadService) Bootstrap(start, end string, unlocked bool, rawValuationCurrency ...string) (gin.H, error) {
	snapshot, err := s.Snapshot(context.Background())
	if err != nil {
		return nil, err
	}
	return BuildLedgerBootstrap(snapshot, start, end, unlocked, firstValuationCurrency(rawValuationCurrency)), nil
}

func (s *LedgerReadService) Summary(start, end string, unlocked bool, rawValuationCurrency ...string) (gin.H, error) {
	snapshot, err := s.Snapshot(context.Background())
	if err != nil {
		return nil, err
	}
	return BuildLedgerSummary(snapshot, start, end, unlocked, firstValuationCurrency(rawValuationCurrency)), nil
}

func (s *LedgerReadService) Transactions(start, end string, unlocked bool) (gin.H, error) {
	snapshot, err := s.Snapshot(context.Background())
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

func (s *LedgerReadService) IncomeStatement(start, end string, unlocked bool, rawValuationCurrency ...string) (gin.H, error) {
	snapshot, err := s.Snapshot(context.Background())
	if err != nil {
		return nil, err
	}
	return BuildLedgerIncomeStatement(snapshot, start, end, unlocked, firstValuationCurrency(rawValuationCurrency)), nil
}

func BuildLedgerBootstrap(snapshot *LedgerSnapshot, start, end string, unlocked bool, rawValuationCurrency string) gin.H {
	valuationCurrency := ValidValuationCurrency(rawValuationCurrency, snapshot.Commodities)
	summary := scopedLedgerSummary(snapshot, start, end, unlocked, valuationCurrency)
	netWorthRows, monthEndRows, windows, creditCards := scopedNetWorthSummary(snapshot, start, end, unlocked, valuationCurrency)
	accountBalances := AccountBalanceRowsWithPriceIndex(snapshotRawBalances(snapshot), snapshotPriceIndex(snapshot), "", valuationCurrency)
	reconciliationRows := []gin.H{}
	accountStatuses := []AccountStatus{}
	investments := InvestmentSummary{}
	if unlocked {
		reconciliationRows = buildReconciliationRows(snapshot, start, end)
		accountStatuses = AccountStatusIndicators(snapshot.Transactions, snapshot.BalanceAssertions, snapshot.Accounts)
		investments = BuildInvestmentSummaryFromBeanEntries(snapshot.BeanEntries, snapshot.Accounts, snapshot.Prices)
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
		"investments":        investments,
		"transactions":       filterLedgerTransactionsDesc(snapshotTransactionsDesc(snapshot), start, end, unlocked),
		"reconciliationRows": reconciliationRows,
		"accounts":           snapshot.Accounts,
		"commodities":        snapshot.Commodities,
		"prices":             snapshot.Prices,
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
	accountBalances := AccountBalanceRowsWithPriceIndex(snapshotRawBalances(snapshot), snapshotPriceIndex(snapshot), "", valuationCurrency)
	return gin.H{"start": start, "end": end, "summary": summary, "balances": statusMap(unlocked, snapshot.Balances), "accountBalances": statusAccountBalances(unlocked, accountBalances), "netWorthHistory": netWorthRows, "monthEndNetWorth": monthEndRows, "netWorthWindows": windows, "creditCards": creditCards, "commodities": snapshot.Commodities, "prices": snapshot.Prices, "valuationCurrency": valuationCurrency, "sensitiveUnlocked": unlocked}
}

func BuildLedgerTransactions(snapshot *LedgerSnapshot, start, end string, unlocked bool) gin.H {
	return gin.H{"start": start, "end": end, "transactions": filterLedgerTransactionsDesc(snapshotTransactionsDesc(snapshot), start, end, unlocked), "sensitiveUnlocked": unlocked}
}

func BuildLedgerIncomeStatement(snapshot *LedgerSnapshot, start, end string, unlocked bool, rawValuationCurrency ...string) gin.H {
	valuationCurrency := ValidValuationCurrency(firstValuationCurrency(rawValuationCurrency), snapshot.Commodities)
	payload := buildLedgerIncomeStatementFields(snapshot, start, end, unlocked, valuationCurrency)
	payload["start"] = start
	payload["end"] = end
	payload["valuationCurrency"] = valuationCurrency
	payload["sensitiveUnlocked"] = unlocked
	return payload
}

func buildLedgerIncomeStatementFields(snapshot *LedgerSnapshot, start, end string, unlocked bool, valuationCurrency string) gin.H {
	expense, topPayees, topAccounts := ExpenseAnalyticsInCurrency(snapshot.Transactions, start, end, snapshot.Accounts, snapshot.Prices, valuationCurrency)
	allIncomeNodes, expenseNodes, totalIncome, totalExpense, netIncome := IncomeStatementTreeInCurrency(start, end, snapshot.Transactions, snapshot.Prices, valuationCurrency)
	accountMap := snapshotAccountMap(snapshot)
	allIncomeNodes = applyIncomeStatementAccountLabels(allIncomeNodes, accountMap)
	expenseNodes = applyIncomeStatementAccountLabels(expenseNodes, accountMap)
	incomeNodes := []IncomeStatementNode{}
	if unlocked {
		incomeNodes = allIncomeNodes
	}
	return gin.H{"income": incomeNodes, "expense": expenseNodes, "totalIncome": statusInt(unlocked, totalIncome), "totalExpense": totalExpense, "expenseAnalytics": expense, "topPayees": topPayees, "topPaymentAccounts": topAccounts, "netIncome": statusInt(unlocked, netIncome), "valuationCurrency": valuationCurrency}
}

func FilterLedgerTransactions(txns []Transaction, start, end string, unlocked bool) []Transaction {
	_, desc := sortedTransactionViews(txns)
	return filterLedgerTransactionsDesc(desc, start, end, unlocked)
}

func filterLedgerTransactionsDesc(txns []Transaction, start, end string, unlocked bool) []Transaction {
	filtered := make([]Transaction, 0, min(len(txns), 256))
	for _, txn := range txns {
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
	allRows := netWorthHistoryInCurrencyAsc(snapshotTransactionsAsc(snapshot), snapshot.Prices, valuationCurrency)
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
