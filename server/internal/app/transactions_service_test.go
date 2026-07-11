package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReverseTransactionEntryMirrorsOriginalPostings(t *testing.T) {
	original := Transaction{
		Date:      "2026-05-01",
		Payee:     "Cafe",
		Narration: "Lunch",
		Tags:      []string{"work"},
		Postings: []Posting{
			{Account: "Expenses:Food", Amount: 1200, Currency: "CNY"},
			{Account: "Assets:Cash", Amount: -1200, Currency: "CNY"},
		},
	}
	entry := ReverseTransactionEntry(original, "2026-05-02")
	if entry.Date != "2026-05-02" || entry.Payee != "Cafe" || entry.Narration != "冲销：Lunch" {
		t.Fatalf("unexpected reversal entry header: %#v", entry)
	}
	if len(entry.Postings) != 2 || entry.Postings[0].Amount != "-12.00" || entry.Postings[1].Amount != "12.00" {
		t.Fatalf("reversal postings should invert original amounts: %#v", entry.Postings)
	}
	if entry.Metadata["reversal"] != true || len(entry.Tags) != 1 || entry.Tags[0] != "work" {
		t.Fatalf("reversal metadata/tags were not preserved: %#v", entry)
	}
}

func TestTransactionServiceReverseWritesEntry(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	cache := NewLedgerCache(cfg)
	writer := NewLedgerWriter(cfg, cache)
	service := NewTransactionService(cache, writer)
	entry, err := service.Reverse(ReverseTransactionRequest{Source: TransactionSource{File: filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean"), Line: 1}, Date: "2026-05-02"})
	if err != nil {
		t.Fatal(err)
	}
	if entry.Narration != "冲销：Lunch" {
		t.Fatalf("unexpected reversal entry: %#v", entry)
	}
	text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")))
	if !strings.Contains(text, "冲销：Lunch") || !strings.Contains(text, "Assets:Cash") || !strings.Contains(text, "12.00 CNY") {
		t.Fatalf("reversal was not written:\n%s", text)
	}
}

func TestTransactionServiceReverseUsesInjectedSnapshotWithoutLocalLedger(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"main.bean":                 "include \"commodities.bean\"\ninclude \"accounts.bean\"\ninclude \"transactions/2026/05.bean\"\n",
		"commodities.bean":          "2026-01-01 commodity CNY\n",
		"accounts.bean":             "2026-01-01 open Assets:Cash CNY\n2026-01-01 open Expenses:Food CNY\n",
		"transactions/2026/05.bean": "; 2026-05 transactions\n",
	})
	defer fake.server.Close()

	cfg := githubAPITestConfig(t, fake)
	snapshot := &LedgerSnapshot{Transactions: []Transaction{{
		Date:      "2026-05-01",
		Payee:     "Cafe",
		Narration: "Lunch",
		Postings: []Posting{
			{Account: "Expenses:Food", Amount: 1200, Currency: "CNY"},
			{Account: "Assets:Cash", Amount: -1200, Currency: "CNY"},
		},
		Source: TransactionSource{File: "transactions/2026/05.bean", Line: 1, Hash: "source-hash"},
	}}}
	service := NewTransactionServiceWithSnapshot(nil, NewLedgerWriter(cfg, nil), func() (*LedgerSnapshot, error) {
		return snapshot, nil
	})

	entry, err := service.Reverse(ReverseTransactionRequest{Source: snapshot.Transactions[0].Source, Date: "2026-05-02"})
	if err != nil {
		t.Fatal(err)
	}
	if entry.Narration != "冲销：Lunch" || fake.commitCount != 1 {
		t.Fatalf("entry=%#v commits=%d", entry, fake.commitCount)
	}
}
