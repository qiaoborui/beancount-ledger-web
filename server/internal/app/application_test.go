package app

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

type applicationTestCloser struct {
	id     string
	closed *[]string
	err    error
}

func (c *applicationTestCloser) Close() error {
	*c.closed = append(*c.closed, c.id)
	return c.err
}

func TestNewApplicationServesExistingRouterContract(t *testing.T) {
	application, err := NewApplication(testLedger(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := application.Close(); err != nil {
			t.Error(err)
		}
	})

	response := httptest.NewRecorder()
	application.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/health", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("health status = %d body=%s", response.Code, response.Body.String())
	}
	if application.router == nil {
		t.Fatal("application router is nil")
	}
}

func TestApplicationCloseClosesResourcesOnceInReverseOrder(t *testing.T) {
	closed := []string{}
	application := newApplication(gin.New(), nil, []io.Closer{
		&applicationTestCloser{id: "database", closed: &closed},
		&applicationTestCloser{id: "index", closed: &closed},
	})

	if err := application.Close(); err != nil {
		t.Fatal(err)
	}
	if err := application.Close(); err != nil {
		t.Fatal(err)
	}
	if want := []string{"index", "database"}; !reflect.DeepEqual(closed, want) {
		t.Fatalf("closed resources = %v, want %v", closed, want)
	}
}

func TestApplicationCloseJoinsResourceErrors(t *testing.T) {
	firstErr := errors.New("first close failed")
	secondErr := errors.New("second close failed")
	closed := []string{}
	application := newApplication(gin.New(), nil, []io.Closer{
		&applicationTestCloser{id: "first", closed: &closed, err: firstErr},
		&applicationTestCloser{id: "second", closed: &closed, err: secondErr},
	})

	err := application.Close()
	if !errors.Is(err, firstErr) || !errors.Is(err, secondErr) {
		t.Fatalf("Close error = %v, want both resource errors", err)
	}
}

func TestApplicationGmailPollingDoesNotStartAfterClose(t *testing.T) {
	var created atomic.Int32
	application := newApplication(gin.New(), &Server{cfg: Config{GmailDeliveryMode: "poll", GmailClientID: "configured"}}, nil)
	application.pollWorkerFactory = func() *gmailPollWorker {
		created.Add(1)
		return newGmailPollWorker(time.Hour, time.Second, nil, func(context.Context) error { return nil })
	}
	if err := application.Close(); err != nil {
		t.Fatal(err)
	}
	application.StartGmailPolling(context.Background())
	if got := created.Load(); got != 0 {
		t.Fatalf("workers created after close=%d, want 0", got)
	}
}

func TestApplicationMaintenanceModeDoesNotStartBackgroundWork(t *testing.T) {
	var moduleStarted, pollWorkerCreated atomic.Int32
	registry, err := NewModuleRegistry(testModule{
		name: "background",
		start: func(context.Context) error {
			moduleStarted.Add(1)
			return nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := startApplicationModules(context.Background(), registry, true); err != nil {
		t.Fatal(err)
	}
	application := newApplication(gin.New(), &Server{cfg: Config{
		MaintenanceMode:   true,
		GmailDeliveryMode: "poll",
		GmailClientID:     "configured",
	}}, nil)
	application.pollWorkerFactory = func() *gmailPollWorker {
		pollWorkerCreated.Add(1)
		return newGmailPollWorker(time.Hour, time.Second, nil, func(context.Context) error { return nil })
	}

	application.StartGmailPolling(context.Background())

	if got := moduleStarted.Load(); got != 0 {
		t.Fatalf("modules started in maintenance mode=%d, want 0", got)
	}
	if got := pollWorkerCreated.Load(); got != 0 {
		t.Fatalf("Gmail poll workers created in maintenance mode=%d, want 0", got)
	}
}

func TestMaintenanceModeAllowsHealthReadinessAndAssociationMetadata(t *testing.T) {
	router := gin.New()
	router.Use(maintenanceModeGuard(true))
	called := false
	router.Any("/*path", func(c *gin.Context) {
		called = true
		c.Status(http.StatusNoContent)
	})

	blocked := httptest.NewRecorder()
	router.ServeHTTP(blocked, httptest.NewRequest(http.MethodPost, "/api/setup/install", nil))
	if blocked.Code != http.StatusServiceUnavailable || called {
		t.Fatalf("blocked status=%d called=%v body=%s", blocked.Code, called, blocked.Body.String())
	}

	for _, path := range []string{
		"/api/health",
		"/api/ready",
		"/.well-known/webauthn",
		"/.well-known/apple-app-site-association",
	} {
		called = false
		response := httptest.NewRecorder()
		router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != http.StatusNoContent || !called {
			t.Fatalf("%s status=%d called=%v", path, response.Code, called)
		}
	}
}

func TestApplicationGmailPollingRegistersWorkerBeforeClose(t *testing.T) {
	started := make(chan struct{})
	stopped := make(chan struct{})
	application := newApplication(gin.New(), &Server{cfg: Config{GmailDeliveryMode: "poll", GmailClientID: "configured"}}, nil)
	application.pollWorkerFactory = func() *gmailPollWorker {
		return newGmailPollWorker(time.Hour, time.Second, nil, func(ctx context.Context) error {
			close(started)
			<-ctx.Done()
			close(stopped)
			return ctx.Err()
		})
	}
	application.StartGmailPolling(context.Background())
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("worker did not start")
	}
	if err := application.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("Close did not stop registered worker")
	}
}

func TestApplicationGmailPollingConcurrentStartAndClose(t *testing.T) {
	for attempt := 0; attempt < 50; attempt++ {
		var created, stopped atomic.Int32
		application := newApplication(gin.New(), &Server{cfg: Config{GmailDeliveryMode: "poll", GmailClientID: "configured"}}, nil)
		application.pollWorkerFactory = func() *gmailPollWorker {
			created.Add(1)
			return newGmailPollWorker(time.Hour, time.Second, nil, func(ctx context.Context) error {
				<-ctx.Done()
				stopped.Add(1)
				return ctx.Err()
			})
		}
		var wait sync.WaitGroup
		wait.Add(2)
		go func() {
			defer wait.Done()
			application.StartGmailPolling(context.Background())
		}()
		go func() {
			defer wait.Done()
			_ = application.Close()
		}()
		wait.Wait()
		if got := created.Load(); got > 1 {
			t.Fatalf("attempt %d created=%d", attempt, got)
		}
		if got := stopped.Load(); got != created.Load() {
			t.Fatalf("attempt %d stopped=%d created=%d", attempt, got, created.Load())
		}
	}
}
