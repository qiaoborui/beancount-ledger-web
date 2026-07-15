package app

import (
	"errors"
	"io"
)

// applicationStorageAdapters groups infrastructure selected by application configuration.
// The composition root owns selection; application services receive only their ports.
type applicationStorageAdapters struct {
	runtimeStore  RuntimeStore
	indexStore    LedgerIndexPort
	indexStoreErr error
	limiter       RateLimiter
	closers       []io.Closer
}

func openApplicationStorageAdapters(cfg Config) (*applicationStorageAdapters, error) {
	adapters := &applicationStorageAdapters{}
	fail := func(err error) (*applicationStorageAdapters, error) {
		return nil, errors.Join(err, closeResources(adapters.closers))
	}
	if cfg.DatabaseURL != "" {
		db, err := openPostgres(cfg.DatabaseURL)
		if err != nil {
			return nil, err
		}
		adapters.closers = append(adapters.closers, db)
		adapters.runtimeStore, err = NewRuntimeStoreWithDB(db)
		if err != nil {
			return fail(err)
		}
		if ledgerReadModelEnabled(cfg) {
			adapters.indexStore, adapters.indexStoreErr = NewLedgerIndexStoreWithDB(db, cfg)
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
