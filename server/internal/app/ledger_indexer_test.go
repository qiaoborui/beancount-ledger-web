package app

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestNormalizeLedgerSnapshotSourcePathsUsesLedgerRelativePaths(t *testing.T) {
	root := t.TempDir()
	snapshot := &LedgerSnapshot{
		Transactions: []Transaction{{
			Source: TransactionSource{File: filepath.Join(root, "transactions", "2026", "05.bean"), Line: 1},
		}},
		BeanEntries: []BeanEntry{{File: filepath.Join(root, "accounts.bean"), Line: 1}},
		BeanErrors:  []BeanParseError{{File: filepath.Join(root, "transactions", "2026", "bad.bean"), Line: 1}},
	}

	normalizeLedgerSnapshotSourcePaths(Config{LedgerRoot: root}, snapshot)

	if got := snapshot.Transactions[0].Source.File; got != "transactions/2026/05.bean" {
		t.Fatalf("transaction source file=%q", got)
	}
	if got := snapshot.BeanEntries[0].File; got != "accounts.bean" {
		t.Fatalf("bean entry file=%q", got)
	}
	if got := snapshot.BeanErrors[0].File; got != "transactions/2026/bad.bean" {
		t.Fatalf("bean error file=%q", got)
	}
}

func TestShouldSkipLedgerIndex(t *testing.T) {
	active := LedgerIndexRevision{LedgerVersion: LedgerVersion{Version: "v1"}, GitSHA: "commit-1"}
	version := LedgerVersion{Version: "v1"}

	if !shouldSkipLedgerIndex(active, version, "commit-1", false) {
		t.Fatal("matching version and commit should skip")
	}
	if shouldSkipLedgerIndex(active, version, "commit-2", false) {
		t.Fatal("new commit should rebuild")
	}
	if shouldSkipLedgerIndex(active, version, "commit-1", true) {
		t.Fatal("forced rebuild should bypass the version shortcut")
	}
}

func TestShouldSkipLedgerIndexByGitSHA(t *testing.T) {
	active := LedgerIndexRevision{LedgerVersion: LedgerVersion{Version: "v1"}, GitSHA: "commit-1"}

	if !shouldSkipLedgerIndexByGitSHA(active, "commit-1", false) {
		t.Fatal("matching immutable commit should skip before reading ledger files")
	}
	if shouldSkipLedgerIndexByGitSHA(active, "commit-2", false) {
		t.Fatal("new immutable commit should rebuild")
	}
	if shouldSkipLedgerIndexByGitSHA(active, "", false) {
		t.Fatal("filesystem sources should continue to use ledger version detection")
	}
	if shouldSkipLedgerIndexByGitSHA(active, "commit-1", true) {
		t.Fatal("forced rebuild should bypass immutable commit shortcut")
	}
}

func TestCanSkipLedgerIndexByGitSHARequiresCleanMatchingCheckout(t *testing.T) {
	root := t.TempDir()
	cfg := Config{LedgerRoot: root}
	writeLedgerVersionFile(t, root, "main.bean", "include \"transactions/2026/05.bean\"\n")
	writeLedgerVersionFile(t, root, "transactions/2026/05.bean", "2026-05-01 * \"Lunch\"\n  Expenses:Food  10 USD\n  Assets:Cash\n")
	runLedgerIndexerGit(t, root, "init")
	runLedgerIndexerGit(t, root, "config", "user.name", "Ledger Test")
	runLedgerIndexerGit(t, root, "config", "user.email", "ledger-test@example.com")
	runLedgerIndexerGit(t, root, "add", ".")
	runLedgerIndexerGit(t, root, "commit", "-m", "ledger fixture")
	sha := strings.TrimSpace(runLedgerIndexerGit(t, root, "rev-parse", "HEAD"))
	active := LedgerIndexRevision{GitSHA: sha}

	if !canSkipLedgerIndexByGitSHA(cfg, active, sha, false) {
		t.Fatal("clean checkout at the indexed commit should skip")
	}

	writeLedgerVersionFile(t, root, "transactions/2026/05.bean", "2026-05-02 * \"Dinner\"\n  Expenses:Food  20 USD\n  Assets:Cash\n")
	if canSkipLedgerIndexByGitSHA(cfg, active, sha, false) {
		t.Fatal("dirty included file should fall back to manifest hashing")
	}
}

func runLedgerIndexerGit(t *testing.T, root string, args ...string) string {
	t.Helper()
	command := append([]string{"-c", "safe.directory=" + root, "-C", root}, args...)
	out, err := exec.Command("git", command...).CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}
