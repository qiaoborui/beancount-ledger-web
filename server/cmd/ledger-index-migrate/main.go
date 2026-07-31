package main

import (
	"context"
	"flag"
	"log"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

func main() {
	confirm := flag.Bool("confirm-drop-legacy-bean-payloads", false, "confirm the maintenance operation that drops legacy bean payload columns")
	flag.Parse()
	if !*confirm {
		log.Fatal("--confirm-drop-legacy-bean-payloads is required")
	}

	cfg := app.LoadIndexerConfig()
	if err := app.ValidateIndexerConfig(cfg); err != nil {
		log.Fatal(err)
	}
	store, err := app.NewLedgerIndexStore(cfg)
	if err != nil {
		log.Fatal(err)
	}
	defer store.Close()
	if err := store.MigrateLegacyBeanPayloads(context.Background()); err != nil {
		log.Fatal(err)
	}
	log.Print("legacy ledger bean payload columns migrated and removed")
}
