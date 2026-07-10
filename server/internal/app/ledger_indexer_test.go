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
