package app

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

type Config struct {
	AppRoot            string
	LedgerRoot         string
	RuntimeDir         string
	StaticDir          string
	ServeStatic        bool
	Port               string
	LedgerStorage      string
	LedgerGitBranch    string
	LedgerGitHubOwner  string
	LedgerGitHubRepo   string
	LedgerGitHubToken  string
	LedgerGitHubAPIURL string
	DatabaseURL        string
	LedgerReadModel    string
	ReadModelStrict    bool
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
		AppRoot:            "",
		LedgerRoot:         filepath.Clean(ledgerRoot),
		RuntimeDir:         filepath.Clean(runtimeDir),
		StaticDir:          filepath.Clean(env("STATIC_DIR", "")),
		ServeStatic:        envBool("SERVE_STATIC", false),
		Port:               env("PORT", "3000"),
		LedgerStorage:      storage,
		LedgerGitBranch:    env("LEDGER_GIT_BRANCH", "main"),
		LedgerGitHubOwner:  strings.TrimSpace(os.Getenv("LEDGER_GITHUB_OWNER")),
		LedgerGitHubRepo:   strings.TrimSpace(os.Getenv("LEDGER_GITHUB_REPO")),
		LedgerGitHubToken:  strings.TrimSpace(os.Getenv("LEDGER_GITHUB_TOKEN")),
		LedgerGitHubAPIURL: strings.TrimSpace(os.Getenv("LEDGER_GITHUB_API_URL")),
		DatabaseURL:        strings.TrimSpace(os.Getenv("DATABASE_URL")),
		LedgerReadModel:    ledgerReadModel,
		ReadModelStrict:    envBool("LEDGER_READ_MODEL_STRICT", ledgerReadModel == "postgres" || ledgerReadModel == "pg"),
	}
}

func ValidateConfig(cfg Config) error {
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
