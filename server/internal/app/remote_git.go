package app

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const remoteGitSyncTTL = 2 * time.Second

type remoteGitState struct {
	mu        sync.Mutex
	checkedAt time.Time
}

var remoteGitStates sync.Map

func remoteGitEnabled(cfg Config) bool {
	return strings.EqualFold(cfg.LedgerStorage, "remote_git")
}

func remoteGitStateFor(cfg Config) *remoteGitState {
	key := cfg.LedgerRoot
	if key == "" {
		key = cfg.LedgerGitRemote
	}
	state, _ := remoteGitStates.LoadOrStore(key, &remoteGitState{})
	return state.(*remoteGitState)
}

func ensureLedgerReady(cfg Config) error {
	if !remoteGitEnabled(cfg) {
		return nil
	}
	state := remoteGitStateFor(cfg)
	state.mu.Lock()
	defer state.mu.Unlock()
	return ensureRemoteGitCheckoutLocked(cfg, state, false)
}

func syncLedgerNow(cfg Config) error {
	if !remoteGitEnabled(cfg) {
		return nil
	}
	state := remoteGitStateFor(cfg)
	state.mu.Lock()
	defer state.mu.Unlock()
	return ensureRemoteGitCheckoutLocked(cfg, state, true)
}

func ensureRemoteGitCheckoutLocked(cfg Config, state *remoteGitState, force bool) error {
	if err := validateRemoteGitConfig(cfg); err != nil {
		return err
	}
	if !force && !state.checkedAt.IsZero() && time.Since(state.checkedAt) < remoteGitSyncTTL {
		if _, err := os.Stat(mainBeanPath(cfg)); err == nil {
			return nil
		}
	}
	if err := ensureRemoteGitClone(cfg); err != nil {
		return err
	}
	if err := syncRemoteGitCheckout(cfg); err != nil {
		return err
	}
	state.checkedAt = time.Now()
	return nil
}

func validateRemoteGitConfig(cfg Config) error {
	if strings.TrimSpace(cfg.LedgerGitRemote) == "" {
		return errors.New("LEDGER_GIT_REMOTE is required when LEDGER_STORAGE=remote_git")
	}
	if strings.TrimSpace(cfg.LedgerGitBranch) == "" {
		return errors.New("LEDGER_GIT_BRANCH is required when LEDGER_STORAGE=remote_git")
	}
	if strings.TrimSpace(cfg.LedgerRoot) == "" || strings.TrimSpace(cfg.LedgerGitWorkDir) == "" {
		return errors.New("LEDGER_GIT_WORKDIR could not be resolved")
	}
	return nil
}

func ensureRemoteGitClone(cfg Config) error {
	gitDir := filepath.Join(cfg.LedgerRoot, ".git")
	if _, err := os.Stat(gitDir); err == nil {
		return nil
	}
	if err := os.RemoveAll(cfg.LedgerRoot); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(cfg.LedgerRoot), 0o700); err != nil {
		return err
	}
	_, err := gitOutput("", "clone", "--branch", cfg.LedgerGitBranch, "--single-branch", cfg.LedgerGitRemote, cfg.LedgerRoot)
	return err
}

func syncRemoteGitCheckout(cfg Config) error {
	if _, err := gitLedgerOutput(cfg, "remote", "set-url", "origin", cfg.LedgerGitRemote); err != nil {
		return err
	}
	if _, err := gitLedgerOutput(cfg, "fetch", "origin", cfg.LedgerGitBranch); err != nil {
		return err
	}
	if _, err := gitLedgerOutput(cfg, "checkout", "-B", cfg.LedgerGitBranch, remoteGitRemoteRef(cfg)); err != nil {
		return err
	}
	if _, err := gitLedgerOutput(cfg, "reset", "--hard", remoteGitRemoteRef(cfg)); err != nil {
		return err
	}
	if _, err := gitLedgerOutput(cfg, "clean", "-fd"); err != nil {
		return err
	}
	return nil
}

func remoteGitRemoteRef(cfg Config) string {
	return "origin/" + cfg.LedgerGitBranch
}

func gitOutput(dir string, args ...string) (string, error) {
	command := exec.Command("git", args...)
	if dir != "" {
		command.Dir = dir
	}
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Run(); err != nil {
		message := strings.TrimSpace(output.String())
		if message == "" {
			message = err.Error()
		}
		return output.String(), fmt.Errorf("%w: %s", err, message)
	}
	return output.String(), nil
}
