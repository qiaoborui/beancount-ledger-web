package app

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Config struct {
	AppRoot                     string
	LedgerClusterID             string
	LedgerRoot                  string
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
	DatabaseURL                 string
	LedgerReadModel             string
	ReadModelStrict             bool
	EnabledModules              []string
	NotificationRefreshInterval string
}

func LoadConfig() Config {
	storage := strings.ToLower(env("LEDGER_STORAGE", "filesystem"))
	if storage == "github" {
		storage = "github_api"
	}
	ledgerRoot := strings.TrimSpace(os.Getenv("LEDGER_ROOT"))
	runtimeDir := os.Getenv("RUNTIME_DIR")
	if runtimeDir == "" {
		runtimeDir = filepath.Join(os.TempDir(), "beancount-ledger-web", "runtime")
	}
	ledgerReadModel := strings.ToLower(env("LEDGER_READ_MODEL", "files"))

	return Config{
		AppRoot:                     "",
		LedgerClusterID:             strings.TrimSpace(os.Getenv("LEDGER_CLUSTER_ID")),
		LedgerRoot:                  filepath.Clean(ledgerRoot),
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
		DatabaseURL:                 strings.TrimSpace(os.Getenv("DATABASE_URL")),
		LedgerReadModel:             ledgerReadModel,
		ReadModelStrict:             envBool("LEDGER_READ_MODEL_STRICT", ledgerReadModel == "postgres" || ledgerReadModel == "pg"),
		EnabledModules:              parseEnabledModules(os.Getenv("LEDGER_ENABLED_MODULES")),
		NotificationRefreshInterval: env("LEDGER_NOTIFICATION_REFRESH_INTERVAL", "off"),
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

func LoadIndexerConfig() Config {
	cfg := loadBaseConfig()
	cfg.LedgerStorage = "filesystem"
	cfg.LedgerReadModel = "postgres"
	cfg.ReadModelStrict = true
	ledgerRoot := strings.TrimSpace(os.Getenv("LEDGER_ROOT"))
	cfg.LedgerRoot = filepath.Clean(ledgerRoot)
	return cfg
}

func loadBaseConfig() Config {
	return Config{
		AppRoot:                     "",
		LedgerClusterID:             strings.TrimSpace(os.Getenv("LEDGER_CLUSTER_ID")),
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
		DatabaseURL:                 strings.TrimSpace(os.Getenv("DATABASE_URL")),
		EnabledModules:              parseEnabledModules(os.Getenv("LEDGER_ENABLED_MODULES")),
		NotificationRefreshInterval: env("LEDGER_NOTIFICATION_REFRESH_INTERVAL", "off"),
	}
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
	if _, err := enabledBuiltinModules(cfg.EnabledModules); err != nil {
		return err
	}
	if _, err := notificationRefreshInterval(cfg.NotificationRefreshInterval); err != nil {
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
	if strings.TrimSpace(cfg.LedgerGitHubOwner) == "" || strings.TrimSpace(cfg.LedgerGitHubRepo) == "" {
		return errors.New("LEDGER_GITHUB_OWNER and LEDGER_GITHUB_REPO are required")
	}
	if strings.TrimSpace(cfg.LedgerGitHubToken) == "" {
		return errors.New("LEDGER_GITHUB_TOKEN is required")
	}
	return nil
}

func ValidateIndexerConfig(cfg Config) error {
	if cfg.DatabaseURL == "" {
		return errors.New("DATABASE_URL is required")
	}
	if strings.TrimSpace(cfg.LedgerRoot) == "" || cfg.LedgerRoot == "." {
		return errors.New("LEDGER_ROOT is required for ledger-indexer")
	}
	if !ledgerReadModelEnabled(cfg) {
		return errors.New("ledger-indexer requires the Postgres read model")
	}
	if maxOpenConns := postgresPoolSettingsFromEnv().maxOpenConns; maxOpenConns > 0 && maxOpenConns < 2 {
		return errors.New("ledger-indexer requires POSTGRES_MAX_OPEN_CONNS to be at least 2 when it is set")
	}
	return nil
}

func ValidateConfig(cfg Config) error {
	if _, err := enabledBuiltinModules(cfg.EnabledModules); err != nil {
		return err
	}
	if _, err := notificationRefreshInterval(cfg.NotificationRefreshInterval); err != nil {
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
