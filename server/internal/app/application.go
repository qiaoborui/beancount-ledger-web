package app

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"sync"

	"github.com/gin-gonic/gin"
)

// Application owns the HTTP handler and every resource opened while wiring it.
type Application struct {
	router            *gin.Engine
	server            *Server
	closers           []io.Closer
	pollWorkerFactory func() *gmailPollWorker

	lifecycleMu    sync.Mutex
	closed         bool
	pollingStarted bool
	closeOnce      sync.Once
	closeErr       error
}

type applicationDependencies struct {
	cfg                  Config
	runtimeStore         RuntimeStore
	runtimeConfig        *RuntimeConfigStore
	bqlHistoryRepository bqlHistoryRepository
	quickUnlocks         quickUnlockRepository
	gmailRepository      gmailStateRepository
	importState          importStateRepository
	pushSubscriptions    pushSubscriptionRepository
	notifications        notificationRepository
	passkeys             passkeyRepository
	agentMemories        agentMemoryRepository
	indexStore           LedgerIndexPort
	indexStoreErr        error
	cache                *LedgerCache
	modules              *ModuleRegistry
	moduleNames          []string
	notificationService  *NotificationService
	writer               *LedgerWriter
	accountService       *AccountService
	queryPort            LedgerQueryPort
	snapshotPort         LedgerSnapshotPort
	reconcileService     *ReconciliationService
	txService            *TransactionService
	limiter              RateLimiter
	closers              []io.Closer
}

func NewApplication(cfg Config) (*Application, error) {
	return NewApplicationWithLogger(cfg, nil)
}

// NewApplicationWithLogger builds the application with an explicit structured
// logger created by the process entry point. A nil logger falls back to the
// standard slog default.
func NewApplicationWithLogger(cfg Config, logger *slog.Logger) (*Application, error) {
	dependencies, err := buildApplicationDependenciesWithLogger(cfg, logger)
	if err != nil {
		return nil, err
	}
	server := &Server{
		cfg:                  dependencies.cfg,
		logger:               logger,
		runtimeStore:         dependencies.runtimeStore,
		runtimeConfig:        dependencies.runtimeConfig,
		bqlHistoryRepository: dependencies.bqlHistoryRepository,
		quickUnlocks:         dependencies.quickUnlocks,
		gmailRepository:      dependencies.gmailRepository,
		importState:          dependencies.importState,
		passkeys:             dependencies.passkeys,
		agentMemories:        dependencies.agentMemories,
		indexStore:           dependencies.indexStore,
		indexStoreErr:        dependencies.indexStoreErr,
		cache:                dependencies.cache,
		importers:            dependencies.modules.Importers(),
		moduleNames:          dependencies.moduleNames,
		notificationService:  dependencies.notificationService,
		writer:               dependencies.writer,
		accountService:       dependencies.accountService,
		queryPort:            dependencies.queryPort,
		snapshotPort:         dependencies.snapshotPort,
		reconcileService:     dependencies.reconcileService,
		txService:            dependencies.txService,
		limiter:              dependencies.limiter,
	}
	return newApplication(newRouter(dependencies.cfg, server), server, dependencies.closers), nil
}

func buildApplicationDependencies(cfg Config) (*applicationDependencies, error) {
	return buildApplicationDependenciesWithLogger(cfg, nil)
}

func buildApplicationDependenciesWithLogger(cfg Config, logger *slog.Logger) (*applicationDependencies, error) {
	dependencies := &applicationDependencies{}
	fail := func(err error) (*applicationDependencies, error) {
		return nil, errors.Join(err, closeResources(dependencies.closers))
	}
	storageAdapters, err := openApplicationStorageAdaptersWithLogger(cfg, logger)
	if err != nil {
		return nil, err
	}
	cfg = storageAdapters.config
	dependencies.cfg = cfg
	dependencies.closers = append(dependencies.closers, storageAdapters.closers...)
	dependencies.runtimeStore = storageAdapters.runtimeStore
	dependencies.runtimeConfig = storageAdapters.runtimeConfig
	selectedModules, err := enabledBuiltinModules(cfg.EnabledModules)
	if err != nil {
		return fail(err)
	}
	modules, err := NewModuleRegistry(selectedModules...)
	if err != nil {
		return fail(err)
	}
	if storageAdapters.persistence != nil {
		dependencies.bqlHistoryRepository = newEntBQLHistoryRepository(storageAdapters.persistence.Client)
		dependencies.quickUnlocks = newEntQuickUnlockRepository(storageAdapters.persistence.Client)
		dependencies.gmailRepository = newEntGmailStateRepository(storageAdapters.persistence.Client)
		dependencies.importState = newFallbackImportStateRepository(
			newEntImportStateRepository(storageAdapters.persistence.Client),
			newRuntimeImportStateRepository(dependencies.runtimeStore),
		)
		dependencies.pushSubscriptions = newEntPushSubscriptionRepository(storageAdapters.persistence.Client)
		dependencies.notifications = newEntNotificationRepository(storageAdapters.persistence.Client)
		dependencies.passkeys = newEntPasskeyRepository(storageAdapters.persistence.Client)
		dependencies.agentMemories = newEntAgentMemoryRepository(storageAdapters.persistence.Client)
		if err := backfillRelationalRuntime(context.Background(), storageAdapters.persistence, dependencies.runtimeStore, cfg, dependencies.bqlHistoryRepository, dependencies.pushSubscriptions, dependencies.notifications); err != nil {
			return fail(err)
		}
		if err := backfillAgentMemoryRuntime(context.Background(), storageAdapters.persistence, dependencies.runtimeStore, cfg, dependencies.agentMemories); err != nil {
			return fail(err)
		}
		if err := backfillPasskeyRuntime(context.Background(), storageAdapters.persistence, dependencies.runtimeStore, dependencies.passkeys); err != nil {
			return fail(err)
		}
		if err := backfillQuickUnlockRuntime(context.Background(), storageAdapters.persistence, dependencies.runtimeStore, dependencies.quickUnlocks); err != nil {
			return fail(err)
		}
		if err := backfillGmailRuntime(context.Background(), storageAdapters.persistence, dependencies.runtimeStore, dependencies.gmailRepository); err != nil {
			return fail(err)
		}
	}
	dependencies.indexStore = storageAdapters.indexStore
	dependencies.indexStoreErr = storageAdapters.indexStoreErr
	dependencies.limiter = storageAdapters.limiter

	dependencies.cache = NewLedgerCache(cfg)
	readService := NewLedgerReadServiceWithIndex(dependencies.cache, dependencies.indexStore, dependencies.indexStoreErr, cfg.ReadModelStrict)
	dependencies.queryPort = readService
	dependencies.snapshotPort = readService
	dependencies.writer = NewLedgerWriterWithRuntimeStoreAndCommodities(cfg, dependencies.cache, dependencies.runtimeStore, func() ([]string, error) {
		snapshot, err := readService.SnapshotLite(context.Background())
		if err != nil {
			return nil, err
		}
		return snapshot.Commodities, nil
	})
	if logger != nil {
		dependencies.writer.SetLogger(logger)
	}
	if indexStore, ok := dependencies.indexStore.(*LedgerIndexStore); ok {
		dependencies.writer.SetIndexRequestStore(indexStore)
	}
	snapshot := func() (*LedgerSnapshot, error) {
		return readService.SnapshotLite(context.Background())
	}
	dependencies.accountService = NewAccountServiceWithSnapshot(dependencies.cache, dependencies.writer, snapshot)
	dependencies.reconcileService = NewReconciliationServiceWithSnapshot(dependencies.cache, dependencies.writer, snapshot)
	dependencies.txService = NewTransactionServiceWithSnapshot(dependencies.cache, dependencies.writer, snapshot)
	dependencies.notificationService, err = modules.BuildNotificationService(NotificationServiceDependencies{
		Config:                     cfg,
		RuntimeStore:               dependencies.runtimeStore,
		PushSubscriptionRepository: dependencies.pushSubscriptions,
		NotificationRepository:     dependencies.notifications,
		SnapshotPort:               dependencies.snapshotPort,
	})
	if err != nil {
		return fail(err)
	}
	if err := modules.Start(context.Background()); err != nil {
		return fail(err)
	}
	dependencies.modules = modules
	dependencies.moduleNames = modules.Names()
	dependencies.closers = append(dependencies.closers, modules)
	return dependencies, nil
}

func newApplication(router *gin.Engine, server *Server, closers []io.Closer) *Application {
	return &Application{router: router, server: server, closers: append([]io.Closer(nil), closers...)}
}

func (a *Application) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	a.router.ServeHTTP(writer, request)
}

// StartGmailPolling starts the self-hosted, outbound-only Gmail scheduler when
// the explicit poll delivery mode is configured. It is a no-op for webhook
// deployments and for instances without Gmail automation configured.
func (a *Application) StartGmailPolling(ctx context.Context) {
	if a == nil || a.server == nil {
		return
	}
	a.server.cfgMu.RLock()
	enabled := gmailPollingEnabled(a.server.cfg)
	a.server.cfgMu.RUnlock()
	if !enabled {
		return
	}
	a.lifecycleMu.Lock()
	defer a.lifecycleMu.Unlock()
	if a.closed || a.pollingStarted {
		return
	}
	worker := a.newGmailPollWorker()
	worker.Start(ctx)
	// Register while holding the same lifecycle lock Close uses, so Close can
	// neither miss a started worker nor permit a worker after resources close.
	a.closers = append(a.closers, worker)
	a.pollingStarted = true
}

func (a *Application) newGmailPollWorker() *gmailPollWorker {
	if a.pollWorkerFactory != nil {
		return a.pollWorkerFactory()
	}
	return a.server.newGmailPollWorker()
}

func (a *Application) Close() error {
	if a == nil {
		return nil
	}
	a.closeOnce.Do(func() {
		a.lifecycleMu.Lock()
		a.closed = true
		closers := append([]io.Closer(nil), a.closers...)
		a.lifecycleMu.Unlock()
		a.closeErr = closeResources(closers)
	})
	return a.closeErr
}

func closeResources(closers []io.Closer) error {
	errs := make([]error, 0, len(closers))
	for index := len(closers) - 1; index >= 0; index-- {
		if closers[index] == nil {
			continue
		}
		if err := closers[index].Close(); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
