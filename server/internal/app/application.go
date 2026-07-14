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
	runtimeStore     RuntimeStore
	indexStore       *LedgerIndexStore
	indexStoreErr    error
	cache            *LedgerCache
	writer           *LedgerWriter
	accountService   *AccountService
	readService      ledgerReadService
	reconcileService *ReconciliationService
	txService        *TransactionService
	limiter          RateLimiter
	closers          []io.Closer
}

func NewApplication(cfg Config) (*Application, error) {
	dependencies, err := buildApplicationDependencies(cfg)
	if err != nil {
		return nil, err
	}
	server := &Server{
		cfg:              cfg,
		runtimeStore:     dependencies.runtimeStore,
		indexStore:       dependencies.indexStore,
		indexStoreErr:    dependencies.indexStoreErr,
		cache:            dependencies.cache,
		writer:           dependencies.writer,
		accountService:   dependencies.accountService,
		readService:      dependencies.readService,
		reconcileService: dependencies.reconcileService,
		txService:        dependencies.txService,
		limiter:          dependencies.limiter,
	}
	return newApplication(newRouter(cfg, server), dependencies.closers), nil
}

func buildApplicationDependencies(cfg Config) (*applicationDependencies, error) {
	dependencies := &applicationDependencies{}
	fail := func(err error) (*applicationDependencies, error) {
		return nil, errors.Join(err, closeResources(dependencies.closers))
	}

	if cfg.DatabaseURL != "" {
		db, err := openPostgres(cfg.DatabaseURL)
		if err != nil {
			return nil, err
		}
		dependencies.closers = append(dependencies.closers, db)

		dependencies.runtimeStore, err = NewRuntimeStoreWithDB(db)
		if err != nil {
			return fail(err)
		}
		if ledgerReadModelEnabled(cfg) {
			dependencies.indexStore, dependencies.indexStoreErr = NewLedgerIndexStoreWithDB(db, cfg)
		}
		dependencies.limiter, err = NewPostgresRateLimiter(db)
		if err != nil {
			return fail(err)
		}
	} else {
		var err error
		dependencies.runtimeStore, err = NewRuntimeStore(cfg)
		if err != nil {
			return nil, err
		}
		if ledgerReadModelEnabled(cfg) {
			dependencies.indexStore, dependencies.indexStoreErr = NewLedgerIndexStore(cfg)
			if dependencies.indexStore != nil {
				dependencies.closers = append(dependencies.closers, dependencies.indexStore)
			}
		}
		dependencies.limiter = NewRateLimiter()
	}

	dependencies.cache = NewLedgerCache(cfg)
	readService := NewLedgerReadServiceWithIndex(dependencies.cache, dependencies.indexStore, dependencies.indexStoreErr, cfg.ReadModelStrict)
	dependencies.readService = readService
	dependencies.writer = NewLedgerWriterWithRuntimeStoreAndCommodities(cfg, dependencies.cache, dependencies.runtimeStore, func() ([]string, error) {
		snapshot, err := readService.SnapshotLite(context.Background())
		if err != nil {
			return nil, err
		}
		return snapshot.Commodities, nil
	})
	snapshot := func() (*LedgerSnapshot, error) {
		return readService.SnapshotLite(context.Background())
	}
	dependencies.accountService = NewAccountServiceWithSnapshot(dependencies.cache, dependencies.writer, snapshot)
	dependencies.reconcileService = NewReconciliationServiceWithSnapshot(dependencies.cache, dependencies.writer, snapshot)
	dependencies.txService = NewTransactionServiceWithSnapshot(dependencies.cache, dependencies.writer, snapshot)
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
