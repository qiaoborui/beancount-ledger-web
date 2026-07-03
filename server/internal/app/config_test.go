package app

import (
	"path/filepath"
	"testing"
)

func TestLoadConfigFilesystemRespectsLedgerRoot(t *testing.T) {
	ledgerRoot := t.TempDir()
	gitWorkDir := t.TempDir()
	t.Setenv("LEDGER_STORAGE", "filesystem")
	t.Setenv("LEDGER_ROOT", ledgerRoot)
	t.Setenv("LEDGER_GIT_WORKDIR", gitWorkDir)

	cfg := LoadConfig()

	if cfg.LedgerRoot != filepath.Clean(ledgerRoot) {
		t.Fatalf("LedgerRoot=%q, want %q", cfg.LedgerRoot, filepath.Clean(ledgerRoot))
	}
}

func TestLoadConfigRemoteGitUsesWorkdirCheckout(t *testing.T) {
	ledgerRoot := t.TempDir()
	gitWorkDir := t.TempDir()
	t.Setenv("LEDGER_STORAGE", "remote_git")
	t.Setenv("LEDGER_ROOT", ledgerRoot)
	t.Setenv("LEDGER_GIT_WORKDIR", gitWorkDir)

	cfg := LoadConfig()

	want := filepath.Join(gitWorkDir, "repo")
	if cfg.LedgerRoot != filepath.Clean(want) {
		t.Fatalf("LedgerRoot=%q, want %q", cfg.LedgerRoot, filepath.Clean(want))
	}
}
