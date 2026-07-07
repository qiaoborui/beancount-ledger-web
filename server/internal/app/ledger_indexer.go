package app

import (
	"context"
	"errors"
	"log"
	"strings"
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
	if remoteSHA := ledgerRemoteHeadSHA(cfg); remoteSHA != "" && hasActive && active.GitSHA == remoteSHA {
		return LedgerIndexResult{RevisionID: active.ID, GitSHA: active.GitSHA, LedgerVersion: active.LedgerVersion, Skipped: true, SkipReason: "git sha unchanged"}, nil
	}
	if err := ensureLedgerReady(cfg); err != nil {
		return LedgerIndexResult{}, err
	}
	gitSHA := ledgerIndexGitSHA(cfg)
	if gitSHA != "" && hasActive && active.GitSHA == gitSHA {
		return LedgerIndexResult{RevisionID: active.ID, GitSHA: active.GitSHA, LedgerVersion: active.LedgerVersion, Skipped: true, SkipReason: "git sha unchanged"}, nil
	}
	if gitSHA == "" && hasActive {
		version, err := ledgerVersion(cfg)
		if err != nil {
			return LedgerIndexResult{}, err
		}
		if active.LedgerVersion.Version == version.Version {
			return LedgerIndexResult{RevisionID: active.ID, GitSHA: active.GitSHA, LedgerVersion: active.LedgerVersion, Skipped: true, SkipReason: "ledger version unchanged"}, nil
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

func ledgerRemoteHeadSHA(cfg Config) string {
	if !remoteGitEnabled(cfg) {
		return ""
	}
	branch := strings.TrimSpace(cfg.LedgerGitBranch)
	if branch == "" {
		branch = "main"
	}
	out, err := gitOutput("", "ls-remote", cfg.LedgerGitRemote, "refs/heads/"+branch)
	if err != nil {
		return ""
	}
	fields := strings.Fields(out)
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
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
