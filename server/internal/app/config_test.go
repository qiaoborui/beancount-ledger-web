package app

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadConfigFilesystemRespectsLedgerRoot(t *testing.T) {
	ledgerRoot := t.TempDir()
	t.Setenv("LEDGER_STORAGE", "filesystem")
	t.Setenv("LEDGER_ROOT", ledgerRoot)

	cfg := LoadConfig()

	if cfg.LedgerRoot != filepath.Clean(ledgerRoot) {
		t.Fatalf("LedgerRoot=%q, want %q", cfg.LedgerRoot, filepath.Clean(ledgerRoot))
	}
}

func TestLoadConfigReadsLedgerClusterID(t *testing.T) {
	t.Setenv("LEDGER_CLUSTER_ID", "personal-ledger")

	cfg := LoadConfig()

	if cfg.LedgerClusterID != "personal-ledger" {
		t.Fatalf("LedgerClusterID=%q, want personal-ledger", cfg.LedgerClusterID)
	}
}

func TestLoadConfigReadsEnabledModules(t *testing.T) {
	t.Setenv("LEDGER_ENABLED_MODULES", " importers , ")

	cfg := LoadConfig()

	if got := strings.Join(cfg.EnabledModules, ","); got != "importers" {
		t.Fatalf("EnabledModules=%q, want importers", got)
	}
}

func TestLoadConfigReadsNotificationRefreshInterval(t *testing.T) {
	t.Setenv("LEDGER_NOTIFICATION_REFRESH_INTERVAL", "15m")

	if got := LoadConfig().NotificationRefreshInterval; got != "15m" {
		t.Fatalf("NotificationRefreshInterval=%q, want 15m", got)
	}
}

func TestLedgerClusterIDFallsBackToGitHubRepository(t *testing.T) {
	cfg := Config{LedgerGitHubOwner: "Example", LedgerGitHubRepo: "Ledger", LedgerGitBranch: "preview"}

	if got := ledgerClusterID(cfg); got != "github:example/ledger@preview" {
		t.Fatalf("ledgerClusterID=%q", got)
	}
}

func TestLedgerClusterIDFallsBackToFilesystemLedgerRoot(t *testing.T) {
	ledgerRoot := t.TempDir()
	first := ledgerClusterID(Config{LedgerRoot: ledgerRoot})
	second := ledgerClusterID(Config{LedgerRoot: filepath.Clean(ledgerRoot)})

	if !strings.HasPrefix(first, "filesystem:") || first != second {
		t.Fatalf("ledgerClusterID=%q second=%q", first, second)
	}
}

func TestLoadConfigDefaultsToFilesystem(t *testing.T) {
	cfg := LoadConfig()

	if cfg.LedgerStorage != "filesystem" {
		t.Fatalf("LedgerStorage=%q, want filesystem", cfg.LedgerStorage)
	}
}

func TestValidateConfigRejectsRemoteGit(t *testing.T) {
	cfg := Config{LedgerStorage: "remote_git"}

	err := ValidateConfig(cfg)
	if err == nil {
		t.Fatal("expected remote_git to be rejected")
	}
}

func TestValidateConfigRejectsUnknownEnabledModule(t *testing.T) {
	cfg := Config{LedgerStorage: "filesystem", EnabledModules: []string{"missing"}}

	if err := ValidateConfig(cfg); err == nil {
		t.Fatal("expected unknown module to be rejected")
	}
}

func TestValidateConfigRejectsInvalidNotificationRefreshInterval(t *testing.T) {
	cfg := Config{LedgerStorage: "filesystem", NotificationRefreshInterval: "later"}

	if err := ValidateConfig(cfg); err == nil {
		t.Fatal("expected invalid notification refresh interval to be rejected")
	}
}

func TestLoadConfigGitHubAlias(t *testing.T) {
	t.Setenv("LEDGER_STORAGE", "github")
	t.Setenv("LEDGER_GITHUB_OWNER", "example")
	t.Setenv("LEDGER_GITHUB_REPO", "ledger")
	t.Setenv("LEDGER_GITHUB_TOKEN", "secret")
	t.Setenv("LEDGER_ENABLED_MODULES", "importers")

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
	if err := ValidateConfig(cfg); err != nil {
		t.Fatal(err)
	}
}

func TestLoadWebConfigIgnoresLegacyStorageModes(t *testing.T) {
	t.Setenv("LEDGER_STORAGE", "filesystem")
	t.Setenv("LEDGER_READ_MODEL", "files")
	t.Setenv("LEDGER_READ_MODEL_STRICT", "false")
	t.Setenv("LEDGER_ROOT", "/tmp/ledger")
	t.Setenv("RUNTIME_DIR", "/tmp/runtime")
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("LEDGER_GITHUB_OWNER", "example")
	t.Setenv("LEDGER_GITHUB_REPO", "ledger")
	t.Setenv("LEDGER_GITHUB_TOKEN", "secret")
	t.Setenv("LEDGER_ENABLED_MODULES", "importers")

	cfg := LoadWebConfig()

	if cfg.LedgerStorage != "github_api" || cfg.LedgerReadModel != "postgres" || !cfg.ReadModelStrict {
		t.Fatalf("web config did not force stateless modes: %#v", cfg)
	}
	if cfg.LedgerRoot != "" || cfg.RuntimeDir != "" {
		t.Fatalf("web config should not use local ledger/runtime paths: %#v", cfg)
	}
	if got := strings.Join(cfg.EnabledModules, ","); got != "importers" {
		t.Fatalf("EnabledModules=%q, want importers", got)
	}
	if err := ValidateWebConfig(cfg); err != nil {
		t.Fatal(err)
	}
}

func TestValidateWebConfigRequiresPostgresAndGitHub(t *testing.T) {
	cfg := LoadWebConfig()

	if err := ValidateWebConfig(cfg); err == nil {
		t.Fatal("expected missing DATABASE_URL and GitHub config to be rejected")
	}
}

func TestValidateIndexerConfigRequiresTwoPostgresConnections(t *testing.T) {
	t.Setenv("POSTGRES_MAX_OPEN_CONNS", "1")
	cfg := Config{
		DatabaseURL:     "postgres://example",
		LedgerRoot:      t.TempDir(),
		LedgerReadModel: "postgres",
	}

	if err := ValidateIndexerConfig(cfg); err == nil {
		t.Fatal("expected indexer pool capacity to be rejected")
	}
}

func TestGitHubAPIRequiresExplicitRepoConfig(t *testing.T) {
	cfg := Config{
		LedgerStorage:     "github_api",
		LedgerGitHubToken: "secret",
	}

	_, err := newGitHubLedgerClient(cfg)
	if err == nil {
		t.Fatal("expected explicit github owner/repo requirement")
	}
}
