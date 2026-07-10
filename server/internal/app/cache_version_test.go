package app

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLedgerVersionUsesBeanContentInsteadOfCheckoutMtime(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "main.bean")
	if err := os.WriteFile(path, []byte("option \"title\" \"Test\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	initialTime := time.Unix(1_700_000_000, 0)
	if err := os.Chtimes(path, initialTime, initialTime); err != nil {
		t.Fatal(err)
	}

	initial, err := ledgerVersion(Config{LedgerRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	checkoutTime := initialTime.Add(time.Hour)
	if err := os.Chtimes(path, checkoutTime, checkoutTime); err != nil {
		t.Fatal(err)
	}
	afterCheckout, err := ledgerVersion(Config{LedgerRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if afterCheckout.Version != initial.Version {
		t.Fatalf("version changed after mtime-only update: %q -> %q", initial.Version, afterCheckout.Version)
	}
	if afterCheckout.LatestMtime == initial.LatestMtime {
		t.Fatal("latest mtime did not retain checkout metadata")
	}

	if err := os.WriteFile(path, []byte("option \"title\" \"Updated\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	afterContentChange, err := ledgerVersion(Config{LedgerRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if afterContentChange.Version == initial.Version {
		t.Fatal("version did not change after bean content update")
	}
}

func TestLedgerVersionTracksOnlyIncludeReachableFiles(t *testing.T) {
	root := t.TempDir()
	writeLedgerVersionFile(t, root, "main.bean", "include \"transactions/2026/05.bean\"\n")
	writeLedgerVersionFile(t, root, "transactions/2026/05.bean", "2026-05-01 * \"Lunch\"\n  Expenses:Food  10 USD\n  Assets:Cash\n")
	writeLedgerVersionFile(t, root, "transactions/2025/12.bean", "2025-12-01 * \"Old\"\n  Expenses:Food  10 USD\n  Assets:Cash\n")

	initial, err := ledgerVersion(Config{LedgerRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if initial.FileCount != 2 {
		t.Fatalf("file count=%d, want 2 include-reachable files", initial.FileCount)
	}

	writeLedgerVersionFile(t, root, "transactions/2025/12.bean", "2025-12-02 * \"Unrelated\"\n  Expenses:Food  10 USD\n  Assets:Cash\n")
	afterUnrelatedChange, err := ledgerVersion(Config{LedgerRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if afterUnrelatedChange.Version != initial.Version {
		t.Fatalf("version changed for unreachable file: %q -> %q", initial.Version, afterUnrelatedChange.Version)
	}

	writeLedgerVersionFile(t, root, "transactions/2026/05.bean", "2026-05-02 * \"Dinner\"\n  Expenses:Food  20 USD\n  Assets:Cash\n")
	afterIncludedChange, err := ledgerVersion(Config{LedgerRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if afterIncludedChange.Version == initial.Version {
		t.Fatal("version did not change after included file update")
	}

	writeLedgerVersionFile(t, root, "transactions/2026/06.bean", "2026-06-01 * \"Coffee\"\n  Expenses:Food  5 USD\n  Assets:Cash\n")
	writeLedgerVersionFile(t, root, "main.bean", "include \"transactions/2026/05.bean\"\ninclude \"transactions/2026/06.bean\"\n")
	afterIncludeAdded, err := ledgerVersion(Config{LedgerRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if afterIncludeAdded.Version == afterIncludedChange.Version || afterIncludeAdded.FileCount != 3 {
		t.Fatalf("include addition was not tracked: %#v", afterIncludeAdded)
	}

	writeLedgerVersionFile(t, root, "main.bean", "include \"transactions/2026/05.bean\"\n")
	afterIncludeRemoved, err := ledgerVersion(Config{LedgerRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if afterIncludeRemoved.Version == afterIncludeAdded.Version || afterIncludeRemoved.FileCount != 2 {
		t.Fatalf("include removal was not tracked: %#v", afterIncludeRemoved)
	}
}

func TestLedgerVersionFailsWhenIncludedFileIsRemoved(t *testing.T) {
	root := t.TempDir()
	writeLedgerVersionFile(t, root, "main.bean", "include \"transactions/2026/05.bean\"\n")
	if _, err := ledgerVersion(Config{LedgerRoot: root}); err == nil {
		t.Fatal("expected missing included file error")
	}
}

func TestLedgerVersionHandlesNestedAndCyclicIncludes(t *testing.T) {
	root := t.TempDir()
	writeLedgerVersionFile(t, root, "main.bean", "include \"accounts.bean\"\n")
	writeLedgerVersionFile(t, root, "accounts.bean", "include \"config/accounts.bean\"\n")
	writeLedgerVersionFile(t, root, "config/accounts.bean", "include \"../accounts.bean\"\n2026-01-01 open Assets:Cash\n")

	version, err := ledgerVersion(Config{LedgerRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if version.FileCount != 3 {
		t.Fatalf("file count=%d, want 3 unique files in nested cyclic include graph", version.FileCount)
	}
}

func writeLedgerVersionFile(t *testing.T, root, relative, content string) {
	t.Helper()
	path := filepath.Join(root, relative)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
