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
	GeneratedAt          string                    `json:"generatedAt"`
}

func BuildDashboardSummary(snapshot *LedgerSnapshot, start, end string) DashboardSummary {
	summary := MonthSummary(start, end, snapshot.Transactions)
	budgetPressure, budget, budgetSpent := dashboardBudgetPressure(snapshot.Budgets, summary.Categories, end)
	assets, liabilities := balanceTotals(snapshot.Balances)
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
	_, topPayees, topPaymentAccounts := ExpenseAnalytics(snapshot.Transactions, start, end)

	return DashboardSummary{
		Start:                start,
		End:                  end,
		Currency:             "CNY",
		KPIs:                 DashboardKPI{Assets: assets, Liabilities: liabilities, NetWorth: assets - liabilities, Income: summary.Income, Expense: summary.Expense, Net: summary.Net, SavingsRate: savingsRate, Budget: budget, BudgetSpent: budgetSpent, BudgetRemaining: budget - budgetSpent, BudgetUsage: budgetUsage},
		NetWorthSeries:       dashboardNetWorthSeries(snapshot.Transactions, start, end),
		CashflowSeries:       dashboardCashflowSeries(snapshot.Transactions, start, end),
		DailyExpenseSeries:   dashboardDailyExpenseSeries(snapshot.Transactions, start, end),
		WeekdayExpense:       dashboardWeekdayExpense(snapshot.Transactions, start, end),
		CategorySeries:       dashboardCategorySeries(snapshot.Transactions, start, end, 8),
		AccountBalanceSeries: dashboardAccountBalanceSeries(snapshot.Transactions, snapshot.Accounts, snapshot.Balances, start, end, 6),
		BudgetPressure:       budgetPressure,
		Anomalies:            dashboardAnomalies(snapshot.Transactions, start, end, 10),
		TopPayees:            topPayees,
		TopPaymentAccounts:   topPaymentAccounts,
		GeneratedAt:          time.Now().Format(time.RFC3339),
	}
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
	months := monthsBetween(start, end)
	sorted := append([]Transaction(nil), txns...)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Date == sorted[j].Date {
			return sorted[i].Source.Line < sorted[j].Source.Line
		}
		return sorted[i].Date < sorted[j].Date
	})
	balances := map[string]int{}
	out := make([]NetWorthPoint, 0, len(months))
	index := 0
	for _, month := range months {
		monthEnd := monthEnd(month)
		for index < len(sorted) && sorted[index].Date < monthEnd {
			for _, posting := range sorted[index].Postings {
				balances[posting.Account] += posting.Amount
			}
			index++
		}
		assets, liabilities := balanceTotals(balances)
		out = append(out, NetWorthPoint{Date: monthEnd, Assets: assets, Liabilities: liabilities, NetWorth: assets - liabilities})
	}
	return out
}

func dashboardCashflowSeries(txns []Transaction, start, end string) []DashboardCashflowPoint {
	months := monthsBetween(start, end)
	out := make([]DashboardCashflowPoint, 0, len(months))
	for _, month := range months {
		monthStart := month + "-01"
		monthEnd := monthEnd(month)
		summary := MonthSummary(monthStart, monthEnd, txns)
		out = append(out, DashboardCashflowPoint{Month: month, Income: summary.Income, Expense: summary.Expense, Net: summary.Net})
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
	months := monthsBetween(start, end)
	byAccount := map[string]map[string]int{}
	totals := map[string]int{}
	for _, month := range months {
		monthStart := month + "-01"
		monthEnd := monthEnd(month)
		for account, amount := range MonthSummary(monthStart, monthEnd, txns).Categories {
			if byAccount[account] == nil {
				byAccount[account] = map[string]int{}
			}
			byAccount[account][month] += amount
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
		values := make([]DashboardSeriesPoint, 0, len(months))
		for _, month := range months {
			values = append(values, DashboardSeriesPoint{Month: month, Value: byAccount[account][month]})
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

	months := monthsBetween(start, end)
	seriesValues := accountMonthEndBalances(txns, selected, months)
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

func accountMonthEndBalances(txns []Transaction, accounts []string, months []string) map[string][]DashboardSeriesPoint {
	out := map[string][]DashboardSeriesPoint{}
	for _, account := range accounts {
		out[account] = make([]DashboardSeriesPoint, 0, len(months))
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
	for _, month := range months {
		monthEnd := monthEnd(month)
		for index < len(sorted) && sorted[index].Date < monthEnd {
			for _, posting := range sorted[index].Postings {
				balances[posting.Account] += posting.Amount
			}
			index++
		}
		for _, account := range accounts {
			out[account] = append(out[account], DashboardSeriesPoint{Month: month, Value: balances[account]})
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

func monthsBetween(start, end string) []string {
	startDate, errStart := time.Parse("2006-01-02", start)
	endDate, errEnd := time.Parse("2006-01-02", end)
	if errStart != nil || errEnd != nil || !startDate.Before(endDate) {
		return nil
	}
	current := time.Date(startDate.Year(), startDate.Month(), 1, 0, 0, 0, 0, time.UTC)
	last := time.Date(endDate.Year(), endDate.Month(), 1, 0, 0, 0, 0, time.UTC)
	if endDate.Day() > 1 {
		last = last.AddDate(0, 1, 0)
	}
	months := []string{}
	for current.Before(last) {
		months = append(months, current.Format("2006-01"))
		current = current.AddDate(0, 1, 0)
	}
	return months
}
