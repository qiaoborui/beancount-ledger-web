package app

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

type MetadataValue any

type BeanLine struct {
	File string `json:"file"`
	Line int    `json:"line"`
	Text string `json:"text"`
}

type Posting struct {
	Account  string `json:"account"`
	Amount   int    `json:"amount"`
	Currency string `json:"currency,omitempty"`
}

type Transaction struct {
	Date      string                   `json:"date"`
	Payee     string                   `json:"payee"`
	Narration string                   `json:"narration"`
	Metadata  map[string]MetadataValue `json:"metadata,omitempty"`
	Tags      []string                 `json:"tags,omitempty"`
	Postings  []Posting                `json:"postings"`
	Source    TransactionSource        `json:"source"`
}

type TransactionSource struct {
	File string `json:"file"`
	Line int    `json:"line"`
	Hash string `json:"hash,omitempty"`
}

type BalanceAssertion struct {
	Date     string `json:"date"`
	Account  string `json:"account"`
	Amount   int    `json:"amount"`
	Currency string `json:"currency"`
}

type Budget struct {
	Date     string `json:"date"`
	Account  string `json:"account"`
	Amount   int    `json:"amount"`
	Currency string `json:"currency"`
}

type Account struct {
	Account   string                   `json:"account"`
	OpenDate  string                   `json:"openDate"`
	CloseDate *string                  `json:"closeDate"`
	Currency  string                   `json:"currency"`
	Alias     *string                  `json:"alias"`
	Label     string                   `json:"label"`
	Group     string                   `json:"group"`
	Active    bool                     `json:"active"`
	Metadata  map[string]MetadataValue `json:"metadata,omitempty"`
}

type AccountStatus struct {
	Account         string  `json:"account"`
	Status          string  `json:"status"`
	LastEntryDate   *string `json:"lastEntryDate"`
	LastEntryType   *string `json:"lastEntryType"`
	AssertionAmount *int    `json:"assertionAmount"`
	ComputedBalance *int    `json:"computedBalance"`
}

type Summary struct {
	Income     int                       `json:"income"`
	Expense    int                       `json:"expense"`
	Net        int                       `json:"net"`
	Days       map[string]map[string]int `json:"days"`
	Categories map[string]int            `json:"categories"`
}

type IncomeStatementNode struct {
	Account  string                `json:"account"`
	Label    string                `json:"label"`
	Amount   int                   `json:"amount"`
	Children []IncomeStatementNode `json:"children"`
	Depth    int                   `json:"depth"`
	TxCount  int                   `json:"txCount"`
}

type NetWorthPoint struct {
	Date        string `json:"date"`
	Assets      int    `json:"assets"`
	Liabilities int    `json:"liabilities"`
	NetWorth    int    `json:"netWorth"`
}

type AccountDetailRow struct {
	Date      string      `json:"date"`
	Payee     string      `json:"payee"`
	Narration string      `json:"narration"`
	Change    int         `json:"change"`
	Balance   int         `json:"balance"`
	Txn       Transaction `json:"txn"`
}

var (
	includeRe = regexp.MustCompile(`^include\s+"([^"]+)"\s*$`)
	txnRe     = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})\s+[*!]\s+"([^"]*)"\s+"([^"]*)"(.*)$`)
	postRe    = regexp.MustCompile(`^\s+([A-Z][A-Za-z0-9-:]+)\s+(-?\d+(?:\.\d+)?)\s+(CNY)\b`)
	metaRe    = regexp.MustCompile(`^\s+([a-z][a-zA-Z0-9_-]*):\s+(.+)$`)
	balanceRe = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})\s+balance\s+([A-Z][A-Za-z0-9-:]+)\s+(-?\d+(?:\.\d+)?)\s+(CNY)\b`)
	budgetRe  = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})\s+custom\s+"budget"\s+(Expenses(?::[A-Za-z0-9-]+)+)\s+"monthly"\s+(-?\d+(?:\.\d+)?)\s+(CNY)\b`)
	openRe    = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})\s+open\s+([A-Z][A-Za-z0-9-:]+)\s+([A-Z][A-Z0-9._-]*)\b`)
	closeRe   = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})\s+close\s+([A-Z][A-Za-z0-9-:]+)\b`)
)

func mainBeanPath(cfg Config) string     { return filepath.Join(cfg.LedgerRoot, "main.bean") }
func accountsBeanPath(cfg Config) string { return filepath.Join(cfg.LedgerRoot, "accounts.bean") }
func transactionsDir(cfg Config) string  { return filepath.Join(cfg.LedgerRoot, "transactions") }

func transactionFileForDate(cfg Config, date string) string {
	if len(date) < 7 {
		return filepath.Join(transactionsDir(cfg), "invalid.bean")
	}
	return filepath.Join(transactionsDir(cfg), date[:4], date[5:7]+".bean")
}

func ReadLedgerLines(entry string, seen map[string]bool) ([]BeanLine, error) {
	full, err := filepath.Abs(entry)
	if err != nil {
		return nil, err
	}
	if seen[full] {
		return nil, nil
	}
	seen[full] = true
	text, err := os.ReadFile(full)
	if err != nil {
		return nil, err
	}
	dir := filepath.Dir(full)
	var out []BeanLine
	for i, line := range strings.Split(string(text), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if m := includeRe.FindStringSubmatch(strings.TrimSpace(line)); m != nil {
			lines, err := ReadLedgerLines(filepath.Join(dir, m[1]), seen)
			if err != nil {
				return nil, err
			}
			out = append(out, lines...)
			continue
		}
		out = append(out, BeanLine{File: full, Line: i + 1, Text: line})
	}
	return out, nil
}

func transactionHash(lines []string) string {
	h := sha256.Sum256([]byte(strings.TrimRight(strings.Join(lines, "\n"), "\n")))
	return hex.EncodeToString(h[:])[:16]
}

func ParseTransactions(lines []BeanLine) []Transaction {
	var txns []Transaction
	var current *Transaction
	var raw []string
	finish := func() {
		if current != nil {
			current.Source.Hash = transactionHash(raw)
		}
		raw = nil
	}
	for _, line := range lines {
		if current != nil && line.File != current.Source.File {
			finish()
			current = nil
		}
		if m := txnRe.FindStringSubmatch(line.Text); m != nil {
			finish()
			raw = []string{line.Text}
			tags := []string{}
			for _, tag := range regexp.MustCompile(`#([A-Za-z0-9_-]+)`).FindAllStringSubmatch(m[4], -1) {
				tags = append(tags, tag[1])
			}
			txns = append(txns, Transaction{
				Date: m[1], Payee: m[2], Narration: m[3],
				Metadata: map[string]MetadataValue{}, Tags: tags,
				Postings: []Posting{},
				Source:   TransactionSource{File: line.File, Line: line.Line, Hash: transactionHash([]string{line.Text})},
			})
			current = &txns[len(txns)-1]
			continue
		}
		if regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\s+`).MatchString(line.Text) {
			finish()
			current = nil
			continue
		}
		if current != nil {
			raw = append(raw, line.Text)
		}
		trimmed := strings.TrimSpace(line.Text)
		if trimmed == "" || strings.HasPrefix(trimmed, ";") || current == nil {
			continue
		}
		if m := metaRe.FindStringSubmatch(line.Text); m != nil {
			current.Metadata[m[1]] = parseMetadataValue(m[2])
			continue
		}
		if m := postRe.FindStringSubmatch(line.Text); m != nil {
			current.Postings = append(current.Postings, Posting{Account: m[1], Amount: cents(m[2]), Currency: "CNY"})
		}
	}
	finish()
	return txns
}

func parseMetadataValue(raw string) MetadataValue {
	value := strings.TrimSpace(raw)
	if strings.HasPrefix(value, `"`) && strings.HasSuffix(value, `"`) && len(value) >= 2 {
		unquoted := value[1 : len(value)-1]
		unquoted = strings.ReplaceAll(unquoted, `\"`, `"`)
		unquoted = strings.ReplaceAll(unquoted, `\\`, `\`)
		return unquoted
	}
	if value == "TRUE" {
		return true
	}
	if value == "FALSE" {
		return false
	}
	if n, err := strconv.ParseFloat(value, 64); err == nil {
		return n
	}
	return value
}

func ParseBalances(lines []BeanLine) []BalanceAssertion {
	var out []BalanceAssertion
	for _, line := range lines {
		if m := balanceRe.FindStringSubmatch(strings.TrimSpace(line.Text)); m != nil {
			out = append(out, BalanceAssertion{Date: m[1], Account: m[2], Amount: cents(m[3]), Currency: m[4]})
		}
	}
	return out
}

func ParseBudgets(lines []BeanLine) []Budget {
	var out []Budget
	for _, line := range lines {
		if m := budgetRe.FindStringSubmatch(strings.TrimSpace(line.Text)); m != nil {
			out = append(out, Budget{Date: m[1], Account: m[2], Amount: cents(m[3]), Currency: m[4]})
		}
	}
	return out
}

func ParseAccounts(cfg Config) ([]Account, error) {
	text, err := os.ReadFile(accountsBeanPath(cfg))
	if err != nil {
		return nil, err
	}
	accounts := map[string]*Account{}
	var current string
	for _, line := range strings.Split(string(text), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if m := openRe.FindStringSubmatch(line); m != nil {
			acct := &Account{Account: m[2], OpenDate: m[1], Currency: m[3], Label: m[2], Group: accountGroup(m[2], nil, nil), Active: true, Metadata: map[string]MetadataValue{}}
			accounts[m[2]] = acct
			current = m[2]
			continue
		}
		if m := closeRe.FindStringSubmatch(line); m != nil {
			if acct := accounts[m[2]]; acct != nil {
				closeDate := m[1]
				acct.CloseDate = &closeDate
				acct.Active = false
			}
			current = ""
			continue
		}
		if m := metaRe.FindStringSubmatch(line); m != nil && current != "" {
			acct := accounts[current]
			if acct == nil {
				continue
			}
			value := parseMetadataValue(m[2])
			acct.Metadata[m[1]] = value
			if m[1] == "alias" {
				if alias, ok := value.(string); ok {
					acct.Alias = &alias
					label := strings.TrimSpace(strings.Split(alias, "/")[0])
					if label != "" {
						acct.Label = label
					}
				}
			}
			acct.Group = accountGroup(acct.Account, acct.Metadata, acct.Alias)
			continue
		}
		if strings.TrimSpace(line) != "" && !strings.HasPrefix(line, " ") {
			current = ""
		}
	}
	out := make([]Account, 0, len(accounts))
	for _, acct := range accounts {
		out = append(out, *acct)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Account < out[j].Account })
	return out, nil
}

func accountGroup(account string, metadata map[string]MetadataValue, alias *string) string {
	if metadata != nil {
		for _, key := range []string{"group", "account-group", "asset-class", "type"} {
			if value, ok := metadata[key].(string); ok {
				if group := normalizeGroup(value); group != "" {
					return group
				}
			}
		}
	}
	haystack := account
	if alias != nil {
		haystack += " " + *alias
	}
	switch {
	case strings.HasPrefix(account, "Expenses:"):
		return "expense"
	case strings.HasPrefix(account, "Income:"):
		return "income"
	case strings.HasPrefix(account, "Equity:"):
		return "equity"
	case strings.HasPrefix(account, "Assets:Receivable"), strings.HasPrefix(account, "Liabilities:Payable"):
		return "receivable"
	case strings.HasPrefix(account, "Liabilities:"):
		return "credit"
	case regexp.MustCompile(`(?i)(^|:)(Wealth|Fund|Stock|Bond|HousingFund|Insurance)(:|$)|理财|稳利宝|增利宝|余利宝|余额宝|零钱通|基金|债券|股票|保险|黄金|存单|定期`).MatchString(haystack):
		return "wealth"
	case strings.HasPrefix(account, "Assets:"):
		return "cash"
	default:
		return "other"
	}
}

func normalizeGroup(value string) string {
	aliases := map[string]string{
		"cash": "cash", "checking": "cash", "bank": "cash", "现金": "cash", "活期": "cash",
		"wealth": "wealth", "investment": "wealth", "invest": "wealth", "asset": "wealth", "理财": "wealth", "投资": "wealth", "基金": "wealth",
		"credit": "credit", "liability": "credit", "liabilities": "credit", "debt": "credit", "负债": "credit", "信用卡": "credit",
		"receivable": "receivable", "payable": "receivable", "应收": "receivable", "应付": "receivable",
		"expense": "expense", "expenses": "expense", "支出": "expense",
		"income": "income", "收入": "income",
		"equity": "equity", "权益": "equity",
		"other": "other", "其他": "other",
	}
	normalized := strings.ReplaceAll(strings.ReplaceAll(strings.ToLower(strings.TrimSpace(value)), " ", "-"), "_", "-")
	if group := aliases[normalized]; group != "" {
		return group
	}
	return aliases[strings.TrimSpace(value)]
}

func CurrentBalances(txns []Transaction) map[string]int {
	balances := map[string]int{}
	for _, txn := range txns {
		for _, posting := range txn.Postings {
			balances[posting.Account] += posting.Amount
		}
	}
	return balances
}

func MonthSummary(start, end string, txns []Transaction) Summary {
	summary := Summary{Days: map[string]map[string]int{}, Categories: map[string]int{}}
	for _, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		day := txn.Date[8:10]
		if summary.Days[day] == nil {
			summary.Days[day] = map[string]int{"income": 0, "expense": 0}
		}
		for _, posting := range txn.Postings {
			if strings.HasPrefix(posting.Account, "Income:") {
				amount := posting.Amount
				if amount < 0 {
					amount = -amount
				}
				summary.Income += amount
				summary.Days[day]["income"] += amount
			}
			if strings.HasPrefix(posting.Account, "Expenses:") {
				summary.Expense += posting.Amount
				summary.Days[day]["expense"] += posting.Amount
				summary.Categories[posting.Account] += posting.Amount
			}
		}
	}
	summary.Net = summary.Income - summary.Expense
	return summary
}

type incomeStatementAggregate struct {
	Amount int
	Txns   map[string]struct{}
}

type incomeStatementBuildNode struct {
	Node IncomeStatementNode
	Txns map[string]struct{}
}

func IncomeStatementTree(start, end string, txns []Transaction) ([]IncomeStatementNode, []IncomeStatementNode, int, int, int) {
	incomeMap := map[string]incomeStatementAggregate{}
	expenseMap := map[string]incomeStatementAggregate{}

	for i, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		txnID := txn.Source.File + ":" + strconv.Itoa(txn.Source.Line)
		if txnID == ":0" {
			txnID = txn.Date + ":" + strconv.Itoa(i)
		}
		for _, posting := range txn.Postings {
			if strings.HasPrefix(posting.Account, "Income:") {
				amount := posting.Amount
				if amount < 0 {
					amount = -amount
				}
				addIncomeStatementAmount(incomeMap, posting.Account, amount, txnID)
			}
			if strings.HasPrefix(posting.Account, "Expenses:") {
				addIncomeStatementAmount(expenseMap, posting.Account, posting.Amount, txnID)
			}
		}
	}

	income := publicIncomeStatementNodes(buildIncomeStatementNodes("Income", incomeMap))
	expense := publicIncomeStatementNodes(buildIncomeStatementNodes("Expenses", expenseMap))
	totalIncome := 0
	for _, node := range income {
		totalIncome += node.Amount
	}
	totalExpense := 0
	for _, node := range expense {
		totalExpense += node.Amount
	}
	return income, expense, totalIncome, totalExpense, totalIncome - totalExpense
}

func addIncomeStatementAmount(target map[string]incomeStatementAggregate, account string, amount int, txnID string) {
	entry := target[account]
	if entry.Txns == nil {
		entry.Txns = map[string]struct{}{}
	}
	entry.Amount += amount
	entry.Txns[txnID] = struct{}{}
	target[account] = entry
}

func buildIncomeStatementNodes(root string, data map[string]incomeStatementAggregate) []incomeStatementBuildNode {
	prefix := root + ":"
	direct := map[string]incomeStatementAggregate{}
	for account, aggregate := range data {
		if !strings.HasPrefix(account, prefix) {
			continue
		}
		rest := strings.TrimPrefix(account, prefix)
		childKey := rest
		if colon := strings.Index(rest, ":"); colon >= 0 {
			childKey = rest[:colon]
		}
		childFull := root + ":" + childKey
		node := direct[childFull]
		if node.Txns == nil {
			node.Txns = map[string]struct{}{}
		}
		if childFull == account {
			node.Amount += aggregate.Amount
			for txnID := range aggregate.Txns {
				node.Txns[txnID] = struct{}{}
			}
		}
		direct[childFull] = node
	}

	keys := make([]string, 0, len(direct))
	for account := range direct {
		keys = append(keys, account)
	}
	sort.Strings(keys)

	nodes := make([]incomeStatementBuildNode, 0, len(keys))
	for _, account := range keys {
		directNode := direct[account]
		children := buildIncomeStatementNodes(account, data)
		amount := directNode.Amount
		txns := map[string]struct{}{}
		for txnID := range directNode.Txns {
			txns[txnID] = struct{}{}
		}
		for _, child := range children {
			amount += child.Node.Amount
			for txnID := range child.Txns {
				txns[txnID] = struct{}{}
			}
		}
		publicChildren := publicIncomeStatementNodes(children)
		nodes = append(nodes, incomeStatementBuildNode{
			Node: IncomeStatementNode{
				Account:  account,
				Label:    account[strings.LastIndex(account, ":")+1:],
				Amount:   amount,
				Children: publicChildren,
				Depth:    strings.Count(account, ":") - 1,
				TxCount:  len(txns),
			},
			Txns: txns,
		})
	}

	sort.Slice(nodes, func(i, j int) bool {
		if nodes[i].Node.Amount == nodes[j].Node.Amount {
			return nodes[i].Node.Account < nodes[j].Node.Account
		}
		return nodes[i].Node.Amount > nodes[j].Node.Amount
	})
	return nodes
}

func publicIncomeStatementNodes(nodes []incomeStatementBuildNode) []IncomeStatementNode {
	public := make([]IncomeStatementNode, 0, len(nodes))
	for _, node := range nodes {
		public = append(public, node.Node)
	}
	return public
}

func NetWorthHistory(txns []Transaction) []NetWorthPoint {
	sorted := append([]Transaction(nil), txns...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Date < sorted[j].Date })
	balances := map[string]int{}
	var rows []NetWorthPoint
	lastDate := ""
	for _, txn := range sorted {
		for _, posting := range txn.Postings {
			balances[posting.Account] += posting.Amount
		}
		if txn.Date == lastDate && len(rows) > 0 {
			rows = rows[:len(rows)-1]
		}
		var assets, liabilities int
		for account, amount := range balances {
			if strings.HasPrefix(account, "Assets:") {
				assets += amount
			}
			if strings.HasPrefix(account, "Liabilities:") {
				if amount < 0 {
					liabilities += -amount
				} else {
					liabilities += amount
				}
			}
		}
		rows = append(rows, NetWorthPoint{Date: txn.Date, Assets: assets, Liabilities: liabilities, NetWorth: assets - liabilities})
		lastDate = txn.Date
	}
	return rows
}

func AccountDetail(account string, txns []Transaction) []AccountDetailRow {
	type relevant struct {
		txn    Transaction
		change int
	}
	var rows []relevant
	for _, txn := range txns {
		for _, posting := range txn.Postings {
			if posting.Account == account {
				rows = append(rows, relevant{txn: txn, change: posting.Amount})
				break
			}
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].txn.Date != rows[j].txn.Date {
			return rows[i].txn.Date < rows[j].txn.Date
		}
		return rows[i].txn.Source.Line < rows[j].txn.Source.Line
	})
	var balance int
	out := make([]AccountDetailRow, 0, len(rows))
	for _, row := range rows {
		balance += row.change
		out = append(out, AccountDetailRow{Date: row.txn.Date, Payee: row.txn.Payee, Narration: row.txn.Narration, Change: row.change, Balance: balance, Txn: row.txn})
	}
	return out
}

func AccountStatusIndicators(txns []Transaction, assertions []BalanceAssertion, accounts []Account) []AccountStatus {
	staleCutoff := time.Now().AddDate(0, 0, -60).Format("2006-01-02")
	var out []AccountStatus
	for _, acct := range accounts {
		if !acct.Active || !(strings.HasPrefix(acct.Account, "Assets:") || strings.HasPrefix(acct.Account, "Liabilities:")) {
			continue
		}
		account := acct.Account
		var lastAssertion *BalanceAssertion
		for i := range assertions {
			if assertions[i].Account == account && (lastAssertion == nil || assertions[i].Date > lastAssertion.Date) {
				lastAssertion = &assertions[i]
			}
		}
		var lastTxnDate *string
		for _, txn := range txns {
			for _, posting := range txn.Postings {
				if posting.Account == account && (lastTxnDate == nil || txn.Date > *lastTxnDate) {
					date := txn.Date
					lastTxnDate = &date
				}
			}
		}
		var lastDate *string
		var lastType *string
		if lastAssertion != nil && lastTxnDate != nil {
			if lastAssertion.Date >= *lastTxnDate {
				date, typ := lastAssertion.Date, "balance"
				lastDate, lastType = &date, &typ
			} else {
				typ := "transaction"
				lastDate, lastType = lastTxnDate, &typ
			}
		} else if lastAssertion != nil {
			date, typ := lastAssertion.Date, "balance"
			lastDate, lastType = &date, &typ
		} else if lastTxnDate != nil {
			typ := "transaction"
			lastDate, lastType = lastTxnDate, &typ
		}
		if lastDate == nil {
			out = append(out, AccountStatus{Account: account, Status: "grey"})
			continue
		}
		if *lastDate < staleCutoff {
			var assertionAmount *int
			if lastAssertion != nil {
				amount := lastAssertion.Amount
				assertionAmount = &amount
			}
			out = append(out, AccountStatus{Account: account, Status: "grey", LastEntryDate: lastDate, LastEntryType: lastType, AssertionAmount: assertionAmount})
			continue
		}
		if lastType != nil && *lastType == "balance" && lastAssertion != nil {
			computed := balanceBefore(account, txns, lastAssertion.Date)
			assertion := lastAssertion.Amount
			status := "red"
			if computed == assertion {
				status = "green"
			}
			out = append(out, AccountStatus{Account: account, Status: status, LastEntryDate: lastDate, LastEntryType: lastType, AssertionAmount: &assertion, ComputedBalance: &computed})
			continue
		}
		out = append(out, AccountStatus{Account: account, Status: "yellow", LastEntryDate: lastDate, LastEntryType: lastType})
	}
	return out
}

func balanceBefore(account string, txns []Transaction, date string) int {
	var balance int
	for _, txn := range txns {
		if txn.Date >= date {
			continue
		}
		for _, posting := range txn.Postings {
			if posting.Account == account {
				balance += posting.Amount
			}
		}
	}
	return balance
}
