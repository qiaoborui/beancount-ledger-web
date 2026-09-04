package app

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestGitHubAPIWriterCommitsWithoutLocalCheckout(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"main.bean": "option \"title\" \"Test\"\n",
	})
	defer fake.server.Close()

	cfg := Config{
		LedgerRoot:         filepath.Join(t.TempDir(), "repo"),
		RuntimeDir:         t.TempDir(),
		LedgerStorage:      "github_api",
		LedgerGitBranch:    "main",
		LedgerGitHubOwner:  "owner",
		LedgerGitHubRepo:   "ledger",
		LedgerGitHubToken:  "token",
		LedgerGitHubAPIURL: fake.server.URL + "/",
	}
	writer := NewLedgerWriter(cfg, nil)
	if err := writer.ReplaceLedgerFile(filepath.Join(cfg.LedgerRoot, "main.bean"), []byte("option \"title\" \"Updated\"\n")); err != nil {
		t.Fatal(err)
	}

	if fake.updatedRef != "refs/heads/main" {
		t.Fatalf("updated ref=%q, want refs/heads/main", fake.updatedRef)
	}
	if got := fake.blobs["blob-1"]; got != "option \"title\" \"Updated\"\n" {
		t.Fatalf("blob content=%q", got)
	}
	if len(fake.treePaths) != 1 || fake.treePaths[0] != "main.bean" {
		t.Fatalf("tree paths=%#v", fake.treePaths)
	}
}

func TestGitHubAPIImportWriteCreatesIncludeBeanAndDocument(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"main.bean":                  "include \"transactions/2026/06.bean\"\n",
		"transactions/2026/06.bean":  "; 2026-06 交易记录\n",
		"imports/alipay-config.yaml": "defaultMinusAccount: Expenses:Unknown\n",
	})
	defer fake.server.Close()

	cfg := Config{
		LedgerRoot:         filepath.Join(t.TempDir(), "repo"),
		RuntimeDir:         t.TempDir(),
		LedgerStorage:      "github_api",
		LedgerGitBranch:    "main",
		LedgerGitHubOwner:  "owner",
		LedgerGitHubRepo:   "ledger",
		LedgerGitHubToken:  "token",
		LedgerGitHubAPIURL: fake.server.URL + "/",
	}
	server := &Server{cfg: cfg, writer: NewLedgerWriter(cfg, nil)}
	server.importDocuments.documents = []ImportDocument{{Path: "stale"}}
	server.importDocuments.key = githubImportDocumentsCacheKey(cfg)
	server.importDocuments.loadedAt = time.Now()
	sourceFile := filepath.Join(t.TempDir(), "statement.csv")
	mustWrite(t, sourceFile, "date,payee,amount\n2026-06-01,Shop,8.00\n")
	beanText := strings.Join([]string{
		`2026-06-01 * "Shop" "Snack"`,
		"  Expenses:Food                         8.00 CNY",
		"  Assets:Cash                          -8.00 CNY",
	}, "\n")
	written, err := server.writeImportedBeanFile(
		filepath.Join(cfg.LedgerRoot, "transactions", "2026", "imports", "alipay.bean"),
		filepath.Join(cfg.LedgerRoot, "transactions", "2026", "06.bean"),
		beanText,
		"alipay",
		"2026-06-01",
		"2026-06-02",
		sourceFile,
		filepath.Join(cfg.LedgerRoot, "transactions", "2026", "documents", "imports", "statement.csv"),
		"Assets:Cash",
		"test-import",
	)
	if err != nil {
		t.Fatal(err)
	}
	if written.GitSHA != "new-commit-1" {
		t.Fatalf("written git SHA=%q, want new-commit-1", written.GitSHA)
	}
	if !server.importDocuments.loadedAt.IsZero() || server.importDocuments.documents != nil {
		t.Fatal("successful import write did not invalidate the document cache")
	}
	if filepath.ToSlash(written.OutputFile) != filepath.ToSlash(filepath.Join(cfg.LedgerRoot, "transactions", "2026", "imports", "alipay.bean")) {
		t.Fatalf("written output=%q", written.OutputFile)
	}
	wantPaths := []string{
		"transactions/2026/06.bean",
		"transactions/2026/documents/imports/statement.csv",
		"transactions/2026/imports/alipay.bean",
	}
	if strings.Join(fake.treePaths, ",") != strings.Join(wantPaths, ",") {
		t.Fatalf("tree paths=%#v, want %#v", fake.treePaths, wantPaths)
	}
	if !strings.Contains(fake.blobs["blob-1"], `include "imports/alipay.bean"`) &&
		!strings.Contains(fake.blobs["blob-2"], `include "imports/alipay.bean"`) &&
		!strings.Contains(fake.blobs["blob-3"], `include "imports/alipay.bean"`) {
		t.Fatalf("monthly include not written in blobs: %#v", fake.blobs)
	}
}

func TestGitHubAPIAppendEntryReadsValidationFilesFromGitHub(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"main.bean":                 "include \"commodities.bean\"\ninclude \"accounts.bean\"\ninclude \"transactions/2026/05.bean\"\n",
		"commodities.bean":          "2026-01-01 commodity CNY\n",
		"accounts.bean":             "2026-01-01 open Assets:Cash CNY\n2026-01-01 open Expenses:Food CNY\n",
		"transactions/2026/05.bean": "; 2026-05 交易记录\n",
	})
	defer fake.server.Close()

	cfg := githubAPITestConfig(t, fake)
	writer := NewLedgerWriter(cfg, nil)
	_, err := writer.AppendEntriesWithSource(ledgerWriteSourceAppendEntry, []LedgerEntry{{
		Kind:      "transaction",
		Date:      "2026-05-03",
		Payee:     "Cafe",
		Narration: "Lunch",
		Currency:  "CNY",
		Postings: []EntryPosting{
			{Account: "Expenses:Food", Amount: "12.00", Currency: "CNY"},
			{Account: "Assets:Cash", Amount: "-12.00", Currency: "CNY"},
		},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(fake.treePaths) != 1 || fake.treePaths[0] != "transactions/2026/05.bean" {
		t.Fatalf("tree paths=%#v", fake.treePaths)
	}
	if got := fake.blobs["blob-1"]; !strings.Contains(got, `2026-05-03 * "Cafe" "Lunch"`) {
		t.Fatalf("transaction was not appended through github blob: %q", got)
	}
}

func TestGitHubAPIReplaceTransactionReadsValidationFilesFromGitHub(t *testing.T) {
	original := strings.Join([]string{
		`2026-05-01 * "Cafe" "Lunch"`,
		"  Expenses:Food 12.00 CNY",
		"  Assets:Cash -12.00 CNY",
		"",
	}, "\n")
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"main.bean":                 "include \"commodities.bean\"\ninclude \"accounts.bean\"\ninclude \"transactions/2026/05.bean\"\n",
		"commodities.bean":          "2026-01-01 commodity CNY\n",
		"accounts.bean":             "2026-01-01 open Assets:Cash CNY\n2026-01-01 open Expenses:Food CNY\n",
		"transactions/2026/05.bean": original,
	})
	defer fake.server.Close()

	cfg := githubAPITestConfig(t, fake)
	writer := NewLedgerWriter(cfg, nil)
	err := writer.ReplaceTransactionBlock(TransactionSource{
		File:   "/home/runner/work/ledger/private-ledger/transactions/2026/05.bean",
		Line:   1,
		Hash:   transactionHash(strings.Split(strings.TrimRight(original, "\n"), "\n")[:3]),
		GitSHA: "indexed-commit",
	}, LedgerEntry{
		Kind:      "transaction",
		Date:      "2026-05-01",
		Payee:     "Cafe",
		Narration: "Dinner",
		Currency:  "CNY",
		Postings: []EntryPosting{
			{Account: "Expenses:Food", Amount: "18.00", Currency: "CNY"},
			{Account: "Assets:Cash", Amount: "-18.00", Currency: "CNY"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(fake.treePaths) != 1 || fake.treePaths[0] != "transactions/2026/05.bean" {
		t.Fatalf("tree paths=%#v", fake.treePaths)
	}
	if got := fake.blobs["blob-1"]; !strings.Contains(got, `"Dinner"`) || strings.Contains(got, `"Lunch"`) {
		t.Fatalf("transaction was not replaced through github blob: %q", got)
	}
}

func TestGitHubAPIReplaceTransactionSkipsIdenticalWrite(t *testing.T) {
	entry := LedgerEntry{
		Kind:      "transaction",
		Date:      "2026-05-01",
		Payee:     "Cafe",
		Narration: "Lunch",
		Currency:  "CNY",
		Postings: []EntryPosting{
			{Account: "Expenses:Food", Amount: "12.00", Currency: "CNY"},
			{Account: "Assets:Cash", Amount: "-12.00", Currency: "CNY"},
		},
	}
	original := TransactionToBean(entry)
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"main.bean":                 "include \"commodities.bean\"\ninclude \"accounts.bean\"\ninclude \"transactions/2026/05.bean\"\n",
		"commodities.bean":          "2026-01-01 commodity CNY\n",
		"accounts.bean":             "2026-01-01 open Assets:Cash CNY\n2026-01-01 open Expenses:Food CNY\n",
		"transactions/2026/05.bean": original,
	})
	defer fake.server.Close()

	writer := NewLedgerWriter(githubAPITestConfig(t, fake), nil)
	err := writer.ReplaceTransactionBlock(TransactionSource{
		File:   "/home/runner/work/ledger/private-ledger/transactions/2026/05.bean",
		Line:   1,
		Hash:   transactionHash(strings.Split(strings.TrimRight(original, "\n"), "\n")[:3]),
		GitSHA: "base-commit",
	}, entry)
	if err != nil {
		t.Fatal(err)
	}
	if len(fake.treePaths) != 0 {
		t.Fatalf("tree paths=%#v, want no commit", fake.treePaths)
	}
	if fake.updatedRef != "" {
		t.Fatalf("updated ref=%q, want no ref update", fake.updatedRef)
	}
}

func TestGitHubAPIAddTransactionTagsUsesOneCommitAcrossFiles(t *testing.T) {
	first := strings.Join([]string{
		`2026-05-01 * "Airline" "Ticket"`,
		"  Expenses:Food 12.00 CNY",
		"  Assets:Cash -12.00 CNY",
	}, "\n")
	second := strings.Join([]string{
		`2026-06-01 * "Hotel" "Room" #travel`,
		"  Expenses:Food 88.00 CNY",
		"  Assets:Cash -88.00 CNY",
	}, "\n")
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"main.bean":                 "include \"commodities.bean\"\ninclude \"accounts.bean\"\ninclude \"transactions/2026/05.bean\"\ninclude \"transactions/2026/06.bean\"\n",
		"commodities.bean":          "2026-01-01 commodity CNY\n",
		"accounts.bean":             "2026-01-01 open Assets:Cash CNY\n2026-01-01 open Expenses:Food CNY\n",
		"transactions/2026/05.bean": first + "\n",
		"transactions/2026/06.bean": second + "\n",
	})
	defer fake.server.Close()

	writer := NewLedgerWriter(githubAPITestConfig(t, fake), nil)
	sources := []TransactionSource{
		{File: "transactions/2026/05.bean", Line: 1, Hash: transactionHash(strings.Split(first, "\n"))},
		{File: "transactions/2026/06.bean", Line: 1, Hash: transactionHash(strings.Split(second, "\n"))},
	}
	service := NewTransactionServiceWithSnapshot(nil, writer, func() (*LedgerSnapshot, error) {
		return &LedgerSnapshot{Transactions: []Transaction{
			{Tags: nil, Source: sources[0]},
			{Tags: []string{"travel"}, Source: sources[1]},
		}}, nil
	})
	err := service.AddTags(sources, []string{"travel", "trip-2026-hokkaido"})
	if err != nil {
		t.Fatal(err)
	}
	if fake.commitCount != 1 || len(fake.treePaths) != 2 {
		t.Fatalf("commits=%d treePaths=%#v", fake.commitCount, fake.treePaths)
	}
	for _, blob := range fake.blobs {
		if strings.Contains(blob, "Airline") && !strings.Contains(blob, "#travel #trip-2026-hokkaido") {
			t.Fatalf("first file missing tags: %q", blob)
		}
		if strings.Contains(blob, "Hotel") && strings.Count(blob, "#travel") != 1 {
			t.Fatalf("existing tag was duplicated: %q", blob)
		}
	}
	if got := fake.contentReadCounts(); len(got) != 2 || got["transactions/2026/05.bean"] != 1 || got["transactions/2026/06.bean"] != 1 {
		t.Fatalf("content reads=%#v, want only one read per modified transaction file", got)
	}
}

func TestGitHubAPIMissingFileReadIsCached(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{})
	defer fake.server.Close()

	client, err := newGitHubLedgerClient(githubAPITestConfig(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	tx, err := client.beginTransaction(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(client.cfg.LedgerRoot, "transactions", "2026", "missing.bean")
	for range 2 {
		exists, err := tx.exists(missing)
		if err != nil {
			t.Fatal(err)
		}
		if exists {
			t.Fatal("missing file unexpectedly exists")
		}
	}
	if got := fake.contentReadCounts()["transactions/2026/missing.bean"]; got != 1 {
		t.Fatalf("missing file reads=%d, want 1", got)
	}
}

func TestGitHubAPIBeginTransactionUsesOneRequest(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{})
	defer fake.server.Close()
	client, err := newGitHubLedgerClient(githubAPITestConfig(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.beginTransaction(t.Context()); err != nil {
		t.Fatal(err)
	}
	if got := fake.totalRequestCount(); got != 1 {
		t.Fatalf("begin transaction requests = %d, want 1", got)
	}
}

func TestGitHubAPIReadLedgerFileUsesOneRequest(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{"main.bean": "option \"title\" \"Test\"\n"})
	defer fake.server.Close()
	client, err := newGitHubLedgerClient(githubAPITestConfig(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.readLedgerFile(t.Context(), "main.bean"); err != nil {
		t.Fatal(err)
	}
	if got := fake.totalRequestCount(); got != 1 {
		t.Fatalf("read ledger file requests = %d, want 1", got)
	}
}

func TestGitHubAPIListEditorFilesUsesOneRequest(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{"main.bean": "option \"title\" \"Test\"\n"})
	defer fake.server.Close()
	client, err := newGitHubLedgerClient(githubAPITestConfig(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.listEditorFiles(t.Context()); err != nil {
		t.Fatal(err)
	}
	if got := fake.totalRequestCount(); got != 1 {
		t.Fatalf("list editor files requests = %d, want 1", got)
	}
}

func TestGitHubAPIListImportDocumentsUsesOneRequest(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"transactions/2026/documents/imports/statement.pdf": "test",
	})
	defer fake.server.Close()
	client, err := newGitHubLedgerClient(githubAPITestConfig(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.listImportDocuments(t.Context()); err != nil {
		t.Fatal(err)
	}
	if got := fake.totalRequestCount(); got != 1 {
		t.Fatalf("list import documents requests = %d, want 1", got)
	}
}

func TestServerListImportDocumentsCachesAndExpires(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"transactions/2026/documents/imports/statement.pdf": "test",
	})
	defer fake.server.Close()
	metrics := NewMetrics()
	server := &Server{cfg: githubAPITestConfig(t, fake), metrics: metrics}

	first, err := server.listImportDocuments(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 1 {
		t.Fatalf("documents = %#v, want one", first)
	}
	first[0].Path = "mutated-by-caller"
	second, err := server.listImportDocuments(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if got := second[0].Path; got != "transactions/2026/documents/imports/statement.pdf" {
		t.Fatalf("cached document path = %q", got)
	}
	if got := fake.totalRequestCount(); got != 1 {
		t.Fatalf("cached list requests = %d, want 1", got)
	}
	if got := testutil.ToFloat64(metrics.cacheRequests.WithLabelValues(cacheGitHubImportDocs, cacheResultHit)); got != 1 {
		t.Fatalf("cache hits = %v, want 1", got)
	}

	server.cfg.LedgerGitHubToken = "rotated-token"
	if _, err := server.listImportDocuments(t.Context()); err != nil {
		t.Fatal(err)
	}
	server.importDocuments.mu.Lock()
	server.importDocuments.loadedAt = time.Now().Add(-githubImportDocumentsCacheTTL)
	server.importDocuments.mu.Unlock()
	if _, err := server.listImportDocuments(t.Context()); err != nil {
		t.Fatal(err)
	}
	if got := fake.totalRequestCount(); got != 3 {
		t.Fatalf("refreshed list requests = %d, want 3", got)
	}
	if got := testutil.ToFloat64(metrics.cacheRequests.WithLabelValues(cacheGitHubImportDocs, cacheResultMiss)); got != 3 {
		t.Fatalf("cache misses = %v, want 3", got)
	}
}

func TestServerListImportDocumentsCoalescesConcurrentRequests(t *testing.T) {
	for _, fail := range []bool{false, true} {
		t.Run(fmt.Sprintf("fail=%t", fail), func(t *testing.T) {
			fake := newFakeGitHubLedgerAPI(t, map[string]string{
				"transactions/2026/documents/imports/statement.pdf": "test",
			})
			defer fake.server.Close()
			fake.requestDelay = 25 * time.Millisecond
			fake.failTree = fail
			server := &Server{cfg: githubAPITestConfig(t, fake)}

			const callers = 8
			start := make(chan struct{})
			errs := make(chan error, callers)
			var wg sync.WaitGroup
			for range callers {
				wg.Add(1)
				go func() {
					defer wg.Done()
					<-start
					_, err := server.listImportDocuments(t.Context())
					errs <- err
				}()
			}
			close(start)
			wg.Wait()
			close(errs)
			for err := range errs {
				if (err != nil) != fail {
					t.Fatalf("list error = %v, fail=%t", err, fail)
				}
			}
			if got := fake.totalRequestCount(); got != 1 {
				t.Fatalf("concurrent list requests = %d, want 1", got)
			}
		})
	}
}

func TestServerListImportDocumentsInvalidationDoesNotWaitForRefresh(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"transactions/2026/documents/imports/statement.pdf": "test",
	})
	defer fake.server.Close()
	fake.treeStarted = make(chan struct{})
	fake.releaseTree = make(chan struct{})
	server := &Server{cfg: githubAPITestConfig(t, fake)}
	result := make(chan error, 1)
	go func() {
		_, err := server.listImportDocuments(t.Context())
		result <- err
	}()
	<-fake.treeStarted

	invalidated := make(chan struct{})
	go func() {
		server.invalidateImportDocumentsCache()
		close(invalidated)
	}()
	select {
	case <-invalidated:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("cache invalidation waited for the GitHub refresh")
	}
	close(fake.releaseTree)
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	server.importDocuments.mu.Lock()
	hasCachedDocuments := server.importDocuments.documents != nil
	server.importDocuments.mu.Unlock()
	if hasCachedDocuments {
		t.Fatal("refresh that started before invalidation repopulated the cache")
	}
	if _, err := server.listImportDocuments(t.Context()); err != nil {
		t.Fatal(err)
	}
	if got := fake.totalRequestCount(); got != 2 {
		t.Fatalf("requests after invalidation = %d, want 2", got)
	}
}

func TestServerListImportDocumentsWaitHonorsCancellation(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"transactions/2026/documents/imports/statement.pdf": "test",
	})
	defer fake.server.Close()
	fake.treeStarted = make(chan struct{})
	fake.releaseTree = make(chan struct{})
	server := &Server{cfg: githubAPITestConfig(t, fake)}
	ctx, cancel := context.WithCancel(t.Context())
	result := make(chan error, 1)
	go func() {
		_, err := server.listImportDocuments(ctx)
		result <- err
	}()
	<-fake.treeStarted
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("list error = %v, want context canceled", err)
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("canceled caller remained blocked on the shared refresh")
	}
	close(fake.releaseTree)
}

func BenchmarkGitHubAPIListImportDocuments(b *testing.B) {
	fake := newFakeGitHubLedgerAPI(b, map[string]string{
		"transactions/2026/documents/imports/statement.pdf": "test",
	})
	defer fake.server.Close()
	fake.requestDelay = time.Millisecond
	server := &Server{cfg: githubAPITestConfig(b, fake)}

	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		if _, err := server.listImportDocuments(b.Context()); err != nil {
			b.Fatal(err)
		}
	}
	b.StopTimer()
	b.ReportMetric(float64(fake.totalRequestCount())/float64(b.N), "requests/op")
}

func BenchmarkGitHubAPIReadLedgerFile(b *testing.B) {
	fake := newFakeGitHubLedgerAPI(b, map[string]string{"main.bean": "option \"title\" \"Test\"\n"})
	defer fake.server.Close()
	fake.requestDelay = time.Millisecond
	client, err := newGitHubLedgerClient(githubAPITestConfig(b, fake))
	if err != nil {
		b.Fatal(err)
	}

	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		if _, err := client.readLedgerFile(b.Context(), "main.bean"); err != nil {
			b.Fatal(err)
		}
	}
	b.StopTimer()
	b.ReportMetric(float64(fake.totalRequestCount())/float64(b.N), "requests/op")
}

func BenchmarkGitHubAPIRestCommit(b *testing.B) {
	fake := newFakeGitHubLedgerAPI(b, map[string]string{})
	defer fake.server.Close()
	fake.requestDelay = time.Millisecond
	client, err := newGitHubLedgerClient(githubAPITestConfig(b, fake))
	if err != nil {
		b.Fatal(err)
	}
	b.ResetTimer()
	for range b.N {
		tx := &githubLedgerTransaction{
			ctx:           b.Context(),
			ledger:        client,
			baseCommitSHA: "base-commit",
			baseTreeSHA:   "base-tree",
			cache:         map[string]fileSnapshot{},
			writes: map[string][]byte{
				"main.bean":                           []byte("main"),
				"transactions/2026/09.bean":           []byte("month"),
				"transactions/2026/imports/test.bean": []byte("import"),
			},
		}
		before := fake.totalRequestCount()
		if _, err := tx.commit("benchmark"); err != nil {
			b.Fatal(err)
		}
		b.ReportMetric(float64(fake.totalRequestCount()-before), "requests/op")
	}
}

func TestGitHubAPIGraphQLCommitUsesOneAtomicRequest(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{})
	defer fake.server.Close()
	client, err := newGitHubLedgerClient(githubAPITestConfig(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	client.useGraphQLCommit = true
	tx := &githubLedgerTransaction{
		ctx:           t.Context(),
		ledger:        client,
		baseCommitSHA: "base-commit",
		baseTreeSHA:   "base-tree",
		cache:         map[string]fileSnapshot{},
		writes: map[string][]byte{
			"main.bean":                 []byte("main"),
			"transactions/2026/09.bean": []byte("month"),
		},
	}
	sha, err := tx.commit("test atomic mutation")
	if err != nil {
		t.Fatal(err)
	}
	if sha != "new-commit-1" {
		t.Fatalf("commit SHA=%q", sha)
	}
	if got := fake.totalRequestCount(); got != 1 {
		t.Fatalf("commit requests=%d, want 1", got)
	}
	if fake.graphQLExpectedHead != "base-commit" || fake.graphQLRepository != "owner/ledger" || fake.graphQLBranch != "main" {
		t.Fatalf("unexpected commit target: head=%q repository=%q branch=%q", fake.graphQLExpectedHead, fake.graphQLRepository, fake.graphQLBranch)
	}
	if fake.files["main.bean"] != "main" || fake.files["transactions/2026/09.bean"] != "month" {
		t.Fatalf("atomic additions not applied: %#v", fake.files)
	}
}

func TestGitHubAPIGraphQLCommitIsLimitedToPublicGitHub(t *testing.T) {
	client, err := newGitHubLedgerClient(Config{
		LedgerRoot:        t.TempDir(),
		LedgerGitBranch:   "main",
		LedgerGitHubOwner: "owner",
		LedgerGitHubRepo:  "ledger",
		LedgerGitHubToken: "token",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !client.useGraphQLCommit {
		t.Fatal("public GitHub API should use atomic GraphQL commits")
	}

	fake := newFakeGitHubLedgerAPI(t, map[string]string{})
	defer fake.server.Close()
	customClient, err := newGitHubLedgerClient(githubAPITestConfig(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	if customClient.useGraphQLCommit {
		t.Fatal("custom and GitHub Enterprise API URLs should retain Git Data REST commits")
	}
}

func TestGitHubAPIGraphQLCommitRejectsStaleHead(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{"main.bean": "before"})
	defer fake.server.Close()
	client, err := newGitHubLedgerClient(githubAPITestConfig(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	client.useGraphQLCommit = true
	tx := &githubLedgerTransaction{
		ctx:           t.Context(),
		ledger:        client,
		baseCommitSHA: "stale-commit",
		cache:         map[string]fileSnapshot{},
		writes:        map[string][]byte{"main.bean": []byte("after")},
	}
	if _, err := tx.commit("stale write"); err == nil || !strings.Contains(err.Error(), "expected head") {
		t.Fatalf("stale commit error=%v", err)
	}
	if fake.files["main.bean"] != "before" || fake.commitCount != 0 {
		t.Fatalf("stale commit changed repository: files=%#v commits=%d", fake.files, fake.commitCount)
	}
}

func TestGitHubAPIGraphQLCommitFallsBackForLargePayload(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{})
	defer fake.server.Close()
	client, err := newGitHubLedgerClient(githubAPITestConfig(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	client.useGraphQLCommit = true
	content := bytes.Repeat([]byte("x"), githubGraphQLCommitMaxEncodedFileBytes)
	tx := &githubLedgerTransaction{
		ctx:           t.Context(),
		ledger:        client,
		baseCommitSHA: "base-commit",
		baseTreeSHA:   "base-tree",
		cache:         map[string]fileSnapshot{},
		writes:        map[string][]byte{"statement.pdf": content},
	}
	if _, err := tx.commit("large import"); err != nil {
		t.Fatal(err)
	}
	if fake.graphQLExpectedHead != "" {
		t.Fatal("large payload should retain the Git Data REST commit path")
	}
	if got := fake.files["statement.pdf"]; got != string(content) {
		t.Fatalf("large payload was not committed: got %d bytes", len(got))
	}
}

func BenchmarkGitHubAPIGraphQLCommit(b *testing.B) {
	fake := newFakeGitHubLedgerAPI(b, map[string]string{})
	defer fake.server.Close()
	fake.requestDelay = time.Millisecond
	client, err := newGitHubLedgerClient(githubAPITestConfig(b, fake))
	if err != nil {
		b.Fatal(err)
	}
	client.useGraphQLCommit = true
	b.ResetTimer()
	for range b.N {
		tx := &githubLedgerTransaction{
			ctx:           b.Context(),
			ledger:        client,
			baseCommitSHA: "base-commit",
			baseTreeSHA:   "base-tree",
			cache:         map[string]fileSnapshot{},
			writes: map[string][]byte{
				"main.bean":                           []byte("main"),
				"transactions/2026/09.bean":           []byte("month"),
				"transactions/2026/imports/test.bean": []byte("import"),
			},
		}
		before := fake.totalRequestCount()
		if _, err := tx.commit("benchmark"); err != nil {
			b.Fatal(err)
		}
		b.ReportMetric(float64(fake.totalRequestCount()-before), "requests/op")
	}
}

func TestGitHubAPICommitCreatesBlobsConcurrently(t *testing.T) {
	t.Setenv("LEDGER_GIT_AUTHOR_NAME", "Ledger Test")
	var activeBlobs atomic.Int32
	var maxActiveBlobs atomic.Int32
	var blobSequence atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/repos/owner/ledger/git/blobs":
			active := activeBlobs.Add(1)
			defer activeBlobs.Add(-1)
			for {
				observed := maxActiveBlobs.Load()
				if active <= observed || maxActiveBlobs.CompareAndSwap(observed, active) {
					break
				}
			}
			time.Sleep(20 * time.Millisecond)
			writeJSON(t, w, map[string]any{"sha": fmt.Sprintf("blob-%d", blobSequence.Add(1))})
		case r.Method == http.MethodPost && r.URL.Path == "/repos/owner/ledger/git/trees":
			writeJSON(t, w, map[string]any{"sha": "new-tree"})
		case r.Method == http.MethodPost && r.URL.Path == "/repos/owner/ledger/git/commits":
			writeJSON(t, w, map[string]any{"sha": "new-commit", "tree": map[string]any{"sha": "new-tree"}})
		case r.Method == http.MethodPatch && r.URL.Path == "/repos/owner/ledger/git/refs/heads/main":
			writeJSON(t, w, map[string]any{"ref": "refs/heads/main", "object": map[string]any{"sha": "new-commit"}})
		default:
			t.Errorf("unexpected github api request: %s %s", r.Method, r.URL.String())
			http.Error(w, "unexpected request", http.StatusNotFound)
		}
	}))
	defer server.Close()

	client, err := newGitHubLedgerClient(Config{
		LedgerRoot:         filepath.Join(t.TempDir(), "repo"),
		LedgerGitBranch:    "main",
		LedgerGitHubOwner:  "owner",
		LedgerGitHubRepo:   "ledger",
		LedgerGitHubToken:  "token",
		LedgerGitHubAPIURL: server.URL + "/",
	})
	if err != nil {
		t.Fatal(err)
	}
	client.useGraphQLCommit = true
	tx := &githubLedgerTransaction{
		ctx:           t.Context(),
		ledger:        client,
		baseCommitSHA: "base-commit",
		baseTreeSHA:   "base-tree",
		cache:         map[string]fileSnapshot{},
		writes: map[string][]byte{
			"transactions/2026/05.bean": []byte("may"),
			"transactions/2026/06.bean": []byte("june"),
			"transactions/2026/07.bean": []byte("july"),
		},
	}
	if _, err := tx.commit("test concurrent blobs"); err != nil {
		t.Fatal(err)
	}
	if got := maxActiveBlobs.Load(); got < 2 {
		t.Fatalf("max concurrent blob requests=%d, want at least 2", got)
	}
}

func TestLedgerWriteTransactionRequiresSourceLocator(t *testing.T) {
	tx := &LedgerWriteTransaction{github: &githubLedgerTransaction{baseCommitSHA: "current-commit"}}

	err := tx.validateTransactionSource(TransactionSource{GitSHA: "current-commit"})

	if err == nil {
		t.Fatal("expected a missing source locator error")
	}
}

func TestTransactionBlockRejectsAmbiguousHashFallback(t *testing.T) {
	transaction := strings.Join([]string{
		`2026-05-01 * "Cafe" "Lunch"`,
		"  Expenses:Food 12.00 CNY",
		"  Assets:Cash -12.00 CNY",
	}, "\n")
	text := strings.Join([]string{transaction, "", transaction, ""}, "\n")

	_, _, _, err := transactionBlock(text, TransactionSource{
		Line: 2,
		Hash: transactionHash(strings.Split(transaction, "\n")),
	})

	if err == nil || !strings.Contains(err.Error(), "交易来源不唯一") {
		t.Fatalf("expected an ambiguous source error, got %v", err)
	}
}

func TestGitHubAPIAppendAccountReadsValidationFilesFromGitHub(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"main.bean":        "include \"commodities.bean\"\ninclude \"accounts.bean\"\n",
		"commodities.bean": "2026-01-01 commodity CNY\n",
		"accounts.bean":    "2026-01-01 open Assets:Cash CNY\n",
	})
	defer fake.server.Close()

	cfg := githubAPITestConfig(t, fake)
	writer := NewLedgerWriter(cfg, nil)
	if err := writer.AppendAccount(AccountInput{Date: "2026-01-02", Account: "Expenses:Travel", Alias: "差旅", Currency: "CNY"}); err != nil {
		t.Fatal(err)
	}
	if len(fake.treePaths) != 1 || fake.treePaths[0] != "accounts.bean" {
		t.Fatalf("tree paths=%#v", fake.treePaths)
	}
	if got := fake.blobs["blob-1"]; !strings.Contains(got, "2026-01-02 open Expenses:Travel CNY") {
		t.Fatalf("account was not appended through github blob: %q", got)
	}
}

func TestGitHubAPIImportConfigReadsFromGitHub(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"imports/cmb-checking-config.yaml": "cashAccount: Assets:Bank:CMB\n",
	})
	defer fake.server.Close()

	cfg := githubAPITestConfig(t, fake)
	server := &Server{cfg: cfg}
	config, err := server.loadCmbCheckingConfig()
	if err != nil {
		t.Fatal(err)
	}
	if config.CashAccount != "Assets:Bank:CMB" {
		t.Fatalf("config should be read from github, got %#v", config)
	}
}

func TestGitHubAPIImportRequirementsDoNotPreflightConfig(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"imports/wechat-config.yaml": "title: Test\n",
	})
	defer fake.server.Close()

	server := &Server{cfg: githubAPITestConfig(t, fake)}
	importer, err := server.ensureImportRequirements("wechat")
	if err != nil {
		t.Fatal(err)
	}
	if got := fake.totalRequestCount(); got != 0 {
		t.Fatalf("requirement preflight requests = %d, want 0", got)
	}
	if _, err := loadDEGModuleConfig(t.Context(), server, importer.ProviderConfig()); err != nil {
		t.Fatal(err)
	}
	if got := fake.totalRequestCount(); got != 1 {
		t.Fatalf("config load requests = %d, want 1", got)
	}
}

func githubAPITestConfig(t testing.TB, fake *fakeGitHubLedgerAPI) Config {
	t.Helper()
	return Config{
		LedgerRoot:         filepath.Join(t.TempDir(), "repo"),
		RuntimeDir:         t.TempDir(),
		LedgerStorage:      "github_api",
		LedgerGitBranch:    "main",
		LedgerGitHubOwner:  "owner",
		LedgerGitHubRepo:   "ledger",
		LedgerGitHubToken:  "token",
		LedgerGitHubAPIURL: fake.server.URL + "/",
	}
}

type fakeGitHubLedgerAPI struct {
	t                              testing.TB
	server                         *httptest.Server
	mu                             sync.Mutex
	totalRequests                  int
	requestDelay                   time.Duration
	failTree                       bool
	treeStarted                    chan struct{}
	releaseTree                    chan struct{}
	treeStartedOnce                sync.Once
	files                          map[string]string
	blobs                          map[string]string
	blobSeq                        int
	treePaths                      []string
	treeBlobs                      map[string]string
	updatedRef                     string
	commitCount                    int
	contentReads                   map[string]int
	failNextContentReadAfterCommit bool
	graphQLExpectedHead            string
	graphQLRepository              string
	graphQLBranch                  string
}

func newFakeGitHubLedgerAPI(t testing.TB, files map[string]string) *fakeGitHubLedgerAPI {
	t.Helper()
	api := &fakeGitHubLedgerAPI{t: t, files: files, blobs: map[string]string{}, treeBlobs: map[string]string{}, contentReads: map[string]int{}}
	api.server = httptest.NewServer(http.HandlerFunc(api.handle))
	return api
}

func (api *fakeGitHubLedgerAPI) contentReadCounts() map[string]int {
	api.mu.Lock()
	defer api.mu.Unlock()
	counts := make(map[string]int, len(api.contentReads))
	for path, count := range api.contentReads {
		counts[path] = count
	}
	return counts
}

func (api *fakeGitHubLedgerAPI) totalRequestCount() int {
	api.mu.Lock()
	defer api.mu.Unlock()
	return api.totalRequests
}

func (api *fakeGitHubLedgerAPI) handle(w http.ResponseWriter, r *http.Request) {
	time.Sleep(api.requestDelay)
	isTreeRequest := r.Method == http.MethodGet && (r.URL.Path == "/repos/owner/ledger/git/trees/main" || r.URL.Path == "/repos/owner/ledger/git/trees/base-tree")
	if isTreeRequest && api.treeStarted != nil {
		api.treeStartedOnce.Do(func() { close(api.treeStarted) })
		<-api.releaseTree
	}
	api.mu.Lock()
	defer api.mu.Unlock()
	api.totalRequests++
	w.Header().Set("Content-Type", "application/json")
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/repos/owner/ledger/git/ref/heads/main":
		writeJSON(api.t, w, map[string]any{"ref": "refs/heads/main", "object": map[string]any{"type": "commit", "sha": "base-commit"}})
	case r.Method == http.MethodGet && r.URL.Path == "/repos/owner/ledger/git/commits/base-commit":
		writeJSON(api.t, w, map[string]any{"sha": "base-commit", "tree": map[string]any{"sha": "base-tree"}})
	case r.Method == http.MethodGet && r.URL.Path == "/repos/owner/ledger/commits/main":
		writeJSON(api.t, w, map[string]any{"sha": "base-commit", "commit": map[string]any{"tree": map[string]any{"sha": "base-tree"}}})
	case r.Method == http.MethodGet && (r.URL.Path == "/repos/owner/ledger/git/trees/main" || r.URL.Path == "/repos/owner/ledger/git/trees/base-tree"):
		if api.failTree {
			w.WriteHeader(http.StatusBadGateway)
			writeJSON(api.t, w, map[string]any{"message": "temporary tree failure"})
			return
		}
		entries := make([]map[string]any, 0, len(api.files))
		for path, content := range api.files {
			entries = append(entries, map[string]any{"path": path, "mode": "100644", "type": "blob", "sha": sha256Hex([]byte(content)), "size": len(content)})
		}
		writeJSON(api.t, w, map[string]any{"sha": "base-tree", "truncated": false, "tree": entries})
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/repos/owner/ledger/contents/"):
		if api.failNextContentReadAfterCommit && api.commitCount > 0 {
			api.failNextContentReadAfterCommit = false
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte(`{"message":"temporary upstream failure"}`))
			return
		}
		path := strings.TrimPrefix(r.URL.Path, "/repos/owner/ledger/contents/")
		api.contentReads[path]++
		content, ok := api.files[path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		writeJSON(api.t, w, map[string]any{"type": "file", "path": path, "encoding": "base64", "content": base64.StdEncoding.EncodeToString([]byte(content)), "size": len(content)})
	case r.Method == http.MethodPost && r.URL.Path == "/graphql":
		var body struct {
			Variables struct {
				Input struct {
					Branch struct {
						Repository string `json:"repositoryNameWithOwner"`
						Name       string `json:"branchName"`
					} `json:"branch"`
					FileChanges struct {
						Additions []githubGraphQLFileAddition `json:"additions"`
					} `json:"fileChanges"`
					ExpectedHeadOID string `json:"expectedHeadOid"`
				} `json:"input"`
			} `json:"variables"`
		}
		decodeJSON(api.t, r, &body)
		api.graphQLExpectedHead = body.Variables.Input.ExpectedHeadOID
		api.graphQLRepository = body.Variables.Input.Branch.Repository
		api.graphQLBranch = body.Variables.Input.Branch.Name
		if api.graphQLExpectedHead != "base-commit" {
			writeJSON(api.t, w, map[string]any{"errors": []map[string]any{{"message": "expected head does not match"}}})
			return
		}
		api.treePaths = api.treePaths[:0]
		for _, addition := range body.Variables.Input.FileChanges.Additions {
			raw, err := base64.StdEncoding.DecodeString(addition.Contents)
			if err != nil {
				api.t.Fatal(err)
			}
			api.treePaths = append(api.treePaths, addition.Path)
			api.files[addition.Path] = string(raw)
		}
		api.commitCount++
		sha := fmt.Sprintf("new-commit-%d", api.commitCount)
		api.updatedRef = "refs/heads/main"
		writeJSON(api.t, w, map[string]any{"data": map[string]any{"createCommitOnBranch": map[string]any{"commit": map[string]any{"oid": sha}}}})
	case r.Method == http.MethodPost && r.URL.Path == "/repos/owner/ledger/git/blobs":
		var body struct {
			Content  string `json:"content"`
			Encoding string `json:"encoding"`
		}
		decodeJSON(api.t, r, &body)
		raw, err := base64.StdEncoding.DecodeString(body.Content)
		if err != nil {
			api.t.Fatal(err)
		}
		api.blobSeq++
		sha := fmt.Sprintf("blob-%d", api.blobSeq)
		api.blobs[sha] = string(raw)
		writeJSON(api.t, w, map[string]any{"sha": sha})
	case r.Method == http.MethodPost && r.URL.Path == "/repos/owner/ledger/git/trees":
		var body struct {
			Tree []struct {
				Path string `json:"path"`
				SHA  string `json:"sha"`
			} `json:"tree"`
		}
		decodeJSON(api.t, r, &body)
		api.treePaths = api.treePaths[:0]
		api.treeBlobs = map[string]string{}
		for _, entry := range body.Tree {
			api.treePaths = append(api.treePaths, entry.Path)
			api.treeBlobs[entry.Path] = entry.SHA
		}
		writeJSON(api.t, w, map[string]any{"sha": "new-tree"})
	case r.Method == http.MethodPost && r.URL.Path == "/repos/owner/ledger/git/commits":
		api.commitCount++
		writeJSON(api.t, w, map[string]any{"sha": fmt.Sprintf("new-commit-%d", api.commitCount), "tree": map[string]any{"sha": "new-tree"}})
	case r.Method == http.MethodPatch && r.URL.Path == "/repos/owner/ledger/git/refs/heads/main":
		var body struct {
			SHA string `json:"sha"`
		}
		decodeJSON(api.t, r, &body)
		api.updatedRef = "refs/heads/main"
		for path, blobSHA := range api.treeBlobs {
			api.files[path] = api.blobs[blobSHA]
		}
		writeJSON(api.t, w, map[string]any{"ref": api.updatedRef, "object": map[string]any{"sha": body.SHA}})
	default:
		api.t.Fatalf("unexpected github api request: %s %s", r.Method, r.URL.String())
	}
}

func writeJSON(t testing.TB, w http.ResponseWriter, value any) {
	t.Helper()
	if err := json.NewEncoder(w).Encode(value); err != nil {
		t.Fatal(err)
	}
}

func decodeJSON(t testing.TB, r *http.Request, value any) {
	t.Helper()
	if err := json.NewDecoder(r.Body).Decode(value); err != nil {
		t.Fatal(err)
	}
}
