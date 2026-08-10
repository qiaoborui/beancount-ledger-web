package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
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

func run() (err error) {
	cfg := app.LoadSelfHostedConfig()
	if err := app.ValidateSelfHostedConfig(cfg); err != nil {
		return err
	}
	application, err := app.NewApplication(cfg)
	if err != nil {
		return err
	}
	defer func() {
		err = errors.Join(err, application.Close())
	}()

	addr := ":" + cfg.Port
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	server := newHTTPServer(addr, application)
	log.Printf("self-hosted ledger web listening on %s", addr)
	return serveHTTP(ctx, server, listener)
}

// newHTTPServer returns the main HTTP server with explicit timeouts so slow or
// stalled clients cannot hold connections open indefinitely. WriteTimeout must
// cover the longest supported response: /api/ai/agent/turn streams an SSE
// response and /api/integrations/telegram/webhook stays open while the agent
// replies, both bounded internally by agentServiceRequestTimeout (14 minutes),
// so 15 minutes keeps streaming responses inside the write deadline. ReadTimeout
// (30s) comfortably covers multi-MB import uploads on local networks, and
// IdleTimeout keeps browser keep-alive connections alive between requests.
func newHTTPServer(addr string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      15 * time.Minute,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
}

func serveHTTP(ctx context.Context, server *http.Server, listener net.Listener) error {
	serveErr := make(chan error, 1)
	go func() {
		serveErr <- server.Serve(listener)
	}()

	select {
	case err := <-serveErr:
		return normalizeHTTPServerError(err)
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		shutdownErr := server.Shutdown(shutdownCtx)
		if shutdownErr != nil {
			shutdownErr = errors.Join(shutdownErr, server.Close())
		}
		return errors.Join(shutdownErr, normalizeHTTPServerError(<-serveErr))
	}
}

func normalizeHTTPServerError(err error) error {
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
