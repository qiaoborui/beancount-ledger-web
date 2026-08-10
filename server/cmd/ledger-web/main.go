package main

import (
	"context"
	"errors"
	"log"
	"log/slog"
	"net"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
	_ "time/tzdata"

	"github.com/borui/beancount-ledger-web/server/internal/app"
	"github.com/borui/beancount-ledger-web/server/internal/logging"
)

const shutdownTimeout = 10 * time.Second

func main() {
	logger := logging.New(logging.LoadConfig())
	if pprofAddr := strings.TrimSpace(os.Getenv("PPROF_ADDR")); pprofAddr != "" {
		go func() {
			logger.Info("pprof listening", "addr", pprofAddr)
			if err := http.ListenAndServe(pprofAddr, nil); err != nil {
				logger.Error("pprof server stopped", "error", err)
			}
		}()
	}
	if err := run(logger); err != nil {
		log.Fatal(err)
	}
}

func run(logger *slog.Logger) (err error) {
	cfg := app.LoadWebConfig()
	if err := app.ValidateWebConfig(cfg); err != nil {
		return err
	}
	application, err := app.NewApplicationWithLogger(cfg, logger)
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
	logger.Info("ledger web listening", "addr", addr)
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
