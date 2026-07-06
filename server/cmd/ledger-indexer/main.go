package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

func main() {
	cfg := app.LoadConfig()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	app.StartLedgerScheduler(cfg)
	app.StartGitHubEventsPoller(cfg)

	interval := indexInterval()
	if interval > 0 {
		log.Printf("ledger indexer running every %s", interval)
	}
	if err := app.RunLedgerIndexLoop(ctx, cfg, interval); err != nil && err != context.Canceled {
		log.Fatal(err)
	}
}

func indexInterval() time.Duration {
	raw := os.Getenv("LEDGER_INDEX_INTERVAL_SECONDS")
	if raw == "" {
		return 0
	}
	seconds, err := strconv.ParseFloat(raw, 64)
	if err != nil || seconds <= 0 {
		return 0
	}
	return time.Duration(seconds * float64(time.Second))
}
