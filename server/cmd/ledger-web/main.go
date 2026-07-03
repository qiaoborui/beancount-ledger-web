package main

import (
	"log"
	"net/http"
	_ "net/http/pprof"
	"os"
	"strings"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

func main() {
	if pprofAddr := strings.TrimSpace(os.Getenv("PPROF_ADDR")); pprofAddr != "" {
		go func() {
			log.Printf("pprof listening on %s", pprofAddr)
			log.Print(http.ListenAndServe(pprofAddr, nil))
		}()
	}

	cfg := app.LoadConfig()
	app.StartLedgerScheduler(cfg)
	router := app.NewRouter(cfg)
	addr := ":" + cfg.Port
	log.Printf("ledger web listening on %s", addr)
	if err := http.ListenAndServe(addr, router); err != nil {
		log.Fatal(err)
	}
}
