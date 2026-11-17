// Command ledger-automation runs a ledger's scheduled tasks on an
// always-on host. A systemd timer calls `ledger-automation tick` every few
// minutes; `ledger-automation run <task>` runs one task now. See
// docs/ledger-automation.md.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/automation"
	"github.com/borui/beancount-ledger-web/server/mobileagent"
)

const usage = `usage:
  ledger-automation tick           run every task that is due
  ledger-automation run <task>...  run the named tasks now
  ledger-automation check          load the tasks and print their next state

Configuration comes from the environment (see docs/ledger-automation.md):
  LEDGER_AUTOMATION_HOME, LEDGER_AUTOMATION_REPO, LEDGER_AUTOMATION_BRANCH,
  LEDGER_AUTOMATION_RUNS_BRANCH, LEDGER_AUTOMATION_ENTRYPOINT,
  LEDGER_AUTOMATION_TIMEZONE, LEDGER_AUTOMATION_MODEL_API,
  LEDGER_AUTOMATION_MODEL_BASE_URL, LEDGER_AUTOMATION_MODEL,
  LEDGER_AUTOMATION_THINKING, LEDGER_AUTOMATION_CONTEXT_WINDOW,
  LEDGER_AUTOMATION_MAX_OUTPUT_TOKENS, LEDGER_AUTOMATION_BARK_SERVER,
  LEDGER_AUTOMATION_GENERIC_NOTIFICATIONS, LEDGER_AUTOMATION_KEEP_RUNS,
  LEDGER_AUTOMATION_BEAN_CHECK
Secrets are read from systemd credentials (model-key, bark-key,
bark-encryption-key) or from LEDGER_AUTOMATION_MODEL_KEY,
LEDGER_AUTOMATION_BARK_KEY and LEDGER_AUTOMATION_BARK_ENCRYPTION_KEY.
`

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	if err := run(os.Args[1:], os.Stdout, logger); err != nil {
		if errors.Is(err, automation.ErrBusy) {
			logger.Info("skipped", "reason", err)
			return
		}
		logger.Error("ledger-automation", "err", err)
		os.Exit(1)
	}
}

func run(args []string, output io.Writer, logger *slog.Logger) error {
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprint(output, usage)
		return nil
	}
	cfg, err := configFromEnv(os.Getenv, logger)
	if err != nil {
		return err
	}
	if check := os.Getenv("LEDGER_AUTOMATION_BEAN_CHECK"); check != "" {
		mobileagent.SetChecker(beanChecker{command: check})
	}
	runner, err := automation.NewRunner(cfg)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	var result automation.Result
	switch args[0] {
	case "tick":
		result, err = runner.Tick(ctx)
	case "run":
		if len(args) < 2 {
			return errors.New("run needs at least one task id")
		}
		result, err = runner.Tick(ctx, args[1:]...)
	case "check":
		return printCheck(output, runner, ctx)
	default:
		return fmt.Errorf("unknown command %q\n%s", args[0], usage)
	}
	if err != nil {
		return err
	}
	encoded, _ := json.Marshal(result)
	logger.Info("tick", "result", string(encoded))
	return nil
}

func printCheck(output io.Writer, runner *automation.Runner, ctx context.Context) error {
	report, err := runner.Check(ctx)
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(output)
	encoder.SetIndent("", "  ")
	return encoder.Encode(report)
}

func configFromEnv(getenv func(string) string, logger *slog.Logger) (automation.Config, error) {
	cfg := automation.Config{
		Home:       getenv("LEDGER_AUTOMATION_HOME"),
		Repo:       getenv("LEDGER_AUTOMATION_REPO"),
		Branch:     getenv("LEDGER_AUTOMATION_BRANCH"),
		RunsBranch: getenv("LEDGER_AUTOMATION_RUNS_BRANCH"),
		Entrypoint: getenv("LEDGER_AUTOMATION_ENTRYPOINT"),
		Model: automation.ModelConfig{
			API:      getenv("LEDGER_AUTOMATION_MODEL_API"),
			BaseURL:  getenv("LEDGER_AUTOMATION_MODEL_BASE_URL"),
			Model:    getenv("LEDGER_AUTOMATION_MODEL"),
			Thinking: getenv("LEDGER_AUTOMATION_THINKING"),
		},
		GenericNotifications: truthy(getenv("LEDGER_AUTOMATION_GENERIC_NOTIFICATIONS")),
		RunTurn:              mobileagent.RunTurnJSON,
		Logger:               logger,
	}
	if cfg.Home == "" {
		if state := getenv("STATE_DIRECTORY"); state != "" {
			cfg.Home = state
		} else {
			cfg.Home = "/var/lib/ledger-automation"
		}
	}
	if zone := getenv("LEDGER_AUTOMATION_TIMEZONE"); zone != "" {
		location, err := time.LoadLocation(zone)
		if err != nil {
			return cfg, fmt.Errorf("LEDGER_AUTOMATION_TIMEZONE: %w", err)
		}
		cfg.Location = location
	}
	for name, limit := range map[string]*int{
		"LEDGER_AUTOMATION_CONTEXT_WINDOW":    &cfg.Model.ContextWindow,
		"LEDGER_AUTOMATION_MAX_OUTPUT_TOKENS": &cfg.Model.MaxOutputTokens,
	} {
		if text := getenv(name); text != "" {
			value, err := strconv.Atoi(text)
			if err != nil || value < 0 {
				return cfg, fmt.Errorf("%s must be a token count, not %q", name, text)
			}
			*limit = value
		}
	}
	if keep := getenv("LEDGER_AUTOMATION_KEEP_RUNS"); keep != "" {
		value, err := strconv.Atoi(keep)
		if err != nil {
			return cfg, fmt.Errorf("LEDGER_AUTOMATION_KEEP_RUNS: %w", err)
		}
		cfg.KeepRuns = value
	}
	var err error
	if cfg.Model.APIKey, err = secret(getenv, "model-key", "LEDGER_AUTOMATION_MODEL_KEY"); err != nil {
		return cfg, err
	}
	deviceKey, err := secret(getenv, "bark-key", "LEDGER_AUTOMATION_BARK_KEY")
	if err != nil {
		return cfg, err
	}
	if deviceKey != "" {
		encryption, err := secret(getenv, "bark-encryption-key", "LEDGER_AUTOMATION_BARK_ENCRYPTION_KEY")
		if err != nil {
			return cfg, err
		}
		cfg.Notifier = &automation.Bark{Server: getenv("LEDGER_AUTOMATION_BARK_SERVER"), DeviceKey: deviceKey,
			EncryptionKey: encryption, Group: "账本定时任务"}
	}
	return cfg, nil
}

// secret reads a systemd credential, falling back to an environment
// variable for a manual run.
func secret(getenv func(string) string, credential, variable string) (string, error) {
	if dir := getenv("CREDENTIALS_DIRECTORY"); dir != "" {
		data, err := os.ReadFile(filepath.Join(dir, credential))
		if err == nil {
			return strings.TrimSpace(string(data)), nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return "", fmt.Errorf("credential %s: %w", credential, err)
		}
	}
	return strings.TrimSpace(getenv(variable)), nil
}

func truthy(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// beanChecker runs an external validator, such as bean-check, for the
// Agent's bean_check tool. It prints nothing for a valid ledger.
type beanChecker struct{ command string }

func (c beanChecker) Check(workspaceRoot, entrypoint string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	command := exec.CommandContext(ctx, c.command, entrypoint)
	command.Dir = workspaceRoot
	out, err := command.CombinedOutput()
	if err == nil {
		return ""
	}
	text := strings.TrimSpace(string(out))
	if text == "" {
		text = err.Error()
	}
	return text
}
