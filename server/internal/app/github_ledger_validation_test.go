package app

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func useRealGitHubBeanCheck(t *testing.T) {
	t.Helper()
	binary, err := exec.LookPath("bean-check")
	if err != nil {
		t.Skip("bean-check is required for GitHub write validation integration tests")
	}
	t.Setenv("BEAN_CHECK_BIN", binary)
}

func validationTestLedger() map[string]string {
	return map[string]string{
		"main.bean":                 "include \"config/accounts.bean\"\ninclude \"transactions/2026/*.bean\"\n",
		"config/accounts.bean":      "include \"../commodities.bean\"\n2026-01-01 open Assets:Cash CNY\n2026-01-01 open Expenses:Food CNY\n",
		"commodities.bean":          "2026-01-01 commodity CNY\n",
		"transactions/2026/05.bean": "; initially empty\n",
	}
}

func TestGitHubWriteValidationRejectsUnbalancedAppendBeforeCommit(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, validationTestLedger())
	defer fake.server.Close()
	useRealGitHubBeanCheck(t)
	writer := NewLedgerWriter(githubAPITestConfig(t, fake), nil)
	// Use an explicit commodity provider because this test exercises the full
	// Beancount include/glob loader, beyond the lightweight query parser.
	writer.commoditiesProvider = func() ([]string, error) { return []string{"CNY"}, nil }
	entry := LedgerEntry{Kind: "transaction", Date: "2026-05-03", Payee: "Cafe", Postings: []EntryPosting{
		{Account: "Expenses:Food", Amount: "10.00", Currency: "CNY"},
		{Account: "Assets:Cash", Amount: "-9.00", Currency: "CNY"},
	}}
	if err := entry.Validate(); err != nil {
		t.Fatal(err)
	}
	_, err := writer.AppendEntries([]LedgerEntry{entry})
	if err == nil || !strings.Contains(err.Error(), "does not balance") {
		t.Fatalf("expected semantic balance failure, got %v", err)
	}
	if fake.commitCount != 0 || fake.updatedRef != "" || len(fake.blobs) != 0 {
		t.Fatalf("validation failure mutated remote: commits=%d ref=%q blobs=%d", fake.commitCount, fake.updatedRef, len(fake.blobs))
	}
	if fake.files["transactions/2026/05.bean"] != "; initially empty\n" {
		t.Fatal("validation failure changed source file")
	}
}

func TestGitHubWriteValidationUsesCompleteOverlaidIncludeTree(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, validationTestLedger())
	defer fake.server.Close()
	useRealGitHubBeanCheck(t)
	cfg := githubAPITestConfig(t, fake)
	writer := NewLedgerWriter(cfg, nil)
	validationTemp := t.TempDir()
	t.Setenv("TMPDIR", validationTemp)
	// The new file must participate in a pre-existing wildcard include, and its
	// new account declaration must replace the remote version before checking.
	err := writer.RunTransaction(func(tx *LedgerWriteTransaction) error {
		if err := tx.WriteFile(filepath.Join(cfg.LedgerRoot, "config/accounts.bean"), []byte(fake.files["config/accounts.bean"]+"2026-01-01 open Expenses:Travel CNY\n"), 0o644); err != nil {
			return err
		}
		return tx.WriteFile(filepath.Join(cfg.LedgerRoot, "transactions/2026/06.bean"), []byte("2026-06-01 * \"Train\"\n  Expenses:Travel 10 CNY\n  Assets:Cash -10 CNY\n"), 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	if fake.commitCount != 1 || fake.updatedRef != "refs/heads/main" {
		t.Fatalf("commit=%d ref=%q", fake.commitCount, fake.updatedRef)
	}
	if _, err := os.Stat(cfg.LedgerRoot); !os.IsNotExist(err) {
		t.Fatalf("validation created a persistent checkout: %v", err)
	}
	if remaining, err := os.ReadDir(validationTemp); err != nil || len(remaining) != 0 {
		t.Fatalf("validation left a temporary ledger snapshot: files=%v err=%v", remaining, err)
	}
}

func TestGitHubWriteValidationRejectsInvalidReplacement(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, validationTestLedger())
	defer fake.server.Close()
	useRealGitHubBeanCheck(t)
	cfg := githubAPITestConfig(t, fake)
	err := NewLedgerWriter(cfg, nil).ReplaceLedgerFile(filepath.Join(cfg.LedgerRoot, "transactions/2026/05.bean"), []byte("2026-05-01 * \"Bad\"\n  Expenses:Missing 10 CNY\n  Assets:Cash -10 CNY\n"))
	if err == nil || !strings.Contains(err.Error(), "unknown account") {
		t.Fatalf("expected unknown account failure, got %v", err)
	}
	if fake.commitCount != 0 || fake.updatedRef != "" {
		t.Fatalf("invalid replacement committed: %d %q", fake.commitCount, fake.updatedRef)
	}
}

func TestGitHubWriteValidationChecksDocumentsWithoutDownloadingBills(t *testing.T) {
	for _, exists := range []bool{true, false} {
		t.Run(map[bool]string{true: "existing", false: "missing"}[exists], func(t *testing.T) {
			files := validationTestLedger()
			if exists {
				files["documents/receipt.pdf"] = "private binary content"
			}
			fake := newFakeGitHubLedgerAPI(t, files)
			defer fake.server.Close()
			useRealGitHubBeanCheck(t)
			cfg := githubAPITestConfig(t, fake)
			err := NewLedgerWriter(cfg, nil).ReplaceLedgerFile(filepath.Join(cfg.LedgerRoot, "transactions/2026/05.bean"), []byte("2026-05-01 document Assets:Cash \"../../documents/receipt.pdf\"\n"))
			if exists && err != nil {
				t.Fatal(err)
			}
			if !exists && (err == nil || fake.commitCount != 0) {
				t.Fatalf("missing document: err=%v commits=%d", err, fake.commitCount)
			}
			if fake.contentReadCounts()["documents/receipt.pdf"] != 0 {
				t.Fatal("validation downloaded a bill")
			}
		})
	}
}

func TestGitHubWriteValidationRejectsIncludeOutsideRepository(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{"main.bean": ""})
	defer fake.server.Close()
	cfg := githubAPITestConfig(t, fake)
	err := NewLedgerWriter(cfg, nil).ReplaceLedgerFile(mainBeanPath(cfg), []byte("include \"../outside.bean\"\n"))
	if err == nil || fake.commitCount != 0 {
		t.Fatalf("external include: err=%v commits=%d", err, fake.commitCount)
	}
}

func TestGitHubWriteValidationNoChangesNeedsNoCheckoutOrValidator(t *testing.T) {
	if err := (&githubLedgerTransaction{}).validate(); err != nil {
		t.Fatal(err)
	}
}

func TestRunBeanCheckContextCancelsValidation(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, binary, "#!/bin/sh\nexec sleep 10\n")
	if err := os.Chmod(binary, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", binary)
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Millisecond)
	defer cancel()
	started := time.Now()
	err := runBeanCheckContext(ctx, Config{LedgerRoot: t.TempDir()})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("cancellation=%v", err)
	}
	if time.Since(started) > time.Second {
		t.Fatal("validation ignored cancellation")
	}
}
