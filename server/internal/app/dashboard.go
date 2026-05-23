package app

import (
	"sort"
	"strings"
	"time"
)

type DashboardKPI struct {
	Assets          int      `json:"assets"`
	Liabilities     int      `json:"liabilities"`
	NetWorth        int      `json:"netWorth"`
	Income          int      `json:"income"`
	Expense         int      `json:"expense"`
	Net             int      `json:"net"`
	SavingsRate     *float64 `json:"savingsRate"`
	Budget          int      `json:"budget"`
	BudgetSpent     int      `json:"budgetSpent"`
	BudgetRemaining int      `json:"budgetRemaining"`
	BudgetUsage     *float64 `json:"budgetUsage"`
}

type DashboardCashflowPoint struct {
	Month   string `json:"month"`
	Income  int    `json:"income"`
	Expense int    `json:"expense"`
	Net     int    `json:"net"`
}

type DashboardFilters struct {
	Category  string `json:"category,omitempty"`
	Account   string `json:"account,omitempty"`
	Payee     string `json:"payee,omitempty"`
	Tag       string `json:"tag,omitempty"`
	Type      string `json:"type,omitempty"`
	MinAmount *int   `json:"minAmount,omitempty"`
	MaxAmount *int   `json:"maxAmount,omitempty"`
}

type DashboardFilterOption struct {
	Value string `json:"value"`
	Label string `json:"label"`
	Count int    `json:"count"`
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
	Label   string                 `json:"label"`
	Total   int                    `json:"total"`
	Values  []DashboardSeriesPoint `json:"values"`
}

type DashboardAccountSeries struct {
	Account string                 `json:"account"`
	Label   string                 `json:"label"`
	Group   string                 `json:"group"`
	Values  []DashboardSeriesPoint `json:"values"`
}

type DashboardBudgetPressure struct {
	Account   string   `json:"account"`
	Label     string   `json:"label"`
	Budget    int      `json:"budget"`
	Spent     int      `json:"spent"`
	Remaining int      `json:"remaining"`
	Ratio     *float64 `json:"ratio"`
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
	BudgetPressure       []DashboardBudgetPressure `json:"budgetPressure"`
	Anomalies            []DashboardAnomaly        `json:"anomalies"`
	TopPayees            []PayeeAnalytics          `json:"topPayees"`
	TopPaymentAccounts   []AccountAnalytics        `json:"topPaymentAccounts"`
	Filters              DashboardFilters          `json:"filters"`
	FilterOptions        DashboardFilterOptions    `json:"filterOptions"`
	GeneratedAt          string                    `json:"generatedAt"`
}

func BuildDashboardSummary(snapshot *LedgerSnapshot, start, end string) DashboardSummary {
	return BuildDashboardSummaryWithFilters(snapshot, start, end, DashboardFilters{})
}

func BuildDashboardSummaryWithFilters(snapshot *LedgerSnapshot, start, end string, filters DashboardFilters) DashboardSummary {
	txns := dashboardFilterTransactions(snapshot.Transactions, filters)
	balances := snapshot.Balances
	if !filters.Empty() {
		balances = CurrentBalances(txns)
	}
	summary := MonthSummary(start, end, txns)
	budgetPressure, budget, budgetSpent := dashboardBudgetPressure(snapshot.Budgets, summary.Categories, end)
	assets, liabilities := balanceTotals(balances)
	var savingsRate *float64
	if summary.Income > 0 {
		value := float64(summary.Net) / float64(summary.Income)
		savingsRate = &value
	}
	var budgetUsage *float64
	if budget > 0 {
		value := float64(budgetSpent) / float64(budget)
		budgetUsage = &value
	}
	_, topPayees, topPaymentAccounts := ExpenseAnalytics(txns, start, end)

	return DashboardSummary{
		Start:                start,
		End:                  end,
		Currency:             "CNY",
		KPIs:                 DashboardKPI{Assets: assets, Liabilities: liabilities, NetWorth: assets - liabilities, Income: summary.Income, Expense: summary.Expense, Net: summary.Net, SavingsRate: savingsRate, Budget: budget, BudgetSpent: budgetSpent, BudgetRemaining: budget - budgetSpent, BudgetUsage: budgetUsage},
		NetWorthSeries:       dashboardNetWorthSeries(txns, start, end),
		CashflowSeries:       dashboardCashflowSeries(txns, start, end),
		DailyExpenseSeries:   dashboardDailyExpenseSeries(txns, start, end),
		WeekdayExpense:       dashboardWeekdayExpense(txns, start, end),
		CategorySeries:       dashboardCategorySeries(txns, start, end, 8),
		AccountBalanceSeries: dashboardAccountBalanceSeries(txns, snapshot.Accounts, balances, start, end, 6),
		BudgetPressure:       budgetPressure,
		Anomalies:            dashboardAnomalies(txns, start, end, 10),
		TopPayees:            topPayees,
		TopPaymentAccounts:   topPaymentAccounts,
		Filters:              filters,
		FilterOptions:        dashboardFilterOptions(snapshot.Transactions, snapshot.Accounts, start, end),
		GeneratedAt:          time.Now().Format(time.RFC3339),
	}
}

func (f DashboardFilters) Empty() bool {
	return f.Category == "" && f.Account == "" && f.Payee == "" && f.Tag == "" && f.Type == "" && f.MinAmount == nil && f.MaxAmount == nil
}

func dashboardFilterTransactions(txns []Transaction, filters DashboardFilters) []Transaction {
	if filters.Empty() {
		return txns
	}
	out := []Transaction{}
	for _, txn := range txns {
		if dashboardTransactionMatches(txn, filters) {
			out = append(out, txn)
		}
	}
	return out
}

func dashboardTransactionMatches(txn Transaction, filters DashboardFilters) bool {
	if filters.Payee != "" && txn.Payee != filters.Payee {
		return false
	}
	if filters.Tag != "" && !hasString(txn.Tags, filters.Tag) {
		return false
	}
	if filters.Type != "" && dashboardTransactionType(txn) != filters.Type {
		return false
	}
	if filters.Category != "" && !transactionHasAccountPrefix(txn, filters.Category) {
		return false
	}
	if filters.Account != "" && !transactionHasAccountPrefix(txn, filters.Account) {
		return false
	}
	amount := dashboardTransactionAmount(txn)
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

func dashboardTransactionAmount(txn Transaction) int {
	var expense, income, movement int
	for _, posting := range txn.Postings {
		if strings.HasPrefix(posting.Account, "Expenses:") && posting.Amount > 0 {
			expense += posting.Amount
		}
		if strings.HasPrefix(posting.Account, "Income:") {
			income += abs(posting.Amount)
		}
		if strings.HasPrefix(posting.Account, "Assets:") || strings.HasPrefix(posting.Account, "Liabilities:") {
			movement += abs(posting.Amount)
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

func transactionHasAccountPrefix(txn Transaction, account string) bool {
	for _, posting := range txn.Postings {
		if posting.Account == account || strings.HasPrefix(posting.Account, account+":") {
			return true
		}
	}
	return false
}

func hasString(values []string, needle string) bool {
	for _, value := range values {
		if value == needle {
			return true
		}
	}
	return false
}

func dashboardFilterOptions(txns []Transaction, accounts []Account, start, end string) DashboardFilterOptions {
	accountLabels := map[string]string{}
	for _, account := range accounts {
		accountLabels[account.Account] = account.Label
	}
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
		Categories: dashboardOptionRows(categoryCounts, accountLabels),
		Accounts:   dashboardOptionRows(accountCounts, accountLabels),
		Payees:     dashboardOptionRows(payeeCounts, nil),
		Tags:       dashboardOptionRows(tagCounts, nil),
	}
}

func dashboardOptionRows(counts map[string]int, labels map[string]string) []DashboardFilterOption {
	rows := make([]DashboardFilterOption, 0, len(counts))
	for value, count := range counts {
		label := value
		if labels != nil && labels[value] != "" {
			label = labels[value]
		}
		rows = append(rows, DashboardFilterOption{Value: value, Label: label, Count: count})
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

func balanceTotals(balances map[string]int) (int, int) {
	var assets, liabilities int
	for account, amount := range balances {
		if strings.HasPrefix(account, "Assets:") {
			assets += amount
		}
		if strings.HasPrefix(account, "Liabilities:") {
			liabilities += abs(amount)
		}
	}
	return assets, liabilities
}

func dashboardNetWorthSeries(txns []Transaction, start, end string) []NetWorthPoint {
	buckets := dashboardBuckets(start, end)
	sorted := append([]Transaction(nil), txns...)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Date == sorted[j].Date {
			return sorted[i].Source.Line < sorted[j].Source.Line
		}
		return sorted[i].Date < sorted[j].Date
	})
	balances := map[string]int{}
	out := make([]NetWorthPoint, 0, len(buckets))
	index := 0
	for _, bucket := range buckets {
		for index < len(sorted) && sorted[index].Date < bucket.End {
			for _, posting := range sorted[index].Postings {
				balances[posting.Account] += posting.Amount
			}
			index++
		}
		assets, liabilities := balanceTotals(balances)
		out = append(out, NetWorthPoint{Date: bucket.Label, Assets: assets, Liabilities: liabilities, NetWorth: assets - liabilities})
	}
	return out
}

func dashboardCashflowSeries(txns []Transaction, start, end string) []DashboardCashflowPoint {
	buckets := dashboardBuckets(start, end)
	out := make([]DashboardCashflowPoint, 0, len(buckets))
	for _, bucket := range buckets {
		summary := MonthSummary(bucket.Start, bucket.End, txns)
		out = append(out, DashboardCashflowPoint{Month: bucket.Label, Income: summary.Income, Expense: summary.Expense, Net: summary.Net})
	}
	return out
}

func dashboardDailyExpenseSeries(txns []Transaction, start, end string) []DashboardDailyExpense {
	byDate := map[string]*DashboardDailyExpense{}
	for _, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		var expense int
		for _, posting := range txn.Postings {
			if strings.HasPrefix(posting.Account, "Expenses:") && posting.Amount > 0 {
				expense += posting.Amount
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

func dashboardWeekdayExpense(txns []Transaction, start, end string) []DashboardWeekdayExpense {
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
				expense += posting.Amount
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

func dashboardCategorySeries(txns []Transaction, start, end string, limit int) []DashboardCategorySeries {
	buckets := dashboardBuckets(start, end)
	byAccount := map[string]map[string]int{}
	totals := map[string]int{}
	for _, bucket := range buckets {
		for account, amount := range MonthSummary(bucket.Start, bucket.End, txns).Categories {
			if byAccount[account] == nil {
				byAccount[account] = map[string]int{}
			}
			byAccount[account][bucket.Label] += amount
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
		values := make([]DashboardSeriesPoint, 0, len(buckets))
		for _, bucket := range buckets {
			values = append(values, DashboardSeriesPoint{Month: bucket.Label, Value: byAccount[account][bucket.Label]})
		}
		out = append(out, DashboardCategorySeries{Account: account, Label: labelFor(account), Total: totals[account], Values: values})
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

func dashboardAccountBalanceSeries(txns []Transaction, accounts []Account, balances map[string]int, start, end string, limit int) []DashboardAccountSeries {
	labels := map[string]Account{}
	for _, account := range accounts {
		labels[account.Account] = account
	}
	selected := make([]string, 0)
	for account, amount := range balances {
		if !strings.HasPrefix(account, "Assets:") && !strings.HasPrefix(account, "Liabilities:") {
			continue
		}
		if amount == 0 {
			continue
		}
		selected = append(selected, account)
	}
	sort.Slice(selected, func(i, j int) bool {
		if abs(balances[selected[i]]) == abs(balances[selected[j]]) {
			return selected[i] < selected[j]
		}
		return abs(balances[selected[i]]) > abs(balances[selected[j]])
	})
	if len(selected) > limit {
		selected = selected[:limit]
	}

	buckets := dashboardBuckets(start, end)
	seriesValues := accountBucketEndBalances(txns, selected, buckets)
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
		out = append(out, DashboardAccountSeries{Account: accountName, Label: label, Group: group, Values: seriesValues[accountName]})
	}
	return out
}

func accountBucketEndBalances(txns []Transaction, accounts []string, buckets []dashboardBucket) map[string][]DashboardSeriesPoint {
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
	balances := map[string]int{}
	index := 0
	for _, bucket := range buckets {
		for index < len(sorted) && sorted[index].Date < bucket.End {
			for _, posting := range sorted[index].Postings {
				balances[posting.Account] += posting.Amount
			}
			index++
		}
		for _, account := range accounts {
			out[account] = append(out[account], DashboardSeriesPoint{Month: bucket.Label, Value: balances[account]})
		}
	}
	return out
}

func dashboardBudgetPressure(budgets []Budget, actual map[string]int, end string) ([]DashboardBudgetPressure, int, int) {
	latest := map[string]Budget{}
	for _, budget := range budgets {
		if budget.Date <= end {
			if cur, ok := latest[budget.Account]; !ok || budget.Date >= cur.Date {
				latest[budget.Account] = budget
			}
		}
	}
	keys := make([]string, 0, len(latest))
	var totalBudget, totalSpent int
	for account := range latest {
		keys = append(keys, account)
		totalBudget += latest[account].Amount
		totalSpent += actual[account]
	}
	sort.Slice(keys, func(i, j int) bool {
		leftRatio, rightRatio := 0.0, 0.0
		if latest[keys[i]].Amount != 0 {
			leftRatio = float64(actual[keys[i]]) / float64(latest[keys[i]].Amount)
		}
		if latest[keys[j]].Amount != 0 {
			rightRatio = float64(actual[keys[j]]) / float64(latest[keys[j]].Amount)
		}
		if leftRatio == rightRatio {
			return keys[i] < keys[j]
		}
		return leftRatio > rightRatio
	})
	if len(keys) > 8 {
		keys = keys[:8]
	}
	out := make([]DashboardBudgetPressure, 0, len(keys))
	for _, account := range keys {
		budget := latest[account].Amount
		spent := actual[account]
		var ratio *float64
		if budget != 0 {
			value := float64(spent) / float64(budget)
			ratio = &value
		}
		out = append(out, DashboardBudgetPressure{Account: account, Label: labelFor(account), Budget: budget, Spent: spent, Remaining: budget - spent, Ratio: ratio})
	}
	return out, totalBudget, totalSpent
}

func dashboardAnomalies(txns []Transaction, start, end string, limit int) []DashboardAnomaly {
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
			rows = append(rows, DashboardAnomaly{Date: txn.Date, Payee: txn.Payee, Narration: txn.Narration, Account: posting.Account, Amount: posting.Amount, Source: source})
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

type dashboardBucket struct {
	Label string
	Start string
	End   string
}

func dashboardBuckets(start, end string) []dashboardBucket {
	startDate, errStart := time.Parse("2006-01-02", start)
	endDate, errEnd := time.Parse("2006-01-02", end)
	if errStart != nil || errEnd != nil || !startDate.Before(endDate) {
		return nil
	}
	days := int(endDate.Sub(startDate).Hours() / 24)
	if days <= 45 {
		return dayBuckets(startDate, endDate)
	}
	if days <= 180 {
		return weekBuckets(startDate, endDate)
	}
	if days <= 730 {
		return monthBuckets(startDate, endDate)
	}
	return quarterBuckets(startDate, endDate)
}

func dayBuckets(startDate, endDate time.Time) []dashboardBucket {
	out := []dashboardBucket{}
	for current := startDate; current.Before(endDate); current = current.AddDate(0, 0, 1) {
		next := current.AddDate(0, 0, 1)
		out = append(out, dashboardBucket{Label: current.Format("01-02"), Start: current.Format("2006-01-02"), End: next.Format("2006-01-02")})
	}
	return out
}

func weekBuckets(startDate, endDate time.Time) []dashboardBucket {
	out := []dashboardBucket{}
	for current := startDate; current.Before(endDate); current = current.AddDate(0, 0, 7) {
		next := current.AddDate(0, 0, 7)
		if next.After(endDate) {
			next = endDate
		}
		labelEnd := next.AddDate(0, 0, -1)
		label := current.Format("01-02") + "~" + labelEnd.Format("01-02")
		out = append(out, dashboardBucket{Label: label, Start: current.Format("2006-01-02"), End: next.Format("2006-01-02")})
	}
	return out
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
