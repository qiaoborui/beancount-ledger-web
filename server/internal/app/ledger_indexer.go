package app

import (
	"context"
	"log"
	"strings"
	"time"
)

type LedgerIndexResult struct {
	RevisionID    int64
	GitSHA        string
	LedgerVersion LedgerVersion
}

func RunLedgerIndexOnce(ctx context.Context, cfg Config) (LedgerIndexResult, error) {
	store, err := NewLedgerIndexStore(cfg)
	if err != nil {
		return LedgerIndexResult{}, err
	}
	defer store.Close()

	cache := NewLedgerCache(cfg)
	snapshot, err := cache.Snapshot()
	if err != nil {
		return LedgerIndexResult{}, err
	}
	gitSHA := ledgerIndexGitSHA(cfg)
	revisionID, err := store.ReplaceActiveSnapshot(ctx, snapshot, gitSHA)
	if err != nil {
		return LedgerIndexResult{}, err
	}
	return LedgerIndexResult{RevisionID: revisionID, GitSHA: gitSHA, LedgerVersion: snapshot.LedgerVersion}, nil
}

func RunLedgerIndexLoop(ctx context.Context, cfg Config, interval time.Duration) error {
	if interval <= 0 {
		_, err := RunLedgerIndexOnce(ctx, cfg)
		return err
	}
	for {
		started := time.Now()
		result, err := RunLedgerIndexOnce(ctx, cfg)
		if err != nil {
			log.Printf("[ledger-indexer] failed: %v", err)
		} else {
			log.Printf("[ledger-indexer] indexed revision=%d version=%s files=%d git=%s in %s", result.RevisionID, result.LedgerVersion.Version, result.LedgerVersion.FileCount, result.GitSHA, time.Since(started).Round(time.Millisecond))
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

func ledgerIndexGitSHA(cfg Config) string {
	if !remoteGitEnabled(cfg) {
		return ""
	}
	out, err := gitLedgerOutput(cfg, "rev-parse", "HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}
