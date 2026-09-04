// Package httpservice coordinates the application and private auxiliary HTTP
// listeners owned by a server process.
package httpservice

import (
	"context"
	"errors"
	"net"
	"net/http"
	"time"
)

// Service pairs an HTTP server with its already-open listener.
type Service struct {
	Server   *http.Server
	Listener net.Listener
}

// NewMetricsServer returns a hardened server that exposes only GET /metrics.
func NewMetricsServer(addr string, handler http.Handler) *http.Server {
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", handler)
	return &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    64 << 10,
	}
}

// Serve runs all listeners as one lifecycle: a process signal or an unexpected
// listener failure gracefully shuts down every sibling server.
func Serve(ctx context.Context, shutdownTimeout time.Duration, services ...Service) error {
	if len(services) == 0 {
		return errors.New("at least one HTTP service is required")
	}
	serveErr := make(chan error, len(services))
	for _, service := range services {
		go func(service Service) {
			serveErr <- service.Server.Serve(service.Listener)
		}(service)
	}

	completed := 0
	var errs []error
	select {
	case err := <-serveErr:
		completed = 1
		errs = append(errs, normalizeServerError(err))
	case <-ctx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	for _, service := range services {
		shutdownErr := service.Server.Shutdown(shutdownCtx)
		if shutdownErr != nil {
			shutdownErr = errors.Join(shutdownErr, service.Server.Close())
		}
		errs = append(errs, shutdownErr)
	}
	for completed < len(services) {
		errs = append(errs, normalizeServerError(<-serveErr))
		completed++
	}
	return errors.Join(errs...)
}

func normalizeServerError(err error) error {
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
