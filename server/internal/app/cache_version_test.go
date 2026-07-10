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
