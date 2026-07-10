package app

import (
	"path/filepath"
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
