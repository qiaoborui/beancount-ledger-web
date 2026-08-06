package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

const telegramWebhookTestSecret = "telegram-webhook-secret"

func telegramWebhookTestServer(t *testing.T, agentURL string) *Server {
	t.Helper()
	cfg := Config{
		RuntimeDir:            t.TempDir(),
		AgentServiceURL:       agentURL,
		AgentServiceToken:     "agent-secret",
		TelegramWebhookSecret: telegramWebhookTestSecret,
	}
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	return server
}

func postTelegramUpdate(t *testing.T, router http.Handler, body string, secret string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/api/integrations/telegram/webhook", strings.NewReader(body))
	if secret != "" {
		request.Header.Set("X-Telegram-Bot-Api-Secret-Token", secret)
	}
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, request)
	return recorder
}

func TestTelegramWebhookRequiresValidSecret(t *testing.T) {
	var calls atomic.Int32
	fakeAgent := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		t.Errorf("Agent must not be called without a valid webhook secret")
	}))
	defer fakeAgent.Close()

	server := telegramWebhookTestServer(t, fakeAgent.URL)
	router := newRouter(server.cfg, server)

	for _, secret := range []string{"", "wrong-secret"} {
		response := postTelegramUpdate(t, router, `{"update_id": 42}`, secret)
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("secret %q status=%d body=%s", secret, response.Code, response.Body.String())
		}
	}
	if calls.Load() != 0 {
		t.Fatalf("Agent was called %d times", calls.Load())
	}
}

func TestTelegramWebhookForwardsUpdateAndDeduplicates(t *testing.T) {
	var calls atomic.Int32
	var receivedBody atomic.Value
	fakeAgent := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/v1/channels/telegram/updates" || r.Header.Get("X-Agent-Service-Token") != "agent-secret" {
			t.Errorf("unexpected Agent request: %s token=%q", r.URL.Path, r.Header.Get("X-Agent-Service-Token"))
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		raw, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read Agent request body: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		receivedBody.Store(string(raw))
		w.WriteHeader(http.StatusNoContent)
	}))
	defer fakeAgent.Close()

	server := telegramWebhookTestServer(t, fakeAgent.URL)
	router := newRouter(server.cfg, server)
	body := `{"update_id": 42, "message": {"message_id": 7, "chat": {"id": 1}, "from": {"id": 2}}}`

	first := postTelegramUpdate(t, router, body, telegramWebhookTestSecret)
	if first.Code != http.StatusNoContent {
		t.Fatalf("first status=%d body=%s", first.Code, first.Body.String())
	}
	second := postTelegramUpdate(t, router, body, telegramWebhookTestSecret)
	if second.Code != http.StatusNoContent {
		t.Fatalf("duplicate status=%d body=%s", second.Code, second.Body.String())
	}

	if calls.Load() != 1 {
		t.Fatalf("Agent was called %d times, want 1", calls.Load())
	}
	var forwarded telegramWebhookPayload
	if err := json.Unmarshal([]byte(receivedBody.Load().(string)), &forwarded); err != nil {
		t.Fatal(err)
	}
	if forwarded.UpdateID != 42 {
		t.Fatalf("forwarded update_id=%d", forwarded.UpdateID)
	}
}

func TestTelegramWebhookReturnsBadGatewayAndRetriesOnAgentFailure(t *testing.T) {
	var calls atomic.Int32
	fakeAgent := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 1 {
			http.Error(w, `{"detail":"model failed"}`, http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer fakeAgent.Close()

	server := telegramWebhookTestServer(t, fakeAgent.URL)
	router := newRouter(server.cfg, server)
	body := `{"update_id": 99}`

	failed := postTelegramUpdate(t, router, body, telegramWebhookTestSecret)
	if failed.Code != http.StatusBadGateway {
		t.Fatalf("failure status=%d body=%s", failed.Code, failed.Body.String())
	}
	retried := postTelegramUpdate(t, router, body, telegramWebhookTestSecret)
	if retried.Code != http.StatusNoContent {
		t.Fatalf("retry status=%d body=%s", retried.Code, retried.Body.String())
	}
	if calls.Load() != 2 {
		t.Fatalf("Agent was called %d times, want 2 (failed updates must be retried)", calls.Load())
	}
}

func TestTelegramWebhookRejectsInvalidPayloads(t *testing.T) {
	server := telegramWebhookTestServer(t, "")
	router := newRouter(server.cfg, server)

	cases := []struct {
		name string
		body string
		want int
	}{
		{"missing update_id", `{"message": {}}`, http.StatusBadRequest},
		{"invalid update_id", `{"update_id": "x"}`, http.StatusBadRequest},
		{"invalid JSON", `{`, http.StatusBadRequest},
		{"empty body", ``, http.StatusBadRequest},
		{"oversized body", `{"update_id": 1, "pad": "` + strings.Repeat("x", telegramWebhookMaxBodyBytes) + `"}`, http.StatusRequestEntityTooLarge},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			response := postTelegramUpdate(t, router, tc.body, telegramWebhookTestSecret)
			if response.Code != tc.want {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}

func TestTelegramCompletedUpdatesAreBounded(t *testing.T) {
	server := telegramWebhookTestServer(t, "")
	ctx := context.Background()
	start := int64(1000)
	total := int64(telegramCompletedUpdateCap + 100)
	for i := int64(0); i < total; i++ {
		if err := server.recordTelegramUpdateCompleted(ctx, start+i); err != nil {
			t.Fatal(err)
		}
	}
	var stored telegramCompletedUpdates
	found, err := server.runtime().GetJSON(ctx, telegramUpdatesScope, telegramCompletedUpdatesKey, &stored)
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("completed updates were not stored")
	}
	if len(stored.IDs) != telegramCompletedUpdateCap {
		t.Fatalf("stored %d updates, want %d", len(stored.IDs), telegramCompletedUpdateCap)
	}
	if stored.IDs[0] != start+total-1 {
		t.Fatalf("most recent update must be first, got %d", stored.IDs[0])
	}
	already, err := server.telegramUpdateCompleted(ctx, start+total-1)
	if err != nil {
		t.Fatal(err)
	}
	if !already {
		t.Fatal("recent completed update must be recognized")
	}
	already, err = server.telegramUpdateCompleted(ctx, start)
	if err != nil {
		t.Fatal(err)
	}
	if already {
		t.Fatal("evicted completed update must not be recognized")
	}
}

func TestTelegramWebhookSerializesUpdatesPerInstance(t *testing.T) {
	server := telegramWebhookTestServer(t, "")
	var concurrent atomic.Int32
	var maxConcurrent atomic.Int32
	var calls atomic.Int32
	fakeAgent := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		current := concurrent.Add(1)
		for {
			observed := maxConcurrent.Load()
			if current <= observed || maxConcurrent.CompareAndSwap(observed, current) {
				break
			}
		}
		defer concurrent.Add(-1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer fakeAgent.Close()
	server.cfg.AgentServiceURL = fakeAgent.URL
	router := newRouter(server.cfg, server)

	done := make(chan struct{}, 8)
	for i := 0; i < 8; i++ {
		go func(updateID int64) {
			defer func() { done <- struct{}{} }()
			response := postTelegramUpdate(t, router, fmt.Sprintf(`{"update_id": %d}`, updateID), telegramWebhookTestSecret)
			if response.Code != http.StatusNoContent {
				t.Errorf("status=%d body=%s", response.Code, response.Body.String())
			}
		}(int64(500 + i))
	}
	for i := 0; i < 8; i++ {
		<-done
	}
	if calls.Load() != 8 {
		t.Fatalf("Agent was called %d times, want 8", calls.Load())
	}
	if maxConcurrent.Load() != 1 {
		t.Fatalf("Agent saw %d concurrent requests, want 1", maxConcurrent.Load())
	}
}
