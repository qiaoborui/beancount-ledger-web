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

func TestLoadConfigGitHubAlias(t *testing.T) {
	t.Setenv("LEDGER_STORAGE", "github")
	t.Setenv("LEDGER_GITHUB_OWNER", "example")
	t.Setenv("LEDGER_GITHUB_REPO", "ledger")
	t.Setenv("LEDGER_GITHUB_TOKEN", "secret")

	cfg := LoadConfig()

	if cfg.LedgerStorage != "github_api" {
		t.Fatalf("LedgerStorage=%q, want github_api", cfg.LedgerStorage)
	}
	client, err := newGitHubLedgerClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if client.owner != "example" || client.repo != "ledger" {
		t.Fatalf("github repo=(%q,%q), want example/ledger", client.owner, client.repo)
	}
}

func TestGitHubAPIRequiresExplicitRepoConfig(t *testing.T) {
	cfg := Config{
		LedgerStorage:     "github_api",
		LedgerGitRemote:   "https://github.com/example/ledger.git",
		LedgerGitHubToken: "secret",
	}

	_, err := newGitHubLedgerClient(cfg)
	if err == nil {
		t.Fatal("expected explicit github owner/repo requirement")
	}
}
