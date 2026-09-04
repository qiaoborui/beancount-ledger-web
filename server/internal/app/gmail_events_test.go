package app

import (
	"bufio"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestGmailPendingEventHubPublishesWithoutBlockingWriters(t *testing.T) {
	hub := newGmailPendingEventHub()
	updates, unsubscribe, ok := hub.subscribe()
	if !ok {
		t.Fatal("first subscriber was rejected")
	}
	defer unsubscribe()

	hub.publish()
	hub.publish()

	select {
	case <-updates:
	case <-time.After(time.Second):
		t.Fatal("subscriber did not receive pending import update")
	}

	select {
	case <-updates:
		t.Fatal("burst updates should coalesce while the subscriber is refreshing")
	default:
	}
}

func TestGmailPendingEventsStartsAuthenticatedSSEWithoutFinancialPayload(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	cfg := testLedger(t)
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir), limiter: NewRateLimiter()}
	httpServer := httptest.NewServer(newRouter(cfg, server))
	defer httpServer.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, httpServer.URL+"/api/ledger/imports/pending/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Accept", "text/event-stream")
	request.Header.Set("Accept-Encoding", "identity")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", response.StatusCode)
	}
	if contentType := response.Header.Get("Content-Type"); !strings.HasPrefix(contentType, "text/event-stream") {
		t.Fatalf("content type=%q", contentType)
	}
	line, err := bufio.NewReader(response.Body).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	if line != "event: pending\n" {
		t.Fatalf("first event line=%q", line)
	}
}

func TestGmailPendingWritePublishesRealtimeUpdate(t *testing.T) {
	cfg := testLedger(t)
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	updates, unsubscribe, ok := server.gmailPendingEventHub().subscribe()
	if !ok {
		t.Fatal("first subscriber was rejected")
	}
	defer unsubscribe()

	err := server.writeGmailPending(context.Background(), gmailPendingStore{
		Items: []GmailPendingImport{{
			ID:        "pending-event",
			MessageID: "message-event",
			Status:    "processing",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}

	select {
	case <-updates:
	case <-time.After(time.Second):
		t.Fatal("persisted pending change did not publish realtime update")
	}
}

type delayedGmailLockRepository struct {
	gmailStateRepository
	callbackDone chan struct{}
	allowReturn  chan struct{}
}

func (r *delayedGmailLockRepository) WithLock(ctx context.Context, _ string, fn func(context.Context) error) error {
	if err := fn(ctx); err != nil {
		return err
	}
	close(r.callbackDone)
	select {
	case <-r.allowReturn:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func TestGmailPendingMutationPublishesAfterDurableLockReturns(t *testing.T) {
	cfg := testLedger(t)
	baseRepository := newRuntimeGmailStateRepository(newFilesystemRuntimeStore(cfg.RuntimeDir))
	repository := &delayedGmailLockRepository{
		gmailStateRepository: baseRepository,
		callbackDone:         make(chan struct{}),
		allowReturn:          make(chan struct{}),
	}
	server := &Server{cfg: cfg, gmailRepository: repository}
	updates, unsubscribe, ok := server.gmailPendingEventHub().subscribe()
	if !ok {
		t.Fatal("subscriber was rejected")
	}
	defer unsubscribe()

	finished := make(chan error, 1)
	go func() {
		_, err := server.reserveGmailPending(context.Background(), GmailPendingImport{
			ID: "pending-after-commit", MessageID: "message-after-commit", Status: "processing",
		})
		finished <- err
	}()
	<-repository.callbackDone
	select {
	case <-updates:
		t.Fatal("pending event published before durable lock returned")
	default:
	}
	close(repository.allowReturn)
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
	select {
	case <-updates:
	case <-time.After(time.Second):
		t.Fatal("pending event was not published after durable lock returned")
	}
}

func TestGmailPendingEventHubStopsPublishingAfterUnsubscribe(t *testing.T) {
	hub := newGmailPendingEventHub()
	updates, unsubscribe, ok := hub.subscribe()
	if !ok {
		t.Fatal("first subscriber was rejected")
	}
	unsubscribe()
	hub.publish()

	select {
	case <-updates:
		t.Fatal("unsubscribed listener received an update")
	default:
	}
}

func TestGmailPendingEventHubBoundsLongLivedConnections(t *testing.T) {
	hub := newGmailPendingEventHub()
	unsubscribes := make([]func(), 0, maxGmailPendingEventSubscribers)
	for range maxGmailPendingEventSubscribers {
		_, unsubscribe, ok := hub.subscribe()
		if !ok {
			t.Fatal("subscriber rejected before limit")
		}
		unsubscribes = append(unsubscribes, unsubscribe)
	}
	if _, _, ok := hub.subscribe(); ok {
		t.Fatal("subscriber accepted above limit")
	}
	unsubscribes[0]()
	if _, unsubscribe, ok := hub.subscribe(); !ok {
		t.Fatal("subscriber slot was not released")
	} else {
		unsubscribe()
	}
	for _, unsubscribe := range unsubscribes[1:] {
		unsubscribe()
	}
}
