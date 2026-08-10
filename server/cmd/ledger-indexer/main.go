package main

import (
	"context"
	"log"

	"github.com/borui/beancount-ledger-web/server/internal/app"
	"github.com/borui/beancount-ledger-web/server/internal/logging"
)

func main() {
	logger := logging.New(logging.LoadConfig())
	cfg := app.LoadIndexerConfig()
	if err := app.ValidateIndexerConfig(cfg); err != nil {
		log.Fatal(err)
	}
	if err := app.SyncLedgerGitCheckout(context.Background(), cfg); err != nil {
		log.Fatal(err)
	}
	result, err := app.RunLedgerIndexOnce(context.Background(), cfg)
	if err != nil {
		log.Fatal(err)
	}
	if result.Skipped {
		logger.Info("ledger indexer skipped", "revision", result.RevisionID, "version", result.LedgerVersion.Version, "reason", result.SkipReason)
		return
	}
	logger.Info("ledger indexer indexed", "revision", result.RevisionID, "version", result.LedgerVersion.Version, "files", result.LedgerVersion.FileCount)
}
