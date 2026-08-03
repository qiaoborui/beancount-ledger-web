package app

import (
	"context"
	"errors"
	"io"
	"net/http"
	"sync"

	"github.com/gin-gonic/gin"
)

// Application owns the HTTP handler and every resource opened while wiring it.
type Application struct {
	router    *gin.Engine
	closers   []io.Closer
	closeOnce sync.Once
	closeErr  error
}

type applicationDependencies struct {
	runtimeStore         RuntimeStore
	bqlHistoryRepository bqlHistoryRepository
	quickUnlocks         quickUnlockRepository
	gmailRepository      gmailStateRepository
	importState          importStateRepository
	pushSubscriptions    pushSubscriptionRepository
	notifications        notificationRepository
	passkeys             passkeyRepository
	agentSessions        agentSessionRepository
	agentApprovals       agentApprovalRepository
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
	dependencies, err := buildApplicationDependencies(cfg)
	if err != nil {
		return nil, err
	}
	server := &Server{
		cfg:                  cfg,
		runtimeStore:         dependencies.runtimeStore,
		bqlHistoryRepository: dependencies.bqlHistoryRepository,
		quickUnlocks:         dependencies.quickUnlocks,
		gmailRepository:      dependencies.gmailRepository,
		importState:          dependencies.importState,
		passkeys:             dependencies.passkeys,
		agentSessions:        dependencies.agentSessions,
		agentApprovals:       dependencies.agentApprovals,
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
	return newApplication(newRouter(cfg, server), dependencies.closers), nil
}

func buildApplicationDependencies(cfg Config) (*applicationDependencies, error) {
	dependencies := &applicationDependencies{}
	fail := func(err error) (*applicationDependencies, error) {
		return nil, errors.Join(err, closeResources(dependencies.closers))
	}
	selectedModules, err := enabledBuiltinModules(cfg.EnabledModules)
	if err != nil {
		return nil, err
	}
	modules, err := NewModuleRegistry(selectedModules...)
	if err != nil {
		return nil, err
	}

	storageAdapters, err := openApplicationStorageAdapters(cfg)
	if err != nil {
		return nil, err
	}
	dependencies.closers = append(dependencies.closers, storageAdapters.closers...)
	dependencies.runtimeStore = storageAdapters.runtimeStore
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
		dependencies.agentSessions = newEntAgentSessionRepository(storageAdapters.persistence.Client)
		dependencies.agentApprovals = newEntAgentApprovalRepository(storageAdapters.persistence.Client)
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

func newApplication(router *gin.Engine, closers []io.Closer) *Application {
	return &Application{router: router, closers: append([]io.Closer(nil), closers...)}
}

func (a *Application) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	a.router.ServeHTTP(writer, request)
}

func (a *Application) Close() error {
	if a == nil {
		return nil
	}
	a.closeOnce.Do(func() {
		a.closeErr = closeResources(a.closers)
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
