package app

import (
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
)

type Server struct {
	cfg     Config
	cache   *LedgerCache
	writer  *LedgerWriter
	limiter *RateLimiter
}

func NewRouter(cfg Config) *gin.Engine {
	cache := NewLedgerCache(cfg)
	server := &Server{cfg: cfg, cache: cache, writer: NewLedgerWriter(cfg, cache), limiter: NewRateLimiter()}
	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery(), sameOriginMiddleware())
	server.registerAPI(router.Group("/api"))
	if cfg.ServeStatic {
		router.NoRoute(server.staticFallback)
	} else {
		router.NoRoute(func(c *gin.Context) {
			c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
		})
	}
	return router
}

func (s *Server) registerAPI(api *gin.RouterGroup) {
	api.GET("/health", s.health)
	api.POST("/auth/login", s.login)
	api.POST("/auth/lock", s.lockSensitive)
	api.POST("/auth/logout", s.logout)
	api.GET("/auth/me", s.me)
	api.GET("/passkey/status", s.passkeyStatus)
	api.POST("/passkey/login/options", s.passkeyLoginOptions)
	api.POST("/passkey/login/verify", s.passkeyLoginVerify)
	api.POST("/passkey/register/options", s.passkeyRegisterOptions)
	api.POST("/passkey/register/verify", s.passkeyRegisterVerify)

	ledger := api.Group("/ledger")
	ledger.GET("/version", s.ledgerVersion)
	ledger.GET("/summary", s.summary)
	ledger.GET("/transactions", s.transactions)
	ledger.POST("/transactions", s.reverseTransaction)
	ledger.PUT("/transactions", s.updateTransaction)
	ledger.DELETE("/transactions", s.deleteTransaction)
	ledger.GET("/balances", s.balances)
	ledger.GET("/budget", s.budget)
	ledger.GET("/income-statement", s.incomeStatement)
	ledger.GET("/dashboard", s.dashboard)
	ledger.GET("/accounts", s.accounts)
	ledger.POST("/accounts", s.appendAccount)
	ledger.GET("/accounts/detail", s.accountDetail)
	ledger.GET("/account-status", s.accountStatus)
	ledger.GET("/reconciliation", s.reconciliation)
	ledger.POST("/reconciliation", s.reconcile)
	ledger.POST("/append", s.appendEntry)
	ledger.POST("/append-batch", s.appendBatch)
	ledger.GET("/insights", s.insights)
	ledger.GET("/notifications", s.notifications)
	ledger.PATCH("/notifications", s.updateNotifications)
	ledger.POST("/imports/preview", s.importsPreview)
	ledger.POST("/imports/commit", s.importsCommit)

	api.POST("/ai/parse", s.aiParse)
	api.POST("/ai/chat", s.aiChat)
	api.GET("/git/status", s.gitStatus)
	api.POST("/git/pull", s.gitPull)
	api.POST("/git/commit", s.gitCommit)
	api.GET("/push/subscription", s.pushStatus)
	api.POST("/push/subscription", s.pushSave)
	api.DELETE("/push/subscription", s.pushDelete)
	api.PUT("/push/subscription", s.pushTest)
	api.POST("/push/notify", s.pushNotify)
}

func (s *Server) health(c *gin.Context) {
	_, ledgerErr := os.Stat(s.cfg.LedgerRoot)
	_, mainErr := os.Stat(mainBeanPath(s.cfg))
	_, runtimeErr := os.Stat(s.cfg.RuntimeDir)
	ok := ledgerErr == nil && mainErr == nil
	c.JSON(status(ok, http.StatusOK, http.StatusServiceUnavailable), gin.H{
		"ok": ok, "uptimeSeconds": int(time.Since(startedAt).Seconds()),
		"ledgerRootExists": ledgerErr == nil, "mainBeanExists": mainErr == nil, "runtimeDirExists": runtimeErr == nil,
	})
}

var startedAt = time.Now()
