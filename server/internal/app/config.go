package app

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	defaultGmailPollTimeout       = 14 * time.Minute
	maxGmailPollTimeout           = 14 * time.Minute
	defaultGmailZIPTimeoutSeconds = 14 * 60
	maxGmailZIPTimeoutSeconds     = 14 * 60
)

type Config struct {
	SelfHosted                  bool
	MaintenanceMode             bool
	AppRoot                     string
	LedgerClusterID             string
	LedgerRoot                  string
	LedgerLockFile              string
	LedgerFilesystemLockEnabled bool
	AuthTransport               string
	RuntimeDir                  string
	StaticDir                   string
	ServeStatic                 bool
	Port                        string
	LedgerStorage               string
	LedgerGitBranch             string
	LedgerGitSHA                string
	LedgerIndexForceRebuild     bool
	LedgerGitHubOwner           string
	LedgerGitHubRepo            string
	LedgerGitHubToken           string
	LedgerGitHubAPIURL          string
	LedgerGitSyncEnabled        bool
	LedgerGitRemoteURL          string
	LedgerGitReadToken          string
	LedgerIndexNotifyEnabled    bool
	LedgerIndexBeanCheckEnabled bool
	IndexerConfigURL            string
	IndexerHealthURL            string
	IndexerIdentityToken        string
	DatabaseURL                 string
	LedgerReadModel             string
	ReadModelStrict             bool
	EnabledModules              []string
	NotificationRefreshInterval string
	GmailClientID               string
	GmailClientSecret           string
	GmailOAuthRedirectURL       string
	GmailPubSubTopic            string
	GmailPubSubAudience         string
	GmailPubSubServiceAccount   string
	GmailDeliveryMode           string
	GmailPollInterval           time.Duration
	GmailPollTimeout            time.Duration
	GmailLabel                  string
	GmailAllowedSenders         []string
	GmailTokenEncryptionKey     string
	GmailSyncLookbackDays       int
	GmailZipPasswords           []string
	GmailZipTimeoutSeconds      int
	ZIPWorkerURL                string
	ZIPWorkerAudience           string
	AgentServiceURL             string
	AgentServiceAudience        string
	AgentServiceToken           string
	TelegramWebhookSecret       string
	CronSecret                  string
	CronOIDCAudience            string
	CronOIDCServiceAccount      string
}

func LoadConfig() Config {
	zipWorkerURL, zipWorkerAudience := loadZIPWorkerConfig()
	storage := strings.ToLower(env("LEDGER_STORAGE", "filesystem"))
	if storage == "github" {
		storage = "github_api"
	}
	ledgerRoot := strings.TrimSpace(os.Getenv("LEDGER_ROOT"))
	ledgerLockFile := strings.TrimSpace(os.Getenv("LEDGER_LOCK_FILE"))
	if ledgerLockFile == "" && ledgerRoot != "" {
		ledgerLockFile = filepath.Join(ledgerRoot, ".ledger-web.lock")
	}
	runtimeDir := os.Getenv("RUNTIME_DIR")
	if runtimeDir == "" {
		runtimeDir = filepath.Join(os.TempDir(), "beancount-ledger-web", "runtime")
	}
	ledgerReadModel := strings.ToLower(env("LEDGER_READ_MODEL", "files"))

	return Config{
		MaintenanceMode:             envBool("LEDGER_MAINTENANCE_MODE", false),
		AppRoot:                     "",
		LedgerClusterID:             strings.TrimSpace(os.Getenv("LEDGER_CLUSTER_ID")),
		LedgerRoot:                  filepath.Clean(ledgerRoot),
		LedgerLockFile:              filepath.Clean(ledgerLockFile),
		LedgerFilesystemLockEnabled: envBool("LEDGER_FILESYSTEM_LOCK_ENABLED", false),
		AuthTransport:               authTransportMode(),
		RuntimeDir:                  filepath.Clean(runtimeDir),
		StaticDir:                   filepath.Clean(env("STATIC_DIR", "")),
		ServeStatic:                 envBool("SERVE_STATIC", false),
		Port:                        env("PORT", "3000"),
		LedgerStorage:               storage,
		LedgerGitBranch:             env("LEDGER_GIT_BRANCH", "main"),
		LedgerGitSHA:                strings.TrimSpace(os.Getenv("LEDGER_GIT_SHA")),
		LedgerIndexForceRebuild:     envBool("LEDGER_INDEX_FORCE_REBUILD", false),
		LedgerGitHubOwner:           strings.TrimSpace(os.Getenv("LEDGER_GITHUB_OWNER")),
		LedgerGitHubRepo:            strings.TrimSpace(os.Getenv("LEDGER_GITHUB_REPO")),
		LedgerGitHubToken:           strings.TrimSpace(os.Getenv("LEDGER_GITHUB_TOKEN")),
		LedgerGitHubAPIURL:          strings.TrimSpace(os.Getenv("LEDGER_GITHUB_API_URL")),
		LedgerGitSyncEnabled:        envBool("LEDGER_GIT_SYNC_ENABLED", false),
		LedgerGitRemoteURL:          strings.TrimSpace(os.Getenv("LEDGER_GIT_REMOTE_URL")),
		LedgerGitReadToken:          strings.TrimSpace(os.Getenv("LEDGER_GITHUB_INDEX_TOKEN")),
		LedgerIndexNotifyEnabled:    envBool("LEDGER_INDEX_NOTIFY_ENABLED", false),
		LedgerIndexBeanCheckEnabled: envBool("LEDGER_INDEX_BEAN_CHECK_ENABLED", false),
		IndexerConfigURL:            strings.TrimSpace(os.Getenv("INDEXER_CONFIG_URL")),
		IndexerHealthURL:            strings.TrimSpace(os.Getenv("INDEXER_HEALTH_URL")),
		IndexerIdentityToken:        strings.TrimSpace(os.Getenv("INDEXER_IDENTITY_TOKEN")),
		DatabaseURL:                 strings.TrimSpace(os.Getenv("DATABASE_URL")),
		LedgerReadModel:             ledgerReadModel,
		ReadModelStrict:             envBool("LEDGER_READ_MODEL_STRICT", ledgerReadModel == "postgres" || ledgerReadModel == "pg"),
		EnabledModules:              parseEnabledModules(os.Getenv("LEDGER_ENABLED_MODULES")),
		NotificationRefreshInterval: env("LEDGER_NOTIFICATION_REFRESH_INTERVAL", "off"),
		GmailClientID:               strings.TrimSpace(os.Getenv("GMAIL_CLIENT_ID")),
		GmailClientSecret:           strings.TrimSpace(os.Getenv("GMAIL_CLIENT_SECRET")),
		GmailOAuthRedirectURL:       strings.TrimSpace(os.Getenv("GMAIL_OAUTH_REDIRECT_URL")),
		GmailPubSubTopic:            strings.TrimSpace(os.Getenv("GMAIL_PUBSUB_TOPIC")),
		GmailPubSubAudience:         strings.TrimSpace(os.Getenv("GMAIL_PUBSUB_AUDIENCE")),
		GmailPubSubServiceAccount:   strings.ToLower(strings.TrimSpace(os.Getenv("GMAIL_PUBSUB_SERVICE_ACCOUNT"))),
		GmailDeliveryMode:           gmailDeliveryModeFromEnv("webhook"),
		GmailPollInterval:           envDuration("GMAIL_POLL_INTERVAL", 15*time.Minute),
		GmailPollTimeout:            envDuration("GMAIL_POLL_TIMEOUT", defaultGmailPollTimeout),
		GmailLabel:                  env("GMAIL_LABEL", "Ledger/Bills"),
		GmailAllowedSenders:         parseCSVLower(os.Getenv("GMAIL_ALLOWED_SENDERS")),
		GmailTokenEncryptionKey:     strings.TrimSpace(os.Getenv("GMAIL_TOKEN_ENCRYPTION_KEY")),
		GmailSyncLookbackDays:       envInt("GMAIL_SYNC_LOOKBACK_DAYS", 30),
		GmailZipPasswords:           parseCSV(os.Getenv("GMAIL_ZIP_PASSWORDS")),
		GmailZipTimeoutSeconds:      envInt("GMAIL_ZIP_TIMEOUT_SECONDS", defaultGmailZIPTimeoutSeconds),
		ZIPWorkerURL:                zipWorkerURL,
		ZIPWorkerAudience:           zipWorkerAudience,
		AgentServiceURL:             strings.TrimRight(strings.TrimSpace(os.Getenv("AGENT_SERVICE_URL")), "/"),
		AgentServiceAudience:        strings.TrimSpace(os.Getenv("AGENT_SERVICE_AUDIENCE")),
		AgentServiceToken:           strings.TrimSpace(os.Getenv("AGENT_SERVICE_TOKEN")),
		TelegramWebhookSecret:       strings.TrimSpace(os.Getenv("TELEGRAM_WEBHOOK_SECRET")),
		CronSecret:                  strings.TrimSpace(os.Getenv("CRON_SECRET")),
		CronOIDCAudience:            strings.TrimSpace(os.Getenv("CRON_OIDC_AUDIENCE")),
		CronOIDCServiceAccount:      strings.ToLower(strings.TrimSpace(os.Getenv("CRON_OIDC_SERVICE_ACCOUNT"))),
	}
}

func LoadWebConfig() Config {
	cfg := loadBaseConfig()
	cfg.LedgerStorage = "github_api"
	cfg.LedgerReadModel = "postgres"
	cfg.ReadModelStrict = true
	cfg.RuntimeDir = ""
	cfg.LedgerRoot = ""
	return cfg
}

// LoadSelfHostedConfig selects the self-hosted API topology. It deliberately
// remains stateless: ledger reads and writes go through the GitHub API, while
// the separate indexer owns the local Git checkout used to build Postgres.
func LoadSelfHostedConfig() Config {
	cfg := LoadWebConfig()
	cfg.SelfHosted = true
	// A self-hosted server commonly has no public ingress. Polling only makes
	// outbound Gmail API calls, while a deployment that has a public endpoint
	// can opt back into the webhook mode explicitly.
	cfg.GmailDeliveryMode = gmailDeliveryModeFromEnv("poll")
	return cfg
}

func LoadIndexerConfig() Config {
	cfg := loadBaseConfig()
	cfg.LedgerStorage = "filesystem"
	cfg.LedgerReadModel = "postgres"
	cfg.ReadModelStrict = true
	ledgerRoot := strings.TrimSpace(os.Getenv("LEDGER_ROOT"))
	cfg.LedgerRoot = filepath.Clean(ledgerRoot)
	lockFile := strings.TrimSpace(os.Getenv("LEDGER_LOCK_FILE"))
	if lockFile == "" && ledgerRoot != "" {
		lockFile = filepath.Join(ledgerRoot, ".ledger-web.lock")
	}
	cfg.LedgerLockFile = filepath.Clean(lockFile)
	return cfg
}

func loadBaseConfig() Config {
	zipWorkerURL, zipWorkerAudience := loadZIPWorkerConfig()
	return Config{
		MaintenanceMode:             envBool("LEDGER_MAINTENANCE_MODE", false),
		AppRoot:                     "",
		LedgerClusterID:             strings.TrimSpace(os.Getenv("LEDGER_CLUSTER_ID")),
		AuthTransport:               authTransportMode(),
		StaticDir:                   filepath.Clean(env("STATIC_DIR", "")),
		ServeStatic:                 envBool("SERVE_STATIC", false),
		Port:                        env("PORT", "3000"),
		LedgerGitBranch:             env("LEDGER_GIT_BRANCH", "main"),
		LedgerGitSHA:                strings.TrimSpace(os.Getenv("LEDGER_GIT_SHA")),
		LedgerIndexForceRebuild:     envBool("LEDGER_INDEX_FORCE_REBUILD", false),
		LedgerGitHubOwner:           strings.TrimSpace(os.Getenv("LEDGER_GITHUB_OWNER")),
		LedgerGitHubRepo:            strings.TrimSpace(os.Getenv("LEDGER_GITHUB_REPO")),
		LedgerGitHubToken:           strings.TrimSpace(os.Getenv("LEDGER_GITHUB_TOKEN")),
		LedgerGitHubAPIURL:          strings.TrimSpace(os.Getenv("LEDGER_GITHUB_API_URL")),
		LedgerGitSyncEnabled:        envBool("LEDGER_GIT_SYNC_ENABLED", false),
		LedgerGitRemoteURL:          strings.TrimSpace(os.Getenv("LEDGER_GIT_REMOTE_URL")),
		LedgerGitReadToken:          strings.TrimSpace(os.Getenv("LEDGER_GITHUB_INDEX_TOKEN")),
		LedgerIndexNotifyEnabled:    envBool("LEDGER_INDEX_NOTIFY_ENABLED", false),
		LedgerIndexBeanCheckEnabled: envBool("LEDGER_INDEX_BEAN_CHECK_ENABLED", false),
		IndexerConfigURL:            strings.TrimSpace(os.Getenv("INDEXER_CONFIG_URL")),
		IndexerHealthURL:            strings.TrimSpace(os.Getenv("INDEXER_HEALTH_URL")),
		IndexerIdentityToken:        strings.TrimSpace(os.Getenv("INDEXER_IDENTITY_TOKEN")),
		DatabaseURL:                 strings.TrimSpace(os.Getenv("DATABASE_URL")),
		EnabledModules:              parseEnabledModules(os.Getenv("LEDGER_ENABLED_MODULES")),
		NotificationRefreshInterval: env("LEDGER_NOTIFICATION_REFRESH_INTERVAL", "off"),
		GmailClientID:               strings.TrimSpace(os.Getenv("GMAIL_CLIENT_ID")),
		GmailClientSecret:           strings.TrimSpace(os.Getenv("GMAIL_CLIENT_SECRET")),
		GmailOAuthRedirectURL:       strings.TrimSpace(os.Getenv("GMAIL_OAUTH_REDIRECT_URL")),
		GmailPubSubTopic:            strings.TrimSpace(os.Getenv("GMAIL_PUBSUB_TOPIC")),
		GmailPubSubAudience:         strings.TrimSpace(os.Getenv("GMAIL_PUBSUB_AUDIENCE")),
		GmailPubSubServiceAccount:   strings.ToLower(strings.TrimSpace(os.Getenv("GMAIL_PUBSUB_SERVICE_ACCOUNT"))),
		GmailDeliveryMode:           gmailDeliveryModeFromEnv("webhook"),
		GmailPollInterval:           envDuration("GMAIL_POLL_INTERVAL", 15*time.Minute),
		GmailPollTimeout:            envDuration("GMAIL_POLL_TIMEOUT", defaultGmailPollTimeout),
		GmailLabel:                  env("GMAIL_LABEL", "Ledger/Bills"),
		GmailAllowedSenders:         parseCSVLower(os.Getenv("GMAIL_ALLOWED_SENDERS")),
		GmailTokenEncryptionKey:     strings.TrimSpace(os.Getenv("GMAIL_TOKEN_ENCRYPTION_KEY")),
		GmailSyncLookbackDays:       envInt("GMAIL_SYNC_LOOKBACK_DAYS", 30),
		GmailZipPasswords:           parseCSV(os.Getenv("GMAIL_ZIP_PASSWORDS")),
		GmailZipTimeoutSeconds:      envInt("GMAIL_ZIP_TIMEOUT_SECONDS", defaultGmailZIPTimeoutSeconds),
		ZIPWorkerURL:                zipWorkerURL,
		ZIPWorkerAudience:           zipWorkerAudience,
		AgentServiceURL:             strings.TrimRight(strings.TrimSpace(os.Getenv("AGENT_SERVICE_URL")), "/"),
		AgentServiceAudience:        strings.TrimSpace(os.Getenv("AGENT_SERVICE_AUDIENCE")),
		AgentServiceToken:           strings.TrimSpace(os.Getenv("AGENT_SERVICE_TOKEN")),
		TelegramWebhookSecret:       strings.TrimSpace(os.Getenv("TELEGRAM_WEBHOOK_SECRET")),
		CronSecret:                  strings.TrimSpace(os.Getenv("CRON_SECRET")),
		CronOIDCAudience:            strings.TrimSpace(os.Getenv("CRON_OIDC_AUDIENCE")),
		CronOIDCServiceAccount:      strings.ToLower(strings.TrimSpace(os.Getenv("CRON_OIDC_SERVICE_ACCOUNT"))),
	}
}

func parseCSVLower(raw string) []string {
	values := parseCSV(raw)
	for index := range values {
		values[index] = strings.ToLower(values[index])
	}
	return values
}

func loadZIPWorkerConfig() (string, string) {
	workerURL := strings.TrimSpace(os.Getenv("ZIP_WORKER_URL"))
	audience := strings.TrimSpace(os.Getenv("ZIP_WORKER_AUDIENCE"))
	if audience == "" && strings.HasPrefix(workerURL, "https://") {
		audience = workerURL
	}
	return workerURL, audience
}

func parseCSV(raw string) []string {
	parts := strings.Split(raw, ",")
	values := make([]string, 0, len(parts))
	for _, part := range parts {
		if value := strings.TrimSpace(part); value != "" {
			values = append(values, value)
		}
	}
	return values
}

func parseEnabledModules(raw string) []string {
	parts := strings.Split(raw, ",")
	modules := make([]string, 0, len(parts))
	for _, part := range parts {
		if name := strings.TrimSpace(part); name != "" {
			modules = append(modules, name)
		}
	}
	return modules
}

func notificationRefreshInterval(raw string) (time.Duration, error) {
	value := strings.ToLower(strings.TrimSpace(raw))
	if value == "" || value == "off" || value == "disabled" {
		return 0, nil
	}
	interval, err := time.ParseDuration(value)
	if err != nil || interval <= 0 {
		return 0, errors.New("LEDGER_NOTIFICATION_REFRESH_INTERVAL must be a positive duration or off")
	}
	return interval, nil
}

func ValidateWebConfig(cfg Config) error {
	if err := validateAuthTransportConfig(cfg); err != nil {
		return err
	}
	for _, key := range []string{"LEDGER_ROOT", "RUNTIME_DIR", "BEAN_CHECK_BIN", "INDEXER_CONFIG_URL"} {
		if strings.TrimSpace(os.Getenv(key)) != "" {
			return fmt.Errorf("%s belongs to the indexer or filesystem runtime and must not be set on the stateless API service", key)
		}
	}
	if _, err := enabledBuiltinModules(cfg.EnabledModules); err != nil {
		return err
	}
	if _, err := notificationRefreshInterval(cfg.NotificationRefreshInterval); err != nil {
		return err
	}
	if err := validateZIPWorkerConfig(cfg); err != nil {
		return err
	}
	if err := validateGmailAutomationConfig(cfg); err != nil {
		return err
	}
	if err := validateTelegramWebhookConfig(cfg); err != nil {
		return err
	}
	if cfg.DatabaseURL == "" {
		return errors.New("DATABASE_URL is required")
	}
	if cfg.LedgerStorage != "github_api" {
		return errors.New("ledger-web is stateless and requires GitHub API ledger storage")
	}
	if !ledgerReadModelEnabled(cfg) || !cfg.ReadModelStrict {
		return errors.New("ledger-web requires the Postgres read model in strict mode")
	}
	if strings.TrimSpace(os.Getenv("AUTH_SECRET")) == "" {
		return errors.New("AUTH_SECRET is required")
	}
	if err := validateAgentServiceConfig(cfg, true); err != nil {
		return err
	}
	return nil
}

// ValidateSelfHostedConfig checks the mandatory boundaries for the Compose
// deployment before the HTTP server opens a listener.
func ValidateSelfHostedConfig(cfg Config) error {
	if err := ValidateWebConfig(cfg); err != nil {
		return err
	}
	if strings.TrimSpace(cfg.IndexerIdentityToken) == "" {
		return errors.New("INDEXER_IDENTITY_TOKEN is required for the self-hosted API")
	}
	if err := validateInternalServiceURL("INDEXER_HEALTH_URL", cfg.IndexerHealthURL); err != nil {
		return err
	}
	return validateSelfHostedOriginConfig(cfg)
}

func ValidateIndexerConfig(cfg Config) error {
	if cfg.DatabaseURL == "" {
		return errors.New("DATABASE_URL is required")
	}
	if strings.TrimSpace(cfg.LedgerRoot) == "" || cfg.LedgerRoot == "." {
		return errors.New("LEDGER_ROOT is required for ledger-indexer")
	}
	if !filepath.IsAbs(cfg.LedgerRoot) {
		return errors.New("LEDGER_ROOT must be an absolute path for ledger-indexer")
	}
	if info, err := os.Stat(cfg.LedgerRoot); err != nil {
		return fmt.Errorf("LEDGER_ROOT is unavailable: %w", err)
	} else if !info.IsDir() {
		return errors.New("LEDGER_ROOT must be a directory")
	}
	if cfg.LedgerFilesystemLockEnabled {
		if _, err := ledgerFilesystemLockPath(cfg); err != nil {
			return errors.New("LEDGER_LOCK_FILE is required for ledger-indexer")
		}
	}
	if !ledgerReadModelEnabled(cfg) {
		return errors.New("ledger-indexer requires the Postgres read model")
	}
	if cfg.LedgerGitSyncEnabled && strings.TrimSpace(cfg.LedgerGitRemoteURL) == "" {
		return errors.New("LEDGER_GIT_REMOTE_URL is required when LEDGER_GIT_SYNC_ENABLED=true")
	}
	if cfg.IndexerConfigURL != "" {
		if err := validateInternalServiceURL("INDEXER_CONFIG_URL", cfg.IndexerConfigURL); err != nil {
			return err
		}
		if strings.TrimSpace(cfg.IndexerIdentityToken) == "" {
			return errors.New("INDEXER_IDENTITY_TOKEN is required when INDEXER_CONFIG_URL is set")
		}
	}
	if maxOpenConns := postgresPoolSettingsFromEnv().maxOpenConns; maxOpenConns > 0 && maxOpenConns < 2 {
		return errors.New("ledger-indexer requires POSTGRES_MAX_OPEN_CONNS to be at least 2 when it is set")
	}
	return nil
}

func ValidateConfig(cfg Config) error {
	if err := validateAuthTransportConfig(cfg); err != nil {
		return err
	}
	if _, err := enabledBuiltinModules(cfg.EnabledModules); err != nil {
		return err
	}
	if _, err := notificationRefreshInterval(cfg.NotificationRefreshInterval); err != nil {
		return err
	}
	if err := validateZIPWorkerConfig(cfg); err != nil {
		return err
	}
	if err := validateGmailAutomationConfig(cfg); err != nil {
		return err
	}
	if err := validateTelegramWebhookConfig(cfg); err != nil {
		return err
	}
	switch strings.ToLower(strings.TrimSpace(cfg.LedgerStorage)) {
	case "", "filesystem", "file", "github_api":
	case "remote_git", "git":
		return errors.New("LEDGER_STORAGE=remote_git has been removed; use LEDGER_STORAGE=github_api for the stateless API or LEDGER_STORAGE=filesystem for the local ledger worker")
	default:
		return errors.New("unsupported LEDGER_STORAGE: " + cfg.LedgerStorage)
	}
	if githubAPIEnabled(cfg) {
		if strings.TrimSpace(cfg.LedgerGitHubOwner) == "" || strings.TrimSpace(cfg.LedgerGitHubRepo) == "" {
			return errors.New("LEDGER_GITHUB_OWNER and LEDGER_GITHUB_REPO are required when LEDGER_STORAGE=github_api")
		}
		if strings.TrimSpace(cfg.LedgerGitHubToken) == "" {
			return errors.New("LEDGER_GITHUB_TOKEN is required when LEDGER_STORAGE=github_api")
		}
	}
	if ledgerReadModelEnabled(cfg) && cfg.DatabaseURL == "" {
		return errors.New("DATABASE_URL is required when LEDGER_READ_MODEL=postgres")
	}
	if cfg.ReadModelStrict && !ledgerReadModelEnabled(cfg) {
		return errors.New("LEDGER_READ_MODEL_STRICT=true requires LEDGER_READ_MODEL=postgres")
	}
	if err := validateAgentServiceConfig(cfg, false); err != nil {
		return err
	}
	return nil
}

func validateAgentServiceConfig(cfg Config, required bool) error {
	serviceURL := strings.TrimSpace(cfg.AgentServiceURL)
	token := strings.TrimSpace(cfg.AgentServiceToken)
	if serviceURL == "" && token == "" && !required {
		return nil
	}
	if serviceURL == "" || token == "" {
		return errors.New("AGENT_SERVICE_URL and AGENT_SERVICE_TOKEN must be configured together")
	}
	parsed, err := url.ParseRequestURI(serviceURL)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return errors.New("AGENT_SERVICE_URL must be an HTTP or HTTPS URL")
	}
	if audience := strings.TrimSpace(cfg.AgentServiceAudience); audience != "" {
		parsedAudience, err := url.ParseRequestURI(audience)
		if err != nil || parsedAudience.Scheme != "https" || parsedAudience.Host == "" {
			return errors.New("AGENT_SERVICE_AUDIENCE must be an HTTPS URL")
		}
	}
	return nil
}

func validateTelegramWebhookConfig(cfg Config) error {
	secret := strings.TrimSpace(cfg.TelegramWebhookSecret)
	if secret == "" {
		return nil
	}
	if len(secret) > 256 {
		return errors.New("TELEGRAM_WEBHOOK_SECRET must match ^[A-Za-z0-9_-]{1,256}$")
	}
	for _, char := range []byte(secret) {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') || char == '_' || char == '-' {
			continue
		}
		return errors.New("TELEGRAM_WEBHOOK_SECRET must match ^[A-Za-z0-9_-]{1,256}$")
	}
	return nil
}

func validateAuthTransportConfig(cfg Config) error {
	switch cfg.AuthTransport {
	case "", "https":
		return nil
	case "http":
		for _, key := range []string{"LEDGER_CORS_ORIGINS", "CORS_ALLOWED_ORIGINS", "PUBLIC_ORIGINS"} {
			if strings.TrimSpace(os.Getenv(key)) != "" {
				return errors.New("" + key + " cannot be set when LEDGER_AUTH_TRANSPORT=http")
			}
		}
		for _, key := range []string{"PUBLIC_ORIGIN", "LEDGER_PUBLIC_ORIGIN", "WEBAUTHN_PUBLIC_ORIGIN", "WEBAUTHN_RP_ORIGINS", "WEBAUTHN_RP_ID"} {
			if strings.TrimSpace(os.Getenv(key)) != "" {
				return errors.New("" + key + " requires LEDGER_AUTH_TRANSPORT=https")
			}
		}
		return nil
	default:
		return errors.New("LEDGER_AUTH_TRANSPORT must be https or http")
	}
}

func validateInternalServiceURL(name, value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return fmt.Errorf("%s is required", name)
	}
	parsed, err := url.ParseRequestURI(value)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return fmt.Errorf("%s must be an HTTP or HTTPS URL without credentials, query, or fragment", name)
	}
	return nil
}

func validateSelfHostedOriginConfig(cfg Config) error {
	if cfg.AuthTransport == "http" {
		return nil
	}
	origin := strings.TrimSpace(os.Getenv("PUBLIC_ORIGIN"))
	if origin == "" {
		origin = strings.TrimSpace(os.Getenv("LEDGER_PUBLIC_ORIGIN"))
	}
	parsed, err := url.ParseRequestURI(origin)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("PUBLIC_ORIGIN must be the external HTTPS origin without a path, credentials, query, or fragment when LEDGER_AUTH_TRANSPORT=https")
	}
	rpID := strings.ToLower(strings.TrimSpace(os.Getenv("WEBAUTHN_RP_ID")))
	if rpID == "" {
		return errors.New("WEBAUTHN_RP_ID is required when LEDGER_AUTH_TRANSPORT=https")
	}
	if !webAuthnOriginMatchesRPID(origin, rpID) {
		return errors.New("PUBLIC_ORIGIN host must equal or be a subdomain of WEBAUTHN_RP_ID")
	}
	for _, value := range []string{os.Getenv("WEBAUTHN_PUBLIC_ORIGIN"), os.Getenv("WEBAUTHN_RP_ORIGINS")} {
		for _, candidate := range strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == '\n' || r == '\t' || r == ' ' }) {
			parsedCandidate, err := url.ParseRequestURI(candidate)
			if err != nil || parsedCandidate.Scheme != "https" || parsedCandidate.Host == "" || parsedCandidate.User != nil || parsedCandidate.Path != "" || parsedCandidate.RawQuery != "" || parsedCandidate.Fragment != "" {
				return errors.New("WebAuthn origins must be HTTPS origins without paths, credentials, queries, or fragments")
			}
			if !webAuthnOriginMatchesRPID(candidate, rpID) {
				return fmt.Errorf("WebAuthn origin %q does not match WEBAUTHN_RP_ID", candidate)
			}
		}
	}
	return nil
}

func gmailAutomationConfigured(cfg Config) bool {
	return cfg.GmailClientID != "" || cfg.GmailClientSecret != "" || cfg.GmailOAuthRedirectURL != "" || cfg.GmailPubSubTopic != "" || cfg.GmailPubSubAudience != "" || cfg.GmailPubSubServiceAccount != "" || cfg.GmailTokenEncryptionKey != "" || len(cfg.GmailAllowedSenders) > 0
}

func gmailDeliveryModeFromEnv(fallback string) string {
	return strings.ToLower(strings.TrimSpace(env("GMAIL_DELIVERY_MODE", fallback)))
}

func gmailPollingEnabled(cfg Config) bool {
	return gmailAutomationConfigured(cfg) && normalizedGmailDeliveryMode(cfg) == "poll"
}

func normalizedGmailDeliveryMode(cfg Config) string {
	mode := strings.ToLower(strings.TrimSpace(cfg.GmailDeliveryMode))
	if mode == "" {
		return "webhook"
	}
	return mode
}

func validateZIPWorkerConfig(cfg Config) error {
	workerURL := strings.TrimSpace(cfg.ZIPWorkerURL)
	audience := strings.TrimSpace(cfg.ZIPWorkerAudience)
	if workerURL == "" && audience == "" {
		return nil
	}
	if workerURL == "" {
		return errors.New("ZIP_WORKER_URL and ZIP_WORKER_AUDIENCE must be configured together")
	}
	parsed, err := url.ParseRequestURI(workerURL)
	if err != nil || parsed.Host == "" {
		return errors.New("ZIP_WORKER_URL must be a valid URL")
	}
	if cfg.SelfHosted && workerURL == "http://zip-worker:8080" {
		if audience != "" {
			return errors.New("ZIP_WORKER_AUDIENCE must be empty for the self-hosted internal ZIP Worker")
		}
		return nil
	}
	if parsed.Scheme != "https" {
		return errors.New("ZIP_WORKER_URL must be an HTTPS URL")
	}
	if audience == "" {
		return errors.New("ZIP_WORKER_URL and ZIP_WORKER_AUDIENCE must be configured together")
	}
	audienceURL, err := url.ParseRequestURI(audience)
	if err != nil || audienceURL.Scheme != "https" || audienceURL.Host == "" {
		return errors.New("ZIP_WORKER_AUDIENCE must be an HTTPS URL")
	}
	return nil
}

func validateGmailAutomationConfig(cfg Config) error {
	if !gmailAutomationConfigured(cfg) {
		return nil
	}
	mode := normalizedGmailDeliveryMode(cfg)
	if mode != "webhook" && mode != "poll" {
		return errors.New("GMAIL_DELIVERY_MODE must be webhook or poll")
	}
	required := map[string]string{
		"GMAIL_CLIENT_ID":            cfg.GmailClientID,
		"GMAIL_CLIENT_SECRET":        cfg.GmailClientSecret,
		"GMAIL_OAUTH_REDIRECT_URL":   cfg.GmailOAuthRedirectURL,
		"GMAIL_TOKEN_ENCRYPTION_KEY": cfg.GmailTokenEncryptionKey,
	}
	for name, value := range required {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("%s is required when Gmail automation is configured", name)
		}
	}
	if len(cfg.GmailAllowedSenders) == 0 {
		return errors.New("GMAIL_ALLOWED_SENDERS is required when Gmail automation is configured")
	}
	switch mode {
	case "webhook":
		for name, value := range map[string]string{
			"GMAIL_PUBSUB_TOPIC":           cfg.GmailPubSubTopic,
			"GMAIL_PUBSUB_AUDIENCE":        cfg.GmailPubSubAudience,
			"GMAIL_PUBSUB_SERVICE_ACCOUNT": cfg.GmailPubSubServiceAccount,
		} {
			if strings.TrimSpace(value) == "" {
				return fmt.Errorf("%s is required when GMAIL_DELIVERY_MODE=webhook", name)
			}
		}
		cronSecretConfigured := strings.TrimSpace(cfg.CronSecret) != ""
		cronOIDCAudienceConfigured := strings.TrimSpace(cfg.CronOIDCAudience) != ""
		cronOIDCServiceAccountConfigured := strings.TrimSpace(cfg.CronOIDCServiceAccount) != ""
		if cronOIDCAudienceConfigured != cronOIDCServiceAccountConfigured {
			return errors.New("CRON_OIDC_AUDIENCE and CRON_OIDC_SERVICE_ACCOUNT must be configured together")
		}
		if !cronSecretConfigured && !cronOIDCAudienceConfigured {
			return errors.New("CRON_SECRET or Cloud Scheduler OIDC configuration is required when GMAIL_DELIVERY_MODE=webhook")
		}
		if cronOIDCAudienceConfigured && !strings.HasPrefix(cfg.CronOIDCAudience, "https://") {
			return errors.New("CRON_OIDC_AUDIENCE must use HTTPS")
		}
		if !strings.HasPrefix(cfg.GmailPubSubTopic, "projects/") || !strings.Contains(cfg.GmailPubSubTopic, "/topics/") {
			return errors.New("GMAIL_PUBSUB_TOPIC must use projects/<project>/topics/<topic>")
		}
	case "poll":
		if cfg.GmailPollInterval < time.Minute || cfg.GmailPollInterval > 24*time.Hour {
			return errors.New("GMAIL_POLL_INTERVAL must be between 1m and 24h when GMAIL_DELIVERY_MODE=poll")
		}
		// Keep every local run below the durable sync lease, so another process
		// cannot claim an expired lease while it still runs.
		if cfg.GmailPollTimeout < 30*time.Second || cfg.GmailPollTimeout > maxGmailPollTimeout {
			return errors.New("GMAIL_POLL_TIMEOUT must be between 30s and 14m when GMAIL_DELIVERY_MODE=poll")
		}
	}
	key, err := base64.RawStdEncoding.DecodeString(cfg.GmailTokenEncryptionKey)
	if err != nil {
		key, err = base64.StdEncoding.DecodeString(cfg.GmailTokenEncryptionKey)
	}
	if err != nil || len(key) != 32 {
		return errors.New("GMAIL_TOKEN_ENCRYPTION_KEY must be a base64-encoded 32-byte key")
	}
	if cfg.GmailSyncLookbackDays < 1 || cfg.GmailSyncLookbackDays > 365 {
		return errors.New("GMAIL_SYNC_LOOKBACK_DAYS must be between 1 and 365")
	}
	if cfg.GmailZipTimeoutSeconds < 1 || cfg.GmailZipTimeoutSeconds > maxGmailZIPTimeoutSeconds {
		return errors.New("GMAIL_ZIP_TIMEOUT_SECONDS must be between 1 and 840")
	}
	return nil
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func truthyEnv(key string) bool {
	return envBool(key, false)
}

func envBool(key string, fallback bool) bool {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	switch strings.ToLower(strings.TrimSpace(os.Getenv(key))) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
	}
}

func envInt(key string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envDuration(key string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}
	return parsed
}
