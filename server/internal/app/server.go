package app

import (
	"context"
	"database/sql"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/gin-contrib/gzip"
	"github.com/gin-gonic/gin"
)

type Server struct {
	cfg              Config
	runtimeStore     RuntimeStore
	indexStore       *LedgerIndexStore
	indexStoreErr    error
	db               *sql.DB
	cache            *LedgerCache
	writer           *LedgerWriter
	accountService   *AccountService
	readService      ledgerReadService
	reconcileService *ReconciliationService
	txService        *TransactionService
	limiter          RateLimiter
}

type ledgerReadService interface {
	Version(context.Context) (LedgerVersion, error)
	Snapshot(context.Context) (*LedgerSnapshot, error)
	SnapshotLite(context.Context) (*LedgerSnapshot, error)
	Bootstrap(string, string, bool, ...string) (gin.H, error)
	BootstrapLite(string, string, bool, ...string) (gin.H, error)
	Summary(string, string, bool, ...string) (gin.H, error)
	Transactions(string, string, bool) (gin.H, error)
	Balances(context.Context) (map[string]int, []BalanceAssertion, error)
	IncomeStatement(string, string, bool, ...string) (gin.H, error)
}

func NewRouter(cfg Config) *gin.Engine {
	router, err := NewRouterWithError(cfg)
	if err != nil {
		panic(err)
	}
	return router
}

func NewRouterWithError(cfg Config) (*gin.Engine, error) {
	var runtimeStore RuntimeStore
	var indexStore *LedgerIndexStore
	var indexStoreErr error
	var db *sql.DB
	var limiter RateLimiter
	if cfg.DatabaseURL != "" {
		var err error
		db, err = openPostgres(cfg.DatabaseURL)
		if err != nil {
			return nil, err
		}
		runtimeStore, err = NewRuntimeStoreWithDB(db)
		if err != nil {
			_ = db.Close()
			return nil, err
		}
		if ledgerReadModelEnabled(cfg) {
			indexStore, indexStoreErr = NewLedgerIndexStoreWithDB(db, cfg)
		}
		limiter, err = NewPostgresRateLimiter(db)
		if err != nil {
			_ = db.Close()
			return nil, err
		}
	} else {
		var err error
		runtimeStore, err = NewRuntimeStore(cfg)
		if err != nil {
			return nil, err
		}
		if ledgerReadModelEnabled(cfg) {
			indexStore, indexStoreErr = NewLedgerIndexStore(cfg)
		}
		limiter = NewRateLimiter()
	}
	cache := NewLedgerCache(cfg)
	readService := NewLedgerReadServiceWithIndex(cache, indexStore, indexStoreErr, cfg.ReadModelStrict)
	writer := NewLedgerWriterWithRuntimeStoreAndCommodities(cfg, cache, runtimeStore, func() ([]string, error) {
		snapshot, err := readService.SnapshotLite(context.Background())
		if err != nil {
			return nil, err
		}
		return snapshot.Commodities, nil
	})
	server := &Server{cfg: cfg, runtimeStore: runtimeStore, indexStore: indexStore, indexStoreErr: indexStoreErr, cache: cache, writer: writer, accountService: NewAccountServiceWithSnapshot(cache, writer, func() (*LedgerSnapshot, error) {
		return readService.SnapshotLite(context.Background())
	}), db: db, readService: readService, reconcileService: NewReconciliationService(cache, writer), txService: NewTransactionService(cache, writer), limiter: limiter}
	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery(), corsMiddleware(), sameOriginMiddleware(), gzip.Gzip(gzip.DefaultCompression))
	router.GET("/.well-known/webauthn", server.webAuthnRelatedOrigins)
	server.registerAPI(router.Group("/api"))
	if cfg.ServeStatic {
		router.NoRoute(server.staticFallback)
	} else {
		router.NoRoute(func(c *gin.Context) {
			c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
		})
	}
	return router, nil
}

func (s *Server) registerAPI(api *gin.RouterGroup) {
	api.GET("/health", s.health)
	api.POST("/auth/login", s.login)
	api.POST("/auth/lock", s.lockSensitive)
	api.POST("/auth/logout", s.logout)

	readOnly30s := api.Group("", cacheControl(30))
	readOnly60s := api.Group("", cacheControl(60))

	readOnly30s.GET("/auth/me", s.me)
	readOnly30s.GET("/quick-unlock/status", s.quickUnlockStatus)
	readOnly60s.GET("/passkey/status", s.passkeyStatus)

	api.POST("/quick-unlock/register", s.quickUnlockRegister)
	api.POST("/quick-unlock/verify", s.quickUnlockVerify)
	api.POST("/quick-unlock/revoke", s.quickUnlockRevoke)

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
	ledgerRead60s.GET("/index-info", s.indexInfo)
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
	if s.indexStoreErr != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"ok":               false,
			"uptimeSeconds":    int(time.Since(startedAt).Seconds()),
			"ledgerReadModel":  s.cfg.LedgerReadModel,
			"readModelStrict":  s.cfg.ReadModelStrict,
			"ledgerIndexError": s.indexStoreErr.Error(),
			"runtimeBackend":   runtimeBackend(s.cfg),
		})
		return
	}
	if s.indexStore != nil {
		revision, indexed, err := s.indexStore.ActiveRevision(c.Request.Context())
		body := gin.H{
			"ok":                  err == nil && indexed,
			"uptimeSeconds":       int(time.Since(startedAt).Seconds()),
			"ledgerReadModel":     s.cfg.LedgerReadModel,
			"readModelStrict":     s.cfg.ReadModelStrict,
			"ledgerIndexActive":   indexed,
			"ledgerIndexSource":   sanitizeLedgerIndexSource(s.cfg),
			"runtimeBackend":      runtimeBackend(s.cfg),
			"runtimeDirRequired":  runtimeBackend(s.cfg) == "filesystem",
			"ledgerVersion":       revision.LedgerVersion.Version,
			"ledgerVersionFiles":  revision.LedgerVersion.FileCount,
			"ledgerIndexedAtUnix": revision.IndexedAt.Unix(),
			"ledgerIndexGitSHA":   revision.GitSHA,
		}
		if err != nil {
			body["error"] = err.Error()
		}
		c.JSON(status(err == nil && indexed, http.StatusOK, http.StatusServiceUnavailable), body)
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"ok": false, "error": err.Error()})
		return
	}
	_, ledgerErr := os.Stat(s.cfg.LedgerRoot)
	_, mainErr := os.Stat(mainBeanPath(s.cfg))
	runtimeDirRequired := runtimeBackend(s.cfg) == "filesystem"
	runtimeDirExists := true
	if runtimeDirRequired {
		_, runtimeErr := os.Stat(s.cfg.RuntimeDir)
		runtimeDirExists = runtimeErr == nil
	}
	ok := ledgerErr == nil && mainErr == nil
	body := gin.H{
		"ok": ok, "uptimeSeconds": int(time.Since(startedAt).Seconds()),
		"ledgerRootExists": ledgerErr == nil, "mainBeanExists": mainErr == nil,
		"runtimeBackend":     runtimeBackend(s.cfg),
		"runtimeDirRequired": runtimeDirRequired,
	}
	if runtimeDirRequired {
		body["runtimeDirExists"] = runtimeDirExists
	}
	c.JSON(status(ok, http.StatusOK, http.StatusServiceUnavailable), body)
}

func (s *Server) indexInfo(c *gin.Context) {
	if s.indexStore == nil {
		c.JSON(http.StatusOK, gin.H{"readModel": s.cfg.LedgerReadModel, "enabled": false})
		return
	}
	revision, indexed, err := s.indexStore.ActiveRevision(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"readModel": s.cfg.LedgerReadModel, "enabled": false, "error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"readModel": s.cfg.LedgerReadModel,
		"enabled":   true,
		"active":    indexed,
		"gitSHA":    revision.GitSHA,
		"source":    sanitizeLedgerIndexSource(s.cfg),
		"version":   revision.LedgerVersion.Version,
		"fileCount": revision.LedgerVersion.FileCount,
		"indexedAt": revision.IndexedAt.UTC().Format(time.RFC3339),
	})
}

func sanitizeLedgerIndexSource(cfg Config) string {
	source := ledgerIndexSourceKey(cfg)
	// Strip credentials from URLs (e.g. https://token@host -> https://host)
	if idx := strings.Index(source, "@"); idx != -1 {
		if protoEnd := strings.Index(source, "://"); protoEnd != -1 && protoEnd < idx {
			source = source[:protoEnd+3] + source[idx+1:]
		}
	}
	return source
}

var startedAt = time.Now()
