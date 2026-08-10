package main

import (
	"context"
	"errors"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/app"
	"github.com/borui/beancount-ledger-web/server/internal/logging"
)

const shutdownTimeout = 10 * time.Second

func main() {
	logger := logging.New(logging.LoadConfig())
	if err := run(logger); err != nil {
		log.Fatal(err)
	}
}

func run(logger *slog.Logger) error {
	workers, err := workerCount()
	if err != nil {
		return err
	}
	port := strings.TrimSpace(os.Getenv("PORT"))
	if port == "" {
		port = "8080"
	}
	server := newHTTPServer(":"+port, app.NewZIPWorkerHandler(workers))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	serveErr := make(chan error, 1)
	go func() {
		serveErr <- server.ListenAndServe()
	}()
	logger.Info("ZIP worker listening", "addr", server.Addr, "workers", workers)
	select {
	case err := <-serveErr:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		return errors.Join(server.Shutdown(shutdownCtx), normalizeServerError(<-serveErr))
	}
}

// newHTTPServer returns the ZIP worker HTTP server with explicit timeouts so
// slow or stalled clients cannot hold connections open indefinitely.
// ReadHeaderTimeout (10s) rejects stalled header reads, ReadTimeout (30s) covers
// the multi-MB archive upload, and IdleTimeout (60s) bounds idle keep-alive
// connections. WriteTimeout is generous (15m) because a legitimate password
// search may run long: the caller cancels the request context on its own import
// timeout, so the worker must not cut off an in-flight search with a short
// write deadline.
func newHTTPServer(addr string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      15 * time.Minute,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
}

func workerCount() (int, error) {
	raw := strings.TrimSpace(os.Getenv("ZIP_WORKERS"))
	if raw == "" {
		return runtime.NumCPU(), nil
	}
	workers, err := strconv.Atoi(raw)
	if err != nil || workers < 1 || workers > 64 {
		return 0, errors.New("ZIP_WORKERS must be between 1 and 64")
	}
	return workers, nil
}

func normalizeServerError(err error) error {
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
