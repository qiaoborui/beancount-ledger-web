package app

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// SyncLedgerGitCheckout makes the indexer's private checkout match its remote
// branch. The API never receives this directory; it writes through GitHub's
// Contents API instead. Refusing a dirty checkout prevents a background index
// pass from silently replacing an operator's local changes.
func SyncLedgerGitCheckout(ctx context.Context, cfg Config) error {
	if !cfg.LedgerGitSyncEnabled {
		return nil
	}
	root := strings.TrimSpace(cfg.LedgerRoot)
	remote := strings.TrimSpace(cfg.LedgerGitRemoteURL)
	if root == "" || root == "." {
		return errors.New("LEDGER_ROOT is required for Git checkout sync")
	}
	if remote == "" {
		return errors.New("LEDGER_GIT_REMOTE_URL is required for Git checkout sync")
	}
	branch := strings.TrimSpace(cfg.LedgerGitBranch)
	if branch == "" {
		branch = "main"
	}
	if _, err := os.Stat(filepath.Join(root, ".git")); errors.Is(err, os.ErrNotExist) {
		entries, readErr := os.ReadDir(root)
		if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
			return fmt.Errorf("read ledger checkout: %w", readErr)
		}
		if len(entries) != 0 {
			return errors.New("ledger checkout is not a Git repository and is not empty")
		}
		if err := os.MkdirAll(filepath.Dir(root), 0o755); err != nil {
			return fmt.Errorf("create ledger checkout parent: %w", err)
		}
		if err := runLedgerGit(ctx, cfg, "clone", "--branch", branch, "--single-branch", remote, root); err != nil {
			return fmt.Errorf("clone ledger checkout: %w", err)
		}
		return nil
	} else if err != nil {
		return fmt.Errorf("inspect ledger checkout: %w", err)
	}

	status, err := ledgerGitOutput(ctx, cfg, "-C", root, "status", "--porcelain")
	if err != nil {
		return fmt.Errorf("check ledger checkout status: %w", err)
	}
	if strings.TrimSpace(status) != "" {
		return errors.New("ledger checkout has uncommitted changes; commit or discard them before indexing")
	}
	if err := runLedgerGit(ctx, cfg, "-C", root, "fetch", "--prune", "origin", branch); err != nil {
		return fmt.Errorf("fetch ledger checkout: %w", err)
	}
	if err := runLedgerGit(ctx, cfg, "-C", root, "merge", "--ff-only", "FETCH_HEAD"); err != nil {
		return fmt.Errorf("fast-forward ledger checkout: %w", err)
	}
	return nil
}

func runLedgerGit(ctx context.Context, cfg Config, args ...string) error {
	_, err := ledgerGitOutput(ctx, cfg, args...)
	return err
}

func ledgerGitOutput(ctx context.Context, cfg Config, args ...string) (string, error) {
	cmdArgs := append([]string(nil), args...)
	if token := strings.TrimSpace(cfg.LedgerGitReadToken); token != "" {
		header := "Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte("x-access-token:"+token))
		cmdArgs = append([]string{"-c", "http.extraHeader=" + header}, cmdArgs...)
	}
	cmd := exec.CommandContext(ctx, "git", cmdArgs...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s: %w", strings.Join(redactGitArgs(args), " "), err)
	}
	return string(output), nil
}

func redactGitArgs(args []string) []string {
	// Git's output is intentionally not included: it can echo an authenticated
	// remote URL supplied by an operator.
	return append([]string(nil), args...)
}
