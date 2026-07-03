package main

import (
	"log"
	"net/http"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

func main() {
	cfg := app.LoadConfig()
	app.StartLedgerScheduler(cfg)
	router := app.NewRouter(cfg)
	addr := ":" + cfg.Port
	log.Printf("ledger web listening on %s", addr)
	if err := http.ListenAndServe(addr, router); err != nil {
		log.Fatal(err)
	}
}
