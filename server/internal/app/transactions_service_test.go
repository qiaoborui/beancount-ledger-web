package app

import (
	"encoding/json"
	"net/http"
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

func TestFindTransactionPrefersHashOverStaleLine(t *testing.T) {
	txns := []Transaction{
		{Narration: "Replaced", Source: TransactionSource{File: "transactions/2026/05.bean", Line: 1, Hash: "new"}},
		{Narration: "Original", Source: TransactionSource{File: "transactions/2026/05.bean", Line: 2, Hash: "old"}},
	}
	found := FindTransaction(txns, TransactionSource{File: "transactions/2026/05.bean", Line: 1, Hash: "old"})
	if found == nil || found.Narration != "Original" {
		t.Fatalf("hash must identify the approved transaction, got %#v", found)
	}
}

func TestTransactionServiceAddTagsUpdatesBatchAndPreservesHeaderComment(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	before := string(mustRead(t, file))
	lines := strings.Split(strings.TrimRight(before, "\n"), "\n")
	first := transactionHash(lines[0:4])
	second := transactionHash(lines[5:8])
	lines[0] = `2026-05-01 * "Cafe; inside quote" "Lunch" #work ; keep this`
	mustWrite(t, file, strings.Join(lines, "\n")+"\n")
	updated := strings.Split(strings.TrimRight(string(mustRead(t, file)), "\n"), "\n")
	first = transactionHash(updated[0:4])

	service := NewTransactionService(NewLedgerCache(cfg), NewLedgerWriter(cfg, nil))
	err := service.AddTags([]TransactionSource{
		{File: "transactions/2026/05.bean", Line: 1, Hash: first},
		{File: "transactions/2026/05.bean", Line: 6, Hash: second},
	}, []string{"travel", "trip-2026-hokkaido", "travel"})
	if err != nil {
		t.Fatal(err)
	}
	after := string(mustRead(t, file))
	if !strings.Contains(after, `#work #travel #trip-2026-hokkaido ; keep this`) {
		t.Fatalf("first transaction tags/comment were not preserved:\n%s", after)
	}
	if strings.Count(after, "#travel") != 2 || strings.Count(after, "#trip-2026-hokkaido") != 2 {
		t.Fatalf("both transactions should receive deduplicated tags:\n%s", after)
	}
}

func TestTransactionServiceAddTagsKeepsLineDistinctSourcesWithSameHash(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	block := "2026-05-01 * \"Duplicate\" \"Same raw transaction\"\n  Expenses:Food  12.00 CNY\n  Assets:Cash  -12.00 CNY"
	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	mustWrite(t, file, block+"\n"+block)
	hash := transactionHash(strings.Split(block, "\n"))

	service := NewTransactionService(NewLedgerCache(cfg), NewLedgerWriter(cfg, nil))
	err := service.AddTags([]TransactionSource{
		{File: "transactions/2026/05.bean", Line: 1, Hash: hash},
		{File: "transactions/2026/05.bean", Line: 4, Hash: hash},
	}, []string{"travel"})
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(string(mustRead(t, file)), "#travel"); got != 2 {
		t.Fatalf("line-distinct sources with one hash received %d tags, want 2", got)
	}
}

func TestTransactionServiceAddTagsIsAtomicWhenAnySourceIsStale(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	before := string(mustRead(t, file))
	lines := strings.Split(strings.TrimRight(before, "\n"), "\n")
	validHash := transactionHash(lines[0:4])

	service := NewTransactionService(NewLedgerCache(cfg), NewLedgerWriter(cfg, nil))
	err := service.AddTags([]TransactionSource{
		{File: "transactions/2026/05.bean", Line: 1, Hash: validHash},
		{File: "transactions/2026/05.bean", Line: 6, Hash: "stale"},
	}, []string{"travel"})
	if err == nil || !strings.Contains(err.Error(), "找不到原交易") {
		t.Fatalf("expected stale-source error, got %v", err)
	}
	if after := string(mustRead(t, file)); after != before {
		t.Fatalf("batch must be all-or-nothing; file changed:\n%s", after)
	}
}

func TestAddTransactionTagsRouteWritesOneValidatedBatch(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	lines := strings.Split(strings.TrimRight(string(mustRead(t, file)), "\n"), "\n")
	body, err := json.Marshal(AddTransactionTagsRequest{
		Sources: []TransactionSource{{File: "transactions/2026/05.bean", Line: 1, Hash: transactionHash(lines[0:4])}},
		Tags:    []string{"travel"},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := testRouter(t, cfg)
	response := requestWithCookies(router, http.MethodPost, "/api/ledger/transactions/tags", string(body), loginCookies(t, router))
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if after := string(mustRead(t, file)); !strings.Contains(after, `"Lunch" #work #travel`) {
		t.Fatalf("route did not add tag:\n%s", after)
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
