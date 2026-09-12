package app

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// This read-only fake preserves immutable revisions. Its current branch can
// move independently of already-created transactions, including force pushes.
type validationRevisionAPI struct {
	mu        sync.Mutex
	server    *httptest.Server
	head      string
	revisions map[string]map[string]string
	reads     map[string]int
	trees     []string
	truncated bool
	treeModes map[string]string
	treeSHAs  map[string]string
}

func newValidationRevisionAPI(t *testing.T) *validationRevisionAPI {
	t.Helper()
	api := &validationRevisionAPI{revisions: map[string]map[string]string{}, reads: map[string]int{}, treeModes: map[string]string{}, treeSHAs: map[string]string{}}
	api.server = httptest.NewServer(http.HandlerFunc(api.serveHTTP))
	t.Cleanup(api.server.Close)
	return api
}

func (api *validationRevisionAPI) addRevision(name string, files map[string]string) {
	api.mu.Lock()
	defer api.mu.Unlock()
	copy := make(map[string]string, len(files))
	for path, content := range files {
		copy[path] = content
	}
	api.revisions[name] = copy
	api.head = name
}

func (api *validationRevisionAPI) setHead(name string) {
	api.mu.Lock()
	defer api.mu.Unlock()
	api.head = name
}

func (api *validationRevisionAPI) readCount() int {
	api.mu.Lock()
	defer api.mu.Unlock()
	count := 0
	for _, reads := range api.reads {
		count += reads
	}
	return count
}

func (api *validationRevisionAPI) serveHTTP(w http.ResponseWriter, r *http.Request) {
	api.mu.Lock()
	defer api.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if r.Method != http.MethodGet || len(parts) < 5 || parts[0] != "repos" {
		http.Error(w, "unexpected mutation or route", http.StatusBadRequest)
		return
	}
	if parts[3] == "commits" {
		_ = json.NewEncoder(w).Encode(map[string]any{"sha": api.head, "commit": map[string]any{"tree": map[string]any{"sha": "tree-" + api.head}}})
		return
	}
	if len(parts) == 6 && parts[3] == "git" && parts[4] == "trees" {
		revision := strings.TrimPrefix(parts[5], "tree-")
		files, exists := api.revisions[revision]
		if !exists {
			http.NotFound(w, r)
			return
		}
		api.trees = append(api.trees, revision)
		entries := make([]map[string]any, 0, len(files))
		for path, content := range files {
			mode, sha := "100644", gitBlobSHA([]byte(content))
			if override := api.treeModes[revision+":"+path]; override != "" {
				mode = override
			}
			if override := api.treeSHAs[revision+":"+path]; override != "" {
				sha = override
			}
			entries = append(entries, map[string]any{"path": path, "type": "blob", "mode": mode, "sha": sha, "size": len(content)})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"sha": parts[5], "truncated": api.truncated, "tree": entries})
		return
	}
	if parts[3] == "contents" {
		revision, path := r.URL.Query().Get("ref"), strings.Join(parts[4:], "/")
		api.reads[revision+":"+path]++
		content, exists := api.revisions[revision][path]
		if !exists {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"type": "file", "path": path, "encoding": "base64", "content": base64.StdEncoding.EncodeToString([]byte(content)), "sha": gitBlobSHA([]byte(content)), "size": len(content)})
		return
	}
	http.NotFound(w, r)
}

func validationCacheConfig(t *testing.T, api *validationRevisionAPI) Config {
	t.Helper()
	return Config{LedgerRoot: filepath.Join(t.TempDir(), "ledger"), LedgerStorage: "github_api", LedgerGitHubOwner: "owner", LedgerGitHubRepo: "ledger", LedgerGitBranch: "main", LedgerGitHubToken: "test-token", LedgerGitHubAPIURL: api.server.URL + "/"}
}

func validationCacheTransaction(t *testing.T, cfg Config, cache *githubValidationCache) *githubLedgerTransaction {
	t.Helper()
	cache.setScope(cfg)
	client, err := newGitHubLedgerClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	client.validationCache = cache
	tx, err := client.beginTransaction(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	// Keep the ledger itself untouched, while exercising the nonempty write
	// validation path exactly as an auxiliary file update would.
	tx.writes["validation-probe.json"] = []byte("{}")
	return tx
}

func cacheTestLedger() map[string]string {
	return map[string]string{
		"main.bean":        "include \"accounts.bean\"\ninclude \"entries/*.bean\"\n",
		"accounts.bean":    "2026-01-01 open Assets:Cash CNY\n2026-01-01 open Expenses:Food CNY\n",
		"entries/one.bean": "2026-05-01 * \"Cafe\"\n  Expenses:Food 10 CNY\n  Assets:Cash -10 CNY\n",
	}
}

func TestGitHubValidationCachePinsReadsToTransactionCommit(t *testing.T) {
	useRealGitHubBeanCheck(t)
	api := newValidationRevisionAPI(t)
	api.addRevision("original", cacheTestLedger())
	cfg := validationCacheConfig(t, api)
	var cache githubValidationCache
	tx := validationCacheTransaction(t, cfg, &cache)
	changed := cacheTestLedger()
	changed["entries/one.bean"] = strings.ReplaceAll(changed["entries/one.bean"], "-10 CNY", "-9 CNY")
	api.addRevision("external", changed)
	if err := tx.validate(); err != nil {
		t.Fatalf("fixed original revision changed underneath validation: %v", err)
	}
	if api.trees[0] != "original" || api.reads["original:entries/one.bean"] != 1 {
		t.Fatalf("reads were not pinned: trees=%v reads=%v", api.trees, api.reads)
	}
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err == nil || !strings.Contains(err.Error(), "does not balance") {
		t.Fatalf("new external revision reused stale content: %v", err)
	}
}

func TestGitHubValidationCacheTracksExternalIncludeAndGlobChanges(t *testing.T) {
	useRealGitHubBeanCheck(t)
	api := newValidationRevisionAPI(t)
	cfg := validationCacheConfig(t, api)
	var cache githubValidationCache
	api.addRevision("initial", cacheTestLedger())
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err != nil {
		t.Fatal(err)
	}
	initialReads := api.readCount()
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err != nil {
		t.Fatal(err)
	}
	if api.readCount() != initialReads {
		t.Fatal("warm validation refetched unchanged blobs")
	}

	added := cacheTestLedger()
	added["entries/two.bean"] = "2026-05-02 * \"Bad\"\n  Expenses:Food 10 CNY\n  Assets:Cash -9 CNY\n"
	api.addRevision("glob-add", added)
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err == nil {
		t.Fatal("external wildcard match was missed")
	}
	if api.readCount() != initialReads+1 {
		t.Fatal("external addition refetched unchanged blobs")
	}

	api.addRevision("glob-delete", cacheTestLedger())
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err != nil {
		t.Fatalf("deleted wildcard file remained in validation: %v", err)
	}

	changedInclude := cacheTestLedger()
	changedInclude["main.bean"] = "include \"accounts.bean\"\ninclude \"other/invalid.bean\"\n"
	changedInclude["other/invalid.bean"] = added["entries/two.bean"]
	api.addRevision("include-change", changedInclude)
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err == nil {
		t.Fatal("external include directive reused the old include closure")
	}
}

func TestGitHubValidationCacheSupportsForcePushToOlderSnapshot(t *testing.T) {
	useRealGitHubBeanCheck(t)
	api := newValidationRevisionAPI(t)
	cfg := validationCacheConfig(t, api)
	var cache githubValidationCache
	api.addRevision("older", cacheTestLedger())
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err != nil {
		t.Fatal(err)
	}
	newer := cacheTestLedger()
	newer["entries/one.bean"] = strings.ReplaceAll(newer["entries/one.bean"], "10 CNY", "20 CNY")
	api.addRevision("newer", newer)
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err != nil {
		t.Fatal(err)
	}
	before := api.readCount()
	api.setHead("older")
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err != nil {
		t.Fatalf("force push to old valid snapshot failed: %v", err)
	}
	if api.readCount() != before || api.trees[len(api.trees)-1] != "older" {
		t.Fatalf("force push cache/tree mismatch: reads=%v trees=%v", api.reads, api.trees)
	}
}

func TestGitHubValidationCacheSeparatesLedgerConfigurations(t *testing.T) {
	useRealGitHubBeanCheck(t)
	for _, change := range []string{"owner", "repo", "branch", "root", "token", "api"} {
		t.Run(change, func(t *testing.T) {
			api := newValidationRevisionAPI(t)
			api.addRevision("original", cacheTestLedger())
			cfg := validationCacheConfig(t, api)
			var cache githubValidationCache
			if err := validationCacheTransaction(t, cfg, &cache).validate(); err != nil {
				t.Fatal(err)
			}
			before := api.readCount()
			switch change {
			case "owner":
				cfg.LedgerGitHubOwner = "another-owner"
			case "repo":
				cfg.LedgerGitHubRepo = "another-ledger"
			case "branch":
				cfg.LedgerGitBranch = "preview"
			case "root":
				cfg.LedgerRoot = filepath.Join(t.TempDir(), "other")
			case "token":
				cfg.LedgerGitHubToken = "rotated-token"
			case "api":
				other := httptest.NewServer(http.HandlerFunc(api.serveHTTP))
				t.Cleanup(other.Close)
				cfg.LedgerGitHubAPIURL = other.URL + "/"
			}
			if err := validationCacheTransaction(t, cfg, &cache).validate(); err != nil {
				t.Fatal(err)
			}
			if api.readCount() != before*2 {
				t.Fatalf("%s change reused prior ledger cache: before=%d after=%d", change, before, api.readCount())
			}
		})
	}
}

func TestGitHubValidationCacheRejectsTruncatedTreeEvenWhenWarm(t *testing.T) {
	useRealGitHubBeanCheck(t)
	api := newValidationRevisionAPI(t)
	api.addRevision("original", cacheTestLedger())
	cfg := validationCacheConfig(t, api)
	var cache githubValidationCache
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err != nil {
		t.Fatal(err)
	}
	api.mu.Lock()
	api.truncated = true
	api.mu.Unlock()
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err == nil || !strings.Contains(err.Error(), "too large") {
		t.Fatalf("warm cache accepted truncated tree: %v", err)
	}
}

func TestGitHubValidationCacheFailedCandidateDoesNotReplaceBaseBlob(t *testing.T) {
	useRealGitHubBeanCheck(t)
	api := newValidationRevisionAPI(t)
	files := cacheTestLedger()
	api.addRevision("original", files)
	cfg := validationCacheConfig(t, api)
	var cache githubValidationCache
	tx := validationCacheTransaction(t, cfg, &cache)
	tx.writes["entries/one.bean"] = []byte(strings.ReplaceAll(files["entries/one.bean"], "-10 CNY", "-9 CNY"))
	if err := tx.validate(); err == nil {
		t.Fatal("invalid candidate unexpectedly passed")
	}
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err != nil {
		t.Fatalf("failed candidate contaminated the base snapshot: %v", err)
	}
	if api.reads["original:entries/one.bean"] != 1 {
		t.Fatalf("base revision was not loaded after failed candidate: %v", api.reads)
	}
}

func TestGitBlobSHAUsesGitObjectHeader(t *testing.T) {
	for content, expected := range map[string]string{
		"":        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
		"hello\n": "ce013625030ba8dba906f756967f9e9ca394464a",
	} {
		if got := gitBlobSHA([]byte(content)); got != expected {
			t.Fatalf("blob SHA for %q=%s want=%s", content, got, expected)
		}
	}
}

func TestGitHubValidationCacheSymlinkReadsContentInsteadOfLinkTextBlob(t *testing.T) {
	useRealGitHubBeanCheck(t)
	api := newValidationRevisionAPI(t)
	files := cacheTestLedger()
	files["targets/source.bean"] = files["entries/one.bean"]
	api.addRevision("linked", files)
	linkText := []byte("../targets/source.bean")
	api.mu.Lock()
	api.treeModes["linked:entries/one.bean"] = "120000"
	api.treeSHAs["linked:entries/one.bean"] = gitBlobSHA(linkText)
	api.mu.Unlock()
	cfg := validationCacheConfig(t, api)
	var cache githubValidationCache
	tx := validationCacheTransaction(t, cfg, &cache)
	// A prior read can cache bytes identical to the link's target path. That
	// Git blob identity describes link text, while Contents returns target data.
	cache.put(linkText)
	if err := tx.validate(); err != nil {
		t.Fatalf("symlink used cached path text as ledger content: %v", err)
	}
	if err := validationCacheTransaction(t, cfg, &cache).validate(); err != nil {
		t.Fatalf("warm symlink validation failed: %v", err)
	}
	api.mu.Lock()
	defer api.mu.Unlock()
	if api.reads["linked:entries/one.bean"] != 2 {
		t.Fatalf("symlink must resolve target content at its fixed commit every time: reads=%v", api.reads)
	}
}
