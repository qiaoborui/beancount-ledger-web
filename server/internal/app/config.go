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
	DatabaseURL      string
}

func LoadConfig() Config {
	wd, _ := os.Getwd()
	appRoot := filepath.Clean(filepath.Join(wd, ".."))
	if filepath.Base(wd) != "server" {
		appRoot = wd
	}
	storage := strings.ToLower(env("LEDGER_STORAGE", "filesystem"))
	if storage == "git" {
		storage = "remote_git"
	}
	ledgerRoot := env("LEDGER_ROOT", filepath.Join(appRoot, "examples", "minimal-ledger"))
	runtimeDir := env("RUNTIME_DIR", filepath.Join(ledgerRoot, ".runtime"))
	gitWorkDir := env("LEDGER_GIT_WORKDIR", "")
	if storage == "remote_git" {
		if gitWorkDir == "" {
			gitWorkDir = filepath.Join(os.TempDir(), "beancount-ledger-web", "ledger")
		}
		ledgerRoot = filepath.Join(gitWorkDir, "repo")
		if strings.TrimSpace(os.Getenv("RUNTIME_DIR")) == "" {
			runtimeDir = filepath.Join(os.TempDir(), "beancount-ledger-web", "runtime")
		}
	}
	return Config{
		AppRoot:          appRoot,
		LedgerRoot:       filepath.Clean(ledgerRoot),
		RuntimeDir:       filepath.Clean(runtimeDir),
		StaticDir:        filepath.Clean(env("STATIC_DIR", filepath.Join(appRoot, "web", "dist"))),
		ServeStatic:      envBool("SERVE_STATIC", true),
		Port:             env("PORT", "3000"),
		LedgerStorage:    storage,
		LedgerGitRemote:  strings.TrimSpace(os.Getenv("LEDGER_GIT_REMOTE")),
		LedgerGitBranch:  env("LEDGER_GIT_BRANCH", "main"),
		LedgerGitWorkDir: filepath.Clean(gitWorkDir),
		RuntimeStore:     strings.ToLower(env("RUNTIME_STORE", "filesystem")),
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
