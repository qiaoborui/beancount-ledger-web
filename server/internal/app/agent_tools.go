package app

import (
	"crypto/subtle"
	"fmt"
	"net/http"
	"sort"
	"strings"

	"github.com/gin-gonic/gin"
)

type AgentQueryTransactionsRequest struct {
	Start         string `json:"start"`
	End           string `json:"end"`
	Account       string `json:"account,omitempty"`
	AccountPrefix string `json:"accountPrefix,omitempty"`
	Payee         string `json:"payee,omitempty"`
	Text          string `json:"text,omitempty"`
	Limit         int    `json:"limit,omitempty"`
	IncludeIncome bool   `json:"includeIncome,omitempty"`
}

type AgentSummarizeExpensesRequest struct {
	Start   string `json:"start"`
	End     string `json:"end"`
	GroupBy string `json:"groupBy,omitempty"`
	Limit   int    `json:"limit,omitempty"`
}

type AgentValidateEntriesRequest struct {
	Entries []LedgerEntry `json:"entries"`
}

type AgentExpenseSummaryRow struct {
	Key     string `json:"key"`
	Amount  int    `json:"amount"`
	TxCount int    `json:"txCount"`
}

func (r AgentQueryTransactionsRequest) Validate() error {
	if err := validateDate("start", r.Start); err != nil {
		return err
	}
	if err := validateDate("end", r.End); err != nil {
		return err
	}
	if r.End <= r.Start {
		return fmt.Errorf("end must be after start")
	}
	if r.Limit < 0 {
		return fmt.Errorf("limit must be >= 0")
	}
	if r.Limit > 200 {
		return fmt.Errorf("limit must be <= 200")
	}
	return nil
}

func (r AgentSummarizeExpensesRequest) Validate() error {
	if err := validateDate("start", r.Start); err != nil {
		return err
	}
	if err := validateDate("end", r.End); err != nil {
		return err
	}
	if r.End <= r.Start {
		return fmt.Errorf("end must be after start")
	}
	switch r.GroupBy {
	case "", "account", "date", "payee":
	default:
		return fmt.Errorf("groupBy must be account, date, or payee")
	}
	if r.Limit < 0 {
		return fmt.Errorf("limit must be >= 0")
	}
	if r.Limit > 200 {
		return fmt.Errorf("limit must be <= 200")
	}
	return nil
}

func (r *AgentValidateEntriesRequest) Validate() error {
	if len(r.Entries) == 0 {
		return fmt.Errorf("entries is required")
	}
	if len(r.Entries) > 50 {
		return fmt.Errorf("entries must contain at most 50 items")
	}
	for i, entry := range r.Entries {
		if entry.Kind == "" {
			entry.Kind = "transaction"
			r.Entries[i].Kind = "transaction"
		}
		if err := entry.Validate(); err != nil {
			return fmt.Errorf("entries[%d]: %w", i, err)
		}
	}
	return nil
}

func (s *Server) registerAgentTools(group *gin.RouterGroup) {
	group.Use(s.requireAgentToolToken)
	group.GET("/accounts", s.agentAccounts)
	group.POST("/transactions/query", s.agentQueryTransactions)
	group.POST("/expenses/summary", s.agentSummarizeExpenses)
	group.POST("/entries/validate", s.agentValidateEntries)
}

func (s *Server) requireAgentToolToken(c *gin.Context) {
	expected := strings.TrimSpace(s.cfg.AgentToolToken)
	if expected == "" {
		c.AbortWithStatusJSON(http.StatusNotFound, gin.H{"error": "agent tools are disabled"})
		return
	}
	auth := strings.TrimSpace(c.GetHeader("Authorization"))
	token := strings.TrimSpace(c.GetHeader("X-Ledger-Agent-Token"))
	if strings.HasPrefix(strings.ToLower(auth), "bearer ") {
		token = strings.TrimSpace(auth[len("Bearer "):])
	}
	if token == "" || subtle.ConstantTimeCompare([]byte(token), []byte(expected)) != 1 {
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid agent tool token"})
		return
	}
	c.Next()
}

func (s *Server) agentAccounts(c *gin.Context) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"accounts": snapshot.Accounts})
}

func (s *Server) agentQueryTransactions(c *gin.Context) {
	var input AgentQueryTransactionsRequest
	if !bindJSON(c, &input) {
		return
	}
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	txns := filterAgentTransactions(snapshot.Transactions, input)
	c.JSON(http.StatusOK, gin.H{"start": input.Start, "end": input.End, "transactions": txns, "count": len(txns)})
}

func (s *Server) agentSummarizeExpenses(c *gin.Context) {
	var input AgentSummarizeExpensesRequest
	if !bindJSON(c, &input) {
		return
	}
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	groupBy := input.GroupBy
	if groupBy == "" {
		groupBy = "account"
	}
	rows := summarizeAgentExpenses(snapshot.Transactions, input.Start, input.End, groupBy)
	total := 0
	for _, row := range rows {
		total += row.Amount
	}
	if input.Limit > 0 && len(rows) > input.Limit {
		rows = rows[:input.Limit]
	}
	c.JSON(http.StatusOK, gin.H{"start": input.Start, "end": input.End, "groupBy": groupBy, "rows": rows, "total": total})
}

func (s *Server) agentValidateEntries(c *gin.Context) {
	var input AgentValidateEntriesRequest
	if !bindJSON(c, &input) {
		return
	}
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	entries, err := validateAIEntries(input.Entries, activeAccounts(snapshot.Accounts))
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	beanText := make([]string, 0, len(entries))
	for _, entry := range entries {
		switch entry.Kind {
		case "", "transaction":
			beanText = append(beanText, TransactionToBean(entry))
		case "balance":
			beanText = append(beanText, BalanceToBean(entry))
		default:
			errorJSON(c, http.StatusBadRequest, fmt.Errorf("unsupported ledger entry kind: %s", entry.Kind))
			return
		}
	}
	c.JSON(http.StatusOK, gin.H{"entries": entries, "beanText": beanText})
}

func filterAgentTransactions(txns []Transaction, input AgentQueryTransactionsRequest) []Transaction {
	limit := input.Limit
	if limit == 0 {
		limit = 50
	}
	text := strings.ToLower(strings.TrimSpace(input.Text))
	payee := strings.ToLower(strings.TrimSpace(input.Payee))
	out := []Transaction{}
	for _, txn := range txns {
		if txn.Date < input.Start || txn.Date >= input.End {
			continue
		}
		if payee != "" && !strings.Contains(strings.ToLower(txn.Payee), payee) {
			continue
		}
		if text != "" && !transactionContainsText(txn, text) {
			continue
		}
		if input.Account != "" && !transactionHasAccount(txn, input.Account, false) {
			continue
		}
		if input.AccountPrefix != "" && !transactionHasAccount(txn, input.AccountPrefix, true) {
			continue
		}
		if !input.IncludeIncome && agentTransactionHasAccountPrefix(txn, "Income:") {
			continue
		}
		out = append(out, txn)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Date == out[j].Date {
			return out[i].Source.Line > out[j].Source.Line
		}
		return out[i].Date > out[j].Date
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

func transactionContainsText(txn Transaction, text string) bool {
	if strings.Contains(strings.ToLower(txn.Payee), text) || strings.Contains(strings.ToLower(txn.Narration), text) {
		return true
	}
	for _, tag := range txn.Tags {
		if strings.Contains(strings.ToLower(tag), text) {
			return true
		}
	}
	for key, value := range txn.Metadata {
		if strings.Contains(strings.ToLower(key), text) || strings.Contains(strings.ToLower(fmt.Sprint(value)), text) {
			return true
		}
	}
	for _, posting := range txn.Postings {
		if strings.Contains(strings.ToLower(posting.Account), text) {
			return true
		}
	}
	return false
}

func transactionHasAccount(txn Transaction, account string, prefix bool) bool {
	for _, posting := range txn.Postings {
		if posting.Account == account || (prefix && strings.HasPrefix(posting.Account, account)) {
			return true
		}
	}
	return false
}

func agentTransactionHasAccountPrefix(txn Transaction, prefix string) bool {
	for _, posting := range txn.Postings {
		if strings.HasPrefix(posting.Account, prefix) {
			return true
		}
	}
	return false
}

func summarizeAgentExpenses(txns []Transaction, start, end, groupBy string) []AgentExpenseSummaryRow {
	rows := map[string]*AgentExpenseSummaryRow{}
	seenTxn := map[string]map[string]bool{}
	for index, txn := range txns {
		if txn.Date < start || txn.Date >= end {
			continue
		}
		txnKey := txn.Source.File + ":" + formatInt(txn.Source.Line)
		if txnKey == ":0" {
			txnKey = txn.Date + ":" + formatInt(index)
		}
		for _, posting := range txn.Postings {
			if !strings.HasPrefix(posting.Account, "Expenses:") {
				continue
			}
			key := posting.Account
			if groupBy == "date" {
				key = txn.Date
			} else if groupBy == "payee" {
				key = txn.Payee
				if key == "" {
					key = "(empty payee)"
				}
			}
			row := rows[key]
			if row == nil {
				row = &AgentExpenseSummaryRow{Key: key}
				rows[key] = row
			}
			amount := posting.Amount
			if amount < 0 {
				amount = -amount
			}
			row.Amount += amount
			if seenTxn[key] == nil {
				seenTxn[key] = map[string]bool{}
			}
			if !seenTxn[key][txnKey] {
				row.TxCount++
				seenTxn[key][txnKey] = true
			}
		}
	}
	out := make([]AgentExpenseSummaryRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, *row)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Amount == out[j].Amount {
			return out[i].Key < out[j].Key
		}
		return out[i].Amount > out[j].Amount
	})
	return out
}
