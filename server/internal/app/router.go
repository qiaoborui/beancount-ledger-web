package app

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

func (s *Server) ledgerVersion(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	version, err := s.readService.Version(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, version)
}

func (s *Server) snapshot(c *gin.Context, sensitive bool) (*LedgerSnapshot, bool) {
	return s.snapshotWithLoader(c, sensitive, s.ledgerSnapshot)
}

func (s *Server) snapshotLite(c *gin.Context, sensitive bool) (*LedgerSnapshot, bool) {
	return s.snapshotWithLoader(c, sensitive, s.ledgerSnapshotLite)
}

func (s *Server) snapshotWithLoader(c *gin.Context, sensitive bool, load func(context.Context) (*LedgerSnapshot, error)) (*LedgerSnapshot, bool) {
	if sensitive {
		if !requireSensitive(c) {
			return nil, false
		}
	} else if !requireAuth(c) {
		return nil, false
	}
	snapshot, err := load(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return nil, false
	}
	return snapshot, true
}

func (s *Server) ledgerBootstrap(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	start, end := parseTimeParams(c)
	payload, err := s.readService.Bootstrap(start, end, isSensitiveUnlocked(c), c.Query("valuationCurrency"))
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, payload)
}

func (s *Server) ledgerEntries(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	snapshot, err := s.ledgerSnapshot(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, BeanLoadResultFromEntries(snapshot.BeanEntries, snapshot.BeanErrors))
}

func (s *Server) summary(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	start, end := parseTimeParams(c)
	payload, err := s.readService.Summary(start, end, isSensitiveUnlocked(c), c.Query("valuationCurrency"))
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, payload)
}

func (s *Server) transactions(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	start, end := parseTimeParams(c)
	payload, err := s.readService.Transactions(start, end, isSensitiveUnlocked(c))
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, payload)
}

func (s *Server) balances(c *gin.Context) {
	snapshot, ok := s.snapshotLite(c, true)
	if !ok {
		return
	}
	c.JSON(http.StatusOK, gin.H{"balances": snapshot.Balances, "assertions": snapshot.BalanceAssertions})
}

func (s *Server) incomeStatement(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	start, end := parseTimeParams(c)
	payload, err := s.readService.IncomeStatement(start, end, isSensitiveUnlocked(c), c.Query("valuationCurrency"))
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, payload)
}

func (s *Server) dashboard(c *gin.Context) {
	snapshot, ok := s.snapshotLite(c, true)
	if !ok {
		return
	}
	start, end := parseTimeParams(c)
	c.JSON(http.StatusOK, BuildDashboardSummaryWithFiltersInCurrency(snapshot, start, end, parseDashboardFilters(c), c.Query("valuationCurrency")))
}

func (s *Server) investments(c *gin.Context) {
	snapshot, ok := s.snapshot(c, true)
	if !ok {
		return
	}
	c.JSON(http.StatusOK, BuildInvestmentSummaryFromBeanEntries(snapshot.BeanEntries, snapshot.Accounts, snapshot.Prices))
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
	if !requireAuth(c) {
		return
	}
	accounts, err := s.accountService.List()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"accounts": accounts})
}

func (s *Server) appendAccount(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if s.rejectWorkerOnly(c, "ledger.accounts.append") {
		return
	}
	var input AccountInput
	if !bindJSON(c, &input) {
		return
	}
	account, err := s.accountService.Append(input)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "account": account})
}

func (s *Server) applyAccountOperations(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if s.rejectWorkerOnly(c, "ledger.accounts.operations") {
		return
	}
	var input AccountOperationsRequest
	if !bindJSON(c, &input) {
		return
	}
	texts, err := s.accountService.ApplyOperations(input.Operations)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "count": len(input.Operations), "beanTexts": texts})
}

func (s *Server) accountDetail(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	detail, err := s.accountService.Detail(c.Query("account"))
	if errors.Is(err, ErrAccountRequired) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "account is required"})
		return
	}
	if errors.Is(err, ErrAccountNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"error": "account not found"})
		return
	}
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, detail)
}

func (s *Server) accountStatus(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	statuses, err := s.accountService.Statuses()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"statuses": statuses})
}

func (s *Server) reconciliation(c *gin.Context) {
	snapshot, ok := s.snapshotLite(c, true)
	if !ok {
		return
	}
	start, end := parseTimeParams(c)
	c.JSON(http.StatusOK, gin.H{"start": start, "end": end, "monthPrefix": start[:7], "rows": buildReconciliationRows(snapshot, start, end)})
}

func buildReconciliationRows(snapshot *LedgerSnapshot, start, end string) []gin.H {
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
		rows = append(rows, gin.H{"account": account.Account, "alias": account.Alias, "label": account.Label, "currency": defaultAccountCurrency(account.Account, account.Currency), "ledgerBalance": snapshot.Balances[account.Account], "status": status, "lastAssertion": last})
	}
	return rows
}

func (s *Server) appendEntry(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if s.rejectWorkerOnly(c, "ledger.append") {
		return
	}
	var entry LedgerEntry
	if !bindJSON(c, &entry) {
		return
	}
	texts, err := s.writer.AppendEntriesWithSource(ledgerWriteSourceAppendEntry, []LedgerEntry{entry})
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
	if s.rejectWorkerOnly(c, "ledger.append-batch") {
		return
	}
	var input AppendBatchRequest
	if !bindJSON(c, &input) {
		return
	}
	texts, err := s.writer.AppendEntriesWithSource(ledgerWriteSourceAppendBatch, input.Entries)
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
	if s.rejectWorkerOnly(c, "ledger.transactions.reverse") {
		return
	}
	var input ReverseTransactionRequest
	if !bindJSON(c, &input) {
		return
	}
	entry, err := s.txService.Reverse(input)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "entry": entry})
}

func (s *Server) updateTransaction(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if s.rejectWorkerOnly(c, "ledger.transactions.update") {
		return
	}
	var input UpdateTransactionRequest
	if !bindJSON(c, &input) {
		return
	}
	if err := s.txService.Update(input.Source, input.Entry); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) deleteTransaction(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if s.rejectWorkerOnly(c, "ledger.transactions.delete") {
		return
	}
	var input DeleteTransactionRequest
	if !bindJSON(c, &input) {
		return
	}
	if err := s.txService.Delete(input.Source, input.Reason); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) reconcile(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	if s.rejectWorkerOnly(c, "ledger.reconciliation.write") {
		return
	}
	var input ReconcileRequest
	if !bindJSON(c, &input) {
		return
	}
	result, err := s.reconcileService.Reconcile(input)
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
	if path == "/" {
		setStaticCacheHeaders(c, "index.html")
		c.File(filepath.Join(s.cfg.StaticDir, "index.html"))
		return
	}
	if isSensitiveStaticProbe(path) {
		c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
		return
	}
	if !strings.Contains(filepath.Base(path), ".") {
		setStaticCacheHeaders(c, "index.html")
		c.File(filepath.Join(s.cfg.StaticDir, "index.html"))
		return
	}
	cleanPath, ok := cleanStaticAssetPath(path)
	if !ok {
		c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
		return
	}
	fullPath := filepath.Join(s.cfg.StaticDir, cleanPath)
	if info, err := os.Stat(fullPath); err != nil || info.IsDir() {
		c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
		return
	}
	setStaticCacheHeaders(c, cleanPath)
	c.File(fullPath)
}

func cleanStaticAssetPath(path string) (string, bool) {
	cleanPath := filepath.Clean(strings.TrimPrefix(path, "/"))
	if cleanPath == "." || cleanPath == ".." || filepath.IsAbs(cleanPath) || strings.HasPrefix(cleanPath, ".."+string(filepath.Separator)) {
		return "", false
	}
	return cleanPath, true
}

func isSensitiveStaticProbe(path string) bool {
	cleanPath, ok := cleanStaticAssetPath(path)
	if !ok {
		return true
	}
	for _, part := range strings.Split(filepath.ToSlash(cleanPath), "/") {
		switch {
		case part == ".git", part == ".ssh", part == ".runtime", part == ".env":
			return true
		case strings.HasPrefix(part, ".env."):
			return true
		}
	}
	return false
}

func setStaticCacheHeaders(c *gin.Context, path string) {
	switch {
	case path == "index.html", strings.HasSuffix(path, "/index.html"), strings.HasSuffix(path, "sw.js"):
		c.Header("Cache-Control", "no-cache")
	case strings.HasPrefix(path, "assets/"), strings.Contains(path, "/assets/"):
		c.Header("Cache-Control", "public, max-age=31536000, immutable")
	default:
		c.Header("Cache-Control", "public, max-age=3600")
	}
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
func statusAccountBalances(ok bool, value []AccountBalance) []AccountBalance {
	if ok {
		return value
	}
	return []AccountBalance{}
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
