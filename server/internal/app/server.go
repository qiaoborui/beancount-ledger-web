package app

import (
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/gin-contrib/gzip"
	"github.com/gin-gonic/gin"
)

type Server struct {
	cfg              Config
	runtimeStore     RuntimeStore
	runtimeFileStore RuntimeFileStore
	cache            *LedgerCache
	writer           *LedgerWriter
	accountService   *AccountService
	readService      *LedgerReadService
	reconcileService *ReconciliationService
	txService        *TransactionService
	limiter          *RateLimiter
	events           *EventHub
}

func NewRouter(cfg Config) *gin.Engine {
	runtimeStore := MustRuntimeStore(cfg)
	runtimeFileStore := MustRuntimeFileStore(cfg)
	cache := NewLedgerCache(cfg)
	writer := NewLedgerWriterWithRuntimeStore(cfg, cache, runtimeStore)
	server := &Server{cfg: cfg, runtimeStore: runtimeStore, runtimeFileStore: runtimeFileStore, cache: cache, writer: writer, accountService: NewAccountService(cache, writer), readService: NewLedgerReadService(cache), reconcileService: NewReconciliationService(cache, writer), txService: NewTransactionService(cache, writer), limiter: NewRateLimiter(), events: ledgerEventHub}
	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery(), sameOriginMiddleware(), gzip.Gzip(gzip.DefaultCompression))
	router.GET("/.well-known/webauthn", server.webAuthnRelatedOrigins)
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

	readOnly30s := api.Group("", cacheControl(30))
	readOnly60s := api.Group("", cacheControl(60))

	readOnly30s.GET("/auth/me", s.me)
	readOnly60s.GET("/passkey/status", s.passkeyStatus)

	api.POST("/passkey/login/options", s.passkeyLoginOptions)
	api.POST("/passkey/login/verify", s.passkeyLoginVerify)
	api.POST("/passkey/register/options", s.passkeyRegisterOptions)
	api.POST("/passkey/register/verify", s.passkeyRegisterVerify)

	ledger := api.Group("/ledger")

	ledgerRead30s := ledger.Group("", cacheControl(30))
	ledgerRead30s.GET("/bootstrap", s.ledgerBootstrap)
	ledgerRead30s.GET("/summary", s.summary)
	ledgerRead30s.GET("/transactions", s.transactions)
	ledgerRead30s.GET("/income-statement", s.incomeStatement)
	ledgerRead30s.GET("/dashboard", s.dashboard)
	ledgerRead30s.GET("/reconciliation", s.reconciliation)
	ledgerRead30s.GET("/notifications", s.notifications)

	ledgerRead60s := ledger.Group("", cacheControl(60))
	ledgerRead60s.GET("/version", s.ledgerVersion)
	ledgerRead60s.GET("/entries", s.ledgerEntries)
	ledgerRead60s.GET("/balances", s.balances)
	ledgerRead60s.GET("/investments", s.investments)
	ledgerRead60s.GET("/accounts/detail", s.accountDetail)
	ledgerRead60s.GET("/account-status", s.accountStatus)

	ledgerRead300s := ledger.Group("", cacheControl(300))
	ledgerRead300s.GET("/accounts", s.accounts)
	ledgerRead300s.GET("/insights", s.insights)

	ledger.POST("/transactions", s.reverseTransaction)
	ledger.PUT("/transactions", s.updateTransaction)
	ledger.DELETE("/transactions", s.deleteTransaction)
	ledger.POST("/accounts", s.appendAccount)
	ledger.POST("/accounts/operations", s.applyAccountOperations)
	ledger.POST("/reconciliation", s.reconcile)
	ledger.POST("/append", s.appendEntry)
	ledger.POST("/append-batch", s.appendBatch)
	ledger.PATCH("/notifications", s.updateNotifications)

	ledgerRead30s.GET("/imports/providers", s.importsProviders)
	ledgerRead30s.GET("/imports/documents", s.importsDocuments)
	ledgerRead30s.GET("/imports/documents/file", s.importsDocumentFile)
	ledger.POST("/imports/preview", s.importsPreview)
	ledger.POST("/imports/commit", s.importsCommit)

	ledgerRead30s.GET("/editor/files", s.editorFiles)
	ledgerRead30s.GET("/editor/file", s.editorFile)
	ledger.PUT("/editor/file", s.saveEditorFile)

	api.POST("/ai/parse", s.aiParse)
	api.POST("/ai/chat", s.aiChat)
	api.POST("/ai/accounts-chat", s.aiAccountsChat)

	readOnly30s.GET("/git/status", s.gitStatus)
	readOnly30s.GET("/git/diff", s.gitDiff)
	api.POST("/git/pull", s.gitPull)
	api.POST("/git/commit", s.gitCommit)

	readOnly60s.GET("/push/subscription", s.pushStatus)
	api.POST("/push/subscription", s.pushSave)
	api.DELETE("/push/subscription", s.pushDelete)
	api.PUT("/push/subscription", s.pushTest)
	api.POST("/push/notify", s.pushNotify)
}

func cacheControl(maxAge int) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Cache-Control", fmt.Sprintf("private, max-age=%d", maxAge))
		c.Next()
	}
}

func (s *Server) health(c *gin.Context) {
	if err := ensureLedgerReady(s.cfg); err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"ok": false, "error": err.Error()})
		return
	}
	_, ledgerErr := os.Stat(s.cfg.LedgerRoot)
	_, mainErr := os.Stat(mainBeanPath(s.cfg))
	runtimeDirRequired := filesystemRuntimeBackend(s.cfg.RuntimeStore) || filesystemRuntimeBackend(s.cfg.RuntimeFileStore)
	runtimeDirExists := true
	if runtimeDirRequired {
		_, runtimeErr := os.Stat(s.cfg.RuntimeDir)
		runtimeDirExists = runtimeErr == nil
	}
	ok := ledgerErr == nil && mainErr == nil
	body := gin.H{
		"ok": ok, "uptimeSeconds": int(time.Since(startedAt).Seconds()),
		"ledgerRootExists": ledgerErr == nil, "mainBeanExists": mainErr == nil,
		"runtimeStore": s.cfg.RuntimeStore, "runtimeFileStore": s.cfg.RuntimeFileStore,
		"runtimeDirRequired": runtimeDirRequired,
	}
	if runtimeDirRequired {
		body["runtimeDirExists"] = runtimeDirExists
	}
	c.JSON(status(ok, http.StatusOK, http.StatusServiceUnavailable), body)
}

func filesystemRuntimeBackend(value string) bool {
	return value == "" || value == "file" || value == "filesystem"
}

var startedAt = time.Now()
