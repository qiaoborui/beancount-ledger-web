package app

import (
	"net/url"
	"sort"
	"strings"
	"time"
)

type DashboardKPI struct {
	Assets      int      `json:"assets"`
	Liabilities int      `json:"liabilities"`
	NetWorth    int      `json:"netWorth"`
	Income      int      `json:"income"`
	Expense     int      `json:"expense"`
	Net         int      `json:"net"`
	SavingsRate *float64 `json:"savingsRate"`
}

type DashboardCashflowPoint struct {
	Month   string `json:"month"`
	Income  int    `json:"income"`
	Expense int    `json:"expense"`
	Net     int    `json:"net"`
}

type DashboardFilters struct {
	Categories []string `json:"categories,omitempty"`
	Accounts   []string `json:"accounts,omitempty"`
	Payees     []string `json:"payees,omitempty"`
	Tags       []string `json:"tags,omitempty"`
	Types      []string `json:"types,omitempty"`
	MinAmount  *int     `json:"minAmount,omitempty"`
	MaxAmount  *int     `json:"maxAmount,omitempty"`
}

type DashboardAnnotation struct {
	Date      string `json:"date"`
	Kind      string `json:"kind"`
	Label     string `json:"label"`
	Payee     string `json:"payee,omitempty"`
	Account   string `json:"account,omitempty"`
	Amount    int    `json:"amount,omitempty"`
	Bucket    string `json:"bucket,omitempty"`
	Severity  string `json:"severity"`
	Drilldown string `json:"drilldown"`
}

type DashboardFilterOption struct {
	Value string  `json:"value"`
	Alias *string `json:"alias,omitempty"`
	Label string  `json:"label"`
	Count int     `json:"count"`
}

type DashboardFilterOptions struct {
	Categories []DashboardFilterOption `json:"categories"`
	Accounts   []DashboardFilterOption `json:"accounts"`
	Payees     []DashboardFilterOption `json:"payees"`
	Tags       []DashboardFilterOption `json:"tags"`
}

type DashboardSeriesPoint struct {
	Month string `json:"month"`
	Value int    `json:"value"`
}

type DashboardDailyExpense struct {
	Date    string `json:"date"`
	Weekday string `json:"weekday"`
	Amount  int    `json:"amount"`
	TxCount int    `json:"txCount"`
}

type DashboardWeekdayExpense struct {
	Weekday string `json:"weekday"`
	Amount  int    `json:"amount"`
	TxCount int    `json:"txCount"`
}

type DashboardCategorySeries struct {
	Account string                 `json:"account"`
	Alias   *string                `json:"alias,omitempty"`
	Label   string                 `json:"label"`
	Total   int                    `json:"total"`
	Values  []DashboardSeriesPoint `json:"values"`
}

type DashboardAccountSeries struct {
	Account string                 `json:"account"`
	Alias   *string                `json:"alias,omitempty"`
	Label   string                 `json:"label"`
	Group   string                 `json:"group"`
	Values  []DashboardSeriesPoint `json:"values"`
}

type DashboardAnomaly struct {
	Date      string `json:"date"`
	Payee     string `json:"payee"`
	Narration string `json:"narration"`
	Account   string `json:"account"`
	Amount    int    `json:"amount"`
	Source    string `json:"source"`
}

type DashboardSummary struct {
	Start                string                    `json:"start"`
	End                  string                    `json:"end"`
	Currency             string                    `json:"currency"`
	KPIs                 DashboardKPI              `json:"kpis"`
	NetWorthSeries       []NetWorthPoint           `json:"netWorthSeries"`
	CashflowSeries       []DashboardCashflowPoint  `json:"cashflowSeries"`
	DailyExpenseSeries   []DashboardDailyExpense   `json:"dailyExpenseSeries"`
	WeekdayExpense       []DashboardWeekdayExpense `json:"weekdayExpense"`
	CategorySeries       []DashboardCategorySeries `json:"categorySeries"`
	AccountBalanceSeries []DashboardAccountSeries  `json:"accountBalanceSeries"`
	Anomalies            []DashboardAnomaly        `json:"anomalies"`
	TopPayees            []PayeeAnalytics          `json:"topPayees"`
	TopPaymentAccounts   []AccountAnalytics        `json:"topPaymentAccounts"`
	Filters              DashboardFilters          `json:"filters"`
	FilterOptions        DashboardFilterOptions    `json:"filterOptions"`
	Annotations          []DashboardAnnotation     `json:"annotations"`
	GeneratedAt          string                    `json:"generatedAt"`
}

func BuildDashboardSummary(snapshot *LedgerSnapshot, start, end string) DashboardSummary {
	return BuildDashboardSummaryWithFilters(snapshot, start, end, DashboardFilters{})
}

func BuildDashboardSummaryWithFilters(snapshot *LedgerSnapshot, start, end string, filters DashboardFilters) DashboardSummary {
	return BuildDashboardSummaryWithFiltersInCurrency(snapshot, start, end, filters, "CNY")
}

func BuildDashboardSummaryWithFiltersInCurrency(snapshot *LedgerSnapshot, start, end string, filters DashboardFilters, valuationCurrency string) DashboardSummary {
	valuationCurrency = ValidValuationCurrency(valuationCurrency, snapshot.Commodities)
	priceIndex := snapshotPriceIndex(snapshot)
	txns := dashboardFilterTransactions(snapshot.Transactions, filters, priceIndex, valuationCurrency)
	seriesStart, seriesEnd := dashboardSeriesRange(start, end, txns)
	includeYearLabels := dashboardIncludeYearBucketLabels(start, end)
	rawBalances := snapshotRawBalances(snapshot)
	if !filters.Empty() {
		rawBalances = CurrentBalances(txns)
	}
	balanceRows := AccountBalanceRowsWithPriceIndex(rawBalances, priceIndex, end, valuationCurrency)
	summary := MonthSummaryWithPriceIndex(start, end, txns, priceIndex, valuationCurrency)
	accountMap := snapshotAccountMap(snapshot)
	seriesSummaries := dashboardBucketSummaries(txns, priceIndex, seriesStart, seriesEnd, valuationCurrency, includeYearLabels)
	assets, liabilities := balanceTotals(balanceRows)
	var savingsRate *float64
	if summary.Income > 0 {
		value := float64(summary.Net) / float64(summary.Income)
		savingsRate = &value
	}
	_, topPayees, topPaymentAccounts := ExpenseAnalyticsInCurrency(txns, start, end, snapshot.Accounts, snapshot.Prices, valuationCurrency)

	return DashboardSummary{
		Start:                start,
		End:                  end,
		Currency:             valuationCurrency,
		KPIs:                 DashboardKPI{Assets: assets, Liabilities: liabilities, NetWorth: assets - liabilities, Income: summary.Income, Expense: summary.Expense, Net: summary.Net, SavingsRate: savingsRate},
		NetWorthSeries:       dashboardNetWorthSeries(dashboardSortedTransactions(snapshot, txns, filters), priceIndex, seriesStart, seriesEnd, valuationCurrency, includeYearLabels),
		CashflowSeries:       dashboardCashflowSeries(seriesSummaries),
		DailyExpenseSeries:   dashboardDailyExpenseSeries(txns, priceIndex, start, end, valuationCurrency),
		WeekdayExpense:       dashboardWeekdayExpense(txns, priceIndex, start, end, valuationCurrency),
		CategorySeries:       dashboardCategorySeries(seriesSummaries, 8, accountMap),
		AccountBalanceSeries: dashboardAccountBalanceSeries(txns, snapshot.Accounts, balanceRows, priceIndex, seriesStart, seriesEnd, 6, valuationCurrency, includeYearLabels),
		Anomalies:            dashboardAnomalies(txns, priceIndex, start, end, 10, valuationCurrency),
		TopPayees:            topPayees,
		TopPaymentAccounts:   topPaymentAccounts,
		Filters:              filters,
		FilterOptions:        dashboardFilterOptions(snapshot.Transactions, snapshot.Accounts, start, end),
		Annotations:          dashboardAnnotations(txns, priceIndex, start, end, 12, valuationCurrency),
		GeneratedAt:          time.Now().Format(time.RFC3339),
	}
}

func dashboardSeriesRange(start, end string, txns []Transaction) (string, string) {
	startDate, errStart := time.Parse("2006-01-02", start)
	endDate, errEnd := time.Parse("2006-01-02", end)
	if errStart != nil || errEnd != nil || !startDate.Before(endDate) {
		return start, end
	}
	if endDate.Sub(startDate).Hours()/24 <= 730 {
		return start, end
	}
	first, last := "", ""
	for _, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		if first == "" || txn.Date < first {
			first = txn.Date
		}
		if last == "" || txn.Date > last {
			last = txn.Date
		}
	}
	if first == "" {
		return start, start
	}
	lastDate, err := time.Parse("2006-01-02", last)
	if err != nil {
		return first, end
	}
	return first, lastDate.AddDate(0, 0, 1).Format("2006-01-02")
}

func (f DashboardFilters) Empty() bool {
	return len(f.Categories) == 0 && len(f.Accounts) == 0 && len(f.Payees) == 0 && len(f.Tags) == 0 && len(f.Types) == 0 && f.MinAmount == nil && f.MaxAmount == nil
}

func dashboardFilterTransactions(txns []Transaction, filters DashboardFilters, priceIndex PriceIndex, valuationCurrency string) []Transaction {
	if filters.Empty() {
		return txns
	}
	out := []Transaction{}
	for _, txn := range txns {
		if dashboardTransactionMatches(txn, filters, priceIndex, valuationCurrency) {
			out = append(out, txn)
		}
	}
	return out
}

func dashboardTransactionMatches(txn Transaction, filters DashboardFilters, priceIndex PriceIndex, valuationCurrency string) bool {
	if len(filters.Payees) > 0 && !containsString(filters.Payees, txn.Payee) {
		return false
	}
	if len(filters.Tags) > 0 && !intersectsString(txn.Tags, filters.Tags) {
		return false
	}
	if len(filters.Types) > 0 && !containsString(filters.Types, dashboardTransactionType(txn)) {
		return false
	}
	if len(filters.Categories) > 0 && !transactionHasAnyAccountPrefix(txn, filters.Categories) {
		return false
	}
	if len(filters.Accounts) > 0 && !transactionHasAnyAccountPrefix(txn, filters.Accounts) {
		return false
	}
	amount := dashboardTransactionAmount(txn, priceIndex, valuationCurrency)
	if filters.MinAmount != nil && amount < *filters.MinAmount {
		return false
	}
	if filters.MaxAmount != nil && amount > *filters.MaxAmount {
		return false
	}
	return true
}

func dashboardTransactionType(txn Transaction) string {
	hasExpense, hasIncome := false, false
	for _, posting := range txn.Postings {
		if strings.HasPrefix(posting.Account, "Expenses:") && posting.Amount > 0 {
			hasExpense = true
		}
		if strings.HasPrefix(posting.Account, "Income:") {
			hasIncome = true
		}
	}
	if hasExpense {
		return "expense"
	}
	if hasIncome {
		return "income"
	}
	return "transfer"
}

func dashboardTransactionAmount(txn Transaction, priceIndex PriceIndex, valuationCurrency string) int {
	var expense, income, movement int
	for _, posting := range txn.Postings {
		amount := postingValuationWithPriceIndex(posting, priceIndex, "", valuationCurrency)
		if strings.HasPrefix(posting.Account, "Expenses:") && posting.Amount > 0 {
			expense += amount
		}
		if strings.HasPrefix(posting.Account, "Income:") {
			income += abs(amount)
		}
		if strings.HasPrefix(posting.Account, "Assets:") || strings.HasPrefix(posting.Account, "Liabilities:") {
			movement += abs(amount)
		}
	}
	if expense > 0 {
		return expense
	}
	if income > 0 {
		return income
	}
	return movement
}

func transactionHasAnyAccountPrefix(txn Transaction, accounts []string) bool {
	for _, account := range accounts {
		if transactionHasAccountPrefix(txn, account) {
			return true
		}
	}
	return false
}

func transactionHasAccountPrefix(txn Transaction, account string) bool {
	for _, posting := range txn.Postings {
		if posting.Account == account || strings.HasPrefix(posting.Account, account+":") {
			return true
		}
	}
	return false
}

func containsString(values []string, needle string) bool {
	for _, value := range values {
		if value == needle {
			return true
		}
	}
	return false
}

func intersectsString(left []string, right []string) bool {
	for _, value := range left {
		if containsString(right, value) {
			return true
		}
	}
	return false
}

func dashboardFilterOptions(txns []Transaction, accounts []Account, start, end string) DashboardFilterOptions {
	accountMap := accountByName(accounts)
	categoryCounts, accountCounts, payeeCounts, tagCounts := map[string]int{}, map[string]int{}, map[string]int{}, map[string]int{}
	for _, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		seenCategories, seenAccounts, seenTags := map[string]bool{}, map[string]bool{}, map[string]bool{}
		for _, posting := range txn.Postings {
			if strings.HasPrefix(posting.Account, "Expenses:") || strings.HasPrefix(posting.Account, "Income:") {
				seenCategories[posting.Account] = true
			}
			if strings.HasPrefix(posting.Account, "Assets:") || strings.HasPrefix(posting.Account, "Liabilities:") {
				seenAccounts[posting.Account] = true
			}
		}
		for _, tag := range txn.Tags {
			seenTags[tag] = true
		}
		for account := range seenCategories {
			categoryCounts[account]++
		}
		for account := range seenAccounts {
			accountCounts[account]++
		}
		for tag := range seenTags {
			tagCounts[tag]++
		}
		payee := txn.Payee
		if payee == "" {
			payee = "（无商户）"
		}
		payeeCounts[payee]++
	}
	return DashboardFilterOptions{
		Categories: dashboardOptionRows(categoryCounts, accountMap),
		Accounts:   dashboardOptionRows(accountCounts, accountMap),
		Payees:     dashboardOptionRows(payeeCounts, nil),
		Tags:       dashboardOptionRows(tagCounts, nil),
	}
}

func dashboardOptionRows(counts map[string]int, accounts map[string]Account) []DashboardFilterOption {
	rows := make([]DashboardFilterOption, 0, len(counts))
	for value, count := range counts {
		label, alias := accountLabelAlias(value, accounts)
		if accounts == nil {
			label = value
			alias = nil
		}
		rows = append(rows, DashboardFilterOption{Value: value, Alias: alias, Label: label, Count: count})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Count == rows[j].Count {
			return rows[i].Value < rows[j].Value
		}
		return rows[i].Count > rows[j].Count
	})
	if len(rows) > 30 {
		rows = rows[:30]
	}
	return rows
}

func balanceTotals(balances []AccountBalance) (int, int) {
	var assets, liabilities int
	for _, balance := range balances {
		if balance.ValuationMissing {
			continue
		}
		if strings.HasPrefix(balance.Account, "Assets:") {
			assets += balance.Valuation
		}
		if strings.HasPrefix(balance.Account, "Liabilities:") {
			liabilities += abs(balance.Valuation)
		}
	}
	return assets, liabilities
}

func dashboardSortedTransactions(snapshot *LedgerSnapshot, txns []Transaction, filters DashboardFilters) []Transaction {
	if filters.Empty() {
		return snapshotTransactionsAsc(snapshot)
	}
	sorted := append([]Transaction(nil), txns...)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Date == sorted[j].Date {
			return sorted[i].Source.Line < sorted[j].Source.Line
		}
		return sorted[i].Date < sorted[j].Date
	})
	return sorted
}

type dashboardBucketSummary struct {
	Bucket     dashboardBucket
	Income     int
	Expense    int
	Net        int
	Categories map[string]int
}

func dashboardBucketSummaries(txns []Transaction, priceIndex PriceIndex, start, end, valuationCurrency string, includeYearLabels bool) []dashboardBucketSummary {
	buckets := dashboardBuckets(start, end, includeYearLabels)
	rows := make([]dashboardBucketSummary, len(buckets))
	for i, bucket := range buckets {
		rows[i] = dashboardBucketSummary{Bucket: bucket, Categories: map[string]int{}}
	}
	for _, txn := range txns {
		index := dashboardBucketIndex(buckets, txn.Date)
		if index < 0 {
			continue
		}
		row := &rows[index]
		for _, posting := range txn.Postings {
			amount := postingValuationWithPriceIndex(posting, priceIndex, "", valuationCurrency)
			if strings.HasPrefix(posting.Account, "Income:") {
				if amount < 0 {
					amount = -amount
				}
				row.Income += amount
			}
			if strings.HasPrefix(posting.Account, "Expenses:") {
				row.Expense += amount
				row.Categories[posting.Account] += amount
			}
		}
	}
	for i := range rows {
		rows[i].Net = rows[i].Income - rows[i].Expense
	}
	return rows
}

func dashboardBucketIndex(buckets []dashboardBucket, date string) int {
	index := sort.Search(len(buckets), func(i int) bool {
		return buckets[i].End > date
	})
	if index >= len(buckets) || buckets[index].Start > date {
		return -1
	}
	return index
}

func dashboardNetWorthSeries(sorted []Transaction, priceIndex PriceIndex, start, end, valuationCurrency string, includeYearLabels bool) []NetWorthPoint {
	buckets := dashboardBuckets(start, end, includeYearLabels)
	balances := map[string]map[string]int{}
	out := make([]NetWorthPoint, 0, len(buckets))
	index := 0
	for _, bucket := range buckets {
		for index < len(sorted) && sorted[index].Date < bucket.End {
			for _, posting := range sorted[index].Postings {
				currency := posting.Currency
				if currency == "" {
					currency = "CNY"
				}
				if balances[posting.Account] == nil {
					balances[posting.Account] = map[string]int{}
				}
				balances[posting.Account][currency] += posting.Amount
			}
			index++
		}
		assets, liabilities := balanceTotals(AccountBalanceRowsWithPriceIndex(balances, priceIndex, bucket.End, valuationCurrency))
		out = append(out, NetWorthPoint{Date: bucket.Label, Assets: assets, Liabilities: liabilities, NetWorth: assets - liabilities})
	}
	return out
}

func dashboardCashflowSeries(summaries []dashboardBucketSummary) []DashboardCashflowPoint {
	out := make([]DashboardCashflowPoint, 0, len(summaries))
	for _, summary := range summaries {
		out = append(out, DashboardCashflowPoint{Month: summary.Bucket.Label, Income: summary.Income, Expense: summary.Expense, Net: summary.Net})
	}
	return out
}

func dashboardDailyExpenseSeries(txns []Transaction, priceIndex PriceIndex, start, end, valuationCurrency string) []DashboardDailyExpense {
	byDate := map[string]*DashboardDailyExpense{}
	for _, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		var expense int
		for _, posting := range txn.Postings {
			if strings.HasPrefix(posting.Account, "Expenses:") && posting.Amount > 0 {
				expense += postingValuationWithPriceIndex(posting, priceIndex, "", valuationCurrency)
			}
		}
		if expense <= 0 {
			continue
		}
		row := byDate[txn.Date]
		if row == nil {
			row = &DashboardDailyExpense{Date: txn.Date, Weekday: weekdayLabel(txn.Date)}
			byDate[txn.Date] = row
		}
		row.Amount += expense
		row.TxCount++
	}
	dates := make([]string, 0, len(byDate))
	for date := range byDate {
		dates = append(dates, date)
	}
	sort.Strings(dates)
	out := make([]DashboardDailyExpense, 0, len(dates))
	for _, date := range dates {
		out = append(out, *byDate[date])
	}
	return out
}

func dashboardWeekdayExpense(txns []Transaction, priceIndex PriceIndex, start, end, valuationCurrency string) []DashboardWeekdayExpense {
	order := []string{"周一", "周二", "周三", "周四", "周五", "周六", "周日"}
	rows := map[string]*DashboardWeekdayExpense{}
	for _, label := range order {
		rows[label] = &DashboardWeekdayExpense{Weekday: label}
	}
	for _, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		var expense int
		for _, posting := range txn.Postings {
			if strings.HasPrefix(posting.Account, "Expenses:") && posting.Amount > 0 {
				expense += postingValuationWithPriceIndex(posting, priceIndex, "", valuationCurrency)
			}
		}
		if expense <= 0 {
			continue
		}
		row := rows[weekdayLabel(txn.Date)]
		row.Amount += expense
		row.TxCount++
	}
	out := make([]DashboardWeekdayExpense, 0, len(order))
	for _, label := range order {
		out = append(out, *rows[label])
	}
	return out
}

func dashboardCategorySeries(summaries []dashboardBucketSummary, limit int, accountLookup map[string]Account) []DashboardCategorySeries {
	byAccount := map[string]map[string]int{}
	totals := map[string]int{}
	for _, summary := range summaries {
		for account, amount := range summary.Categories {
			if byAccount[account] == nil {
				byAccount[account] = map[string]int{}
			}
			byAccount[account][summary.Bucket.Label] += amount
			totals[account] += amount
		}
	}
	accounts := make([]string, 0, len(totals))
	for account := range totals {
		accounts = append(accounts, account)
	}
	sort.Slice(accounts, func(i, j int) bool {
		if totals[accounts[i]] == totals[accounts[j]] {
			return accounts[i] < accounts[j]
		}
		return totals[accounts[i]] > totals[accounts[j]]
	})
	if len(accounts) > limit {
		accounts = accounts[:limit]
	}
	out := make([]DashboardCategorySeries, 0, len(accounts))
	for _, account := range accounts {
		label, alias := accountLabelAlias(account, accountLookup)
		values := make([]DashboardSeriesPoint, 0, len(summaries))
		for _, summary := range summaries {
			values = append(values, DashboardSeriesPoint{Month: summary.Bucket.Label, Value: byAccount[account][summary.Bucket.Label]})
		}
		out = append(out, DashboardCategorySeries{Account: account, Alias: alias, Label: label, Total: totals[account], Values: values})
	}
	return out
}

func weekdayLabel(date string) string {
	parsed, err := time.Parse("2006-01-02", date)
	if err != nil {
		return ""
	}
	switch parsed.Weekday() {
	case time.Monday:
		return "周一"
	case time.Tuesday:
		return "周二"
	case time.Wednesday:
		return "周三"
	case time.Thursday:
		return "周四"
	case time.Friday:
		return "周五"
	case time.Saturday:
		return "周六"
	default:
		return "周日"
	}
}

func dashboardAccountBalanceSeries(txns []Transaction, accounts []Account, balances []AccountBalance, priceIndex PriceIndex, start, end string, limit int, valuationCurrency string, includeYearLabels bool) []DashboardAccountSeries {
	labels := map[string]Account{}
	for _, account := range accounts {
		labels[account.Account] = account
	}
	selected := make([]string, 0)
	balanceByAccount := map[string]int{}
	for _, balance := range balances {
		if !strings.HasPrefix(balance.Account, "Assets:") && !strings.HasPrefix(balance.Account, "Liabilities:") {
			continue
		}
		if balance.Valuation == 0 || balance.ValuationMissing {
			continue
		}
		balanceByAccount[balance.Account] += balance.Valuation
	}
	for account := range balanceByAccount {
		selected = append(selected, account)
	}
	sort.Slice(selected, func(i, j int) bool {
		if abs(balanceByAccount[selected[i]]) == abs(balanceByAccount[selected[j]]) {
			return selected[i] < selected[j]
		}
		return abs(balanceByAccount[selected[i]]) > abs(balanceByAccount[selected[j]])
	})
	if len(selected) > limit {
		selected = selected[:limit]
	}

	buckets := dashboardBuckets(start, end, includeYearLabels)
	seriesValues := accountBucketEndValuations(txns, selected, buckets, priceIndex, valuationCurrency)
	out := make([]DashboardAccountSeries, 0, len(selected))
	for _, accountName := range selected {
		acct := labels[accountName]
		label := acct.Label
		if label == "" {
			label = labelFor(accountName)
		}
		group := acct.Group
		if group == "" {
			group = accountGroup(accountName, nil, nil)
		}
		out = append(out, DashboardAccountSeries{Account: accountName, Alias: acct.Alias, Label: label, Group: group, Values: seriesValues[accountName]})
	}
	return out
}

func accountBucketEndValuations(txns []Transaction, accounts []string, buckets []dashboardBucket, priceIndex PriceIndex, valuationCurrency string) map[string][]DashboardSeriesPoint {
	out := map[string][]DashboardSeriesPoint{}
	for _, account := range accounts {
		out[account] = make([]DashboardSeriesPoint, 0, len(buckets))
	}
	sorted := append([]Transaction(nil), txns...)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Date == sorted[j].Date {
			return sorted[i].Source.Line < sorted[j].Source.Line
		}
		return sorted[i].Date < sorted[j].Date
	})
	balances := map[string]map[string]int{}
	index := 0
	for _, bucket := range buckets {
		for index < len(sorted) && sorted[index].Date < bucket.End {
			for _, posting := range sorted[index].Postings {
				currency := posting.Currency
				if currency == "" {
					currency = "CNY"
				}
				if balances[posting.Account] == nil {
					balances[posting.Account] = map[string]int{}
				}
				balances[posting.Account][currency] += posting.Amount
			}
			index++
		}
		for _, account := range accounts {
			valuation := 0
			for currency, amount := range balances[account] {
				value, ok := priceIndex.Valuation(amount, currency, valuationCurrency, "")
				if ok {
					valuation += value
				}
			}
			out[account] = append(out[account], DashboardSeriesPoint{Month: bucket.Label, Value: valuation})
		}
	}
	return out
}

func dashboardAnomalies(txns []Transaction, priceIndex PriceIndex, start, end string, limit int, valuationCurrency string) []DashboardAnomaly {
	rows := []DashboardAnomaly{}
	for _, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		for _, posting := range txn.Postings {
			if !strings.HasPrefix(posting.Account, "Expenses:") || posting.Amount <= 0 {
				continue
			}
			source := txn.Source.File
			if txn.Source.Line > 0 {
				source += ":" + formatInt(txn.Source.Line)
			}
			rows = append(rows, DashboardAnomaly{Date: txn.Date, Payee: txn.Payee, Narration: txn.Narration, Account: posting.Account, Amount: postingValuationWithPriceIndex(posting, priceIndex, "", valuationCurrency), Source: source})
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Amount == rows[j].Amount {
			return rows[i].Date > rows[j].Date
		}
		return rows[i].Amount > rows[j].Amount
	})
	if len(rows) > limit {
		rows = rows[:limit]
	}
	return rows
}

func dashboardAnnotations(txns []Transaction, priceIndex PriceIndex, start, end string, limit int, valuationCurrency string) []DashboardAnnotation {
	rows := []DashboardAnnotation{}
	for _, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		income := 0
		for _, posting := range txn.Postings {
			if strings.HasPrefix(posting.Account, "Income:") {
				income += abs(postingValuationWithPriceIndex(posting, priceIndex, "", valuationCurrency))
			}
			expense := postingValuationWithPriceIndex(posting, priceIndex, "", valuationCurrency)
			if strings.HasPrefix(posting.Account, "Expenses:") && expense >= 50000 {
				rows = append(rows, DashboardAnnotation{
					Date:      txn.Date,
					Kind:      "large-expense",
					Label:     "大额支出",
					Payee:     txn.Payee,
					Account:   posting.Account,
					Amount:    expense,
					Severity:  "warning",
					Drilldown: dashboardTransactionURL(txn.Date, posting.Account, txn.Payee, ""),
				})
			}
		}
		if income > 0 {
			rows = append(rows, DashboardAnnotation{
				Date:      txn.Date,
				Kind:      "income",
				Label:     "收入",
				Payee:     txn.Payee,
				Amount:    income,
				Severity:  "info",
				Drilldown: dashboardTransactionURL(txn.Date, "", txn.Payee, ""),
			})
		}
		for _, tag := range txn.Tags {
			if tag == "work" || tag == "reimburse" || tag == "报销" {
				rows = append(rows, DashboardAnnotation{
					Date:      txn.Date,
					Kind:      "tag",
					Label:     "#" + tag,
					Payee:     txn.Payee,
					Severity:  "info",
					Drilldown: dashboardTransactionURL(txn.Date, "", txn.Payee, tag),
				})
			}
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Date == rows[j].Date {
			return rows[i].Kind < rows[j].Kind
		}
		return rows[i].Date > rows[j].Date
	})
	if len(rows) > limit {
		rows = rows[:limit]
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Date == rows[j].Date {
			return rows[i].Kind < rows[j].Kind
		}
		return rows[i].Date < rows[j].Date
	})
	return rows
}

func dashboardTransactionURL(date, category, payee, tag string) string {
	params := []string{}
	if category != "" {
		params = append(params, "category="+url.QueryEscape(category))
	}
	if payee != "" || date != "" {
		query := strings.TrimSpace(payee + " " + date)
		params = append(params, "q="+url.QueryEscape(query))
	}
	if tag != "" {
		params = append(params, "metadata="+url.QueryEscape("#"+tag))
	}
	if category != "" {
		params = append(params, "mode=prefix")
	}
	if len(params) == 0 {
		return "/transactions"
	}
	return "/transactions?" + strings.Join(params, "&")
}

type dashboardBucket struct {
	Label string
	Start string
	End   string
}

func dashboardBuckets(start, end string, includeYearLabels bool) []dashboardBucket {
	startDate, errStart := time.Parse("2006-01-02", start)
	endDate, errEnd := time.Parse("2006-01-02", end)
	if errStart != nil || errEnd != nil || !startDate.Before(endDate) {
		return nil
	}
	days := int(endDate.Sub(startDate).Hours() / 24)
	if days <= 45 {
		return dayBuckets(startDate, endDate, includeYearLabels)
	}
	if days <= 180 {
		return weekBuckets(startDate, endDate, includeYearLabels)
	}
	if days <= 730 {
		return monthBuckets(startDate, endDate)
	}
	return quarterBuckets(startDate, endDate)
}

func dayBuckets(startDate, endDate time.Time, includeYearLabels bool) []dashboardBucket {
	out := []dashboardBucket{}
	for current := startDate; current.Before(endDate); current = current.AddDate(0, 0, 1) {
		next := current.AddDate(0, 0, 1)
		out = append(out, dashboardBucket{Label: dashboardDateBucketLabel(current, includeYearLabels), Start: current.Format("2006-01-02"), End: next.Format("2006-01-02")})
	}
	return out
}

func weekBuckets(startDate, endDate time.Time, includeYearLabels bool) []dashboardBucket {
	out := []dashboardBucket{}
	for current := startDate; current.Before(endDate); current = current.AddDate(0, 0, 7) {
		next := current.AddDate(0, 0, 7)
		if next.After(endDate) {
			next = endDate
		}
		labelEnd := next.AddDate(0, 0, -1)
		label := dashboardDateBucketLabel(current, includeYearLabels) + "~" + dashboardDateBucketLabel(labelEnd, includeYearLabels)
		out = append(out, dashboardBucket{Label: label, Start: current.Format("2006-01-02"), End: next.Format("2006-01-02")})
	}
	return out
}

func dashboardIncludeYearBucketLabels(start, end string) bool {
	startDate, errStart := time.Parse("2006-01-02", start)
	endDate, errEnd := time.Parse("2006-01-02", end)
	return errStart == nil && errEnd == nil && endDate.Sub(startDate).Hours()/24 > 730
}

func dashboardDateBucketLabel(date time.Time, includeYear bool) string {
	if includeYear {
		return date.Format("2006-01-02")
	}
	return date.Format("01-02")
}

func monthBuckets(startDate, endDate time.Time) []dashboardBucket {
	current := time.Date(startDate.Year(), startDate.Month(), 1, 0, 0, 0, 0, time.UTC)
	last := time.Date(endDate.Year(), endDate.Month(), 1, 0, 0, 0, 0, time.UTC)
	if endDate.Day() > 1 {
		last = last.AddDate(0, 1, 0)
	}
	out := []dashboardBucket{}
	for current.Before(last) {
		next := current.AddDate(0, 1, 0)
		bucketStart := current
		if bucketStart.Before(startDate) {
			bucketStart = startDate
		}
		bucketEnd := next
		if bucketEnd.After(endDate) {
			bucketEnd = endDate
		}
		out = append(out, dashboardBucket{Label: current.Format("2006-01"), Start: bucketStart.Format("2006-01-02"), End: bucketEnd.Format("2006-01-02")})
		current = next
	}
	return out
}

func quarterBuckets(startDate, endDate time.Time) []dashboardBucket {
	quarterMonth := time.Month(((int(startDate.Month()) - 1) / 3 * 3) + 1)
	current := time.Date(startDate.Year(), quarterMonth, 1, 0, 0, 0, 0, time.UTC)
	lastQuarterMonth := time.Month(((int(endDate.Month()) - 1) / 3 * 3) + 1)
	last := time.Date(endDate.Year(), lastQuarterMonth, 1, 0, 0, 0, 0, time.UTC)
	if endDate.After(last) {
		last = last.AddDate(0, 3, 0)
	}
	out := []dashboardBucket{}
	for current.Before(last) {
		next := current.AddDate(0, 3, 0)
		bucketStart := current
		if bucketStart.Before(startDate) {
			bucketStart = startDate
		}
		bucketEnd := next
		if bucketEnd.After(endDate) {
			bucketEnd = endDate
		}
		quarter := ((int(current.Month()) - 1) / 3) + 1
		out = append(out, dashboardBucket{Label: current.Format("2006") + "-Q" + formatInt(quarter), Start: bucketStart.Format("2006-01-02"), End: bucketEnd.Format("2006-01-02")})
		current = next
	}
	return out
}
