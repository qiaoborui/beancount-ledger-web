package app

import (
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type NetWorthDelta struct {
	Baseline    *NetWorthPoint `json:"baseline"`
	Change      *int           `json:"change"`
	ChangeRatio *float64       `json:"changeRatio"`
}

type NetWorthWindows struct {
	Latest           *NetWorthPoint `json:"latest"`
	PreviousMonthEnd *NetWorthPoint `json:"previousMonthEnd"`
	MonthChange      *int           `json:"monthChange"`
	SixMonth         NetWorthDelta  `json:"sixMonth"`
	TwelveMonth      NetWorthDelta  `json:"twelveMonth"`
}

type CreditCardAnalytics struct {
	Account          string  `json:"account"`
	Alias            *string `json:"alias,omitempty"`
	Label            string  `json:"label"`
	Balance          int     `json:"balance"`
	Outstanding      int     `json:"outstanding"`
	PeriodSpend      int     `json:"periodSpend"`
	PeriodRepayments int     `json:"periodRepayments"`
	BillCycleSpend   int     `json:"billCycleSpend"`
	BillCycleStart   string  `json:"billCycleStart"`
	BillCycleEnd     string  `json:"billCycleEnd"`
	StatementDate    string  `json:"statementDate"`
	DueDate          string  `json:"dueDate"`
	TxCount          int     `json:"txCount"`
	RepaymentCount   int     `json:"repaymentCount"`
	LastActivityDate *string `json:"lastActivityDate"`
}

type PayeeAnalytics struct {
	Payee   string `json:"payee"`
	Amount  int    `json:"amount"`
	TxCount int    `json:"txCount"`
}

type AccountAnalytics struct {
	Account string  `json:"account"`
	Alias   *string `json:"alias,omitempty"`
	Label   string  `json:"label"`
	Amount  int     `json:"amount"`
	TxCount int     `json:"txCount"`
}

type ExpenseCategoryAnalytics struct {
	Account        string           `json:"account"`
	Alias          *string          `json:"alias,omitempty"`
	Label          string           `json:"label"`
	Amount         int              `json:"amount"`
	TxCount        int              `json:"txCount"`
	Share          *float64         `json:"share"`
	PreviousAmount int              `json:"previousAmount"`
	ChangeRatio    *float64         `json:"changeRatio"`
	TopPayees      []PayeeAnalytics `json:"topPayees"`
}

func MonthEndNetWorth(rows []NetWorthPoint) []NetWorthPoint {
	sorted := append([]NetWorthPoint(nil), rows...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Date < sorted[j].Date })
	byMonth := map[string]NetWorthPoint{}
	keys := []string{}
	for _, row := range sorted {
		month := row.Date[:7]
		if _, ok := byMonth[month]; !ok {
			keys = append(keys, month)
		}
		byMonth[month] = row
	}
	sort.Strings(keys)
	out := make([]NetWorthPoint, 0, len(keys))
	for _, key := range keys {
		out = append(out, byMonth[key])
	}
	return out
}

func NetWorthChangeWindows(rows []NetWorthPoint) NetWorthWindows {
	monthly := MonthEndNetWorth(rows)
	var latest *NetWorthPoint
	if len(rows) > 0 {
		latest = &rows[len(rows)-1]
	}
	var previous *NetWorthPoint
	if len(monthly) >= 2 {
		previous = &monthly[len(monthly)-2]
	}
	var monthChange *int
	if latest != nil && previous != nil {
		value := latest.NetWorth - previous.NetWorth
		monthChange = &value
	}
	return NetWorthWindows{Latest: latest, PreviousMonthEnd: previous, MonthChange: monthChange, SixMonth: deltaFromMonthly(monthly, latest, 6), TwelveMonth: deltaFromMonthly(monthly, latest, 12)}
}

func deltaFromMonthly(monthly []NetWorthPoint, latest *NetWorthPoint, months int) NetWorthDelta {
	if latest == nil || len(monthly) == 0 {
		return NetWorthDelta{}
	}
	index := 0
	if len(monthly) > months {
		index = len(monthly) - months - 1
	}
	baseline := monthly[index]
	change := latest.NetWorth - baseline.NetWorth
	var ratio *float64
	if baseline.NetWorth != 0 {
		value := float64(change) / float64(abs(baseline.NetWorth))
		ratio = &value
	}
	return NetWorthDelta{Baseline: &baseline, Change: &change, ChangeRatio: ratio}
}

func CreditCards(txns []Transaction, balances map[string]int, accounts []Account, start, end string) []CreditCardAnalytics {
	return CreditCardsInCurrency(txns, balances, accounts, start, end, nil, "CNY")
}

func CreditCardsInCurrency(txns []Transaction, balances map[string]int, accounts []Account, start, end string, prices []Price, valuationCurrency string) []CreditCardAnalytics {
	cycleStart, cycleEnd, statementDate, dueDate := creditCardBillingCycle(time.Now().Format("2006-01-02"))
	var out []CreditCardAnalytics
	for _, account := range accounts {
		if account.Group != "credit" || !strings.HasPrefix(account.Account, "Liabilities:") {
			continue
		}
		row := CreditCardAnalytics{Account: account.Account, Alias: account.Alias, Label: accountDisplayLabel(account.Account, account.Label), BillCycleStart: cycleStart, BillCycleEnd: cycleEnd, StatementDate: statementDate, DueDate: dueDate}
		for _, txn := range txns {
			var cardTotal, expenseAmount, assetOutflow int
			for _, posting := range txn.Postings {
				if posting.Account == account.Account {
					cardTotal += posting.Amount
				}
				if strings.HasPrefix(posting.Account, "Expenses:") {
					expenseAmount += posting.Amount
				}
				if strings.HasPrefix(posting.Account, "Assets:") && posting.Amount < 0 {
					assetOutflow += -posting.Amount
				}
			}
			if cardTotal != 0 && (row.LastActivityDate == nil || txn.Date > *row.LastActivityDate) {
				date := txn.Date
				row.LastActivityDate = &date
			}
			cardSpend := 0
			if expenseAmount > 0 && cardTotal < 0 {
				cardSpend = min(expenseAmount, -cardTotal)
			}
			if txn.Date >= cycleStart && txn.Date < cycleEnd && cardSpend > 0 {
				row.BillCycleSpend += valuationOrZero(cardSpend, account.Currency, prices, txn.Date, valuationCurrency)
			}
			if txn.Date < start || txn.Date >= end || cardTotal == 0 {
				continue
			}
			if cardSpend > 0 {
				row.PeriodSpend += valuationOrZero(cardSpend, account.Currency, prices, txn.Date, valuationCurrency)
				row.TxCount++
			} else if assetOutflow > 0 && cardTotal > 0 {
				row.PeriodRepayments += valuationOrZero(min(assetOutflow, cardTotal), account.Currency, prices, txn.Date, valuationCurrency)
				row.RepaymentCount++
			}
		}
		row.Balance = valuationOrZero(balances[account.Account], account.Currency, prices, end, valuationCurrency)
		row.Outstanding = max(0, abs(min(row.Balance, 0)))
		out = append(out, row)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Outstanding != out[j].Outstanding {
			return out[i].Outstanding > out[j].Outstanding
		}
		if out[i].PeriodSpend != out[j].PeriodSpend {
			return out[i].PeriodSpend > out[j].PeriodSpend
		}
		return out[i].Label < out[j].Label
	})
	return out
}

func valuationOrZero(amount int, currency string, prices []Price, date, valuationCurrency string) int {
	value, ok := ValuationInCurrency(amount, currency, valuationCurrency, prices, date)
	if !ok {
		return 0
	}
	return value
}

func ExpenseAnalytics(txns []Transaction, start, end string, accounts []Account) ([]ExpenseCategoryAnalytics, []PayeeAnalytics, []AccountAnalytics) {
	return ExpenseAnalyticsInCurrency(txns, start, end, accounts, nil, "CNY")
}

func ExpenseAnalyticsInCurrency(txns []Transaction, start, end string, accounts []Account, prices []Price, valuationCurrency string) ([]ExpenseCategoryAnalytics, []PayeeAnalytics, []AccountAnalytics) {
	current := collectExpenseCategories(txns, start, end, prices, valuationCurrency)
	prevStart, prevEnd := previousRange(start, end)
	previous := collectExpenseCategories(txns, prevStart, prevEnd, prices, valuationCurrency)
	accountMap := accountByName(accounts)
	totalExpense := 0
	for _, row := range current {
		totalExpense += row.amount
	}

	categories := []ExpenseCategoryAnalytics{}
	for account, row := range current {
		share := (*float64)(nil)
		if totalExpense > 0 {
			value := float64(row.amount) / float64(totalExpense)
			share = &value
		}
		previousAmount := previous[account].amount
		var changeRatio *float64
		if previousAmount == 0 {
			if row.amount == 0 {
				value := 0.0
				changeRatio = &value
			}
		} else {
			value := float64(row.amount-previousAmount) / float64(previousAmount)
			changeRatio = &value
		}
		label, alias := accountLabelAlias(account, accountMap)
		categories = append(categories, ExpenseCategoryAnalytics{
			Account:        account,
			Alias:          alias,
			Label:          label,
			Amount:         row.amount,
			TxCount:        len(row.txns),
			Share:          share,
			PreviousAmount: previousAmount,
			ChangeRatio:    changeRatio,
			TopPayees:      categoryTopPayees(row.payees),
		})
	}
	sort.Slice(categories, func(i, j int) bool {
		if categories[i].Amount == categories[j].Amount {
			return categories[i].Account < categories[j].Account
		}
		return categories[i].Amount > categories[j].Amount
	})
	return categories, summarizePayees(txns, start, end, prices, valuationCurrency), summarizePaymentAccounts(txns, start, end, accountMap, prices, valuationCurrency)
}

type expenseCategoryAccumulator struct {
	amount int
	txns   map[string]bool
	payees map[string]expensePayeeAccumulator
}

type expensePayeeAccumulator struct {
	amount int
	txns   map[string]bool
}

func collectExpenseCategories(txns []Transaction, start, end string, prices []Price, valuationCurrency string) map[string]expenseCategoryAccumulator {
	categories := map[string]expenseCategoryAccumulator{}
	for index, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		id := transactionID(txn, index)
		for _, posting := range txn.Postings {
			if !strings.HasPrefix(posting.Account, "Expenses:") {
				continue
			}
			row := categories[posting.Account]
			if row.txns == nil {
				row.txns = map[string]bool{}
			}
			if row.payees == nil {
				row.payees = map[string]expensePayeeAccumulator{}
			}
			amount := postingValuationInCurrency(posting, prices, txn.Date, valuationCurrency)
			row.amount += amount
			row.txns[id] = true

			payeeName := txn.Payee
			if payeeName == "" {
				payeeName = "（无商户）"
			}
			payee := row.payees[payeeName]
			if payee.txns == nil {
				payee.txns = map[string]bool{}
			}
			payee.amount += amount
			payee.txns[id] = true
			row.payees[payeeName] = payee
			categories[posting.Account] = row
		}
	}
	return categories
}

func categoryTopPayees(rows map[string]expensePayeeAccumulator) []PayeeAnalytics {
	out := []PayeeAnalytics{}
	for payee, row := range rows {
		out = append(out, PayeeAnalytics{Payee: payee, Amount: row.amount, TxCount: len(row.txns)})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Amount != out[j].Amount {
			return out[i].Amount > out[j].Amount
		}
		if out[i].TxCount != out[j].TxCount {
			return out[i].TxCount > out[j].TxCount
		}
		return out[i].Payee < out[j].Payee
	})
	if len(out) > 3 {
		out = out[:3]
	}
	return out
}

func previousRange(start, end string) (string, string) {
	startDate, errStart := time.Parse("2006-01-02", start)
	endDate, errEnd := time.Parse("2006-01-02", end)
	if errStart != nil || errEnd != nil {
		return start, start
	}
	duration := endDate.Sub(startDate)
	return startDate.Add(-duration).Format("2006-01-02"), start
}

func transactionID(txn Transaction, index int) string {
	id := txn.Source.File + ":" + formatInt(txn.Source.Line)
	if id == ":0" {
		return txn.Date + ":" + formatInt(index)
	}
	return id
}

func summarizePayees(txns []Transaction, start, end string, prices []Price, valuationCurrency string) []PayeeAnalytics {
	type acc struct {
		amount int
		txns   map[string]bool
	}
	rows := map[string]acc{}
	for _, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		var expense int
		for _, posting := range txn.Postings {
			if strings.HasPrefix(posting.Account, "Expenses:") {
				expense += postingValuationInCurrency(posting, prices, txn.Date, valuationCurrency)
			}
		}
		if expense <= 0 {
			continue
		}
		payee := txn.Payee
		if payee == "" {
			payee = "（无商户）"
		}
		row := rows[payee]
		if row.txns == nil {
			row.txns = map[string]bool{}
		}
		row.amount += expense
		row.txns[txn.Source.File+":"+formatInt(txn.Source.Line)] = true
		rows[payee] = row
	}
	out := []PayeeAnalytics{}
	for payee, row := range rows {
		out = append(out, PayeeAnalytics{Payee: payee, Amount: row.amount, TxCount: len(row.txns)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Amount > out[j].Amount })
	if len(out) > 8 {
		out = out[:8]
	}
	return out
}

func summarizePaymentAccounts(txns []Transaction, start, end string, accounts map[string]Account, prices []Price, valuationCurrency string) []AccountAnalytics {
	type acc struct {
		amount int
		txns   map[string]bool
	}
	rows := map[string]acc{}
	for _, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		hasExpense := false
		for _, posting := range txn.Postings {
			if strings.HasPrefix(posting.Account, "Expenses:") {
				hasExpense = true
			}
		}
		if !hasExpense {
			continue
		}
		id := txn.Source.File + ":" + formatInt(txn.Source.Line)
		for _, posting := range txn.Postings {
			if !(strings.HasPrefix(posting.Account, "Assets:") || strings.HasPrefix(posting.Account, "Liabilities:")) {
				continue
			}
			outflow := -posting.Amount
			if outflow <= 0 {
				continue
			}
			outflow, ok := ValuationInCurrency(outflow, posting.Currency, valuationCurrency, prices, txn.Date)
			if !ok {
				continue
			}
			row := rows[posting.Account]
			if row.txns == nil {
				row.txns = map[string]bool{}
			}
			row.amount += outflow
			row.txns[id] = true
			rows[posting.Account] = row
		}
	}
	out := []AccountAnalytics{}
	for account, row := range rows {
		label, alias := accountLabelAlias(account, accounts)
		out = append(out, AccountAnalytics{Account: account, Alias: alias, Label: label, Amount: row.amount, TxCount: len(row.txns)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Amount > out[j].Amount })
	if len(out) > 8 {
		out = out[:8]
	}
	return out
}

func creditCardBillingCycle(asOf string) (string, string, string, string) {
	date, _ := time.Parse("2006-01-02", asOf)
	year, month, day := date.Date()
	cycleMonth := int(month)
	if day < 17 {
		cycleMonth--
	}
	return dateString(year, cycleMonth, 17), dateString(year, cycleMonth+1, 17), dateString(year, cycleMonth+1, 18), dateString(year, cycleMonth+2, 5)
}

func dateString(year int, month int, day int) string {
	return time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC).Format("2006-01-02")
}

func labelFor(account string) string {
	base := filepath.Base(strings.ReplaceAll(account, ":", string(filepath.Separator)))
	if base == "." {
		return account
	}
	return base
}

func accountByName(accounts []Account) map[string]Account {
	out := map[string]Account{}
	for _, account := range accounts {
		out[account.Account] = account
	}
	return out
}

func accountLabelAlias(account string, accounts map[string]Account) (string, *string) {
	if acct, ok := accounts[account]; ok {
		return accountDisplayLabel(account, acct.Label), acct.Alias
	}
	return labelFor(account), nil
}

func accountDisplayLabel(account, label string) string {
	if strings.TrimSpace(label) != "" {
		return label
	}
	return labelFor(account)
}

func abs(value int) int {
	if value < 0 {
		return -value
	}
	return value
}
