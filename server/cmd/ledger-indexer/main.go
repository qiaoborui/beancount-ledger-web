package main

import (
	"context"
	"log"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

func main() {
	cfg := app.LoadIndexerConfig()
	if err := app.ValidateIndexerConfig(cfg); err != nil {
		log.Fatal(err)
	}
	result, err := app.RunLedgerIndexOnce(context.Background(), cfg)
	if err != nil {
		log.Fatal(err)
	}
	if result.Skipped {
		log.Printf("ledger indexer skipped revision=%d version=%s reason=%s", result.RevisionID, result.LedgerVersion.Version, result.SkipReason)
		return
	}
	log.Printf("ledger indexer indexed revision=%d version=%s files=%d", result.RevisionID, result.LedgerVersion.Version, result.LedgerVersion.FileCount)
}
