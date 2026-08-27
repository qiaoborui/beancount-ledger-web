package app

import (
	"encoding/base64"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

func TestLoadSelfHostedConfigReadsMaintenanceMode(t *testing.T) {
	t.Setenv("LEDGER_MAINTENANCE_MODE", "true")

	if !LoadSelfHostedConfig().MaintenanceMode {
		t.Fatal("MaintenanceMode=false, want true")
	}
}

func TestGmailDeliveryModeDefaultsByDeployment(t *testing.T) {
	if got := LoadWebConfig().GmailDeliveryMode; got != "webhook" {
		t.Fatalf("web delivery mode=%q, want webhook", got)
	}
	if got := LoadSelfHostedConfig().GmailDeliveryMode; got != "poll" {
		t.Fatalf("self-host delivery mode=%q, want poll", got)
	}
}

func TestValidateGmailPollModeDoesNotRequirePubSubOrCron(t *testing.T) {
	cfg := Config{
		GmailDeliveryMode:       "poll",
		GmailPollInterval:       15 * time.Minute,
		GmailPollTimeout:        14 * time.Minute,
		GmailClientID:           "client",
		GmailClientSecret:       "secret",
		GmailOAuthRedirectURL:   "https://ledger.example/api/integrations/gmail/callback",
		GmailTokenEncryptionKey: base64.RawStdEncoding.EncodeToString(make([]byte, 32)),
		GmailAllowedSenders:     []string{"billing@example.com"},
		GmailSyncLookbackDays:   30,
		GmailZipTimeoutSeconds:  14 * 60,
	}
	if err := validateGmailAutomationConfig(cfg); err != nil {
		t.Fatal(err)
	}
}

func TestValidateGmailAutomationConfigRejectsUnknownDeliveryMode(t *testing.T) {
	cfg := Config{GmailDeliveryMode: "push", GmailClientID: "configured"}
	if err := validateGmailAutomationConfig(cfg); err == nil || !strings.Contains(err.Error(), "GMAIL_DELIVERY_MODE") {
		t.Fatalf("error=%v", err)
	}
}

func TestValidateGmailPollModeKeepsTimeoutBelowSyncLease(t *testing.T) {
	cfg := Config{
		GmailDeliveryMode:       "poll",
		GmailPollInterval:       15 * time.Minute,
		GmailPollTimeout:        15 * time.Minute,
		GmailClientID:           "client",
		GmailClientSecret:       "secret",
		GmailOAuthRedirectURL:   "https://ledger.example/api/integrations/gmail/callback",
		GmailTokenEncryptionKey: base64.RawStdEncoding.EncodeToString(make([]byte, 32)),
		GmailAllowedSenders:     []string{"billing@example.com"},
		GmailSyncLookbackDays:   30,
		GmailZipTimeoutSeconds:  14 * 60,
	}
	if err := validateGmailAutomationConfig(cfg); err == nil || !strings.Contains(err.Error(), "GMAIL_POLL_TIMEOUT") {
		t.Fatalf("error=%v", err)
	}
}

func TestLoadConfigDefaultsAllowLongZIPWorkerSearch(t *testing.T) {
	t.Setenv("GMAIL_POLL_TIMEOUT", "")
	t.Setenv("GMAIL_ZIP_TIMEOUT_SECONDS", "")

	cfg := LoadConfig()
	if cfg.GmailPollTimeout != 14*time.Minute || cfg.GmailZipTimeoutSeconds != 14*60 {
		t.Fatalf("poll timeout=%s zip timeout=%ds, want 14m and 840s", cfg.GmailPollTimeout, cfg.GmailZipTimeoutSeconds)
	}
}

func TestGmailLongImportTimeoutsStayInsideSyncLease(t *testing.T) {
	zipTimeout := time.Duration(maxGmailZIPTimeoutSeconds) * time.Second
	if zipTimeout > maxGmailPollTimeout {
		t.Fatalf("ZIP timeout %s exceeds poll timeout %s", zipTimeout, maxGmailPollTimeout)
	}
	if maxGmailPollTimeout >= gmailSyncLeaseTTL {
		t.Fatalf("poll timeout %s must stay below sync lease %s", maxGmailPollTimeout, gmailSyncLeaseTTL)
	}
}

func TestLoadConfigReadsZIPWorker(t *testing.T) {
	t.Setenv("ZIP_WORKER_URL", "https://zip-worker.example")

	cfg := LoadConfig()

	if cfg.ZIPWorkerURL != "https://zip-worker.example" || cfg.ZIPWorkerAudience != cfg.ZIPWorkerURL {
		t.Fatalf("worker URL=%q audience=%q", cfg.ZIPWorkerURL, cfg.ZIPWorkerAudience)
	}
}

func TestLoadWebConfigReadsTelegramWebhookSecret(t *testing.T) {
	t.Setenv("TELEGRAM_WEBHOOK_SECRET", "telegram-webhook-secret")

	cfg := LoadWebConfig()

	if cfg.TelegramWebhookSecret != "telegram-webhook-secret" {
		t.Fatalf("TelegramWebhookSecret=%q, want configured secret", cfg.TelegramWebhookSecret)
	}
}

func TestValidateConfigRejectsInsecureZIPWorkerURL(t *testing.T) {
	cfg := Config{LedgerStorage: "filesystem", ZIPWorkerURL: "http://zip-worker.example", ZIPWorkerAudience: "http://zip-worker.example"}

	if err := ValidateConfig(cfg); err == nil || !strings.Contains(err.Error(), "HTTPS") {
		t.Fatalf("error=%v", err)
	}
}

func TestValidateSelfHostedConfigAllowsInternalZIPWorker(t *testing.T) {
	cfg := Config{SelfHosted: true, ZIPWorkerURL: "http://zip-worker:8080"}

	if err := validateZIPWorkerConfig(cfg); err != nil {
		t.Fatalf("error=%v", err)
	}
}

func TestValidateConfigRejectsInvalidTelegramWebhookSecret(t *testing.T) {
	cfg := Config{LedgerStorage: "filesystem", TelegramWebhookSecret: "base64+secret="}

	if err := ValidateConfig(cfg); err == nil || !strings.Contains(err.Error(), "TELEGRAM_WEBHOOK_SECRET") {
		t.Fatalf("error=%v", err)
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

func TestValidateConfigAuthTransportModes(t *testing.T) {
	if err := ValidateConfig(Config{LedgerStorage: "filesystem", AuthTransport: "https"}); err != nil {
		t.Fatalf("https transport should be valid: %v", err)
	}
	if err := ValidateConfig(Config{LedgerStorage: "filesystem", AuthTransport: "smtp"}); err == nil || !strings.Contains(err.Error(), "LEDGER_AUTH_TRANSPORT") {
		t.Fatalf("invalid transport error=%v", err)
	}
	t.Setenv("WEBAUTHN_RP_ID", "ledger.example.com")
	if err := ValidateConfig(Config{LedgerStorage: "filesystem", AuthTransport: "http"}); err == nil || !strings.Contains(err.Error(), "requires") {
		t.Fatalf("http WebAuthn config error=%v", err)
	}
}

func TestLoadConfigPreservesInvalidAuthTransportForValidation(t *testing.T) {
	t.Setenv("LEDGER_AUTH_TRANSPORT", "smtp")
	cfg := LoadConfig()
	if err := ValidateConfig(cfg); err == nil || !strings.Contains(err.Error(), "LEDGER_AUTH_TRANSPORT") {
		t.Fatalf("invalid transport error=%v", err)
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

func TestLoadWebConfigRejectsFilesystemWorkerVariables(t *testing.T) {
	t.Setenv("AGENT_SERVICE_URL", "http://agent:8080")
	t.Setenv("AGENT_SERVICE_TOKEN", "test-agent-token")
	t.Setenv("LEDGER_STORAGE", "filesystem")
	t.Setenv("LEDGER_READ_MODEL", "files")
	t.Setenv("LEDGER_READ_MODEL_STRICT", "false")
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("AUTH_SECRET", "test-auth-secret")
	t.Setenv("LEDGER_GITHUB_OWNER", "example")
	t.Setenv("LEDGER_GITHUB_REPO", "ledger")
	t.Setenv("LEDGER_GITHUB_TOKEN", "secret")
	t.Setenv("LEDGER_ENABLED_MODULES", "importers")

	cfg := LoadWebConfig()

	if cfg.LedgerStorage != "github_api" || cfg.LedgerReadModel != "postgres" || !cfg.ReadModelStrict || cfg.LedgerFilesystemLockEnabled {
		t.Fatalf("web config did not force stateless modes: %#v", cfg)
	}
	if cfg.LedgerRoot != "" || cfg.RuntimeDir != "" {
		t.Fatalf("web config should not use local ledger/runtime paths: %#v", cfg)
	}
	if got := strings.Join(cfg.EnabledModules, ","); got != "importers" {
		t.Fatalf("EnabledModules=%q, want importers", got)
	}
	for _, key := range []string{"LEDGER_ROOT", "RUNTIME_DIR", "BEAN_CHECK_BIN", "INDEXER_CONFIG_URL"} {
		t.Setenv(key, "/misplaced/value")
		if err := ValidateWebConfig(cfg); err == nil || !strings.Contains(err.Error(), key) {
			t.Fatalf("expected misplaced %s to fail fast, got %v", key, err)
		}
		t.Setenv(key, "")
	}
}

func TestLoadSelfHostedConfigForcesGitHubAPITopology(t *testing.T) {
	t.Setenv("AGENT_SERVICE_URL", "http://agent:8080")
	t.Setenv("AGENT_SERVICE_TOKEN", "test-agent-token")
	t.Setenv("LEDGER_AUTH_DISABLED", "false")
	t.Setenv("LEDGER_AUTH_TRANSPORT", "http")
	t.Setenv("INDEXER_HEALTH_URL", "http://indexer:3001/health")
	t.Setenv("INDEXER_IDENTITY_TOKEN", "indexer-identity-token")
	t.Setenv("LEDGER_STORAGE", "github_api")
	t.Setenv("LEDGER_READ_MODEL", "files")
	t.Setenv("LEDGER_READ_MODEL_STRICT", "false")
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("AUTH_SECRET", "self-hosted-auth-secret")
	t.Setenv("APP_PASSWORD", "self-hosted-password")
	t.Setenv("LEDGER_GITHUB_OWNER", "example")
	t.Setenv("LEDGER_GITHUB_REPO", "ledger")
	t.Setenv("LEDGER_GITHUB_TOKEN", "secret")

	cfg := LoadSelfHostedConfig()
	if !cfg.SelfHosted || cfg.LedgerStorage != "github_api" || cfg.LedgerReadModel != "postgres" || !cfg.ReadModelStrict || cfg.LedgerFilesystemLockEnabled {
		t.Fatalf("self-hosted topology = %#v", cfg)
	}
	if cfg.RuntimeDir != "" || cfg.LedgerRoot != "" {
		t.Fatalf("self-hosted API must not receive filesystem paths: %#v", cfg)
	}
	if err := ValidateSelfHostedConfig(cfg); err != nil {
		t.Fatal(err)
	}
}

func TestValidateSelfHostedConfigRequiresPlatformSecretsNotRuntimeGitHubConfig(t *testing.T) {
	t.Setenv("AGENT_SERVICE_URL", "http://agent:8080")
	t.Setenv("AGENT_SERVICE_TOKEN", "test-agent-token")
	t.Setenv("LEDGER_AUTH_DISABLED", "false")
	t.Setenv("PUBLIC_ORIGIN", "")
	t.Setenv("WEBAUTHN_PUBLIC_ORIGIN", "")
	t.Setenv("WEBAUTHN_RP_ID", "")
	t.Setenv("AUTH_SECRET", "")
	t.Setenv("APP_PASSWORD", "")
	cfg := Config{
		LedgerStorage:        "github_api",
		DatabaseURL:          "postgres://example",
		LedgerReadModel:      "postgres",
		ReadModelStrict:      true,
		AuthTransport:        "http",
		IndexerHealthURL:     "http://indexer:3001/health",
		IndexerIdentityToken: "indexer-identity-token",
		AgentServiceURL:      "http://agent:8080",
		AgentServiceToken:    "test-agent-token",
	}

	if err := ValidateSelfHostedConfig(cfg); err == nil || !strings.Contains(err.Error(), "AUTH_SECRET") {
		t.Fatalf("error=%v", err)
	}

	t.Setenv("AUTH_SECRET", "runtime-encryption-key")
	if err := ValidateSelfHostedConfig(cfg); err != nil {
		t.Fatalf("database-backed runtime configuration should allow missing GitHub env vars: %v", err)
	}
}

func TestValidateSelfHostedConfigRequiresCoherentHTTPSOrigin(t *testing.T) {
	t.Setenv("AUTH_SECRET", "runtime-encryption-key")
	t.Setenv("PUBLIC_ORIGIN", "https://ledger.home.example")
	t.Setenv("WEBAUTHN_PUBLIC_ORIGIN", "https://ledger.home.example")
	t.Setenv("WEBAUTHN_RP_ID", "home.example")
	cfg := Config{
		LedgerStorage:        "github_api",
		DatabaseURL:          "postgres://example",
		LedgerReadModel:      "postgres",
		ReadModelStrict:      true,
		AuthTransport:        "https",
		IndexerHealthURL:     "http://indexer:3001/health",
		IndexerIdentityToken: "indexer-identity-token",
		AgentServiceURL:      "http://agent:8080",
		AgentServiceToken:    "test-agent-token",
	}
	if err := ValidateSelfHostedConfig(cfg); err != nil {
		t.Fatalf("valid reverse-proxy origin rejected: %v", err)
	}
	t.Setenv("WEBAUTHN_RP_ID", "other.example")
	if err := ValidateSelfHostedConfig(cfg); err == nil || !strings.Contains(err.Error(), "WEBAUTHN_RP_ID") {
		t.Fatalf("mismatched RP ID error=%v", err)
	}
}

func TestValidateSelfHostedConfigRejectsPasskeysInHTTPMode(t *testing.T) {
	t.Setenv("AUTH_SECRET", "runtime-encryption-key")
	t.Setenv("PUBLIC_ORIGIN", "https://ledger.home.example")
	cfg := Config{
		LedgerStorage:        "github_api",
		DatabaseURL:          "postgres://example",
		LedgerReadModel:      "postgres",
		ReadModelStrict:      true,
		AuthTransport:        "http",
		IndexerHealthURL:     "http://indexer:3001/health",
		IndexerIdentityToken: "indexer-identity-token",
		AgentServiceURL:      "http://agent:8080",
		AgentServiceToken:    "test-agent-token",
	}
	if err := ValidateSelfHostedConfig(cfg); err == nil || !strings.Contains(err.Error(), "requires LEDGER_AUTH_TRANSPORT=https") {
		t.Fatalf("HTTP origin error=%v", err)
	}
}

func TestLoadIndexerConfigReadsGitSyncSettings(t *testing.T) {
	t.Setenv("LEDGER_ROOT", t.TempDir())
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("LEDGER_GIT_SYNC_ENABLED", "true")
	t.Setenv("LEDGER_GIT_REMOTE_URL", "https://github.com/example/ledger.git")
	t.Setenv("LEDGER_GITHUB_INDEX_TOKEN", "read-only-token")

	cfg := LoadIndexerConfig()
	if !cfg.LedgerGitSyncEnabled || cfg.LedgerGitRemoteURL == "" || cfg.LedgerGitReadToken != "read-only-token" {
		t.Fatalf("indexer Git sync settings were not loaded: %#v", cfg)
	}
	if err := ValidateIndexerConfig(cfg); err != nil {
		t.Fatal(err)
	}
}

func TestValidateWebConfigRequiresPostgres(t *testing.T) {
	t.Setenv("AUTH_SECRET", "test-auth-secret")
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

func TestValidateIndexerConfigRequiresPersistentAbsoluteLedgerRoot(t *testing.T) {
	cfg := Config{DatabaseURL: "postgres://example", LedgerRoot: "relative-ledger", LedgerReadModel: "postgres"}
	if err := ValidateIndexerConfig(cfg); err == nil || !strings.Contains(err.Error(), "absolute") {
		t.Fatalf("relative LEDGER_ROOT error=%v", err)
	}
	cfg.LedgerRoot = filepath.Join(t.TempDir(), "missing")
	if err := ValidateIndexerConfig(cfg); err == nil || !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("missing LEDGER_ROOT error=%v", err)
	}
}

func TestValidateIndexerConfigRequiresIdentityForRuntimeConfig(t *testing.T) {
	cfg := Config{
		DatabaseURL:      "postgres://example",
		LedgerRoot:       t.TempDir(),
		LedgerReadModel:  "postgres",
		IndexerConfigURL: "http://server:3000/api/indexer/config",
	}
	if err := ValidateIndexerConfig(cfg); err == nil || !strings.Contains(err.Error(), "INDEXER_IDENTITY_TOKEN") {
		t.Fatalf("identity token error=%v", err)
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
