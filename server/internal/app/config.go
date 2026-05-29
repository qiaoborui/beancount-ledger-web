package app

import (
	"crypto/rand"
	"encoding/base64"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type Config struct {
	AppRoot        string
	LedgerRoot     string
	RuntimeDir     string
	StaticDir      string
	AIRuntime      string
	AgentToolToken string
	PiAgentCommand string
	PiAgentArgs    []string
	PiAgentTimeout int
	ServeStatic    bool
	Port           string
}

func LoadConfig() Config {
	wd, _ := os.Getwd()
	appRoot := filepath.Clean(filepath.Join(wd, ".."))
	if filepath.Base(wd) != "server" {
		appRoot = wd
	}
	ledgerRoot := env("LEDGER_ROOT", filepath.Join(appRoot, "examples", "minimal-ledger"))
	aiRuntime := strings.ToLower(env("LEDGER_AI_RUNTIME", "legacy"))
	agentToolToken := strings.TrimSpace(os.Getenv("LEDGER_AGENT_TOOL_TOKEN"))
	if aiRuntime == "pi" && agentToolToken == "" {
		agentToolToken = randomToken()
	}
	return Config{
		AppRoot:        appRoot,
		LedgerRoot:     filepath.Clean(ledgerRoot),
		RuntimeDir:     filepath.Clean(env("RUNTIME_DIR", filepath.Join(ledgerRoot, ".runtime"))),
		StaticDir:      filepath.Clean(env("STATIC_DIR", filepath.Join(appRoot, "web", "dist"))),
		AIRuntime:      aiRuntime,
		AgentToolToken: agentToolToken,
		PiAgentCommand: strings.TrimSpace(os.Getenv("LEDGER_PI_COMMAND")),
		PiAgentArgs:    fieldsEnv("LEDGER_PI_ARGS"),
		PiAgentTimeout: intEnv("LEDGER_PI_TIMEOUT_SECONDS", 120),
		ServeStatic:    envBool("SERVE_STATIC", true),
		Port:           env("PORT", "3000"),
	}
}

func randomToken() string {
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(raw[:])
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func fieldsEnv(key string) []string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return nil
	}
	return strings.Fields(value)
}

func intEnv(key string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed <= 0 {
		return fallback
	}
	return parsed
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
