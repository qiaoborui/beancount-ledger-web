package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/app"
	"github.com/borui/beancount-ledger-web/server/internal/logging"
)

const shutdownTimeout = 10 * time.Second

func main() {
	logger := logging.New(logging.LoadConfig())
	if err := run(logger, os.Args[1:], os.Stdout); err != nil {
		log.Fatal(err)
	}
}

func run(logger *slog.Logger, args []string, output io.Writer) (err error) {
	command, err := selfHostCommand(args)
	if err != nil {
		return err
	}
	if command == "help" {
		writeUsage(output)
		return nil
	}
	cfg := app.LoadSelfHostedConfig()
	if err := app.ValidateSelfHostedConfig(cfg); err != nil {
		return err
	}
	if command == "recover-install-code" {
		code, err := app.RecoverSelfHostedInstallCode(context.Background(), cfg, logger)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(output, "New one-time install code: %s\nThe previous install code is now invalid. This rotation was recorded in runtime_config_audit.\n", code)
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
	logger.Info("self-hosted ledger web listening", "addr", addr)
	return serveHTTP(ctx, server, listener)
}

func selfHostCommand(args []string) (string, error) {
	if len(args) == 0 {
		return "serve", nil
	}
	if len(args) == 1 {
		switch args[0] {
		case "recover-install-code":
			return args[0], nil
		case "help", "--help", "-h":
			return "help", nil
		}
	}
	return "", fmt.Errorf("unknown ledger-selfhost command %q; use --help", strings.Join(args, " "))
}

func writeUsage(output io.Writer) {
	_, _ = fmt.Fprintln(output, "Usage: ledger-selfhost [recover-install-code]")
	_, _ = fmt.Fprintln(output, "  no command            start the self-hosted API server")
	_, _ = fmt.Fprintln(output, "  recover-install-code  rotate the one-time code while setup is incomplete")
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
