package app

import (
	"os"
	"path/filepath"
	"strings"
)

type Config struct {
	AppRoot          string
	LedgerRoot       string
	RuntimeDir       string
	StaticDir        string
	ServeStatic      bool
	Port             string
	LedgerStorage    string
	LedgerGitRemote  string
	LedgerGitBranch  string
	LedgerGitWorkDir string
	RuntimeStore     string
	RuntimeFileStore string
	DatabaseURL      string
}

func LoadConfig() Config {
	storage := strings.ToLower(env("LEDGER_STORAGE", "remote_git"))
	if storage == "git" {
		storage = "remote_git"
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
	return Config{
		AppRoot:          "",
		LedgerRoot:       filepath.Clean(ledgerRoot),
		RuntimeDir:       filepath.Clean(runtimeDir),
		StaticDir:        filepath.Clean(env("STATIC_DIR", "")),
		ServeStatic:      envBool("SERVE_STATIC", false),
		Port:             env("PORT", "3000"),
		LedgerStorage:    storage,
		LedgerGitRemote:  strings.TrimSpace(os.Getenv("LEDGER_GIT_REMOTE")),
		LedgerGitBranch:  env("LEDGER_GIT_BRANCH", "main"),
		LedgerGitWorkDir: filepath.Clean(gitWorkDir),
		RuntimeStore:     runtimeStore,
		RuntimeFileStore: runtimeFileStore,
		DatabaseURL:      strings.TrimSpace(os.Getenv("DATABASE_URL")),
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
