package app

import (
	"errors"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type Server struct {
	cfg     Config
	cache   *LedgerCache
	writer  *LedgerWriter
	limiter *RateLimiter
}

func NewRouter(cfg Config) *gin.Engine {
	cache := NewLedgerCache(cfg)
	server := &Server{cfg: cfg, cache: cache, writer: NewLedgerWriter(cfg, cache), limiter: NewRateLimiter()}
	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery())
	server.registerAPI(router.Group("/api"))
	router.NoRoute(server.staticFallback)
	return router
}

func (s *Server) registerAPI(api *gin.RouterGroup) {
	api.GET("/health", s.health)
	api.POST("/auth/login", s.login)
	api.POST("/auth/lock", s.lockSensitive)
	api.POST("/auth/logout", s.logout)
	api.GET("/auth/me", s.me)
	api.GET("/passkey/status", s.passkeyStatus)
	api.POST("/passkey/login/options", s.passkeyLoginOptions)
	api.POST("/passkey/login/verify", s.passkeyLoginVerify)
	api.POST("/passkey/register/options", s.passkeyRegisterOptions)
	api.POST("/passkey/register/verify", s.passkeyRegisterVerify)

	ledger := api.Group("/ledger")
	ledger.GET("/version", s.ledgerVersion)
	ledger.GET("/summary", s.summary)
	ledger.GET("/transactions", s.transactions)
	ledger.POST("/transactions", s.reverseTransaction)
	ledger.PUT("/transactions", s.updateTransaction)
	ledger.DELETE("/transactions", s.deleteTransaction)
	ledger.GET("/balances", s.balances)
	ledger.GET("/budget", s.budget)
	ledger.GET("/income-statement", s.incomeStatement)
	ledger.GET("/accounts", s.accounts)
	ledger.POST("/accounts", s.appendAccount)
	ledger.GET("/accounts/detail", s.accountDetail)
	ledger.GET("/account-status", s.accountStatus)
	ledger.GET("/reconciliation", s.reconciliation)
	ledger.POST("/reconciliation", s.reconcile)
	ledger.POST("/append", s.appendEntry)
	ledger.POST("/append-batch", s.appendBatch)
	ledger.GET("/insights", s.insights)
	ledger.GET("/notifications", s.notifications)
	ledger.PATCH("/notifications", s.updateNotifications)
	ledger.POST("/imports/preview", s.importsPreview)
	ledger.POST("/imports/commit", s.importsCommit)

	api.POST("/ai/parse", s.aiParse)
	api.POST("/ai/chat", s.aiChat)
	api.GET("/git/status", s.gitStatus)
	api.POST("/git/pull", s.gitPull)
	api.POST("/git/commit", s.gitCommit)
	api.GET("/push/subscription", s.pushStatus)
	api.POST("/push/subscription", s.pushSave)
	api.DELETE("/push/subscription", s.pushDelete)
	api.PUT("/push/subscription", s.pushTest)
	api.POST("/push/notify", s.pushNotify)
}

func (s *Server) health(c *gin.Context) {
	_, ledgerErr := os.Stat(s.cfg.LedgerRoot)
	_, mainErr := os.Stat(mainBeanPath(s.cfg))
	_, runtimeErr := os.Stat(s.cfg.RuntimeDir)
	ok := ledgerErr == nil && mainErr == nil
	c.JSON(status(ok, http.StatusOK, http.StatusServiceUnavailable), gin.H{
		"ok": ok, "uptimeSeconds": int(time.Since(startedAt).Seconds()),
		"ledgerRootExists": ledgerErr == nil, "mainBeanExists": mainErr == nil, "runtimeDirExists": runtimeErr == nil,
	})
}

var startedAt = time.Now()

func (s *Server) login(c *gin.Context) {
	if !s.limiter.Check(c, "auth.login", 10, time.Minute) {
		return
	}
	if authDisabled() {
		c.JSON(http.StatusOK, gin.H{"ok": true})
		return
	}
	var input struct {
		Password string `json:"password"`
	}
	if !bindJSON(c, &input) {
		return
	}
	ok, err := verifyPassword(input.Password)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid password"})
		return
	}
	token, err := createSessionToken()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	setSessionCookie(c, token)
	setSensitiveCookie(c)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) logout(c *gin.Context) {
	clearAuthCookies(c)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) lockSensitive(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	clearSensitiveCookie(c)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) me(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"authenticated": isAuthenticated(c), "sensitiveUnlocked": isSensitiveUnlocked(c), "authDisabled": authDisabled()})
}

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
	for _, account := range keys {
		budget := latest[account].Amount
		spent := actual[account]
		var ratio *float64
		if budget != 0 {
			value := float64(spent) / float64(budget)
			ratio = &value
		}
		rows = append(rows, gin.H{"account": account, "budget": budget, "spent": spent, "remaining": budget - spent, "ratio": ratio})
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
	expense, topPayees, topAccounts := ExpenseAnalytics(snapshot.Transactions, start, end)
	allIncomeNodes, expenseNodes, totalIncome, totalExpense, netIncome := IncomeStatementTree(start, end, snapshot.Transactions)
	incomeNodes := []IncomeStatementNode{}
	if unlocked {
		incomeNodes = allIncomeNodes
	}
	c.JSON(http.StatusOK, gin.H{"start": start, "end": end, "income": incomeNodes, "expense": expenseNodes, "totalIncome": statusInt(unlocked, totalIncome), "totalExpense": totalExpense, "expenseAnalytics": expense, "topPayees": topPayees, "topPaymentAccounts": topAccounts, "netIncome": statusInt(unlocked, netIncome), "sensitiveUnlocked": unlocked})
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
		rows = append(rows, gin.H{"account": account.Account, "label": account.Label, "ledgerBalance": snapshot.Balances[account.Account], "status": status, "lastAssertion": last})
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
	var input struct {
		Entries []LedgerEntry `json:"entries"`
	}
	if !bindJSON(c, &input) {
		return
	}
	if len(input.Entries) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "entries is required"})
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
	var input struct {
		Source TransactionSource `json:"source"`
		Date   string            `json:"date"`
	}
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
	var input struct {
		Source TransactionSource `json:"source"`
		Entry  LedgerEntry       `json:"entry"`
	}
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
	var input struct {
		Source TransactionSource `json:"source"`
		Reason string            `json:"reason"`
	}
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
	var input struct {
		Account        string `json:"account"`
		ActualAmount   string `json:"actualAmount"`
		BalanceDate    string `json:"balanceDate"`
		AdjustmentDate string `json:"adjustmentDate"`
	}
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

func (s *Server) gitStatus(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	output, _ := exec.Command("git", "-C", s.cfg.LedgerRoot, "status", "--short").Output()
	c.JSON(http.StatusOK, gin.H{"status": string(output), "dirty": strings.TrimSpace(string(output)) != "", "changedFileCount": changedFileCount(string(output)), "changes": []gin.H{}})
}

func (s *Server) gitPull(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	out, err := exec.Command("git", "-C", s.cfg.LedgerRoot, "pull", "--rebase").CombinedOutput()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, errors.New(strings.TrimSpace(string(out))))
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "output": string(out)})
}

func (s *Server) gitCommit(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input struct {
		Message string `json:"message"`
	}
	_ = c.ShouldBindJSON(&input)
	if strings.TrimSpace(input.Message) == "" {
		input.Message = "chore: update ledger"
	}
	before, _ := exec.Command("git", "-C", s.cfg.LedgerRoot, "status", "--short").Output()
	if strings.TrimSpace(string(before)) == "" {
		c.JSON(http.StatusOK, gin.H{"ok": true, "changedFileCount": 0, "output": "No ledger changes to commit."})
		return
	}
	if out, err := exec.Command("git", "-C", s.cfg.LedgerRoot, "add", "-A").CombinedOutput(); err != nil {
		errorJSON(c, http.StatusBadRequest, errors.New(strings.TrimSpace(string(out))))
		return
	}
	if out, err := exec.Command("git", "-C", s.cfg.LedgerRoot, "commit", "-m", input.Message).CombinedOutput(); err != nil {
		errorJSON(c, http.StatusBadRequest, errors.New(strings.TrimSpace(string(out))))
		return
	}
	pullOut, pullErr := exec.Command("git", "-C", s.cfg.LedgerRoot, "pull", "--rebase", "--autostash").CombinedOutput()
	pushOut, pushErr := exec.Command("git", "-C", s.cfg.LedgerRoot, "push").CombinedOutput()
	output := string(pullOut) + string(pushOut)
	if pullErr != nil || pushErr != nil {
		errorJSON(c, http.StatusBadRequest, errors.New(strings.TrimSpace(output)))
		return
	}
	after, _ := exec.Command("git", "-C", s.cfg.LedgerRoot, "status", "--short").Output()
	c.JSON(http.StatusOK, gin.H{"ok": true, "changedFileCount": changedFileCount(string(before)), "remainingChangedFileCount": changedFileCount(string(after)), "output": output})
}

func (s *Server) aiParse(c *gin.Context) {
	if !s.limiter.Check(c, "ai.parse", 20, 5*time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input struct {
		Input string `json:"input"`
	}
	if !bindJSON(c, &input) {
		return
	}
	if strings.TrimSpace(input.Input) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "input is required"})
		return
	}
	start := time.Now()
	entries, err := s.parseNaturalLanguage(input.Input, time.Now().Format("2006-01-02"))
	logDuration("ai.parse", start, map[string]any{"entries": len(entries)})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	var first any
	if len(entries) > 0 {
		first = entries[0]
	}
	c.JSON(http.StatusOK, gin.H{"entries": entries, "entry": first})
}

func (s *Server) aiChat(c *gin.Context) {
	if !s.limiter.Check(c, "ai.chat", 20, 5*time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input struct {
		Message      string        `json:"message"`
		Messages     []ChatMessage `json:"messages"`
		DraftEntries []LedgerEntry `json:"draftEntries"`
	}
	if !bindJSON(c, &input) {
		return
	}
	if strings.TrimSpace(input.Message) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid chat request"})
		return
	}
	start := time.Now()
	result, err := s.chatBookkeeping(input.Message, input.Messages, input.DraftEntries, time.Now().Format("2006-01-02"))
	elapsed := time.Since(start).Milliseconds()
	logDuration("ai.chat", start, map[string]any{"entries": len(result.Entries)})
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error(), "meta": gin.H{"elapsedMs": elapsed}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": result.Message, "entries": result.Entries, "meta": gin.H{"elapsedMs": elapsed}})
}
func (s *Server) importsPreview(c *gin.Context) {
	if !s.limiter.Check(c, "imports.preview", 10, time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	file, header, err := c.Request.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "file is required"})
		return
	}
	_ = file.Close()
	result, err := s.createImportPreview(c.Request.FormValue("provider"), truthyFormValue(c.Request.FormValue("alipayFundRounding")), header)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, result)
}

func (s *Server) importsCommit(c *gin.Context) {
	if !s.limiter.Check(c, "imports.commit", 10, time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input struct {
		ImportID string        `json:"importId"`
		Provider string        `json:"provider"`
		Entries  []ImportEntry `json:"entries"`
	}
	if !bindJSON(c, &input) {
		return
	}
	result, err := s.commitImport(input.ImportID, input.Provider, input.Entries)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, result)
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
func changedFileCount(status string) int {
	n := 0
	for _, line := range strings.Split(strings.TrimSpace(status), "\n") {
		if strings.TrimSpace(line) != "" {
			n++
		}
	}
	return n
}
