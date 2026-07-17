package app

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"log"
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
	state := randomID() + randomID()
	oauthState := gmailOAuthState{Value: state, ExpiresAt: time.Now().UTC().Add(10 * time.Minute).Format(time.RFC3339Nano)}
	if err := s.runtime().PutJSON(c.Request.Context(), "gmail", gmailOAuthStateKey, oauthState); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	url := gmailOAuthConfig(s.cfg).AuthCodeURL(state, oauth2.AccessTypeOffline, oauth2.ApprovalForce)
	c.JSON(http.StatusOK, gin.H{"url": url})
}

func (s *Server) gmailOAuthCallback(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	if callbackError := strings.TrimSpace(c.Query("error")); callbackError != "" {
		c.Redirect(http.StatusFound, "/import?gmail=error&reason="+url.QueryEscape(callbackError))
		return
	}
	var expected gmailOAuthState
	ok, err := s.runtime().GetJSON(c.Request.Context(), "gmail", gmailOAuthStateKey, &expected)
	if err != nil || !ok {
		errorJSON(c, http.StatusBadRequest, errors.New("Gmail OAuth state 不存在或已过期"))
		return
	}
	expiresAt, err := time.Parse(time.RFC3339Nano, expected.ExpiresAt)
	if err != nil || time.Now().UTC().After(expiresAt) || subtle.ConstantTimeCompare([]byte(expected.Value), []byte(c.Query("state"))) != 1 {
		errorJSON(c, http.StatusBadRequest, errors.New("Gmail OAuth state 无效"))
		return
	}
	code := strings.TrimSpace(c.Query("code"))
	if code == "" {
		errorJSON(c, http.StatusBadRequest, errors.New("Gmail OAuth code is required"))
		return
	}
	token, err := gmailOAuthConfig(s.cfg).Exchange(c.Request.Context(), code)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if token.RefreshToken == "" {
		errorJSON(c, http.StatusBadRequest, errors.New("Google 未返回 refresh token，请撤销旧授权后重新连接"))
		return
	}
	service, err := gmail.NewService(c.Request.Context(), option.WithTokenSource(oauth2.StaticTokenSource(token)))
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	api := &googleGmailAPI{service: service}
	profile, err := api.Profile(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	labels, err := api.Labels(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	labelID, found := findGmailLabel(labels, s.cfg.GmailLabel)
	if !found {
		errorJSON(c, http.StatusBadRequest, errors.New("Gmail 中找不到 Label: "+s.cfg.GmailLabel))
		return
	}
	encryptedRefreshToken, err := encryptGmailSecret(s.cfg, token.RefreshToken)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	watch, err := api.Watch(c.Request.Context(), s.cfg.GmailPubSubTopic, labelID)
	if err == nil {
		err = s.runtime().WithLock(c.Request.Context(), "gmail-state", func(lockCtx context.Context) error {
			now := time.Now().UTC().Format(time.RFC3339Nano)
			connection := gmailConnection{Version: 1, Email: strings.ToLower(profile.EmailAddress), EncryptedRefreshToken: encryptedRefreshToken, LabelID: labelID, LabelName: s.cfg.GmailLabel, HistoryID: watch.HistoryId, WatchExpiration: watch.Expiration, ConnectedAt: now, UpdatedAt: now}
			return s.writeGmailConnection(lockCtx, connection)
		})
	}
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	_ = s.runtime().PutJSON(c.Request.Context(), "gmail", gmailOAuthStateKey, gmailOAuthState{})
	c.Redirect(http.StatusFound, "/import?gmail=connected")
}

func (s *Server) gmailRenew(c *gin.Context) {
	if !s.requireCronOrAuth(c) {
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
		err = s.runtime().WithLock(c.Request.Context(), "gmail-state", func(lockCtx context.Context) error {
			if err := s.runtime().DeleteJSON(lockCtx, "gmail", gmailConnectionKey); err != nil {
				return err
			}
			return s.runtime().DeleteJSON(lockCtx, "gmail", gmailOAuthStateKey)
		})
	}
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) gmailPubSub(c *gin.Context) {
	if !gmailAutomationConfigured(s.cfg) {
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
		log.Printf("gmail pubsub payload ignored: %v", err)
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
	c.Status(http.StatusNoContent)
}

func (s *Server) gmailPendingImports(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
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
	c.JSON(http.StatusOK, gin.H{"ok": true})
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
