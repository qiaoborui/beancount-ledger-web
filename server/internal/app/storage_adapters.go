package app

import (
	"context"
	"errors"
	"io"
	"log/slog"

	"github.com/borui/beancount-ledger-web/server/internal/persistence"
)

// applicationStorageAdapters groups infrastructure selected by application configuration.
// The composition root owns selection; application services receive only their ports.
type applicationStorageAdapters struct {
	runtimeStore  RuntimeStore
	runtimeConfig *RuntimeConfigStore
	config        Config
	persistence   *persistence.Store
	indexStore    LedgerIndexPort
	indexStoreErr error
	limiter       RateLimiter
	closers       []io.Closer
}

func openApplicationStorageAdapters(cfg Config) (*applicationStorageAdapters, error) {
	return openApplicationStorageAdaptersWithLogger(cfg, nil)
}

func openApplicationStorageAdaptersWithLogger(cfg Config, logger *slog.Logger) (*applicationStorageAdapters, error) {
	adapters := &applicationStorageAdapters{config: cfg}
	fail := func(err error) (*applicationStorageAdapters, error) {
		return nil, errors.Join(err, closeResources(adapters.closers))
	}
	if cfg.DatabaseURL != "" {
		db, err := openPostgres(cfg.DatabaseURL)
		if err != nil {
			return nil, err
		}
		adapters.closers = append(adapters.closers, db)
		adapters.persistence, err = persistence.NewStore(context.Background(), db)
		if err != nil {
			return fail(err)
		}
		adapters.runtimeConfig, err = NewRuntimeConfigStore(db, logger)
		if err != nil {
			return fail(err)
		}
		adapters.config, err = adapters.runtimeConfig.Bootstrap(context.Background(), cfg)
		if err != nil {
			return fail(err)
		}
		adapters.runtimeStore, err = NewRuntimeStoreWithDB(db)
		if err != nil {
			return fail(err)
		}
		if ledgerReadModelEnabled(adapters.config) {
			adapters.indexStore, adapters.indexStoreErr = NewLedgerIndexStoreWithDB(db, adapters.config)
		}
		adapters.limiter, err = NewPostgresRateLimiter(db)
		if err != nil {
			return fail(err)
		}
		return adapters, nil
	}

	var err error
	adapters.runtimeStore, err = NewRuntimeStore(cfg)
	if err != nil {
		return nil, err
	}
	if ledgerReadModelEnabled(cfg) {
		adapters.indexStore, adapters.indexStoreErr = NewLedgerIndexStore(cfg)
		if closer, ok := adapters.indexStore.(io.Closer); ok {
			adapters.closers = append(adapters.closers, closer)
		}
	}
	adapters.limiter = NewRateLimiter()
	return adapters, nil
}
