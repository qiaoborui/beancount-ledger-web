package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
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

type NotificationServiceDependencies struct {
	Config       Config
	RuntimeStore RuntimeStore
	SnapshotPort LedgerSnapshotPort
}

// NotificationChannelRegistry owns the configured delivery channels.
type NotificationChannelRegistry struct {
	byID    map[string]NotificationChannel
	ordered []NotificationChannel
}

func newNotificationChannelRegistry() *NotificationChannelRegistry {
	return &NotificationChannelRegistry{byID: map[string]NotificationChannel{}}
}

func (r *NotificationChannelRegistry) Register(channel NotificationChannel) error {
	if channel == nil {
		return errors.New("notification channel is required")
	}
	id := strings.TrimSpace(channel.ID())
	if id == "" {
		return errors.New("notification channel ID is required")
	}
	if _, exists := r.byID[id]; exists {
		return errors.New("notification channel is already registered: " + id)
	}
	r.byID[id] = channel
	r.ordered = append(r.ordered, channel)
	return nil
}

func (r *NotificationChannelRegistry) Lookup(id string) (NotificationChannel, bool) {
	channel, ok := r.byID[id]
	return channel, ok
}

func (r *NotificationChannelRegistry) Publish(ctx context.Context, message NotificationMessage) (NotificationDeliveryResult, error) {
	result := NotificationDeliveryResult{}
	errs := make([]error, 0, len(r.ordered))
	for _, channel := range r.ordered {
		current, err := channel.Send(ctx, message)
		result.Attempted += current.Attempted
		result.Sent += current.Sent
		result.Failed += current.Failed
		result.Removed += current.Removed
		if err != nil {
			errs = append(errs, fmt.Errorf("send notification through %q: %w", channel.ID(), err))
		}
	}
	return result, errors.Join(errs...)
}

// NotificationService owns notification state, delivery, and optional refresh scheduling.
type NotificationService struct {
	cfg          Config
	runtimeStore RuntimeStore
	snapshotPort LedgerSnapshotPort
	channels     *NotificationChannelRegistry
	interval     time.Duration

	mu     sync.Mutex
	cancel context.CancelFunc
	done   chan struct{}
}

func newNotificationService(dependencies NotificationServiceDependencies, channels *NotificationChannelRegistry) (*NotificationService, error) {
	if dependencies.RuntimeStore == nil {
		return nil, errors.New("notification runtime store is required")
	}
	if dependencies.SnapshotPort == nil {
		return nil, errors.New("notification snapshot port is required")
	}
	interval, err := notificationRefreshInterval(dependencies.Config.NotificationRefreshInterval)
	if err != nil {
		return nil, err
	}
	if channels == nil {
		return nil, errors.New("notification channels are required")
	}
	return &NotificationService{
		cfg:          dependencies.Config,
		runtimeStore: dependencies.RuntimeStore,
		snapshotPort: dependencies.SnapshotPort,
		channels:     channels,
		interval:     interval,
	}, nil
}

func (s *NotificationService) Start(ctx context.Context) error {
	if s.interval == 0 {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancel != nil {
		return nil
	}
	loopContext, cancel := context.WithCancel(ctx)
	s.cancel = cancel
	s.done = make(chan struct{})
	go func() {
		defer close(s.done)
		ticker := time.NewTicker(s.interval)
		defer ticker.Stop()
		for {
			select {
			case <-loopContext.Done():
				return
			case <-ticker.C:
				_ = s.RefreshCurrent(loopContext)
			}
		}
	}()
	return nil
}

func (s *NotificationService) Close() error {
	s.mu.Lock()
	cancel, done := s.cancel, s.done
	s.cancel = nil
	s.done = nil
	s.mu.Unlock()
	if cancel == nil {
		return nil
	}
	cancel()
	<-done
	return nil
}

func (s *NotificationService) WebPushChannel() (*webPushNotificationChannel, bool) {
	channel, ok := s.channels.Lookup("web-push")
	if !ok {
		return nil, false
	}
	webPush, ok := channel.(*webPushNotificationChannel)
	return webPush, ok
}

func (s *NotificationService) Publish(ctx context.Context, message NotificationMessage) (NotificationDeliveryResult, error) {
	return s.channels.Publish(ctx, message)
}

func (s *NotificationService) Insights(ctx context.Context, month string) ([]Insight, error) {
	snapshot, err := s.snapshotPort.Snapshot(ctx)
	if err != nil {
		return nil, err
	}
	return s.detectInsights(month, snapshot), nil
}

func (s *NotificationService) Notifications(ctx context.Context, start, end string) ([]StoredNotification, error) {
	snapshot, err := s.snapshotPort.Snapshot(ctx)
	if err != nil {
		return nil, err
	}
	all := []StoredNotification{}
	for _, month := range monthsInRange(start, end) {
		notifications, err := s.refreshMonth(month, snapshot)
		if err != nil {
			return nil, err
		}
		all = append(all, notifications...)
	}
	return all, nil
}

func (s *NotificationService) RefreshCurrent(ctx context.Context) error {
	snapshot, err := s.snapshotPort.Snapshot(ctx)
	if err != nil {
		return err
	}
	_, err = s.refreshMonth(time.Now().Format("2006-01"), snapshot)
	return err
}

func (s *NotificationService) refreshMonth(month string, snapshot *LedgerSnapshot) ([]StoredNotification, error) {
	return s.mergeInsightsIntoNotifications(month, s.detectInsights(month, snapshot))
}

func (s *NotificationService) UpdateStatus(ids []string, status string) ([]StoredNotification, error) {
	updated := []StoredNotification{}
	err := s.runtimeStore.WithLock(context.Background(), "notifications", func(lockCtx context.Context) error {
		store := s.readStore(lockCtx)
		now := time.Now().UTC().Format(time.RFC3339Nano)
		idSet := map[string]bool{}
		for _, id := range ids {
			idSet[id] = true
		}
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
		return s.writeStore(lockCtx, store)
	})
	return updated, err
}

func (s *Server) insights(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	service, ok := s.notificationsService(c)
	if !ok {
		return
	}
	month := c.DefaultQuery("month", time.Now().Format("2006-01"))
	insights, err := service.Insights(c.Request.Context(), month)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"month": month, "insights": insights})
}

func (s *Server) notifications(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	service, ok := s.notificationsService(c)
	if !ok {
		return
	}
	start, end := parseTimeParams(c)
	notifications, err := service.Notifications(c.Request.Context(), start, end)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"start": start, "end": end, "notifications": notifications})
}

func (s *Server) updateNotifications(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	service, ok := s.notificationsService(c)
	if !ok {
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
	notifications, err := service.UpdateStatus(input.IDs, input.Status)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "notifications": notifications})
}

func (s *NotificationService) detectInsights(month string, snapshot *LedgerSnapshot) []Insight {
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

func (s *NotificationService) mergeInsightsIntoNotifications(month string, insights []Insight) ([]StoredNotification, error) {
	created := []StoredNotification{}
	var notifications []StoredNotification
	err := s.runtimeStore.WithLock(context.Background(), "notifications", func(lockCtx context.Context) error {
		store := s.readStore(lockCtx)
		now := time.Now().UTC().Format(time.RFC3339Nano)
		currentIDs := map[string]bool{}
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
		if err := s.writeStore(lockCtx, store); err != nil {
			return err
		}
		notifications = s.notificationsForMonth(store.Notifications, month)
		return nil
	})
	if err != nil {
		return nil, err
	}
	if len(created) > 0 {
		sort.Slice(created, func(i, j int) bool { return severityRank(created[i].Severity) < severityRank(created[j].Severity) })
		title := created[0].Title
		if len(created) > 1 {
			title = "我的账本：" + formatInt(len(created)) + " 条新提醒"
		}
		_, _ = s.Publish(context.Background(), NotificationMessage{Title: title, Body: created[0].Detail, URL: "/", Tag: "ledger-notifications-" + month})
	}
	return notifications, nil
}

func (s *NotificationService) readStore(ctx context.Context) notificationStore {
	var store notificationStore
	ok, err := s.runtimeStore.GetJSON(ctx, "notifications", "store", &store)
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

func (s *NotificationService) writeStore(ctx context.Context, store notificationStore) error {
	return s.runtimeStore.PutJSON(ctx, "notifications", "store", store)
}

func (s *NotificationService) notificationsForMonth(notifications []StoredNotification, month string) []StoredNotification {
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

func (s *NotificationService) sourceID(source TransactionSource) string {
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
