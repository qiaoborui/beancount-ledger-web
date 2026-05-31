package app

import (
	"net/http"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

func (s *Server) ledgerVersion(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	version, err := s.cache.Version()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, version)
}

func (s *Server) snapshot(c *gin.Context, sensitive bool) (*LedgerSnapshot, bool) {
	if sensitive {
		if !requireSensitive(c) {
			return nil, false
		}
	} else if !requireAuth(c) {
		return nil, false
	}
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return nil, false
	}
	return snapshot, true
}

func (s *Server) summary(c *gin.Context) {
	snapshot, ok := s.snapshot(c, false)
	if !ok {
		return
	}
	start, end := parseTimeParams(c)
	unlocked := isSensitiveUnlocked(c)
	summary := MonthSummary(start, end, snapshot.Transactions)
	netWorthRows := []NetWorthPoint{}
	monthEndRows := []NetWorthPoint{}
	var windows any
	creditCards := []CreditCardAnalytics{}
	if unlocked {
		allRows := NetWorthHistory(snapshot.Transactions)
		for _, row := range allRows {
			if row.Date >= start && row.Date < end {
				netWorthRows = append(netWorthRows, row)
			}
		}
		monthEndRows = MonthEndNetWorth(netWorthRows)
		windows = NetWorthChangeWindows(allRows)
		creditCards = CreditCards(snapshot.Transactions, snapshot.Balances, snapshot.Accounts, start, end)
	} else {
		for day, value := range summary.Days {
			value["income"] = 0
			summary.Days[day] = value
		}
		summary.Income, summary.Net = 0, 0
	}
	c.JSON(http.StatusOK, gin.H{"start": start, "end": end, "summary": summary, "balances": statusMap(unlocked, snapshot.Balances), "netWorthHistory": netWorthRows, "monthEndNetWorth": monthEndRows, "netWorthWindows": windows, "creditCards": creditCards, "sensitiveUnlocked": unlocked})
}

func (s *Server) transactions(c *gin.Context) {
	snapshot, ok := s.snapshot(c, false)
	if !ok {
		return
	}
	start, end := parseTimeParams(c)
	unlocked := isSensitiveUnlocked(c)
	txns := append([]Transaction(nil), snapshot.Transactions...)
	sort.Slice(txns, func(i, j int) bool { return txns[i].Date > txns[j].Date })
	filtered := []Transaction{}
	for _, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		if !unlocked {
			hasIncome := false
			for _, posting := range txn.Postings {
				if strings.HasPrefix(posting.Account, "Income:") {
					hasIncome = true
				}
			}
			if hasIncome {
				continue
			}
		}
		filtered = append(filtered, txn)
	}
	c.JSON(http.StatusOK, gin.H{"start": start, "end": end, "transactions": filtered, "sensitiveUnlocked": unlocked})
}

func (s *Server) balances(c *gin.Context) {
	snapshot, ok := s.snapshot(c, true)
	if !ok {
		return
	}
	c.JSON(http.StatusOK, gin.H{"balances": snapshot.Balances, "assertions": snapshot.BalanceAssertions})
}

func (s *Server) budget(c *gin.Context) {
	snapshot, ok := s.snapshot(c, false)
	if !ok {
		return
	}
	start, end := parseTimeParams(c)
	latest := map[string]Budget{}
	for _, budget := range snapshot.Budgets {
		if budget.Date <= end {
			if cur, ok := latest[budget.Account]; !ok || budget.Date >= cur.Date {
				latest[budget.Account] = budget
			}
		}
	}
	actual := MonthSummary(start, end, snapshot.Transactions).Categories
	accounts := map[string]bool{}
	for account := range latest {
		accounts[account] = true
	}
	for account := range actual {
		accounts[account] = true
	}
	keys := []string{}
	for account := range accounts {
		keys = append(keys, account)
	}
	sort.Strings(keys)
	rows := []gin.H{}
	accountMap := accountByName(snapshot.Accounts)
	for _, account := range keys {
		label, alias := accountLabelAlias(account, accountMap)
		budget := latest[account].Amount
		spent := actual[account]
		var ratio *float64
		if budget != 0 {
			value := float64(spent) / float64(budget)
			ratio = &value
		}
		rows = append(rows, gin.H{"account": account, "alias": alias, "label": label, "budget": budget, "spent": spent, "remaining": budget - spent, "ratio": ratio})
	}
	c.JSON(http.StatusOK, gin.H{"start": start, "end": end, "rows": rows})
}

func (s *Server) incomeStatement(c *gin.Context) {
	snapshot, ok := s.snapshot(c, false)
	if !ok {
		return
	}
	start, end := parseTimeParams(c)
	unlocked := isSensitiveUnlocked(c)
	expense, topPayees, topAccounts := ExpenseAnalytics(snapshot.Transactions, start, end, snapshot.Accounts)
	allIncomeNodes, expenseNodes, totalIncome, totalExpense, netIncome := IncomeStatementTree(start, end, snapshot.Transactions)
	allIncomeNodes = ApplyIncomeStatementAccountLabels(allIncomeNodes, snapshot.Accounts)
	expenseNodes = ApplyIncomeStatementAccountLabels(expenseNodes, snapshot.Accounts)
	incomeNodes := []IncomeStatementNode{}
	if unlocked {
		incomeNodes = allIncomeNodes
	}
	c.JSON(http.StatusOK, gin.H{"start": start, "end": end, "income": incomeNodes, "expense": expenseNodes, "totalIncome": statusInt(unlocked, totalIncome), "totalExpense": totalExpense, "expenseAnalytics": expense, "topPayees": topPayees, "topPaymentAccounts": topAccounts, "netIncome": statusInt(unlocked, netIncome), "sensitiveUnlocked": unlocked})
}

func (s *Server) dashboard(c *gin.Context) {
	snapshot, ok := s.snapshot(c, true)
	if !ok {
		return
	}
	start, end := parseTimeParams(c)
	c.JSON(http.StatusOK, BuildDashboardSummaryWithFilters(snapshot, start, end, parseDashboardFilters(c)))
}

func parseDashboardFilters(c *gin.Context) DashboardFilters {
	filters := DashboardFilters{
		Categories: splitDashboardFilterValues(c.Query("category")),
		Accounts:   splitDashboardFilterValues(c.Query("account")),
		Payees:     splitDashboardFilterValues(c.Query("payee")),
		Tags:       splitDashboardFilterValues(c.Query("tag")),
		Types:      splitDashboardFilterValues(c.Query("type")),
	}
	if raw := strings.TrimSpace(c.Query("minAmount")); raw != "" {
		value := cents(raw)
		filters.MinAmount = &value
	}
	if raw := strings.TrimSpace(c.Query("maxAmount")); raw != "" {
		value := cents(raw)
		filters.MaxAmount = &value
	}
	return filters
}

func splitDashboardFilterValues(raw string) []string {
	values := []string{}
	for _, value := range strings.Split(raw, ",") {
		trimmed := strings.TrimSpace(value)
		if trimmed != "" {
			values = append(values, trimmed)
		}
	}
	return values
}

func (s *Server) accounts(c *gin.Context) {
	snapshot, ok := s.snapshot(c, false)
	if ok {
		c.JSON(http.StatusOK, gin.H{"accounts": snapshot.Accounts})
	}
}

func (s *Server) appendAccount(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input AccountInput
	if !bindJSON(c, &input) {
		return
	}
	if input.Currency == "" {
		input.Currency = "CNY"
	}
	if err := s.writer.AppendAccount(input); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "account": input})
}

func (s *Server) applyAccountOperations(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input AccountOperationsRequest
	if !bindJSON(c, &input) {
		return
	}
	texts, err := s.writer.ApplyAccountOperations(input.Operations)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "count": len(input.Operations), "beanTexts": texts})
}

func (s *Server) accountDetail(c *gin.Context) {
	snapshot, ok := s.snapshot(c, true)
	if !ok {
		return
	}
	account := c.Query("account")
	if account == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "account is required"})
		return
	}
	var acct *Account
	for i := range snapshot.Accounts {
		if snapshot.Accounts[i].Account == account {
			acct = &snapshot.Accounts[i]
		}
	}
	if acct == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "account not found"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"account":        acct.Account,
		"label":          acct.Label,
		"alias":          acct.Alias,
		"group":          acct.Group,
		"active":         acct.Active,
		"currency":       acct.Currency,
		"rows":           AccountDetail(account, snapshot.Transactions),
		"currentBalance": snapshot.Balances[account],
	})
}

func (s *Server) accountStatus(c *gin.Context) {
	snapshot, ok := s.snapshot(c, true)
	if ok {
		c.JSON(http.StatusOK, gin.H{"statuses": AccountStatusIndicators(snapshot.Transactions, snapshot.BalanceAssertions, snapshot.Accounts)})
	}
}

func (s *Server) reconciliation(c *gin.Context) {
	snapshot, ok := s.snapshot(c, true)
	if !ok {
		return
	}
	start, end := parseTimeParams(c)
	rows := []gin.H{}
	for _, account := range snapshot.Accounts {
		if !account.Active || !(strings.HasPrefix(account.Account, "Assets:") || strings.HasPrefix(account.Account, "Liabilities:")) {
			continue
		}
		status := "pending"
		var last *BalanceAssertion
		for i := range snapshot.BalanceAssertions {
			assertion := snapshot.BalanceAssertions[i]
			if assertion.Account != account.Account {
				continue
			}
			if last == nil || assertion.Date > last.Date {
				last = &assertion
			}
			if assertion.Date >= start && assertion.Date < end {
				status = "asserted"
			}
		}
		rows = append(rows, gin.H{"account": account.Account, "alias": account.Alias, "label": account.Label, "ledgerBalance": snapshot.Balances[account.Account], "status": status, "lastAssertion": last})
	}
	c.JSON(http.StatusOK, gin.H{"start": start, "end": end, "monthPrefix": start[:7], "rows": rows})
}

func (s *Server) appendEntry(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var entry LedgerEntry
	if !bindJSON(c, &entry) {
		return
	}
	texts, err := s.writer.AppendEntries([]LedgerEntry{entry})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "beanText": texts[0]})
}

func (s *Server) appendBatch(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input AppendBatchRequest
	if !bindJSON(c, &input) {
		return
	}
	texts, err := s.writer.AppendEntries(input.Entries)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "count": len(input.Entries), "beanTexts": texts})
}

func (s *Server) reverseTransaction(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input ReverseTransactionRequest
	if !bindJSON(c, &input) {
		return
	}
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	var original *Transaction
	for i := range snapshot.Transactions {
		txn := snapshot.Transactions[i]
		if txn.Source.File == input.Source.File && (txn.Source.Line == input.Source.Line || (input.Source.Hash != "" && txn.Source.Hash == input.Source.Hash)) {
			original = &txn
			break
		}
	}
	if original == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "找不到原交易，账本可能已被修改，请刷新后重试"})
		return
	}
	reverseDate := input.Date
	if reverseDate == "" {
		reverseDate = time.Now().Format("2006-01-02")
	}
	entry := LedgerEntry{Kind: "transaction", Date: reverseDate, Payee: original.Payee, Narration: "冲销：" + original.Narration, Metadata: map[string]MetadataValue{"reversal": true}, Tags: original.Tags, Currency: "CNY", Confidence: 1, NeedsReview: false}
	for _, posting := range original.Postings {
		entry.Postings = append(entry.Postings, EntryPosting{Account: posting.Account, Amount: fromCents(-posting.Amount), Currency: posting.Currency})
	}
	if err := s.writer.AppendBeanText(reverseDate, TransactionToBean(entry)); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "entry": entry})
}

func (s *Server) updateTransaction(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input UpdateTransactionRequest
	if !bindJSON(c, &input) {
		return
	}
	if err := s.writer.ReplaceTransactionBlock(input.Source, input.Entry); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) deleteTransaction(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input DeleteTransactionRequest
	if !bindJSON(c, &input) {
		return
	}
	if err := s.writer.CommentTransactionBlock(input.Source, input.Reason); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) reconcile(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	var input ReconcileRequest
	if !bindJSON(c, &input) {
		return
	}
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	var accountInfo *Account
	for i := range snapshot.Accounts {
		acct := &snapshot.Accounts[i]
		if acct.Active && (strings.HasPrefix(acct.Account, "Assets:") || strings.HasPrefix(acct.Account, "Liabilities:")) && acct.Account == input.Account {
			accountInfo = acct
			break
		}
	}
	if accountInfo == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不支持的对账账户"})
		return
	}
	ledgerBalance := balanceBefore(input.Account, snapshot.Transactions, input.BalanceDate)
	actual := cents(input.ActualAmount)
	diff := actual - ledgerBalance
	adjustmentDate := input.AdjustmentDate
	if adjustmentDate == "" {
		adjustmentDate = input.BalanceDate
	}
	beanText := ""
	var adjustment *LedgerEntry
	if diff != 0 {
		other := "Equity:Balance-Adjustments"
		if accountInfo.Group == "wealth" && diff > 0 {
			other = "Income:Other"
		} else if accountInfo.Group == "wealth" && diff < 0 {
			other = "Expenses:Unknown"
		}
		entry := LedgerEntry{Kind: "transaction", Date: adjustmentDate, Payee: accountInfo.Label, Narration: "余额差额调整", Metadata: map[string]MetadataValue{"purpose": "reconciliation"}, Tags: []string{}, Currency: "CNY", Confidence: 1, NeedsReview: false, Postings: []EntryPosting{{Account: input.Account, Amount: fromCents(diff), Currency: "CNY"}, {Account: other, Amount: fromCents(-diff), Currency: "CNY"}}}
		adjustment = &entry
		beanText += TransactionToBean(entry) + "\n"
	}
	balance := LedgerEntry{Kind: "balance", Date: input.BalanceDate, Account: input.Account, Amount: fromCents(actual), Currency: "CNY"}
	beanText += BalanceToBean(balance)
	if err := s.writer.AppendBeanText(input.BalanceDate, beanText); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "ledgerBalance": ledgerBalance, "actual": actual, "diff": diff, "adjustment": adjustment, "balance": balance, "beanText": beanText})
}

func (s *Server) staticFallback(c *gin.Context) {
	path := c.Request.URL.Path
	if strings.HasPrefix(path, "/api/") {
		c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
		return
	}
	if path == "/" || !strings.Contains(filepath.Base(path), ".") {
		c.File(filepath.Join(s.cfg.StaticDir, "index.html"))
		return
	}
	c.File(filepath.Join(s.cfg.StaticDir, filepath.Clean(path)))
}

func parseTimeParams(c *gin.Context) (string, string) {
	start, end := c.Query("start"), c.Query("end")
	month := c.Query("month")
	if (start == "" || end == "") && month != "" {
		if start == "" {
			start = month + "-01"
		}
		if end == "" {
			end = monthEnd(month)
		}
	}
	if start == "" {
		now := time.Now()
		start = now.Format("2006-01") + "-01"
	}
	if end == "" {
		end = monthEnd(start[:7])
	}
	return start, end
}

func monthEnd(month string) string {
	t, _ := time.Parse("2006-01-02", month+"-01")
	return t.AddDate(0, 1, 0).Format("2006-01-02")
}

func truthyFormValue(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func statusMap(ok bool, value map[string]int) map[string]int {
	if ok {
		return value
	}
	return map[string]int{}
}
func statusInt(ok bool, value int) int {
	if ok {
		return value
	}
	return 0
}
func status(ok bool, yes, no int) int {
	if ok {
		return yes
	}
	return no
}
