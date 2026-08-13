package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/app"
	"github.com/borui/beancount-ledger-web/server/internal/logging"
)

type indexerStatus struct {
	mu           sync.RWMutex
	attempts     int
	lastSuccess  time.Time
	lastAttempt  time.Time
	lastError    string
	lastRevision int64
}

func main() {
	logger := logging.New(logging.LoadConfig())
	cfg := app.LoadIndexerConfig()
	runtimeConfigURL := cfg.IndexerConfigURL
	validationConfig := cfg
	if runtimeConfigURL != "" {
		validationConfig.LedgerGitSyncEnabled = false
	}
	if err := app.ValidateIndexerConfig(validationConfig); err != nil {
		log.Fatal(err)
	}
	status := &indexerStatus{}
	interval := durationEnv("LEDGER_INDEX_INTERVAL_SECONDS", 60*time.Second)
	retry := durationEnv("LEDGER_INDEX_RETRY_INITIAL_SECONDS", 5*time.Second)
	maxRetry := durationEnv("LEDGER_INDEX_RETRY_MAX_SECONDS", time.Minute)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go runIndexer(ctx, logger, cfg, status, interval, retry, maxRetry, runtimeConfigURL)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", status.health)
	mux.HandleFunc("/ready", status.ready)
	server := newHealthServer(":"+strconv.Itoa(intEnv("LEDGER_INDEX_HEALTH_PORT", 3001)), mux)
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

// newHealthServer returns the /health and /ready server with explicit timeouts
// so slow or stalled clients cannot hold connections open indefinitely. The
// handlers are trivial JSON responses, so a short WriteTimeout bounds slow
// clients, while ReadHeaderTimeout/ReadTimeout reject stalled connections and
// MaxHeaderBytes caps header size at 1 MiB.
func newHealthServer(addr string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
}

func runIndexer(ctx context.Context, logger *slog.Logger, cfg app.Config, status *indexerStatus, interval, retry, maxRetry time.Duration, runtimeConfigURL string) {
	failures := 0
	for {
		status.mu.Lock()
		status.attempts++
		status.lastAttempt = time.Now().UTC()
		status.mu.Unlock()
		activeConfig := cfg
		activeInterval, activeRetry, activeMaxRetry := interval, retry, maxRetry
		if runtimeConfigURL != "" {
			runtimeConfig, err := fetchIndexerRuntimeConfig(ctx, runtimeConfigURL, cfg.IndexerIdentityToken)
			if err != nil {
				failures++
				status.mu.Lock()
				status.lastError = "runtime configuration: " + err.Error()
				status.mu.Unlock()
				delay := retry << min(failures-1, 8)
				if delay > maxRetry {
					delay = maxRetry
				}
				logger.Warn("ledger indexer waiting for runtime config", "attempt", failures, "retry_in", delay, "error", err)
				if !wait(ctx, delay) {
					return
				}
				continue
			}
			activeConfig.LedgerClusterID = runtimeConfig.InstanceID
			activeConfig.LedgerGitBranch = runtimeConfig.Branch
			activeConfig.LedgerGitRemoteURL = runtimeConfig.RemoteURL
			activeConfig.LedgerGitReadToken = runtimeConfig.ReadToken
			activeConfig.LedgerGitSyncEnabled = true
			activeInterval = secondsOr(runtimeConfig.IntervalSeconds, interval)
			activeRetry = secondsOr(runtimeConfig.RetryInitialSeconds, retry)
			activeMaxRetry = secondsOr(runtimeConfig.RetryMaximumSeconds, maxRetry)
			if err := app.ValidateIndexerConfig(activeConfig); err != nil {
				failures++
				status.mu.Lock()
				status.lastError = "runtime configuration is invalid: " + err.Error()
				status.mu.Unlock()
				delay := activeRetry << min(failures-1, 8)
				if delay > activeMaxRetry {
					delay = activeMaxRetry
				}
				logger.Warn("ledger indexer runtime config invalid", "attempt", failures, "retry_in", delay, "error", err)
				if !wait(ctx, delay) {
					return
				}
				continue
			}
		}
		requestBoundary, boundaryErr := app.PendingLedgerIndexRequestBoundary(ctx, activeConfig)
		if boundaryErr != nil {
			logger.Warn("read ledger index request boundary", "error", boundaryErr)
		}
		err := app.SyncLedgerGitCheckout(ctx, activeConfig)
		var result app.LedgerIndexResult
		if err == nil {
			result, err = app.RunLedgerIndexOnce(ctx, activeConfig)
		}
		if err != nil {
			failures++
			status.mu.Lock()
			status.lastError = err.Error()
			status.mu.Unlock()
			delay := activeRetry << min(failures-1, 8)
			if delay > activeMaxRetry {
				delay = activeMaxRetry
			}
			logger.Warn("ledger indexer failed", "attempt", failures, "retry_in", delay, "error", err)
			if !wait(ctx, delay) {
				return
			}
			continue
		}
		failures = 0
		status.mu.Lock()
		status.lastSuccess = time.Now().UTC()
		status.lastError = ""
		status.lastRevision = result.RevisionID
		status.mu.Unlock()
		if err := app.CompleteLedgerIndexRequests(ctx, activeConfig, requestBoundary); err != nil {
			logger.Warn("complete ledger index requests", "error", err)
		}
		logger.Info("ledger indexer complete", "revision", result.RevisionID, "skipped", result.Skipped)
		if !app.WaitForLedgerIndexTrigger(ctx, activeConfig, activeInterval) {
			return
		}
	}
}

func fetchIndexerRuntimeConfig(ctx context.Context, endpoint, token string) (app.IndexerRuntimeConfig, error) {
	if strings.TrimSpace(token) == "" {
		return app.IndexerRuntimeConfig{}, errors.New("INDEXER_IDENTITY_TOKEN is required")
	}
	requestCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, endpoint, nil)
	if err != nil {
		return app.IndexerRuntimeConfig{}, err
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := (&http.Client{Timeout: 10 * time.Second}).Do(request)
	if err != nil {
		return app.IndexerRuntimeConfig{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return app.IndexerRuntimeConfig{}, fmt.Errorf("HTTP %d: %s", response.StatusCode, strings.TrimSpace(string(body)))
	}
	var config app.IndexerRuntimeConfig
	if err := json.NewDecoder(response.Body).Decode(&config); err != nil {
		return app.IndexerRuntimeConfig{}, err
	}
	return config, nil
}

func secondsOr(value int, fallback time.Duration) time.Duration {
	if value <= 0 {
		return fallback
	}
	return time.Duration(value) * time.Second
}

func (s *indexerStatus) health(writer http.ResponseWriter, _ *http.Request) { s.respond(writer, false) }
func (s *indexerStatus) ready(writer http.ResponseWriter, _ *http.Request)  { s.respond(writer, true) }
func (s *indexerStatus) respond(writer http.ResponseWriter, requireReady bool) {
	s.mu.RLock()
	body := map[string]any{"attempts": s.attempts, "lastAttempt": s.lastAttempt, "lastSuccess": s.lastSuccess, "lastError": s.lastError, "lastRevision": s.lastRevision}
	firstIndexSucceeded := !s.lastSuccess.IsZero()
	ok := !requireReady || (firstIndexSucceeded && s.lastError == "")
	s.mu.RUnlock()
	body["ok"] = ok
	body["firstIndexSucceeded"] = firstIndexSucceeded
	writer.Header().Set("Content-Type", "application/json")
	if !ok {
		writer.WriteHeader(http.StatusServiceUnavailable)
	}
	_ = json.NewEncoder(writer).Encode(body)
}
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
func wait(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
func durationEnv(name string, fallback time.Duration) time.Duration {
	value, err := strconv.Atoi(os.Getenv(name))
	if err != nil || value < 1 {
		return fallback
	}
	return time.Duration(value) * time.Second
}
func intEnv(name string, fallback int) int {
	value, err := strconv.Atoi(os.Getenv(name))
	if err != nil || value < 1 {
		return fallback
	}
	return value
}
