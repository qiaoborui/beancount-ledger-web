package main

import (
	"context"
	"errors"
	"log"
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
)

const shutdownTimeout = 10 * time.Second

func main() {
	if pprofAddr := strings.TrimSpace(os.Getenv("PPROF_ADDR")); pprofAddr != "" {
		go func() {
			log.Printf("pprof listening on %s", pprofAddr)
			log.Print(http.ListenAndServe(pprofAddr, nil))
		}()
	}
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() (err error) {
	cfg := app.LoadWebConfig()
	if err := app.ValidateWebConfig(cfg); err != nil {
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
	server := &http.Server{Addr: addr, Handler: application}
	log.Printf("ledger web listening on %s", addr)
	return serveHTTP(ctx, server, listener)
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
