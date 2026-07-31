package app

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
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

// NotificationDeliveryResult captures delivery work across notification channels.
type NotificationDeliveryResult struct {
	Attempted int `json:"attempted"`
	Sent      int `json:"sent"`
	Failed    int `json:"failed"`
	Removed   int `json:"removed"`
}

type webPushNotificationChannelFactory struct{}

func (webPushNotificationChannelFactory) ID() string { return "web-push" }

func (webPushNotificationChannelFactory) NewNotificationChannel(store RuntimeStore, subscriptions pushSubscriptionRepository) (NotificationChannel, error) {
	if store == nil {
		return nil, errors.New("runtime store is required")
	}
	return &webPushNotificationChannel{runtimeStore: store, subscriptions: subscriptions}, nil
}

type webPushNotificationChannel struct {
	runtimeStore  RuntimeStore
	subscriptions pushSubscriptionRepository
}

func (c *webPushNotificationChannel) ID() string { return "web-push" }

func (s *Server) pushStatus(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	channel, ok := s.webPushChannel(c)
	if !ok {
		return
	}
	count, err := channel.pushSubscriptionCount(context.Background())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	publicKey := publicVapidKey()
	c.JSON(http.StatusOK, gin.H{
		"publicKey":  publicKey,
		"configured": publicKey != "" && os.Getenv("WEB_PUSH_VAPID_PRIVATE_KEY") != "",
		"count":      count,
	})
}

func (s *Server) pushSave(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	channel, ok := s.webPushChannel(c)
	if !ok {
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
	id, count, err := channel.savePushSubscription(input.Subscription, c.GetHeader("User-Agent"))
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
	channel, ok := s.webPushChannel(c)
	if !ok {
		return
	}
	var input struct {
		Endpoint string `json:"endpoint"`
	}
	if !bindJSON(c, &input) {
		return
	}
	removed, count, err := channel.removePushSubscription(input.Endpoint)
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
	service, ok := s.notificationsService(c)
	if !ok {
		return
	}
	result, err := service.Publish(c.Request.Context(), NotificationMessage{
		Title: "我的账本",
		Body:  "Web Push 测试通知已发送。",
		URL:   "/",
		Tag:   "web-push-test",
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
	service, ok := s.notificationsService(c)
	if !ok {
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
	result, err := service.Publish(c.Request.Context(), NotificationMessage{Title: input.Title, Body: input.Body, URL: input.URL, Tag: input.Tag})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "attempted": result.Attempted, "sent": result.Sent, "failed": result.Failed, "removed": result.Removed})
}

func (s *Server) webPushChannel(c *gin.Context) (*webPushNotificationChannel, bool) {
	service, ok := s.notificationsService(c)
	if !ok {
		return nil, false
	}
	channel, ok := service.WebPushChannel()
	if !ok {
		c.JSON(http.StatusNotFound, gin.H{"error": "web push channel is disabled"})
		return nil, false
	}
	return channel, true
}

func (s *Server) notificationsService(c *gin.Context) (*NotificationService, bool) {
	if s.notificationService != nil {
		return s.notificationService, true
	}
	c.JSON(http.StatusNotFound, gin.H{"error": "notifications module is disabled"})
	return nil, false
}

func publicVapidKey() string {
	if key := strings.TrimSpace(os.Getenv("NEXT_PUBLIC_WEB_PUSH_VAPID_PUBLIC_KEY")); key != "" {
		return key
	}
	return strings.TrimSpace(os.Getenv("WEB_PUSH_VAPID_PUBLIC_KEY"))
}

func (c *webPushNotificationChannel) readPushStore(ctx context.Context) pushStore {
	if c.subscriptions != nil {
		subscriptions, err := c.subscriptions.List(ctx)
		if err != nil {
			return pushStore{Version: 1, Subscriptions: []StoredPushSubscription{}}
		}
		return pushStore{Version: 1, Subscriptions: subscriptions}
	}
	var store pushStore
	ok, err := c.runtimeStore.GetJSON(ctx, "push", "subscriptions", &store)
	if err != nil || !ok {
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

func (c *webPushNotificationChannel) writePushStore(ctx context.Context, store pushStore) error {
	return c.runtimeStore.PutJSON(ctx, "push", "subscriptions", store)
}

func (c *webPushNotificationChannel) savePushSubscription(subscription PushSubscription, userAgent string) (string, int, error) {
	id := base64.RawURLEncoding.EncodeToString([]byte(subscription.Endpoint))
	if len(id) > 48 {
		id = id[:48]
	}
	count := 0
	if c.subscriptions != nil {
		now := time.Now().UTC().Format(time.RFC3339Nano)
		stored, savedCount, err := c.subscriptions.Save(context.Background(), StoredPushSubscription{ID: id, Subscription: subscription, UserAgent: userAgent, CreatedAt: now, UpdatedAt: now})
		return stored.ID, savedCount, err
	}
	err := c.runtimeStore.WithLock(context.Background(), "push-subscriptions", func(lockCtx context.Context) error {
		store := c.readPushStore(lockCtx)
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
		count = len(store.Subscriptions)
		return c.writePushStore(lockCtx, store)
	})
	return id, count, err
}

func (c *webPushNotificationChannel) removePushSubscription(endpoint string) (int, int, error) {
	if c.subscriptions != nil {
		return c.subscriptions.DeleteEndpoints(context.Background(), []string{endpoint})
	}
	removed := 0
	count := 0
	err := c.runtimeStore.WithLock(context.Background(), "push-subscriptions", func(lockCtx context.Context) error {
		store := c.readPushStore(lockCtx)
		kept := store.Subscriptions[:0]
		for _, item := range store.Subscriptions {
			if item.Subscription.Endpoint == endpoint {
				removed++
				continue
			}
			kept = append(kept, item)
		}
		store.Subscriptions = kept
		count = len(store.Subscriptions)
		if removed > 0 {
			return c.writePushStore(lockCtx, store)
		}
		return nil
	})
	return removed, count, err
}

func (c *webPushNotificationChannel) Send(ctx context.Context, message NotificationMessage) (NotificationDeliveryResult, error) {
	publicKey := publicVapidKey()
	privateKey := strings.TrimSpace(os.Getenv("WEB_PUSH_VAPID_PRIVATE_KEY"))
	if publicKey == "" || privateKey == "" {
		return NotificationDeliveryResult{}, errors.New("WEB_PUSH_VAPID_PUBLIC_KEY and WEB_PUSH_VAPID_PRIVATE_KEY are required")
	}
	store := c.readPushStore(context.Background())
	data, err := json.Marshal(map[string]string{"title": message.Title, "body": message.Body, "url": message.URL, "tag": message.Tag})
	if err != nil {
		return NotificationDeliveryResult{}, err
	}
	result := NotificationDeliveryResult{Attempted: len(store.Subscriptions)}
	dead := map[string]bool{}
	for _, item := range store.Subscriptions {
		if err := ctx.Err(); err != nil {
			return result, err
		}
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
		if c.subscriptions != nil {
			endpoints := make([]string, 0, len(dead))
			for endpoint := range dead {
				endpoints = append(endpoints, endpoint)
			}
			removed, _, err := c.subscriptions.DeleteEndpoints(context.Background(), endpoints)
			result.Removed += removed
			return result, err
		}
		err = c.runtimeStore.WithLock(context.Background(), "push-subscriptions", func(lockCtx context.Context) error {
			latest := c.readPushStore(lockCtx)
			kept := latest.Subscriptions[:0]
			for _, item := range latest.Subscriptions {
				if dead[item.Subscription.Endpoint] {
					result.Removed++
					continue
				}
				kept = append(kept, item)
			}
			latest.Subscriptions = kept
			return c.writePushStore(lockCtx, latest)
		})
		if err != nil {
			return result, err
		}
	}
	return result, nil
}

func (c *webPushNotificationChannel) pushSubscriptionCount(ctx context.Context) (int, error) {
	if c.subscriptions != nil {
		return c.subscriptions.Count(ctx)
	}
	return len(c.readPushStore(ctx).Subscriptions), nil
}
