package main

import (
	"context"
	"errors"
	"fmt"
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
	"github.com/borui/beancount-ledger-web/server/internal/httpservice"
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
	application.StartGmailPolling(ctx)
	server := newHTTPServer(addr, application)
	logger.Info("ledger web listening", "addr", addr)
	services := []httpService{{Server: server, Listener: listener}}
	if metricsHandler := application.MetricsHandler(); metricsHandler != nil {
		metricsListener, err := net.Listen("tcp", cfg.MetricsAddr)
		if err != nil {
			_ = listener.Close()
			return fmt.Errorf("listen for metrics on %s: %w", cfg.MetricsAddr, err)
		}
		metricsServer := newMetricsHTTPServer(cfg.MetricsAddr, metricsHandler)
		services = append(services, httpService{Server: metricsServer, Listener: metricsListener})
		logger.Info("prometheus metrics listening", "addr", cfg.MetricsAddr)
	}
	return serveHTTPServices(ctx, services...)
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

func newMetricsHTTPServer(addr string, handler http.Handler) *http.Server {
	return httpservice.NewMetricsServer(addr, handler)
}

type httpService = httpservice.Service

func serveHTTP(ctx context.Context, server *http.Server, listener net.Listener) error {
	return serveHTTPServices(ctx, httpService{Server: server, Listener: listener})
}

func serveHTTPServices(ctx context.Context, services ...httpService) error {
	return httpservice.Serve(ctx, shutdownTimeout, services...)
}
