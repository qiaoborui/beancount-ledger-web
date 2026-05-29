package app

import (
	"os"
	"path/filepath"
	"strings"
)

type Config struct {
	AppRoot     string
	LedgerRoot  string
	RuntimeDir  string
	StaticDir   string
	ServeStatic bool
	Port        string
}

func LoadConfig() Config {
	wd, _ := os.Getwd()
	appRoot := filepath.Clean(filepath.Join(wd, ".."))
	if filepath.Base(wd) != "server" {
		appRoot = wd
	}
	ledgerRoot := env("LEDGER_ROOT", filepath.Join(appRoot, "examples", "minimal-ledger"))
	return Config{
		AppRoot:     appRoot,
		LedgerRoot:  filepath.Clean(ledgerRoot),
		RuntimeDir:  filepath.Clean(env("RUNTIME_DIR", filepath.Join(ledgerRoot, ".runtime"))),
		StaticDir:   filepath.Clean(env("STATIC_DIR", filepath.Join(appRoot, "web", "dist"))),
		ServeStatic: envBool("SERVE_STATIC", true),
		Port:        env("PORT", "3000"),
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
