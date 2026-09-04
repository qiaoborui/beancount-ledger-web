package app

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/oauth2"
	"google.golang.org/api/gmail/v1"
	"google.golang.org/api/option"
)

const maxGmailOAuthStates = 8

type gmailOAuthStateSet struct {
	Version int               `json:"version"`
	Items   []gmailOAuthState `json:"items"`
}

func (s *Server) gmailStatus(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	configured := gmailAutomationConfigured(s.cfg)
	connection, connected, err := s.gmailConnection(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"configured":       configured,
		"deliveryMode":     normalizedGmailDeliveryMode(s.cfg),
		"connected":        connected,
		"email":            connection.Email,
		"label":            valueOr(connection.LabelName, s.cfg.GmailLabel),
		"watchExpiration":  connection.WatchExpiration,
		"lastSyncAt":       nullableString(connection.LastSyncAt),
		"lastError":        nullableString(connection.LastError),
		"allowedSenders":   append([]string(nil), s.cfg.GmailAllowedSenders...),
		"oauthRedirectUrl": s.cfg.GmailOAuthRedirectURL,
	})
}

func (s *Server) gmailConnectStart(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	if err := validateGmailAutomationConfig(s.cfg); err != nil || !gmailAutomationConfigured(s.cfg) {
		if err == nil {
			err = errors.New("Gmail 自动化尚未配置")
		}
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	client := strings.TrimSpace(c.Query("client"))
	if client != "" && client != "ios" {
		errorJSON(c, http.StatusBadRequest, errors.New("unsupported Gmail OAuth client"))
		return
	}
	state := randomID() + randomID()
	if client == "ios" {
		state = "ios." + state
	}
	oauthState := gmailOAuthState{
		Value:     state,
		ExpiresAt: time.Now().UTC().Add(10 * time.Minute).Format(time.RFC3339Nano),
	}
	if err := s.appendGmailOAuthState(c.Request.Context(), oauthState); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	url := gmailOAuthConfig(s.cfg).AuthCodeURL(state, oauth2.AccessTypeOffline, oauth2.ApprovalForce)
	c.JSON(http.StatusOK, gin.H{"url": url})
}

func (s *Server) gmailOAuthCallback(c *gin.Context) {
	receivedState := c.Query("state")
	expected, err := s.findGmailOAuthState(c.Request.Context(), receivedState)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	client := gmailOAuthClient(expected.Value)
	if client != "ios" && !requireSensitive(c) {
		return
	}
	expected, err = s.consumeGmailOAuthState(c.Request.Context(), receivedState)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if callbackError := strings.TrimSpace(c.Query("error")); callbackError != "" {
		redirectGmailOAuthResult(c, client, expected.Value, "error", callbackError)
		return
	}
	code := strings.TrimSpace(c.Query("code"))
	if code == "" {
		failGmailOAuthCallback(c, client, expected.Value, errors.New("Gmail OAuth code is required"))
		return
	}
	token, err := gmailOAuthConfig(s.cfg).Exchange(c.Request.Context(), code)
	if err != nil {
		failGmailOAuthCallback(c, client, expected.Value, err)
		return
	}
	if token.RefreshToken == "" {
		failGmailOAuthCallback(c, client, expected.Value, errors.New("Google 未返回 refresh token，请撤销旧授权后重新连接"))
		return
	}
	service, err := gmail.NewService(c.Request.Context(), option.WithTokenSource(oauth2.StaticTokenSource(token)))
	if err != nil {
		failGmailOAuthCallback(c, client, expected.Value, err)
		return
	}
	api := &googleGmailAPI{service: service}
	profile, err := api.Profile(c.Request.Context())
	if err != nil {
		failGmailOAuthCallback(c, client, expected.Value, err)
		return
	}
	labels, err := api.Labels(c.Request.Context())
	if err != nil {
		failGmailOAuthCallback(c, client, expected.Value, err)
		return
	}
	labelID, found := findGmailLabel(labels, s.cfg.GmailLabel)
	if !found {
		failGmailOAuthCallback(c, client, expected.Value, errors.New("Gmail 中找不到 Label: "+s.cfg.GmailLabel))
		return
	}
	encryptedRefreshToken, err := encryptGmailSecret(s.cfg, token.RefreshToken)
	if err != nil {
		failGmailOAuthCallback(c, client, expected.Value, err)
		return
	}
	connection, err := s.gmailConnectionFromOAuth(c.Request.Context(), api, profile, encryptedRefreshToken, labelID)
	if err == nil {
		err = s.gmailState().WithLock(c.Request.Context(), "gmail-state", func(lockCtx context.Context) error {
			now := time.Now().UTC().Format(time.RFC3339Nano)
			connection.ConnectedAt = now
			connection.UpdatedAt = now
			return s.writeGmailConnection(lockCtx, connection)
		})
	}
	if err != nil {
		failGmailOAuthCallback(c, client, expected.Value, err)
		return
	}
	redirectGmailOAuthResult(c, client, expected.Value, "connected", "")
}

func (s *Server) appendGmailOAuthState(ctx context.Context, pending gmailOAuthState) error {
	return s.gmailState().WithLock(ctx, "gmail-state", func(lockCtx context.Context) error {
		stored, ok, err := s.gmailState().OAuthState(lockCtx)
		if err != nil {
			return err
		}
		items := []gmailOAuthState{}
		if ok {
			items = activeGmailOAuthStates(stored, time.Now().UTC())
		}
		if len(items) >= maxGmailOAuthStates {
			items = items[len(items)-(maxGmailOAuthStates-1):]
		}
		items = append(items, pending)
		return s.saveGmailOAuthStates(lockCtx, items)
	})
}

func (s *Server) findGmailOAuthState(ctx context.Context, received string) (gmailOAuthState, error) {
	stored, ok, err := s.gmailState().OAuthState(ctx)
	if err != nil || !ok {
		return gmailOAuthState{}, errors.New("Gmail OAuth state 不存在或已过期")
	}
	for _, expected := range activeGmailOAuthStates(stored, time.Now().UTC()) {
		if subtle.ConstantTimeCompare([]byte(expected.Value), []byte(received)) == 1 {
			return expected, nil
		}
	}
	return gmailOAuthState{}, errors.New("Gmail OAuth state 无效")
}

func (s *Server) consumeGmailOAuthState(ctx context.Context, received string) (gmailOAuthState, error) {
	var consumed gmailOAuthState
	err := s.gmailState().WithLock(ctx, "gmail-state", func(lockCtx context.Context) error {
		stored, ok, err := s.gmailState().OAuthState(lockCtx)
		if err != nil || !ok {
			return errors.New("Gmail OAuth state 不存在或已过期")
		}
		items := activeGmailOAuthStates(stored, time.Now().UTC())
		remaining := make([]gmailOAuthState, 0, len(items))
		for _, expected := range items {
			if consumed.Value == "" && subtle.ConstantTimeCompare([]byte(expected.Value), []byte(received)) == 1 {
				consumed = expected
				continue
			}
			remaining = append(remaining, expected)
		}
		if consumed.Value == "" {
			return errors.New("Gmail OAuth state 无效")
		}
		if len(remaining) == 0 {
			return s.gmailState().DeleteOAuthState(lockCtx)
		}
		return s.saveGmailOAuthStates(lockCtx, remaining)
	})
	return consumed, err
}

func activeGmailOAuthStates(stored gmailOAuthState, now time.Time) []gmailOAuthState {
	items := []gmailOAuthState{stored}
	var set gmailOAuthStateSet
	if json.Unmarshal([]byte(stored.Value), &set) == nil && set.Version == 1 {
		items = set.Items
	}
	active := make([]gmailOAuthState, 0, len(items))
	for _, item := range items {
		expiresAt, err := time.Parse(time.RFC3339Nano, item.ExpiresAt)
		if err == nil && now.Before(expiresAt) && item.Value != "" {
			active = append(active, item)
		}
	}
	return active
}

func (s *Server) saveGmailOAuthStates(ctx context.Context, items []gmailOAuthState) error {
	latestExpiry := items[0].ExpiresAt
	for _, item := range items[1:] {
		if item.ExpiresAt > latestExpiry {
			latestExpiry = item.ExpiresAt
		}
	}
	encoded, err := json.Marshal(gmailOAuthStateSet{Version: 1, Items: items})
	if err != nil {
		return err
	}
	return s.gmailState().SaveOAuthState(ctx, gmailOAuthState{Value: string(encoded), ExpiresAt: latestExpiry})
}

func gmailOAuthClient(state string) string {
	if strings.HasPrefix(state, "ios.") {
		return "ios"
	}
	return "web"
}

func failGmailOAuthCallback(c *gin.Context, client, state string, err error) {
	if client == "ios" {
		redirectGmailOAuthResult(c, client, state, "error", "callback_failed")
		return
	}
	errorJSON(c, http.StatusBadRequest, err)
}

func redirectGmailOAuthResult(c *gin.Context, client, state, status, reason string) {
	query := url.Values{"gmail": []string{status}}
	if client == "ios" {
		query.Set("state", state)
		if reason == "access_denied" {
			query.Set("reason", "cancelled")
		} else if reason != "" {
			query.Set("reason", "callback_failed")
		}
		c.Redirect(http.StatusFound, "ledger://gmail-import?"+query.Encode())
		return
	}
	if reason != "" {
		query.Set("reason", reason)
	}
	c.Redirect(http.StatusFound, "/import?"+query.Encode())
}

func (s *Server) gmailRenew(c *gin.Context) {
	if !s.requireCronOrAuth(c) {
		return
	}
	if normalizedGmailDeliveryMode(s.cfg) != "webhook" {
		errorJSON(c, http.StatusBadRequest, errors.New("Gmail poll mode does not use users.watch renewal"))
		return
	}
	connection, err := s.renewGmailWatch(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "email": connection.Email, "historyId": connection.HistoryID, "expiration": connection.WatchExpiration})
}

func (s *Server) gmailDisconnect(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	connection, connected, err := s.gmailConnection(c.Request.Context())
	if err == nil && !connected {
		err = errors.New("Gmail 尚未连接")
	}
	var refreshToken string
	if err == nil {
		refreshToken, err = decryptGmailSecret(s.cfg, connection.EncryptedRefreshToken)
	}
	if err == nil {
		if api, apiErr := newGoogleGmailAPI(c.Request.Context(), s.cfg, refreshToken); apiErr == nil {
			_ = api.Stop(c.Request.Context())
		}
		err = revokeGoogleToken(c.Request.Context(), refreshToken)
	}
	if err == nil {
		err = s.gmailState().WithLock(c.Request.Context(), "gmail-state", func(lockCtx context.Context) error {
			if err := s.gmailState().DeleteConnection(lockCtx); err != nil {
				return err
			}
			return s.gmailState().DeleteOAuthState(lockCtx)
		})
	}
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) gmailPubSub(c *gin.Context) {
	if !gmailAutomationConfigured(s.cfg) || normalizedGmailDeliveryMode(s.cfg) != "webhook" {
		c.JSON(http.StatusNotFound, gin.H{"error": "Gmail automation is disabled"})
		return
	}
	if err := validateGmailPubSubToken(c.Request.Context(), c.GetHeader("Authorization"), s.cfg); err != nil {
		errorJSON(c, http.StatusUnauthorized, err)
		return
	}
	body, err := io.ReadAll(io.LimitReader(c.Request.Body, 1024*1024+1))
	if err != nil || len(body) > 1024*1024 {
		if err == nil {
			err = errors.New("Pub/Sub payload is too large")
		}
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	data, messageID, err := decodeGmailPush(body)
	if err != nil {
		s.loggerOr().Warn("gmail pubsub payload ignored", "error", err)
		c.Status(http.StatusNoContent)
		return
	}
	connection, connected, err := s.gmailConnection(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	if !connected || !strings.EqualFold(connection.Email, data.EmailAddress) {
		c.Status(http.StatusNoContent)
		return
	}
	if err := s.enqueueGmailPushEvent(c.Request.Context(), messageID, data); err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	if _, err := s.drainGmailPushEvents(c.Request.Context(), 5); err != nil {
		s.loggerOr().Warn("gmail pubsub immediate drain deferred", "error", err)
	}
	c.Status(http.StatusNoContent)
}

func (s *Server) gmailPendingImports(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	sensitiveUnlocked := isSensitiveUnlocked(c)
	store, err := s.gmailPendingSnapshot(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	items := make([]GmailPendingImport, len(store.Items))
	copy(items, store.Items)
	for index := range items {
		items[index].SourceKey = ""
		items[index].OutputFile = ""
		items[index].StoredBytes = 0
		if !sensitiveUnlocked {
			items[index].ImportID = ""
			items[index].MessageID = ""
			items[index].ThreadID = ""
			items[index].Sender = ""
			items[index].Subject = ""
			items[index].ReceivedAt = ""
			items[index].Filename = ""
			items[index].Provider = ""
			items[index].Error = ""
		}
	}
	sort.Slice(items, func(i, j int) bool {
		if pendingStatusRank(items[i].Status) != pendingStatusRank(items[j].Status) {
			return pendingStatusRank(items[i].Status) < pendingStatusRank(items[j].Status)
		}
		return items[i].UpdatedAt > items[j].UpdatedAt
	})
	c.JSON(http.StatusOK, gin.H{"items": items})
}

func (s *Server) gmailPendingImport(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	store, err := s.gmailPendingSnapshot(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	item, ok := pendingImportByID(store, c.Param("id"))
	if !ok {
		c.JSON(http.StatusNotFound, gin.H{"error": "待 Review 账单不存在"})
		return
	}
	item.SourceKey = ""
	item.OutputFile = ""
	item.StoredBytes = 0
	response := gin.H{"item": item}
	if item.ImportID != "" {
		preview, err := s.readImportPreview(c.Request.Context(), item.ImportID)
		if err != nil {
			errorJSON(c, http.StatusBadRequest, err)
			return
		}
		response["preview"] = preview
	}
	c.JSON(http.StatusOK, response)
}

func (s *Server) gmailDismissPendingImport(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	if err := s.dismissGmailPendingImport(c.Request.Context(), c.Param("id")); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			c.JSON(http.StatusNotFound, gin.H{"error": "待 Review 账单不存在"})
			return
		}
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func pendingStatusRank(status string) int {
	switch status {
	case "ready":
		return 0
	case "failed":
		return 1
	case "committed":
		return 2
	case "dismissed":
		return 3
	default:
		return 4
	}
}

func (s *Server) requireCronOrAuth(c *gin.Context) bool {
	if s.cronCredentialMatches(c) {
		return true
	}
	return requireSensitive(c)
}

func (s *Server) gmailSyncNow(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	if pendingID := strings.TrimSpace(c.Query("pendingId")); pendingID != "" {
		item, err := s.retryGmailPendingImport(c.Request.Context(), pendingID)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				c.JSON(http.StatusNotFound, gin.H{"error": "待重试账单不存在"})
				return
			}
			errorJSON(c, http.StatusBadRequest, err)
			return
		}
		item.SourceKey = ""
		item.OutputFile = ""
		item.StoredBytes = 0
		c.JSON(http.StatusOK, gin.H{"ok": true, "item": item})
		return
	}
	connection, connected, err := s.gmailConnection(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if !connected {
		errorJSON(c, http.StatusBadRequest, errors.New("Gmail 尚未连接"))
		return
	}
	if err := s.syncGmail(c.Request.Context(), connection.HistoryID); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	processed, err := s.drainGmailPushEvents(c.Request.Context(), 5)
	if err != nil && !gmailErrorTransient(err) {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "processed": processed, "retryPending": err != nil})
}

func (s *Server) gmailDrain(c *gin.Context) {
	if !s.requireCronOrSensitive(c) {
		return
	}
	processed, err := s.drainGmailPushEvents(c.Request.Context(), 5)
	if err != nil && !gmailErrorTransient(err) {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "processed": processed, "retryPending": err != nil})
}

func (s *Server) requireCronOrSensitive(c *gin.Context) bool {
	if s.cronCredentialMatches(c) {
		return true
	}
	return requireSensitive(c)
}

func (s *Server) cronCredentialMatches(c *gin.Context) bool {
	if s.cfg.CronSecret != "" {
		for _, provided := range []string{strings.TrimSpace(c.GetHeader("X-Cron-Secret")), strings.TrimSpace(strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer "))} {
			if len(provided) == len(s.cfg.CronSecret) && subtle.ConstantTimeCompare([]byte(provided), []byte(s.cfg.CronSecret)) == 1 {
				return true
			}
		}
	}
	if s.cfg.CronOIDCAudience == "" || s.cfg.CronOIDCServiceAccount == "" {
		return false
	}
	return validateGoogleServiceAccountToken(
		c.Request.Context(),
		c.GetHeader("Authorization"),
		s.cfg.CronOIDCAudience,
		s.cfg.CronOIDCServiceAccount,
		"Cloud Scheduler",
	) == nil
}

func revokeGoogleToken(ctx context.Context, token string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://oauth2.googleapis.com/revoke", strings.NewReader(url.Values{"token": {token}}.Encode()))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := (&http.Client{Timeout: 10 * time.Second}).Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("Google OAuth revoke failed: %s", response.Status)
	}
	return nil
}
