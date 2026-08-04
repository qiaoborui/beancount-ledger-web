package app

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
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
	if err := verifyLedgerIndexerInstance(ctx, cfg, store); err != nil {
		return LedgerIndexResult{}, err
	}
	var result LedgerIndexResult
	err := withLedgerFilesystemLock(ctx, cfg, ledgerFilesystemSharedLock, func() error {
		var err error
		result, err = store.withIndexLock(ctx, func() (LedgerIndexResult, error) {
			return runLedgerIndexOnceWithStore(ctx, cfg, store)
		})
		return err
	})
	return result, err
}

func verifyLedgerIndexerInstance(ctx context.Context, cfg Config, store *LedgerIndexStore) error {
	expected := strings.TrimSpace(cfg.LedgerClusterID)
	if expected == "" || store == nil || store.db == nil {
		return nil
	}
	settings, found, err := readRuntimeConfigSettings(ctx, store.db)
	if err != nil {
		return fmt.Errorf("read runtime instance identity: %w", err)
	}
	if !found || !settings.SetupComplete {
		return errors.New("runtime instance identity is not initialized")
	}
	if settings.InstanceID != expected {
		return fmt.Errorf("indexer instance identity mismatch: configured %q, database requires %q", expected, settings.InstanceID)
	}
	return nil
}

func runLedgerIndexOnceWithStore(ctx context.Context, cfg Config, store *LedgerIndexStore) (LedgerIndexResult, error) {
	active, hasActive, err := store.ActiveRevision(ctx)
	if err != nil {
		return LedgerIndexResult{}, err
	}
	gitSHA, err := ledgerIndexGitSHA(ctx, cfg)
	if err != nil {
		return LedgerIndexResult{}, err
	}
	if hasActive && canSkipLedgerIndexByGitSHA(cfg, active, gitSHA, cfg.LedgerIndexForceRebuild) {
		return LedgerIndexResult{
			RevisionID:    active.ID,
			GitSHA:        active.GitSHA,
			LedgerVersion: active.LedgerVersion,
			Skipped:       true,
			SkipReason:    "ledger git SHA unchanged",
		}, nil
	}
	if err := ensureLedgerReady(cfg); err != nil {
		return LedgerIndexResult{}, err
	}
	if cfg.LedgerIndexBeanCheckEnabled {
		if err := runBeanCheck(cfg); err != nil {
			return LedgerIndexResult{}, fmt.Errorf("bean-check ledger revision: %w", err)
		}
	}
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

// ledgerIndexGitSHA records the exact checkout revision whenever the indexer
// owns a synchronized Git worktree. This keeps Postgres revisions traceable to
// GitHub writes and lets onboarding wait for the commit it just created.
func ledgerIndexGitSHA(ctx context.Context, cfg Config) (string, error) {
	if gitSHA := strings.TrimSpace(cfg.LedgerGitSHA); gitSHA != "" {
		return gitSHA, nil
	}
	if !cfg.LedgerGitSyncEnabled {
		return "", nil
	}
	root := strings.TrimSpace(cfg.LedgerRoot)
	if root == "" || root == "." {
		return "", errors.New("LEDGER_ROOT is required to resolve the synchronized Git revision")
	}
	gitSHA, err := ledgerGitOutput(ctx, cfg, "-C", root, "rev-parse", "--verify", "HEAD")
	if err != nil {
		return "", fmt.Errorf("resolve synchronized ledger revision: %w", err)
	}
	return strings.TrimSpace(gitSHA), nil
}

func shouldSkipLedgerIndexByGitSHA(active LedgerIndexRevision, gitSHA string, force bool) bool {
	return !force && gitSHA != "" && active.GitSHA == gitSHA
}

func canSkipLedgerIndexByGitSHA(cfg Config, active LedgerIndexRevision, gitSHA string, force bool) bool {
	return shouldSkipLedgerIndexByGitSHA(active, gitSHA, force) && ledgerCheckoutMatchesGitSHA(cfg, gitSHA)
}

// ledgerCheckoutMatchesGitSHA verifies that the files under LedgerRoot still
// represent the immutable revision configured for indexing. A verification
// failure intentionally falls back to include-manifest hashing.
func ledgerCheckoutMatchesGitSHA(cfg Config, gitSHA string) bool {
	root, err := filepath.Abs(cfg.LedgerRoot)
	if err != nil {
		return false
	}
	git := func(args ...string) (string, error) {
		command := append([]string{"-c", "safe.directory=" + root, "-C", root}, args...)
		out, err := exec.Command("git", command...).Output()
		return strings.TrimSpace(string(out)), err
	}
	head, err := git("rev-parse", "--verify", "HEAD")
	if err != nil || head != gitSHA {
		return false
	}
	status, err := git("status", "--porcelain=v1", "--untracked-files=all")
	return err == nil && status == ""
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
