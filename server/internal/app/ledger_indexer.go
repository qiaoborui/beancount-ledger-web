package app

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
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
	return store.withIndexLock(ctx, func() (LedgerIndexResult, error) {
		return runLedgerIndexOnceWithStore(ctx, cfg, store)
	})
}

func runLedgerIndexOnceWithStore(ctx context.Context, cfg Config, store *LedgerIndexStore) (LedgerIndexResult, error) {
	active, hasActive, err := store.ActiveRevision(ctx)
	if err != nil {
		return LedgerIndexResult{}, err
	}
	if err := ensureLedgerReady(cfg); err != nil {
		return LedgerIndexResult{}, err
	}
	gitSHA := strings.TrimSpace(cfg.LedgerGitSHA)
	if hasActive {
		version, err := ledgerVersion(cfg)
		if err != nil {
			return LedgerIndexResult{}, err
		}
		if shouldSkipLedgerIndex(active, version, gitSHA, cfg.LedgerIndexForceRebuild) {
			return LedgerIndexResult{RevisionID: active.ID, LedgerVersion: active.LedgerVersion, Skipped: true, SkipReason: "ledger version unchanged"}, nil
		}
	}

	cache := NewLedgerCache(cfg)
	snapshot, err := cache.Snapshot()
	if err != nil {
		return LedgerIndexResult{}, err
	}
	normalizeLedgerSnapshotSourcePaths(cfg, snapshot)
	var revisionID int64
	if cfg.LedgerIndexForceRebuild {
		revisionID, err = store.ForceReplaceActiveSnapshot(ctx, snapshot, gitSHA)
	} else {
		revisionID, err = store.ReplaceActiveSnapshot(ctx, snapshot, gitSHA)
	}
	if err != nil {
		return LedgerIndexResult{}, err
	}
	return LedgerIndexResult{RevisionID: revisionID, GitSHA: gitSHA, LedgerVersion: snapshot.LedgerVersion}, nil
}

func shouldSkipLedgerIndex(active LedgerIndexRevision, version LedgerVersion, gitSHA string, force bool) bool {
	if force || active.LedgerVersion.Version != version.Version {
		return false
	}
	return gitSHA == "" || active.GitSHA == gitSHA
}

func normalizeLedgerSnapshotSourcePaths(cfg Config, snapshot *LedgerSnapshot) {
	if snapshot == nil {
		return
	}
	for index := range snapshot.Transactions {
		snapshot.Transactions[index].Source.File = ledgerRelativeSourcePath(cfg, snapshot.Transactions[index].Source.File)
	}
	for index := range snapshot.BeanEntries {
		snapshot.BeanEntries[index].File = ledgerRelativeSourcePath(cfg, snapshot.BeanEntries[index].File)
	}
	for index := range snapshot.BeanErrors {
		snapshot.BeanErrors[index].File = ledgerRelativeSourcePath(cfg, snapshot.BeanErrors[index].File)
	}
}

func ledgerRelativeSourcePath(cfg Config, file string) string {
	if !filepath.IsAbs(file) {
		return filepath.ToSlash(file)
	}
	root, err := filepath.Abs(cfg.LedgerRoot)
	if err != nil {
		return file
	}
	relative, err := filepath.Rel(root, file)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return file
	}
	return filepath.ToSlash(relative)
}
