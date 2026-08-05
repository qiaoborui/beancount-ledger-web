package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gin-contrib/gzip"
	"github.com/gin-gonic/gin"
)

type Server struct {
	cfg                  Config
	cfgMu                sync.RWMutex
	cfgRefreshedAt       time.Time
	runtimeStore         RuntimeStore
	runtimeConfig        *RuntimeConfigStore
	gmailRepository      gmailStateRepository
	bqlHistoryRepository bqlHistoryRepository
	quickUnlocks         quickUnlockRepository
	passkeys             passkeyRepository
	agentMemories        agentMemoryRepository
	importState          importStateRepository
	indexStore           LedgerIndexPort
	indexStoreErr        error
	cache                *LedgerCache
	importers            *BillImporterRegistry
	moduleNames          []string
	notificationService  *NotificationService
	writer               *LedgerWriter
	accountService       *AccountService
	queryPort            LedgerQueryPort
	snapshotPort         LedgerSnapshotPort
	reconcileService     *ReconciliationService
	txService            *TransactionService
	limiter              RateLimiter
	agentModel           AgentModelClient
	agentTokenWrite      agentTokenWriteResolver
}

// agentTokenWriteResolver reports whether local Agent access tokens may write
// to the ledger. It is backed by the database runtime config when available,
// and defaults to read-only otherwise.
type agentTokenWriteResolver interface {
	AgentTokenWriteEnabled(context.Context) (bool, error)
}

func newRouter(cfg Config, server *Server) *gin.Engine {
	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery(), corsMiddleware(), sameOriginMiddleware(), server.configReadLock(), gzip.Gzip(gzip.DefaultCompression))
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

func (s *Server) configReadLock() gin.HandlerFunc {
	return func(c *gin.Context) {
		path := c.Request.URL.Path
		if (c.Request.Method == http.MethodPost && path == "/api/setup/install") ||
			(c.Request.Method == http.MethodPut && path == "/api/runtime-config") {
			c.Next()
			return
		}
		s.refreshConfigIfNeeded(c.Request.Context())
		s.cfgMu.RLock()
		defer s.cfgMu.RUnlock()
		c.Next()
	}
}

func (s *Server) applyConfigLocked(cfg Config) {
	s.cfg = cfg
	s.cfgRefreshedAt = time.Now()
	if s.writer != nil {
		s.writer.SetConfig(cfg)
	}
	if store, ok := s.indexStore.(*LedgerIndexStore); ok {
		store.SetConfig(cfg)
	}
}

func (s *Server) refreshConfigIfNeeded(ctx context.Context) {
	if s.runtimeConfig == nil {
		return
	}
	s.cfgMu.RLock()
	recent := time.Since(s.cfgRefreshedAt) < 2*time.Second
	s.cfgMu.RUnlock()
	if recent {
		return
	}
	// A request may call an external service that calls back into this server.
	// Do not wait for active requests to release their configuration read locks,
	// otherwise the outer request and callback can deadlock each other.
	if !s.cfgMu.TryLock() {
		return
	}
	defer s.cfgMu.Unlock()
	if time.Since(s.cfgRefreshedAt) < 2*time.Second {
		return
	}
	effective, err := s.runtimeConfig.EffectiveConfig(ctx, s.cfg)
	if err != nil {
		s.cfgRefreshedAt = time.Now()
		log.Printf("refresh database runtime configuration: %v", err)
		return
	}
	s.applyConfigLocked(effective)
}

func (s *Server) registerAPI(api *gin.RouterGroup) {
	api.GET("/health", s.health)
	api.GET("/ready", s.ready)
	api.GET("/setup/status", s.setupStatus)
	api.POST("/setup/test", s.setupTest)
	api.POST("/setup/install", s.setupInstall)
	api.GET("/indexer/config", s.indexerRuntimeConfig)
	api.GET("/runtime-config", s.runtimeConfigStatus)
	api.PUT("/runtime-config", s.runtimeConfigUpdate)
	api.POST("/auth/login", s.login)
	api.POST("/auth/lock", s.lockSensitive)
	api.POST("/auth/logout", s.logout)

	readOnly60s := api.Group("", cacheControl(60))
	authState := api.Group("", noStore())

	authState.GET("/auth/me", s.me)
	authState.GET("/onboarding", s.onboardingStatus)
	authState.POST("/onboarding/agent", s.onboardingAgent)
	authState.POST("/onboarding/initialize", s.initializeLedger)
	authState.GET("/quick-unlock/status", s.quickUnlockStatus)
	authState.GET("/passkey/status", s.passkeyStatus)
	authState.GET("/passkey/credentials", s.passkeyCredentials)
	authState.PATCH("/passkey/credentials/:id", s.renamePasskeyCredential)
	authState.DELETE("/passkey/credentials/:id", s.deletePasskeyCredential)

	api.POST("/quick-unlock/register", s.quickUnlockRegister)
	api.POST("/quick-unlock/verify", s.quickUnlockVerify)
	api.POST("/quick-unlock/revoke", s.quickUnlockRevoke)

	api.POST("/passkey/login/options", s.passkeyLoginOptions)
	api.POST("/passkey/login/verify", s.passkeyLoginVerify)
	api.POST("/passkey/register/options", s.passkeyRegisterOptions)
	api.POST("/passkey/register/verify", s.passkeyRegisterVerify)

	ledger := api.Group("/ledger")
	ledger.GET("/bootstrap", noStore(), s.ledgerBootstrap)

	ledgerRead30s := ledger.Group("", cacheControl(30))
	ledgerRead30s.GET("/summary", s.summary)
	ledgerRead30s.GET("/transactions", s.transactions)
	ledgerRead30s.GET("/income-statement", s.incomeStatement)
	ledgerRead30s.GET("/dashboard", s.dashboard)
	ledgerRead30s.GET("/home-report", s.homeReport)
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
	ledger.POST("/bql", noStore(), s.bql)
	ledger.GET("/bql-history", noStore(), s.bqlHistory)
	ledger.POST("/bql-history", noStore(), s.saveBQLHistory)
	ledger.POST("/bql-history/:id/title", noStore(), s.generateBQLHistoryTitleHandler)
	ledger.PATCH("/bql-history/:id", noStore(), s.renameBQLHistory)
	ledger.DELETE("/bql-history/:id", noStore(), s.deleteBQLHistory)
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
	ledger.GET("/imports/pending", noStore(), s.gmailPendingImports)
	ledger.GET("/imports/pending/:id", noStore(), s.gmailPendingImport)
	ledger.POST("/imports/preview", s.importsPreview)
	ledger.POST("/imports/commit", s.importsCommit)
	ledger.DELETE("/imports/pending/:id", s.gmailDismissPendingImport)

	ledgerRead30s.GET("/editor/files", s.editorFiles)
	ledgerRead30s.GET("/editor/file", s.editorFile)
	ledger.PUT("/editor/file", s.saveEditorFile)

	api.POST("/ai/parse", s.aiParse)
	api.POST("/ai/agent/turn", s.aiAgentTurn)
	api.POST("/ai/agent/interactions/:interactionID", s.aiAgentInteraction)
	api.GET("/ai/agent/sessions/:sessionID/timeline", noStore(), s.aiAgentTimeline)
	api.DELETE("/ai/agent/sessions/:sessionID", s.aiAgentSessionDelete)
	api.GET("/agent/access-tokens", noStore(), s.agentAccessTokens)
	api.POST("/agent/access-tokens", noStore(), s.createAgentAccessToken)
	api.DELETE("/agent/access-tokens/:tokenID", noStore(), s.revokeAgentAccessToken)
	api.POST("/agent/bootstrap", noStore(), s.externalAgentBootstrap)
	api.POST("/agent/model/chat/completions", s.externalAgentModelProxy)
	api.POST("/internal/agent/bootstrap", noStore(), s.internalAgentBootstrap)
	api.GET("/internal/agent/tools", s.internalAgentTools)
	api.POST("/internal/agent/tools/:toolName/preview", s.internalAgentToolPreview)
	api.POST("/internal/agent/tools/:toolName/execute", s.internalAgentToolExecute)
	api.POST("/internal/agent/model/chat/completions", s.internalAgentModelProxy)

	readOnly60s.GET("/push/subscription", s.pushStatus)
	api.POST("/push/subscription", s.pushSave)
	api.DELETE("/push/subscription", s.pushDelete)
	api.PUT("/push/subscription", s.pushTest)
	api.POST("/push/notify", s.pushNotify)

	authState.GET("/integrations/gmail/status", s.gmailStatus)
	api.POST("/integrations/gmail/connect", s.gmailConnectStart)
	api.GET("/integrations/gmail/callback", s.gmailOAuthCallback)
	api.GET("/integrations/gmail/renew", s.gmailRenew)
	api.POST("/integrations/gmail/renew", s.gmailRenew)
	api.POST("/integrations/gmail/sync", s.gmailSyncNow)
	api.DELETE("/integrations/gmail", s.gmailDisconnect)
	api.POST("/integrations/gmail/pubsub", s.gmailPubSub)
	api.GET("/integrations/gmail/drain", s.gmailDrain)
	api.POST("/integrations/gmail/drain", s.gmailDrain)
}

func cacheControl(maxAge int) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Cache-Control", fmt.Sprintf("private, max-age=%d", maxAge))
		c.Next()
	}
}

func noStore() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		c.Next()
	}
}

func (s *Server) health(c *gin.Context) {
	identity := gin.H{
		"apiVersion":   1,
		"clusterId":    ledgerClusterID(s.cfg),
		"capabilities": []string{"full-backend", "cookie-auth", "ledger-version", "ledger-agent-v1", "passkey-management-v1", "agent-access-tokens-v1"},
	}
	if len(s.moduleNames) > 0 {
		identity["modules"] = append([]string(nil), s.moduleNames...)
	}
	if s.runtimeConfig != nil {
		runtimeStatus, err := s.runtimeConfig.Status(c.Request.Context())
		if err != nil {
			body := gin.H{"ok": false, "state": "database_error", "error": err.Error(), "runtimeBackend": runtimeBackend(s.cfg)}
			mergeHealthIdentity(body, identity)
			c.JSON(http.StatusServiceUnavailable, body)
			return
		}
		if runtimeStatus.SetupRequired {
			body := gin.H{"ok": true, "state": "setup_required", "ready": false, "runtimeBackend": runtimeBackend(s.cfg), "configSource": "database"}
			mergeHealthIdentity(body, identity)
			c.JSON(http.StatusOK, body)
			return
		}
		identity["configSource"] = runtimeStatus.ConfigSource
		identity["instanceId"] = runtimeStatus.InstanceID
	}
	if s.indexStoreErr != nil {
		body := gin.H{
			"ok":               false,
			"uptimeSeconds":    int(time.Since(startedAt).Seconds()),
			"ledgerReadModel":  s.cfg.LedgerReadModel,
			"readModelStrict":  s.cfg.ReadModelStrict,
			"ledgerIndexError": s.indexStoreErr.Error(),
			"runtimeBackend":   runtimeBackend(s.cfg),
		}
		mergeHealthIdentity(body, identity)
		c.JSON(http.StatusServiceUnavailable, body)
		return
	}
	if s.indexStore != nil {
		revision, indexed, err := s.indexStore.ActiveRevision(c.Request.Context())
		body := gin.H{
			"ok":                  err == nil,
			"ready":               err == nil && indexed,
			"state":               map[bool]string{true: "ready", false: "indexing"}[indexed],
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
			body["state"] = "database_error"
		}
		mergeHealthIdentity(body, identity)
		c.JSON(status(err == nil, http.StatusOK, http.StatusServiceUnavailable), body)
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		body := gin.H{"ok": false, "error": err.Error()}
		mergeHealthIdentity(body, identity)
		c.JSON(http.StatusServiceUnavailable, body)
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
	mergeHealthIdentity(body, identity)
	c.JSON(status(ok, http.StatusOK, http.StatusServiceUnavailable), body)
}

func (s *Server) ready(c *gin.Context) {
	if s.runtimeConfig != nil {
		setupRequired, err := s.runtimeConfig.SetupRequired(c.Request.Context())
		if err != nil {
			errorJSON(c, http.StatusServiceUnavailable, err)
			return
		}
		if setupRequired {
			c.JSON(http.StatusServiceUnavailable, gin.H{"ok": false, "state": "setup_required"})
			return
		}
	}
	if s.indexStoreErr != nil {
		errorJSON(c, http.StatusServiceUnavailable, s.indexStoreErr)
		return
	}
	if s.indexStore != nil {
		revision, indexed, err := s.indexStore.ActiveRevision(c.Request.Context())
		if err != nil || !indexed {
			if err == nil {
				err = errors.New("ledger index has no active revision")
			}
			errorJSON(c, http.StatusServiceUnavailable, err)
			return
		}
		c.JSON(http.StatusOK, gin.H{"ok": true, "state": "ready", "gitSHA": revision.GitSHA, "revision": revision.ID})
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusServiceUnavailable, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "state": "ready"})
}

func ledgerClusterID(cfg Config) string {
	if configured := strings.TrimSpace(cfg.LedgerClusterID); configured != "" {
		return configured
	}
	owner := strings.TrimSpace(cfg.LedgerGitHubOwner)
	repo := strings.TrimSpace(cfg.LedgerGitHubRepo)
	if owner != "" && repo != "" {
		branch := strings.TrimSpace(cfg.LedgerGitBranch)
		if branch == "" {
			branch = "main"
		}
		return fmt.Sprintf("github:%s/%s@%s", strings.ToLower(owner), strings.ToLower(repo), branch)
	}
	ledgerRoot := strings.TrimSpace(cfg.LedgerRoot)
	if ledgerRoot == "" || ledgerRoot == "." {
		return "unconfigured"
	}
	if absolute, err := filepath.Abs(ledgerRoot); err == nil {
		ledgerRoot = absolute
	}
	sum := sha256.Sum256([]byte(filepath.Clean(ledgerRoot)))
	return "filesystem:" + hex.EncodeToString(sum[:12])
}

func mergeHealthIdentity(body, identity gin.H) {
	for key, value := range identity {
		body[key] = value
	}
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
