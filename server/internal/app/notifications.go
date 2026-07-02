package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

type Insight struct {
	ID       string `json:"id"`
	Severity string `json:"severity"`
	Title    string `json:"title"`
	Detail   string `json:"detail"`
	Amount   *int   `json:"amount,omitempty"`
	Account  string `json:"account,omitempty"`
	Date     string `json:"date,omitempty"`
}

type StoredNotification struct {
	ID          string  `json:"id"`
	InsightID   string  `json:"insightId"`
	Month       string  `json:"month"`
	Severity    string  `json:"severity"`
	Title       string  `json:"title"`
	Detail      string  `json:"detail"`
	DetailHash  string  `json:"detailHash"`
	Amount      *int    `json:"amount,omitempty"`
	Account     string  `json:"account,omitempty"`
	Date        string  `json:"date,omitempty"`
	Status      string  `json:"status"`
	CreatedAt   string  `json:"createdAt"`
	ReadAt      *string `json:"readAt"`
	DismissedAt *string `json:"dismissedAt"`
	ResolvedAt  *string `json:"resolvedAt"`
	UpdatedAt   string  `json:"updatedAt"`
}

type notificationStore struct {
	Version       int                  `json:"version"`
	Notifications []StoredNotification `json:"notifications"`
}

var notificationMu sync.Mutex

func (s *Server) insights(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	month := c.DefaultQuery("month", time.Now().Format("2006-01"))
	c.JSON(http.StatusOK, gin.H{"month": month, "insights": s.detectInsights(month, snapshot)})
}

func (s *Server) notifications(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	start, end := parseTimeParams(c)
	all := []StoredNotification{}
	for _, month := range monthsInRange(start, end) {
		notifications, err := s.mergeInsightsIntoNotifications(month, s.detectInsights(month, snapshot))
		if err != nil {
			errorJSON(c, http.StatusBadRequest, err)
			return
		}
		all = append(all, notifications...)
	}
	c.JSON(http.StatusOK, gin.H{"start": start, "end": end, "notifications": all})
}

func (s *Server) updateNotifications(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input struct {
		IDs    []string `json:"ids"`
		Status string   `json:"status"`
	}
	if !bindJSON(c, &input) {
		return
	}
	if len(input.IDs) == 0 || !validNotificationStatus(input.Status) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid notification update"})
		return
	}
	notifications, err := s.updateNotificationStatus(input.IDs, input.Status)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	s.publishNotificationUpdate("status", s.unreadNotificationCount(), 0)
	c.JSON(http.StatusOK, gin.H{"ok": true, "notifications": notifications})
}

func (s *Server) detectInsights(month string, snapshot *LedgerSnapshot) []Insight {
	start, end := month+"-01", monthEnd(month)
	current := []Transaction{}
	for _, txn := range snapshot.Transactions {
		if txn.Date >= start && txn.Date < end {
			current = append(current, txn)
		}
	}
	insights := []Insight{}
	for _, txn := range current {
		expense := txnExpense(txn, "Expenses:", snapshot.Prices)
		if expense >= 30000 {
			severity := "warning"
			if expense >= 100000 {
				severity = "critical"
			}
			amount := expense
			insights = append(insights, Insight{ID: "large-" + s.sourceID(txn.Source), Severity: severity, Title: "大额支出", Detail: txn.Date + " " + txn.Payee + " " + txn.Narration + "：" + formatCNY(expense) + "，超过 300 元阈值。", Amount: &amount, Date: txn.Date})
		}
	}

	currentExpense := MonthSummary(start, end, snapshot.Transactions, snapshot.Prices).Expense
	previous := []int{}
	for _, offset := range []int{-1, -2, -3} {
		expense := MonthSummary(prevMonth(month, offset)+"-01", monthEnd(prevMonth(month, offset)), snapshot.Transactions, snapshot.Prices).Expense
		if expense > 0 {
			previous = append(previous, expense)
		}
	}
	if len(previous) > 0 {
		total := 0
		for _, amount := range previous {
			total += amount
		}
		avg := float64(total) / float64(len(previous))
		if float64(currentExpense) > avg {
			severity := "info"
			if float64(currentExpense) >= avg*1.2 {
				severity = "warning"
			}
			amount := currentExpense
			insights = append(insights, Insight{ID: "expense-average", Severity: severity, Title: "本月支出高于过去 3 月均值", Detail: "本月 " + formatCNY(currentExpense) + "，过去 " + formatInt(len(previous)) + " 个月平均 " + formatCNY(int(avg)) + "。", Amount: &amount})
		}
	}

	pastPayeeCounts := map[string]int{}
	for _, txn := range snapshot.Transactions {
		if txn.Date < start {
			pastPayeeCounts[txn.Payee]++
		}
	}
	for _, txn := range current {
		expense := txnExpense(txn, "Expenses:", snapshot.Prices)
		if expense >= 10000 && pastPayeeCounts[txn.Payee] <= 1 {
			amount := expense
			insights = append(insights, Insight{ID: "rare-" + s.sourceID(txn.Source), Severity: "info", Title: "不常见商户", Detail: txn.Payee + " 过去很少出现，本次支出 " + formatCNY(expense) + "。", Amount: &amount, Date: txn.Date})
		}
	}

	unknownCount, unknownAmount := 0, 0
	for _, txn := range current {
		for _, posting := range txn.Postings {
			if posting.Account == "Expenses:Unknown" {
				unknownCount++
				unknownAmount += postingValuationInCNY(posting, snapshot.Prices, txn.Date)
			}
		}
	}
	if unknownCount >= 3 || (currentExpense > 0 && float64(unknownAmount)/float64(currentExpense) >= 0.1) {
		amount := unknownAmount
		insights = append(insights, Insight{ID: "unknown-expenses", Severity: "warning", Title: "未分类支出偏多", Detail: "Expenses:Unknown 有 " + formatInt(unknownCount) + " 笔，共 " + formatCNY(unknownAmount) + "，建议补分类。", Amount: &amount, Account: "Expenses:Unknown"})
	}

	sort.Slice(insights, func(i, j int) bool {
		if severityRank(insights[i].Severity) != severityRank(insights[j].Severity) {
			return severityRank(insights[i].Severity) < severityRank(insights[j].Severity)
		}
		return derefInt(insights[i].Amount) > derefInt(insights[j].Amount)
	})
	return insights
}

func (s *Server) mergeInsightsIntoNotifications(month string, insights []Insight) ([]StoredNotification, error) {
	notificationMu.Lock()
	defer notificationMu.Unlock()
	store := s.readNotificationStore()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	currentIDs := map[string]bool{}
	created := []StoredNotification{}
	for _, insight := range insights {
		id := notificationID(month, insight)
		currentIDs[id] = true
		detailHash := notificationDetailHash(insight)
		found := -1
		for i := range store.Notifications {
			if store.Notifications[i].ID == id {
				found = i
				break
			}
		}
		if found == -1 {
			notification := StoredNotification{ID: id, InsightID: insight.ID, Month: month, Severity: insight.Severity, Title: insight.Title, Detail: insight.Detail, DetailHash: detailHash, Amount: insight.Amount, Account: insight.Account, Date: insight.Date, Status: "unread", CreatedAt: now, UpdatedAt: now}
			store.Notifications = append(store.Notifications, notification)
			created = append(created, notification)
			continue
		}
		existing := &store.Notifications[found]
		if existing.DetailHash != detailHash || existing.Severity != insight.Severity || existing.Title != insight.Title {
			existing.Severity = insight.Severity
			existing.Title = insight.Title
			existing.Detail = insight.Detail
			existing.DetailHash = detailHash
			existing.Amount = insight.Amount
			existing.Account = insight.Account
			existing.Date = insight.Date
			existing.UpdatedAt = now
			if existing.Status == "resolved" {
				existing.Status = "unread"
				existing.ResolvedAt = nil
				existing.ReadAt = nil
			}
		}
	}
	for i := range store.Notifications {
		notification := &store.Notifications[i]
		if notification.Month == month && !currentIDs[notification.ID] && notification.Status != "resolved" {
			notification.Status = "resolved"
			notification.ResolvedAt = &now
			notification.UpdatedAt = now
		}
	}
	if err := s.writeNotificationStore(store); err != nil {
		return nil, err
	}
	if len(created) > 0 {
		sort.Slice(created, func(i, j int) bool { return severityRank(created[i].Severity) < severityRank(created[j].Severity) })
		title := created[0].Title
		if len(created) > 1 {
			title = "我的账本：" + formatInt(len(created)) + " 条新提醒"
		}
		_, _ = s.sendWebPushToAll(map[string]string{"title": title, "body": created[0].Detail, "url": "/", "tag": "ledger-notifications-" + month})
	}
	s.publishNotificationUpdate("insights", countUnreadNotifications(store.Notifications), len(created))
	return s.notificationsForMonth(store.Notifications, month), nil
}

func (s *Server) updateNotificationStatus(ids []string, status string) ([]StoredNotification, error) {
	notificationMu.Lock()
	defer notificationMu.Unlock()
	store := s.readNotificationStore()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	idSet := map[string]bool{}
	for _, id := range ids {
		idSet[id] = true
	}
	updated := []StoredNotification{}
	for i := range store.Notifications {
		notification := &store.Notifications[i]
		if !idSet[notification.ID] {
			continue
		}
		notification.Status = status
		notification.UpdatedAt = now
		switch status {
		case "read":
			notification.ReadAt = &now
		case "unread":
			notification.ReadAt = nil
			notification.DismissedAt = nil
			notification.ResolvedAt = nil
		case "dismissed":
			notification.DismissedAt = &now
		case "resolved":
			notification.ResolvedAt = &now
		}
		updated = append(updated, *notification)
	}
	return updated, s.writeNotificationStore(store)
}

func (s *Server) publishNotificationUpdate(source string, unreadCount int, createdCount int) {
	s.events.Publish("notifications.updated", gin.H{"source": source, "unreadCount": unreadCount, "createdCount": createdCount})
}

func countUnreadNotifications(notifications []StoredNotification) int {
	count := 0
	for _, notification := range notifications {
		if notification.Status == "unread" {
			count++
		}
	}
	return count
}

func (s *Server) unreadNotificationCount() int {
	notificationMu.Lock()
	defer notificationMu.Unlock()
	return countUnreadNotifications(s.readNotificationStore().Notifications)
}

func (s *Server) readNotificationStore() notificationStore {
	var store notificationStore
	ok, err := s.runtimeStore.GetJSON(context.Background(), "notifications", "store", &store)
	if err != nil || !ok {
		return notificationStore{Version: 1, Notifications: []StoredNotification{}}
	}
	if store.Version == 0 {
		store.Version = 1
	}
	if store.Notifications == nil {
		store.Notifications = []StoredNotification{}
	}
	return store
}

func (s *Server) writeNotificationStore(store notificationStore) error {
	return s.runtimeStore.PutJSON(context.Background(), "notifications", "store", store)
}

func (s *Server) notificationsForMonth(notifications []StoredNotification, month string) []StoredNotification {
	rows := []StoredNotification{}
	for _, notification := range notifications {
		if notification.Month == month {
			rows = append(rows, notification)
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if statusRank(rows[i].Status) != statusRank(rows[j].Status) {
			return statusRank(rows[i].Status) < statusRank(rows[j].Status)
		}
		if severityRank(rows[i].Severity) != severityRank(rows[j].Severity) {
			return severityRank(rows[i].Severity) < severityRank(rows[j].Severity)
		}
		return rows[i].UpdatedAt > rows[j].UpdatedAt
	})
	return rows
}

func notificationID(month string, insight Insight) string {
	return month + ":" + insight.ID
}

func notificationDetailHash(insight Insight) string {
	parts := []string{insight.Title, insight.Detail, "", insight.Account, insight.Date}
	if insight.Amount != nil {
		parts[2] = formatInt(*insight.Amount)
	}
	sum := sha256.Sum256([]byte(strings.Join(parts, "\n")))
	return hex.EncodeToString(sum[:])[:16]
}

func txnExpense(txn Transaction, prefix string, prices []Price) int {
	total := 0
	for _, posting := range txn.Postings {
		if strings.HasPrefix(posting.Account, prefix) {
			total += postingValuationInCNY(posting, prices, txn.Date)
		}
	}
	return total
}

func (s *Server) sourceID(source TransactionSource) string {
	if rel, err := filepath.Rel(s.cfg.LedgerRoot, source.File); err == nil {
		return rel + ":" + formatInt(source.Line)
	}
	return source.File + ":" + formatInt(source.Line)
}

func prevMonth(month string, offset int) string {
	t, err := time.Parse("2006-01-02", month+"-01")
	if err != nil {
		return month
	}
	return t.AddDate(0, offset, 0).Format("2006-01")
}

func monthsInRange(start, end string) []string {
	first, err := time.Parse("2006-01-02", start[:7]+"-01")
	if err != nil {
		return []string{}
	}
	limit, err := time.Parse("2006-01-02", end[:7]+"-01")
	if err != nil {
		return []string{}
	}
	if end > end[:7]+"-01" {
		limit = limit.AddDate(0, 1, 0)
	}
	months := []string{}
	for t := first; t.Before(limit); t = t.AddDate(0, 1, 0) {
		months = append(months, t.Format("2006-01"))
	}
	return months
}

func formatCNY(centsValue int) string {
	return "¥" + fromCents(centsValue)
}

func severityRank(severity string) int {
	switch severity {
	case "critical":
		return 0
	case "warning":
		return 1
	default:
		return 2
	}
}

func statusRank(status string) int {
	switch status {
	case "unread":
		return 0
	case "read":
		return 1
	case "dismissed":
		return 2
	default:
		return 3
	}
}

func validNotificationStatus(status string) bool {
	return status == "unread" || status == "read" || status == "dismissed" || status == "resolved"
}

func derefInt(value *int) int {
	if value == nil {
		return 0
	}
	return *value
}
