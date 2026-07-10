package app

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
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
	)
	if err != nil {
		t.Fatal(err)
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

func githubAPITestConfig(t *testing.T, fake *fakeGitHubLedgerAPI) Config {
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
	t          *testing.T
	server     *httptest.Server
	mu         sync.Mutex
	files      map[string]string
	blobs      map[string]string
	blobSeq    int
	treePaths  []string
	updatedRef string
}

func newFakeGitHubLedgerAPI(t *testing.T, files map[string]string) *fakeGitHubLedgerAPI {
	t.Helper()
	api := &fakeGitHubLedgerAPI{t: t, files: files, blobs: map[string]string{}}
	api.server = httptest.NewServer(http.HandlerFunc(api.handle))
	return api
}

func (api *fakeGitHubLedgerAPI) handle(w http.ResponseWriter, r *http.Request) {
	api.mu.Lock()
	defer api.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/repos/owner/ledger/git/ref/heads/main":
		writeJSON(api.t, w, map[string]any{"ref": "refs/heads/main", "object": map[string]any{"type": "commit", "sha": "base-commit"}})
	case r.Method == http.MethodGet && r.URL.Path == "/repos/owner/ledger/git/commits/base-commit":
		writeJSON(api.t, w, map[string]any{"sha": "base-commit", "tree": map[string]any{"sha": "base-tree"}})
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/repos/owner/ledger/contents/"):
		path := strings.TrimPrefix(r.URL.Path, "/repos/owner/ledger/contents/")
		content, ok := api.files[path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		writeJSON(api.t, w, map[string]any{"type": "file", "path": path, "encoding": "base64", "content": base64.StdEncoding.EncodeToString([]byte(content)), "size": len(content)})
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
			} `json:"tree"`
		}
		decodeJSON(api.t, r, &body)
		api.treePaths = api.treePaths[:0]
		for _, entry := range body.Tree {
			api.treePaths = append(api.treePaths, entry.Path)
		}
		writeJSON(api.t, w, map[string]any{"sha": "new-tree"})
	case r.Method == http.MethodPost && r.URL.Path == "/repos/owner/ledger/git/commits":
		writeJSON(api.t, w, map[string]any{"sha": "new-commit", "tree": map[string]any{"sha": "new-tree"}})
	case r.Method == http.MethodPatch && r.URL.Path == "/repos/owner/ledger/git/refs/heads/main":
		var body struct {
			SHA string `json:"sha"`
		}
		decodeJSON(api.t, r, &body)
		api.updatedRef = "refs/heads/main"
		writeJSON(api.t, w, map[string]any{"ref": api.updatedRef, "object": map[string]any{"sha": body.SHA}})
	default:
		api.t.Fatalf("unexpected github api request: %s %s", r.Method, r.URL.String())
	}
}

func writeJSON(t *testing.T, w http.ResponseWriter, value any) {
	t.Helper()
	if err := json.NewEncoder(w).Encode(value); err != nil {
		t.Fatal(err)
	}
}

func decodeJSON(t *testing.T, r *http.Request, value any) {
	t.Helper()
	if err := json.NewDecoder(r.Body).Decode(value); err != nil {
		t.Fatal(err)
	}
}
