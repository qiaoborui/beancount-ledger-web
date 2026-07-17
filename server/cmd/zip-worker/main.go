package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

const shutdownTimeout = 10 * time.Second

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	workers, err := workerCount()
	if err != nil {
		return err
	}
	port := strings.TrimSpace(os.Getenv("PORT"))
	if port == "" {
		port = "8080"
	}
	server := &http.Server{
		Addr:              ":" + port,
		Handler:           app.NewZIPWorkerHandler(workers),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	serveErr := make(chan error, 1)
	go func() {
		serveErr <- server.ListenAndServe()
	}()
	log.Printf("ZIP worker listening on %s with %d workers", server.Addr, workers)
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
