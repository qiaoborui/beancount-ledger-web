package app

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
	"github.com/gin-gonic/gin"
)

type PushSubscription struct {
	Endpoint       string              `json:"endpoint"`
	ExpirationTime *float64            `json:"expirationTime,omitempty"`
	Keys           PushSubscriptionKey `json:"keys"`
}

type PushSubscriptionKey struct {
	Auth   string `json:"auth"`
	P256dh string `json:"p256dh"`
}

type StoredPushSubscription struct {
	ID           string           `json:"id"`
	Subscription PushSubscription `json:"subscription"`
	UserAgent    string           `json:"userAgent,omitempty"`
	CreatedAt    string           `json:"createdAt"`
	UpdatedAt    string           `json:"updatedAt"`
}

type pushStore struct {
	Version       int                      `json:"version"`
	Subscriptions []StoredPushSubscription `json:"subscriptions"`
}

type pushSendResult struct {
	Attempted int `json:"attempted"`
	Sent      int `json:"sent"`
	Failed    int `json:"failed"`
	Removed   int `json:"removed"`
}

var pushMu sync.Mutex

func (s *Server) pushStatus(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	store := s.readPushStore()
	publicKey := publicVapidKey()
	c.JSON(http.StatusOK, gin.H{
		"publicKey":  publicKey,
		"configured": publicKey != "" && os.Getenv("WEB_PUSH_VAPID_PRIVATE_KEY") != "",
		"count":      len(store.Subscriptions),
	})
}

func (s *Server) pushSave(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input struct {
		Subscription PushSubscription `json:"subscription"`
	}
	if !bindJSON(c, &input) {
		return
	}
	if strings.TrimSpace(input.Subscription.Endpoint) == "" || strings.TrimSpace(input.Subscription.Keys.Auth) == "" || strings.TrimSpace(input.Subscription.Keys.P256dh) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid push subscription"})
		return
	}
	id, count, err := s.savePushSubscription(input.Subscription, c.GetHeader("User-Agent"))
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "id": id, "count": count})
}

func (s *Server) pushDelete(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input struct {
		Endpoint string `json:"endpoint"`
	}
	if !bindJSON(c, &input) {
		return
	}
	removed, count, err := s.removePushSubscription(input.Endpoint)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "removed": removed, "count": count})
}

func (s *Server) pushTest(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	result, err := s.sendWebPushToAll(map[string]string{
		"title": "我的账本",
		"body":  "Web Push 测试通知已发送。",
		"url":   "/",
		"tag":   "web-push-test",
	})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "attempted": result.Attempted, "sent": result.Sent, "failed": result.Failed, "removed": result.Removed})
}

func (s *Server) pushNotify(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input struct {
		Title string `json:"title"`
		Body  string `json:"body"`
		URL   string `json:"url"`
		Tag   string `json:"tag"`
	}
	if !bindJSON(c, &input) {
		return
	}
	input.Title = strings.TrimSpace(input.Title)
	input.Body = strings.TrimSpace(input.Body)
	if input.Title == "" || input.Body == "" || len([]rune(input.Title)) > 80 || len([]rune(input.Body)) > 200 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid push notification request"})
		return
	}
	if strings.TrimSpace(input.URL) == "" {
		input.URL = "/"
	}
	if strings.TrimSpace(input.Tag) == "" {
		input.Tag = "ledger-notification"
	}
	result, err := s.sendWebPushToAll(map[string]string{"title": input.Title, "body": input.Body, "url": input.URL, "tag": input.Tag})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "attempted": result.Attempted, "sent": result.Sent, "failed": result.Failed, "removed": result.Removed})
}

func publicVapidKey() string {
	if key := strings.TrimSpace(os.Getenv("NEXT_PUBLIC_WEB_PUSH_VAPID_PUBLIC_KEY")); key != "" {
		return key
	}
	return strings.TrimSpace(os.Getenv("WEB_PUSH_VAPID_PUBLIC_KEY"))
}

func (s *Server) pushStorePath() string {
	return filepath.Join(s.cfg.RuntimeDir, "webpush-subscriptions.json")
}

func (s *Server) readPushStore() pushStore {
	content, err := os.ReadFile(s.pushStorePath())
	if err != nil {
		return pushStore{Version: 1, Subscriptions: []StoredPushSubscription{}}
	}
	var store pushStore
	if err := json.Unmarshal(content, &store); err != nil {
		return pushStore{Version: 1, Subscriptions: []StoredPushSubscription{}}
	}
	if store.Version == 0 {
		store.Version = 1
	}
	if store.Subscriptions == nil {
		store.Subscriptions = []StoredPushSubscription{}
	}
	return store
}

func (s *Server) writePushStore(store pushStore) error {
	if err := os.MkdirAll(s.cfg.RuntimeDir, 0o700); err != nil {
		return err
	}
	content, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return err
	}
	content = append(content, '\n')
	return os.WriteFile(s.pushStorePath(), content, 0o600)
}

func (s *Server) savePushSubscription(subscription PushSubscription, userAgent string) (string, int, error) {
	pushMu.Lock()
	defer pushMu.Unlock()
	store := s.readPushStore()
	id := base64.RawURLEncoding.EncodeToString([]byte(subscription.Endpoint))
	if len(id) > 48 {
		id = id[:48]
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	found := false
	for i := range store.Subscriptions {
		if store.Subscriptions[i].ID == id {
			store.Subscriptions[i].Subscription = subscription
			store.Subscriptions[i].UserAgent = userAgent
			store.Subscriptions[i].UpdatedAt = now
			found = true
			break
		}
	}
	if !found {
		store.Subscriptions = append(store.Subscriptions, StoredPushSubscription{ID: id, Subscription: subscription, UserAgent: userAgent, CreatedAt: now, UpdatedAt: now})
	}
	return id, len(store.Subscriptions), s.writePushStore(store)
}

func (s *Server) removePushSubscription(endpoint string) (int, int, error) {
	pushMu.Lock()
	defer pushMu.Unlock()
	store := s.readPushStore()
	kept := store.Subscriptions[:0]
	removed := 0
	for _, item := range store.Subscriptions {
		if item.Subscription.Endpoint == endpoint {
			removed++
			continue
		}
		kept = append(kept, item)
	}
	store.Subscriptions = kept
	if removed > 0 {
		if err := s.writePushStore(store); err != nil {
			return 0, 0, err
		}
	}
	return removed, len(store.Subscriptions), nil
}

func (s *Server) sendWebPushToAll(payload map[string]string) (pushSendResult, error) {
	publicKey := publicVapidKey()
	privateKey := strings.TrimSpace(os.Getenv("WEB_PUSH_VAPID_PRIVATE_KEY"))
	if publicKey == "" || privateKey == "" {
		return pushSendResult{}, errors.New("WEB_PUSH_VAPID_PUBLIC_KEY and WEB_PUSH_VAPID_PRIVATE_KEY are required")
	}
	store := s.readPushStore()
	data, err := json.Marshal(payload)
	if err != nil {
		return pushSendResult{}, err
	}
	result := pushSendResult{Attempted: len(store.Subscriptions)}
	dead := map[string]bool{}
	for _, item := range store.Subscriptions {
		resp, err := webpush.SendNotification(data, &webpush.Subscription{
			Endpoint: item.Subscription.Endpoint,
			Keys: webpush.Keys{
				Auth:   item.Subscription.Keys.Auth,
				P256dh: item.Subscription.Keys.P256dh,
			},
		}, &webpush.Options{
			Subscriber:      env("WEB_PUSH_SUBJECT", "mailto:ledger@example.local"),
			VAPIDPublicKey:  publicKey,
			VAPIDPrivateKey: privateKey,
			TTL:             60,
		})
		if resp != nil && resp.Body != nil {
			_ = resp.Body.Close()
		}
		if err == nil && resp != nil && resp.StatusCode >= 200 && resp.StatusCode < 300 {
			result.Sent++
			continue
		}
		result.Failed++
		if resp != nil && (resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone) {
			dead[item.Subscription.Endpoint] = true
		}
	}
	if len(dead) > 0 {
		pushMu.Lock()
		latest := s.readPushStore()
		kept := latest.Subscriptions[:0]
		for _, item := range latest.Subscriptions {
			if dead[item.Subscription.Endpoint] {
				result.Removed++
				continue
			}
			kept = append(kept, item)
		}
		latest.Subscriptions = kept
		err = s.writePushStore(latest)
		pushMu.Unlock()
		if err != nil {
			return result, err
		}
	}
	return result, nil
}
