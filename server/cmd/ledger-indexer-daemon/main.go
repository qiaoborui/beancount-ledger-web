package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/app"
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
	cfg := app.LoadIndexerConfig()
	if err := app.ValidateIndexerConfig(cfg); err != nil {
		log.Fatal(err)
	}
	status := &indexerStatus{}
	interval := durationEnv("LEDGER_INDEX_INTERVAL_SECONDS", 60*time.Second)
	retry := durationEnv("LEDGER_INDEX_RETRY_INITIAL_SECONDS", 5*time.Second)
	maxRetry := durationEnv("LEDGER_INDEX_RETRY_MAX_SECONDS", time.Minute)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go runIndexer(ctx, cfg, status, interval, retry, maxRetry)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", status.health)
	mux.HandleFunc("/ready", status.ready)
	server := &http.Server{Addr: ":" + strconv.Itoa(intEnv("LEDGER_INDEX_HEALTH_PORT", 3001)), Handler: mux}
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

func runIndexer(ctx context.Context, cfg app.Config, status *indexerStatus, interval, retry, maxRetry time.Duration) {
	failures := 0
	for {
		status.mu.Lock()
		status.attempts++
		status.lastAttempt = time.Now().UTC()
		status.mu.Unlock()
		requestBoundary, boundaryErr := app.PendingLedgerIndexRequestBoundary(ctx, cfg)
		if boundaryErr != nil {
			log.Printf("read ledger index request boundary: %v", boundaryErr)
		}
		err := app.SyncLedgerGitCheckout(ctx, cfg)
		var result app.LedgerIndexResult
		if err == nil {
			result, err = app.RunLedgerIndexOnce(ctx, cfg)
		}
		if err != nil {
			failures++
			status.mu.Lock()
			status.lastError = err.Error()
			status.mu.Unlock()
			delay := retry << min(failures-1, 8)
			if delay > maxRetry {
				delay = maxRetry
			}
			log.Printf("ledger indexer failed attempt=%d retryIn=%s error=%v", failures, delay, err)
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
		if err := app.CompleteLedgerIndexRequests(ctx, cfg, requestBoundary); err != nil {
			log.Printf("complete ledger index requests: %v", err)
		}
		log.Printf("ledger indexer complete revision=%d skipped=%t", result.RevisionID, result.Skipped)
		if !app.WaitForLedgerIndexTrigger(ctx, cfg, interval) {
			return
		}
	}
}

func (s *indexerStatus) health(writer http.ResponseWriter, _ *http.Request) { s.respond(writer, false) }
func (s *indexerStatus) ready(writer http.ResponseWriter, _ *http.Request)  { s.respond(writer, true) }
func (s *indexerStatus) respond(writer http.ResponseWriter, allowLastError bool) {
	s.mu.RLock()
	body := map[string]any{"attempts": s.attempts, "lastAttempt": s.lastAttempt, "lastSuccess": s.lastSuccess, "lastError": s.lastError, "lastRevision": s.lastRevision}
	ok := !s.lastSuccess.IsZero() && (allowLastError || s.lastError == "")
	s.mu.RUnlock()
	body["ok"] = ok
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
