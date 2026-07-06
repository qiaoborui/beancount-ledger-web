package app

import (
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
	LedgerGitRemote    string
	LedgerGitBranch    string
	LedgerGitWorkDir   string
	LedgerGitHubOwner  string
	LedgerGitHubRepo   string
	LedgerGitHubToken  string
	LedgerGitHubAPIURL string
	RuntimeStore       string
	RuntimeFileStore   string
	DatabaseURL        string
	LedgerReadModel    string
	ReadModelStrict    bool
}

func LoadConfig() Config {
	storage := strings.ToLower(env("LEDGER_STORAGE", "remote_git"))
	if storage == "git" {
		storage = "remote_git"
	}
	if storage == "github" {
		storage = "github_api"
	}
	ledgerRoot := strings.TrimSpace(os.Getenv("LEDGER_ROOT"))
	gitWorkDir := env("LEDGER_GIT_WORKDIR", "")
	if gitWorkDir == "" {
		gitWorkDir = filepath.Join(os.TempDir(), "beancount-ledger-web", "ledger")
	}
	if storage == "remote_git" || ledgerRoot == "" {
		ledgerRoot = filepath.Join(gitWorkDir, "repo")
	}
	runtimeDir := os.Getenv("RUNTIME_DIR")
	if runtimeDir == "" {
		runtimeDir = filepath.Join(os.TempDir(), "beancount-ledger-web", "runtime")
	}
	runtimeStore := strings.ToLower(env("RUNTIME_STORE", "filesystem"))
	runtimeFileStore := strings.ToLower(env("RUNTIME_FILE_STORE", ""))
	if runtimeFileStore == "" {
		runtimeFileStore = runtimeStore
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
		LedgerGitRemote:    strings.TrimSpace(os.Getenv("LEDGER_GIT_REMOTE")),
		LedgerGitBranch:    env("LEDGER_GIT_BRANCH", "main"),
		LedgerGitWorkDir:   filepath.Clean(gitWorkDir),
		LedgerGitHubOwner:  strings.TrimSpace(os.Getenv("LEDGER_GITHUB_OWNER")),
		LedgerGitHubRepo:   strings.TrimSpace(os.Getenv("LEDGER_GITHUB_REPO")),
		LedgerGitHubToken:  strings.TrimSpace(env("LEDGER_GITHUB_TOKEN", os.Getenv("GITHUB_TOKEN"))),
		LedgerGitHubAPIURL: strings.TrimSpace(os.Getenv("LEDGER_GITHUB_API_URL")),
		RuntimeStore:       runtimeStore,
		RuntimeFileStore:   runtimeFileStore,
		DatabaseURL:        strings.TrimSpace(os.Getenv("DATABASE_URL")),
		LedgerReadModel:    ledgerReadModel,
		ReadModelStrict:    envBool("LEDGER_READ_MODEL_STRICT", ledgerReadModel == "postgres" || ledgerReadModel == "pg"),
	}
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
