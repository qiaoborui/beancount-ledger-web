package main

import (
	"log"
	"net/http"
	"os"

	"github.com/borui/beancount-ledger-web/server/internal/app"
	"github.com/gin-gonic/gin"
)

func main() {
	if os.Getenv("GIN_MODE") == "" {
		gin.SetMode(gin.ReleaseMode)
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
