package app

import (
	"context"
	"errors"
	"log"
	"time"
)

type LedgerIndexResult struct {
	RevisionID    int64
	GitSHA        string
	LedgerVersion LedgerVersion
	Skipped       bool
	SkipReason    string
}

func RunLedgerIndexOnce(ctx context.Context, cfg Config) (LedgerIndexResult, error) {
	store, err := NewLedgerIndexStore(cfg)
	if err != nil {
		return LedgerIndexResult{}, err
	}
	defer store.Close()

	return RunLedgerIndexOnceWithStore(ctx, cfg, store)
}

func RunLedgerIndexOnceWithStore(ctx context.Context, cfg Config, store *LedgerIndexStore) (LedgerIndexResult, error) {
	if store == nil {
		return LedgerIndexResult{}, errors.New("ledger index store is required")
	}
	active, hasActive, err := store.ActiveRevision(ctx)
	if err != nil {
		return LedgerIndexResult{}, err
	}
	if err := ensureLedgerReady(cfg); err != nil {
		return LedgerIndexResult{}, err
	}
	gitSHA := ""
	if hasActive {
		version, err := ledgerVersion(cfg)
		if err != nil {
			return LedgerIndexResult{}, err
		}
		if active.LedgerVersion.Version == version.Version {
			return LedgerIndexResult{RevisionID: active.ID, LedgerVersion: active.LedgerVersion, Skipped: true, SkipReason: "ledger version unchanged"}, nil
		}
	}

	cache := NewLedgerCache(cfg)
	snapshot, err := cache.Snapshot()
	if err != nil {
		return LedgerIndexResult{}, err
	}
	revisionID, err := store.ReplaceActiveSnapshot(ctx, snapshot, gitSHA)
	if err != nil {
		return LedgerIndexResult{}, err
	}
	return LedgerIndexResult{RevisionID: revisionID, GitSHA: gitSHA, LedgerVersion: snapshot.LedgerVersion}, nil
}

func RunLedgerIndexLoop(ctx context.Context, cfg Config, interval time.Duration) error {
	return RunLedgerIndexLoopWithTrigger(ctx, cfg, interval, nil)
}

func RunLedgerIndexLoopWithTrigger(ctx context.Context, cfg Config, interval time.Duration, trigger <-chan struct{}) error {
	store, err := NewLedgerIndexStore(cfg)
	if err != nil {
		return err
	}
	defer store.Close()

	if interval <= 0 {
		_, err := RunLedgerIndexOnceWithStore(ctx, cfg, store)
		return err
	}
	runOnce := func() {
		started := time.Now()
		result, err := RunLedgerIndexOnceWithStore(ctx, cfg, store)
		if err != nil {
			log.Printf("[ledger-indexer] failed: %v", err)
		} else if result.Skipped {
			log.Printf("[ledger-indexer] skipped revision=%d version=%s git=%s reason=%s in %s", result.RevisionID, result.LedgerVersion.Version, result.GitSHA, result.SkipReason, time.Since(started).Round(time.Millisecond))
		} else {
			log.Printf("[ledger-indexer] indexed revision=%d version=%s files=%d git=%s in %s", result.RevisionID, result.LedgerVersion.Version, result.LedgerVersion.FileCount, result.GitSHA, time.Since(started).Round(time.Millisecond))
		}
	}

	for {
		runOnce()
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-trigger:
			timer.Stop()
			log.Printf("[ledger-indexer] triggered by github events")
		case <-timer.C:
		}
	}
}
