package app

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestRemoteGitWriterChecksCommitsAndPushes(t *testing.T) {
	seed := testLedger(t)
	remote := initBareLedgerRemote(t, seed)
	cfg := remoteGitTestConfig(t, seed, remote)
	t.Setenv("BEAN_CHECK_BIN", fakeBeanCheck(t, 0))
	t.Setenv("LEDGER_GIT_AUTHOR_NAME", "Ledger Bot")
	t.Setenv("LEDGER_GIT_AUTHOR_EMAIL", "ledger@example.test")

	cache := NewLedgerCache(cfg)
	writer := NewLedgerWriter(cfg, cache)
	if err := writer.AppendBeanTextWithSource("2026-06-01", strings.Join([]string{
		`2026-06-01 * "Tea" "Oolong"`,
		"  Expenses:Food 18.00 CNY",
		"  Assets:Cash -18.00 CNY",
		"",
	}, "\n"), "test-remote-git"); err != nil {
		t.Fatal(err)
	}

	main := gitShow(t, remote, "main:main.bean")
	if !strings.Contains(main, `include "transactions/2026/06.bean"`) {
		t.Fatalf("remote main.bean was not updated:\n%s", main)
	}
	month := gitShow(t, remote, "main:transactions/2026/06.bean")
	if !strings.Contains(month, `"Tea" "Oolong"`) {
		t.Fatalf("remote monthly file was not pushed:\n%s", month)
	}

	snapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	foundRelativeSource := false
	for _, txn := range snapshot.Transactions {
		if txn.Payee == "Tea" {
			foundRelativeSource = txn.Source.File == "transactions/2026/06.bean"
		}
	}
	if !foundRelativeSource {
		t.Fatalf("remote snapshot should expose repo-relative transaction source paths: %#v", snapshot.Transactions)
	}
}

func TestRemoteGitWriterDoesNotPushWhenBeanCheckFails(t *testing.T) {
	seed := testLedger(t)
	remote := initBareLedgerRemote(t, seed)
	cfg := remoteGitTestConfig(t, seed, remote)
	t.Setenv("BEAN_CHECK_BIN", fakeBeanCheck(t, 1))
	t.Setenv("LEDGER_GIT_AUTHOR_NAME", "Ledger Bot")
	t.Setenv("LEDGER_GIT_AUTHOR_EMAIL", "ledger@example.test")

	err := NewLedgerWriter(cfg, NewLedgerCache(cfg)).AppendBeanText("2026-06-01", strings.Join([]string{
		`2026-06-01 * "Tea" "Oolong"`,
		"  Expenses:Food 18.00 CNY",
		"  Assets:Cash -18.00 CNY",
		"",
	}, "\n"))
	if err == nil {
		t.Fatal("expected bean-check failure")
	}
	if output, showErr := gitShowMaybe(remote, "main:transactions/2026/06.bean"); showErr == nil {
		t.Fatalf("failed write should not push monthly file:\n%s", output)
	}
	main := gitShow(t, remote, "main:main.bean")
	if strings.Contains(main, `include "transactions/2026/06.bean"`) {
		t.Fatalf("failed write should not push include:\n%s", main)
	}
}

func remoteGitTestConfig(t *testing.T, seed Config, remote string) Config {
	t.Helper()
	workDir := filepath.Join(t.TempDir(), "remote-work")
	return Config{
		AppRoot:          seed.AppRoot,
		LedgerRoot:       filepath.Join(workDir, "repo"),
		RuntimeDir:       filepath.Join(t.TempDir(), "runtime"),
		StaticDir:        seed.StaticDir,
		Port:             "0",
		LedgerStorage:    "remote_git",
		LedgerGitRemote:  remote,
		LedgerGitBranch:  "main",
		LedgerGitWorkDir: workDir,
	}
}

func initBareLedgerRemote(t *testing.T, cfg Config) string {
	t.Helper()
	gitRun(t, cfg.LedgerRoot, "init")
	gitRun(t, cfg.LedgerRoot, "checkout", "-b", "main")
	gitRun(t, cfg.LedgerRoot, "config", "user.name", "Test User")
	gitRun(t, cfg.LedgerRoot, "config", "user.email", "test@example.test")
	gitRun(t, cfg.LedgerRoot, "add", ".")
	gitRun(t, cfg.LedgerRoot, "commit", "-m", "initial ledger")
	remote := filepath.Join(t.TempDir(), "ledger.git")
	gitRun(t, "", "clone", "--bare", cfg.LedgerRoot, remote)
	return remote
}

func fakeBeanCheck(t *testing.T, code int) string {
	t.Helper()
	file := filepath.Join(t.TempDir(), "bean-check")
	text := "#!/bin/sh\nexit " + strconv.Itoa(code) + "\n"
	if err := os.WriteFile(file, []byte(text), 0o755); err != nil {
		t.Fatal(err)
	}
	return file
}

func gitShow(t *testing.T, remote, spec string) string {
	t.Helper()
	out, err := gitShowMaybe(remote, spec)
	if err != nil {
		t.Fatalf("git show %s failed: %v\n%s", spec, err, out)
	}
	return out
}

func gitShowMaybe(remote, spec string) (string, error) {
	out, err := exec.Command("git", "--git-dir", remote, "show", spec).CombinedOutput()
	return string(out), err
}

func gitRun(t *testing.T, dir string, args ...string) string {
	t.Helper()
	command := exec.Command("git", args...)
	if dir != "" {
		command.Dir = dir
	}
	out, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}
