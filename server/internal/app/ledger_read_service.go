package app

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"
)

type LedgerReadService struct {
	cache      *LedgerCache
	indexStore *LedgerIndexStore
	indexErr   error
	strict     bool

	mu             sync.Mutex
	cachedVersion  string
	cachedSnapshot *LedgerSnapshot
	cachedFull     bool
	cachedRevision LedgerIndexRevision
	cachedRevAt    time.Time
}

func NewLedgerReadService(cache *LedgerCache) *LedgerReadService {
	return &LedgerReadService{cache: cache}
}

func NewLedgerReadServiceWithIndex(cache *LedgerCache, indexStore *LedgerIndexStore, indexErr error, strict bool) *LedgerReadService {
	return &LedgerReadService{cache: cache, indexStore: indexStore, indexErr: indexErr, strict: strict}
}

// revisionCacheTTL controls how often we re-query ActiveRevision.
// The indexer runs every 5 min; a 10s TTL avoids redundant Neon queries.
const revisionCacheTTL = 10 * time.Second

func (s *LedgerReadService) cachedActiveRevision(ctx context.Context) (LedgerIndexRevision, bool, error) {
	s.mu.Lock()
	if time.Since(s.cachedRevAt) < revisionCacheTTL {
		rev := s.cachedRevision
		s.mu.Unlock()
		return rev, rev.ID != 0, nil
	}
	s.mu.Unlock()

	rev, ok, err := s.indexStore.ActiveRevision(ctx)
	if err != nil || !ok {
		return rev, ok, err
	}

	s.mu.Lock()
	s.cachedRevision = rev
	s.cachedRevAt = time.Now()
	s.mu.Unlock()
	return rev, true, nil
}

func (s *LedgerReadService) Snapshot(ctx context.Context) (*LedgerSnapshot, error) {
	return s.snapshot(ctx, true)
}

func (s *LedgerReadService) SnapshotLite(ctx context.Context) (*LedgerSnapshot, error) {
	return s.snapshot(ctx, false)
}

func (s *LedgerReadService) snapshot(ctx context.Context, includeBeanPayloads bool) (*LedgerSnapshot, error) {
	if s.indexErr != nil {
		return nil, s.indexErr
	}
	if s.indexStore != nil {
		indexCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		revision, ok, err := s.cachedActiveRevision(indexCtx)
		if err != nil {
			return nil, err
		}
		if !ok {
			if s.strict {
				return nil, ErrLedgerReadModelUnavailable
			}
			return s.cache.Snapshot()
		}
		// Return cached snapshot when version hasn't changed.
		s.mu.Lock()
		if s.cachedSnapshot != nil && s.cachedVersion == revision.LedgerVersion.Version && (!includeBeanPayloads || s.cachedFull) {
			cached := s.cachedSnapshot
			s.mu.Unlock()
			return cached, nil
		}
		s.mu.Unlock()
		// Version changed — reload full snapshot.
		snapCtx, snapCancel := context.WithTimeout(ctx, 30*time.Second)
		defer snapCancel()
		var snapshot *LedgerSnapshot
		var loaded bool
		if includeBeanPayloads {
			snapshot, loaded, err = s.indexStore.ActiveSnapshot(snapCtx)
		} else {
			snapshot, loaded, err = s.indexStore.ActiveSnapshotLite(snapCtx)
		}
		if err != nil {
			return nil, err
		}
		if loaded {
			s.mu.Lock()
			s.cachedSnapshot = snapshot
			s.cachedVersion = snapshot.Version
			s.cachedFull = includeBeanPayloads
			s.mu.Unlock()
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
		indexCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		revision, ok, err := s.cachedActiveRevision(indexCtx)
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

func (s *LedgerReadService) Bootstrap(start, end string, unlocked bool, rawValuationCurrency ...string) (BootstrapResult, error) {
	snapshot, err := s.SnapshotLite(context.Background())
	if unlocked {
		snapshot, err = s.Snapshot(context.Background())
	}
	if err != nil {
		return BootstrapResult{}, err
	}
	return BuildLedgerBootstrap(snapshot, start, end, unlocked, firstValuationCurrency(rawValuationCurrency)), nil
}

func (s *LedgerReadService) BootstrapLite(start, end string, unlocked bool, rawValuationCurrency ...string) (BootstrapResult, error) {
	snapshot, err := s.SnapshotLite(context.Background())
	if err != nil {
		return BootstrapResult{}, err
	}
	return BuildLedgerBootstrapLite(snapshot, start, end, unlocked, firstValuationCurrency(rawValuationCurrency)), nil
}

func (s *LedgerReadService) Summary(start, end string, unlocked bool, rawValuationCurrency ...string) (SummaryQueryResult, error) {
	snapshot, err := s.SnapshotLite(context.Background())
	if err != nil {
		return SummaryQueryResult{}, err
	}
	return BuildLedgerSummary(snapshot, start, end, unlocked, firstValuationCurrency(rawValuationCurrency)), nil
}

func (s *LedgerReadService) Transactions(start, end string, unlocked bool) (TransactionQueryResult, error) {
	if s.indexErr != nil {
		return TransactionQueryResult{}, s.indexErr
	}
	if s.indexStore != nil {
		indexCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		revision, ok, err := s.cachedActiveRevision(indexCtx)
		if err != nil {
			return TransactionQueryResult{}, err
		}
		if ok {
			txns, err := s.indexStore.TransactionsForRevision(indexCtx, revision.ID, start, end)
			if err != nil {
				return TransactionQueryResult{}, err
			}
			for index := range txns {
				txns[index].Source.GitSHA = revision.GitSHA
			}
			return BuildLedgerTransactionsFromIndexedRange(txns, start, end, unlocked), nil
		}
		if s.strict {
			return TransactionQueryResult{}, ErrLedgerReadModelUnavailable
		}
	}
	snapshot, err := s.Snapshot(context.Background())
	if err != nil {
		return TransactionQueryResult{}, err
	}
	return BuildLedgerTransactions(snapshot, start, end, unlocked), nil
}

func (s *LedgerReadService) Balances(ctx context.Context) (map[string]int, []BalanceAssertion, error) {
	if s.indexErr != nil {
		return nil, nil, s.indexErr
	}
	if s.indexStore != nil {
		indexCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		revision, ok, err := s.cachedActiveRevision(indexCtx)
		if err != nil {
			return nil, nil, err
		}
		if ok {
			return s.indexStore.BalancesForRevision(indexCtx, revision.ID)
		}
		if s.strict {
			return nil, nil, ErrLedgerReadModelUnavailable
		}
	}
	if s.strict {
		return nil, nil, ErrLedgerReadModelUnavailable
	}
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return nil, nil, err
	}
	return snapshot.Balances, snapshot.BalanceAssertions, nil
}

func firstValuationCurrency(values []string) string {
	if len(values) == 0 {
		return ""
	}
	return values[0]
}

func (s *LedgerReadService) IncomeStatement(start, end string, unlocked bool, rawValuationCurrency ...string) (IncomeStatementQueryResult, error) {
	snapshot, err := s.SnapshotLite(context.Background())
	if err != nil {
		return IncomeStatementQueryResult{}, err
	}
	return BuildLedgerIncomeStatement(snapshot, start, end, unlocked, firstValuationCurrency(rawValuationCurrency)), nil
}

func BuildLedgerBootstrap(snapshot *LedgerSnapshot, start, end string, unlocked bool, rawValuationCurrency string) BootstrapResult {
	valuationCurrency := ValidValuationCurrency(rawValuationCurrency, snapshot.Commodities)
	summary := scopedLedgerSummary(snapshot, start, end, unlocked, valuationCurrency)
	netWorthRows, monthEndRows, windows, creditCards := scopedNetWorthSummary(snapshot, start, end, unlocked, valuationCurrency)
	accountBalances := snapshotAccountBalances(snapshot, valuationCurrency)
	reconciliationRows := []ReconciliationRow{}
	accountStatuses := []AccountStatus{}
	investments := InvestmentSummary{}
	if unlocked {
		reconciliationRows = buildReconciliationRows(snapshot, start, end)
		accountStatuses = AccountStatusIndicators(snapshot.Transactions, snapshot.BalanceAssertions, snapshot.Accounts)
		investments = BuildInvestmentSummaryFromSnapshot(snapshot)
	}
	incomeStatement := buildLedgerIncomeStatementFields(snapshot, start, end, unlocked, valuationCurrency)
	return BootstrapResult{
		Start:              start,
		End:                end,
		Summary:            summary,
		Balances:           statusMap(unlocked, snapshot.Balances),
		AccountBalances:    statusAccountBalances(unlocked, accountBalances),
		NetWorthHistory:    netWorthRows,
		MonthEndNetWorth:   monthEndRows,
		NetWorthWindows:    windows,
		CreditCards:        creditCards,
		Investments:        investments,
		Transactions:       filterLedgerTransactionsDesc(snapshotTransactionsDesc(snapshot), start, end, unlocked),
		ReconciliationRows: reconciliationRows,
		Accounts:           snapshot.Accounts,
		Commodities:        snapshot.Commodities,
		Prices:             snapshot.Prices,
		ValuationCurrency:  valuationCurrency,
		IncomeStatement:    incomeStatement,
		AccountStatuses:    accountStatuses,
		LedgerVersion:      snapshot.LedgerVersion,
		SensitiveUnlocked:  unlocked,
	}
}

func BuildLedgerBootstrapLite(snapshot *LedgerSnapshot, start, end string, unlocked bool, rawValuationCurrency string) BootstrapResult {
	valuationCurrency := ValidValuationCurrency(rawValuationCurrency, snapshot.Commodities)
	summary := scopedLedgerSummary(snapshot, start, end, unlocked, valuationCurrency)
	expense, _, _ := ExpenseAnalyticsInCurrency(snapshot.Transactions, start, end, snapshot.Accounts, snapshot.Prices, valuationCurrency)
	incomeStatement := IncomeStatementResult{
		Expense:            []IncomeStatementNode{},
		TotalExpense:       summary.Expense,
		ExpenseAnalytics:   expense,
		TopPayees:          []PayeeAnalytics{},
		TopPaymentAccounts: []AccountAnalytics{},
		Income:             []IncomeStatementNode{},
		TotalIncome:        statusInt(unlocked, summary.Income),
		NetIncome:          statusInt(unlocked, summary.Net),
		ValuationCurrency:  valuationCurrency,
	}
	return BootstrapResult{
		Start:              start,
		End:                end,
		Summary:            summary,
		Balances:           statusMap(unlocked, snapshot.Balances),
		AccountBalances:    statusAccountBalances(unlocked, snapshotAccountBalances(snapshot, valuationCurrency)),
		NetWorthHistory:    []NetWorthPoint{},
		MonthEndNetWorth:   []NetWorthPoint{},
		NetWorthWindows:    nil,
		CreditCards:        []CreditCardAnalytics{},
		Investments:        InvestmentSummary{},
		Transactions:       filterLedgerTransactionsDesc(snapshotTransactionsDesc(snapshot), start, end, unlocked),
		ReconciliationRows: []ReconciliationRow{},
		Accounts:           snapshot.Accounts,
		Commodities:        snapshot.Commodities,
		Prices:             snapshot.Prices,
		ValuationCurrency:  valuationCurrency,
		IncomeStatement:    incomeStatement,
		AccountStatuses:    []AccountStatus{},
		LedgerVersion:      snapshot.LedgerVersion,
		SensitiveUnlocked:  unlocked,
	}
}

func BuildLedgerSummary(snapshot *LedgerSnapshot, start, end string, unlocked bool, rawValuationCurrency string) SummaryQueryResult {
	valuationCurrency := ValidValuationCurrency(rawValuationCurrency, snapshot.Commodities)
	summary := scopedLedgerSummary(snapshot, start, end, unlocked, valuationCurrency)
	netWorthRows, monthEndRows, windows, creditCards := scopedNetWorthSummary(snapshot, start, end, unlocked, valuationCurrency)
	accountBalances := snapshotAccountBalances(snapshot, valuationCurrency)
	return SummaryQueryResult{
		Start:             start,
		End:               end,
		Summary:           summary,
		Balances:          statusMap(unlocked, snapshot.Balances),
		AccountBalances:   statusAccountBalances(unlocked, accountBalances),
		NetWorthHistory:   netWorthRows,
		MonthEndNetWorth:  monthEndRows,
		NetWorthWindows:   windows,
		CreditCards:       creditCards,
		Commodities:       snapshot.Commodities,
		Prices:            snapshot.Prices,
		ValuationCurrency: valuationCurrency,
		SensitiveUnlocked: unlocked,
	}
}

func BuildLedgerTransactions(snapshot *LedgerSnapshot, start, end string, unlocked bool) TransactionQueryResult {
	return TransactionQueryResult{
		Start:             start,
		End:               end,
		Transactions:      filterLedgerTransactionsDesc(snapshotTransactionsDesc(snapshot), start, end, unlocked),
		SensitiveUnlocked: unlocked,
	}
}

func BuildLedgerTransactionsFromIndexedRange(txns []Transaction, start, end string, unlocked bool) TransactionQueryResult {
	transactions := txns
	if !unlocked {
		transactions = filterSensitiveTransactions(txns)
	}
	return TransactionQueryResult{Start: start, End: end, Transactions: transactions, SensitiveUnlocked: unlocked}
}

func BuildLedgerIncomeStatement(snapshot *LedgerSnapshot, start, end string, unlocked bool, rawValuationCurrency ...string) IncomeStatementQueryResult {
	valuationCurrency := ValidValuationCurrency(firstValuationCurrency(rawValuationCurrency), snapshot.Commodities)
	return IncomeStatementQueryResult{
		Start:                 start,
		End:                   end,
		IncomeStatementResult: buildLedgerIncomeStatementFields(snapshot, start, end, unlocked, valuationCurrency),
		SensitiveUnlocked:     unlocked,
	}
}

func buildLedgerIncomeStatementFields(snapshot *LedgerSnapshot, start, end string, unlocked bool, valuationCurrency string) IncomeStatementResult {
	expense, topPayees, topAccounts := ExpenseAnalyticsInCurrency(snapshot.Transactions, start, end, snapshot.Accounts, snapshot.Prices, valuationCurrency)
	allIncomeNodes, expenseNodes, totalIncome, totalExpense, netIncome := IncomeStatementTreeInCurrency(start, end, snapshot.Transactions, snapshot.Prices, valuationCurrency)
	accountMap := snapshotAccountMap(snapshot)
	allIncomeNodes = applyIncomeStatementAccountLabels(allIncomeNodes, accountMap)
	expenseNodes = applyIncomeStatementAccountLabels(expenseNodes, accountMap)
	incomeNodes := []IncomeStatementNode{}
	if unlocked {
		incomeNodes = allIncomeNodes
	}
	return IncomeStatementResult{
		Income:             incomeNodes,
		Expense:            expenseNodes,
		TotalIncome:        statusInt(unlocked, totalIncome),
		TotalExpense:       totalExpense,
		ExpenseAnalytics:   expense,
		TopPayees:          topPayees,
		TopPaymentAccounts: topAccounts,
		NetIncome:          statusInt(unlocked, netIncome),
		ValuationCurrency:  valuationCurrency,
	}
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

func filterSensitiveTransactions(txns []Transaction) []Transaction {
	filtered := make([]Transaction, 0, min(len(txns), 256))
	for _, txn := range txns {
		if !transactionHasIncome(txn) {
			filtered = append(filtered, txn)
		}
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

func snapshotAccountBalances(snapshot *LedgerSnapshot, valuationCurrency string) []AccountBalance {
	if normalizeValuationCurrency(valuationCurrency) == "CNY" && snapshot.AccountBalances != nil {
		return snapshot.AccountBalances
	}
	return AccountBalanceRowsWithPriceIndex(snapshotRawBalances(snapshot), snapshotPriceIndex(snapshot), "", valuationCurrency)
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

func scopedNetWorthSummary(snapshot *LedgerSnapshot, start, end string, unlocked bool, valuationCurrency string) ([]NetWorthPoint, []NetWorthPoint, *NetWorthWindows, []CreditCardAnalytics) {
	netWorthRows := []NetWorthPoint{}
	monthEndRows := []NetWorthPoint{}
	var windows *NetWorthWindows
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
	netWorthWindows := NetWorthChangeWindows(allRows)
	windows = &netWorthWindows
	creditCards = CreditCardsInCurrency(snapshot.Transactions, snapshot.Balances, snapshot.Accounts, start, end, snapshot.Prices, valuationCurrency)
	return netWorthRows, monthEndRows, windows, creditCards
}
