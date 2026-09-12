package app

import (
	"bytes"
	"fmt"
	"sync"
	"testing"
)

func TestGitHubValidationCacheCopiesContentOnReadAndWrite(t *testing.T) {
	cache := &githubValidationCache{}
	content := []byte("2026-01-01 open Assets:Cash CNY\n")
	original := bytes.Clone(content)
	sha := gitBlobSHA(content)
	cache.put(content)
	content[0] = 'X'

	first, ok := cache.get(sha)
	if !ok || !bytes.Equal(first, original) {
		t.Fatalf("mutating the input changed cached content: %q, hit=%v", first, ok)
	}
	first[0] = 'Y'
	second, ok := cache.get(sha)
	if !ok || !bytes.Equal(second, original) {
		t.Fatalf("mutating a read changed cached content: %q, hit=%v", second, ok)
	}
	assertGitHubValidationCacheAccounting(t, cache)
}

func TestGitHubValidationCacheEvictsLeastRecentlyUsedAt512Entries(t *testing.T) {
	for _, touch := range []string{"read", "duplicate write"} {
		t.Run(touch, func(t *testing.T) {
			cache := &githubValidationCache{}
			contents := make([][]byte, 512)
			for i := range contents {
				contents[i] = []byte(fmt.Sprintf("blob-%03d", i))
				cache.put(contents[i])
			}
			if touch == "read" {
				if _, ok := cache.get(gitBlobSHA(contents[0])); !ok {
					t.Fatal("the oldest entry was evicted before the entry limit")
				}
			} else {
				cache.put(contents[0])
			}
			assertGitHubValidationCacheAccounting(t, cache)
			if len(cache.entries) != 512 {
				t.Fatalf("cache holds %d entries at the limit, want 512", len(cache.entries))
			}

			newest := []byte("blob-512")
			cache.put(newest)
			if _, ok := cache.get(gitBlobSHA(contents[1])); ok {
				t.Fatal("the least recently used entry survived insertion beyond the entry limit")
			}
			for _, content := range [][]byte{contents[0], contents[2], contents[511], newest} {
				if got, ok := cache.get(gitBlobSHA(content)); !ok || !bytes.Equal(got, content) {
					t.Fatalf("expected retained entry %q, got %q, hit=%v", content, got, ok)
				}
			}
			if len(cache.entries) != 512 {
				t.Fatalf("cache holds %d entries after eviction, want 512", len(cache.entries))
			}
			assertGitHubValidationCacheAccounting(t, cache)
		})
	}
}

func TestGitHubValidationCacheEvictsLeastRecentlyUsedAt32MiB(t *testing.T) {
	cache := &githubValidationCache{}
	first := bytes.Repeat([]byte{'A'}, 16<<20)
	second := bytes.Repeat([]byte{'B'}, 16<<20)
	cache.put(first)
	cache.put(second)
	if cache.bytes != 32<<20 || len(cache.entries) != 2 {
		t.Fatalf("exact byte limit: bytes=%d entries=%d, want 32 MiB and 2 entries", cache.bytes, len(cache.entries))
	}
	if _, ok := cache.get(gitBlobSHA(first)); !ok {
		t.Fatal("the first blob was evicted before the byte limit")
	}

	cache.put([]byte("C"))
	if _, ok := cache.get(gitBlobSHA(second)); ok {
		t.Fatal("least recently used blob survived insertion beyond the byte limit")
	}
	if got, ok := cache.get(gitBlobSHA(first)); !ok || !bytes.Equal(got, first) {
		t.Fatal("the recently read blob was evicted or changed")
	}
	if got, ok := cache.get(gitBlobSHA([]byte("C"))); !ok || string(got) != "C" {
		t.Fatal("new content was not retained after byte-limit eviction")
	}
	if cache.bytes != (16<<20)+1 {
		t.Fatalf("retained bytes=%d, want 16 MiB + 1", cache.bytes)
	}
	assertGitHubValidationCacheAccounting(t, cache)
}

func TestGitHubValidationCacheAcceptsExactLimitAndRejectsOversizedBlob(t *testing.T) {
	cache := &githubValidationCache{}
	cache.put([]byte("first old blob"))
	cache.put([]byte("second old blob"))
	exact := bytes.Repeat([]byte{'A'}, 32<<20)
	cache.put(exact)
	if cache.bytes != len(exact) || len(cache.entries) != 1 {
		t.Fatalf("exact-limit blob was not retained: bytes=%d entries=%d", cache.bytes, len(cache.entries))
	}
	oversized := bytes.Repeat([]byte{'B'}, (32<<20)+1)
	cache.put(oversized)
	if _, ok := cache.get(gitBlobSHA(oversized)); ok {
		t.Fatal("oversized blob was cached")
	}
	if got, ok := cache.get(gitBlobSHA(exact)); !ok || !bytes.Equal(got, exact) {
		t.Fatal("rejecting an oversized blob changed the existing cached content")
	}
	if cache.bytes != len(exact) || len(cache.entries) != 1 {
		t.Fatalf("rejected blob changed accounting: bytes=%d entries=%d", cache.bytes, len(cache.entries))
	}
	assertGitHubValidationCacheAccounting(t, cache)

	empty := &githubValidationCache{}
	empty.put(oversized)
	if len(empty.entries) != 0 || empty.bytes != 0 {
		t.Fatal("an empty cache retained an oversized blob")
	}
	assertGitHubValidationCacheAccounting(t, empty)
}

func TestGitHubValidationCacheScopeChangesClearAllContent(t *testing.T) {
	base := Config{
		LedgerStorage: "github", LedgerGitHubAPIURL: "https://api.example.test",
		LedgerGitHubOwner: "owner", LedgerGitHubRepo: "ledger", LedgerGitBranch: "main",
		LedgerRoot: "/fixture/ledger", LedgerGitHubToken: "fixture-token",
	}
	changes := []struct {
		name   string
		change func(*Config)
	}{
		{"storage", func(cfg *Config) { cfg.LedgerStorage = "local" }},
		{"API URL", func(cfg *Config) { cfg.LedgerGitHubAPIURL = "https://other.example.test" }},
		{"owner", func(cfg *Config) { cfg.LedgerGitHubOwner = "other-owner" }},
		{"repository", func(cfg *Config) { cfg.LedgerGitHubRepo = "other-ledger" }},
		{"branch", func(cfg *Config) { cfg.LedgerGitBranch = "preview" }},
		{"root", func(cfg *Config) { cfg.LedgerRoot = "/fixture/other-ledger" }},
		{"credential", func(cfg *Config) { cfg.LedgerGitHubToken = "other-fixture-token" }},
	}
	for _, change := range changes {
		t.Run(change.name, func(t *testing.T) {
			cache := &githubValidationCache{}
			cache.setScope(base)
			content := []byte("scoped fixture")
			sha := gitBlobSHA(content)
			cache.put(content)
			cache.setScope(base)
			if got, ok := cache.get(sha); !ok || !bytes.Equal(got, content) {
				t.Fatal("unchanged scope discarded its content")
			}

			updated := base
			change.change(&updated)
			cache.setScope(updated)
			if _, ok := cache.get(sha); ok || len(cache.entries) != 0 || cache.bytes != 0 {
				t.Fatal("changed scope retained cached content")
			}
			assertGitHubValidationCacheAccounting(t, cache)
			cache.put(content)
			if _, ok := cache.get(sha); !ok {
				t.Fatal("cache cannot accept content after a scope change")
			}
			cache.setScope(base)
			if _, ok := cache.get(sha); ok || len(cache.entries) != 0 || cache.bytes != 0 {
				t.Fatal("returning to an old scope restored cached content")
			}
			assertGitHubValidationCacheAccounting(t, cache)
		})
	}
}

func TestGitHubValidationCacheConcurrentAccessAndScopeChanges(t *testing.T) {
	cache := &githubValidationCache{}
	var workers sync.WaitGroup
	start := make(chan struct{})
	for worker := 0; worker < 16; worker++ {
		workers.Add(1)
		go func(worker int) {
			defer workers.Done()
			<-start
			for iteration := 0; iteration < 300; iteration++ {
				content := []byte(fmt.Sprintf("worker-%d-blob-%d", worker, iteration))
				sha := gitBlobSHA(content)
				cache.put(content)
				// Eviction or a concurrent scope change may legitimately cause a miss.
				if got, ok := cache.get(sha); ok {
					if !bytes.Equal(got, content) {
						t.Errorf("cache returned changed content for worker %d", worker)
						return
					}
					got[0] = 'X'
					if again, ok := cache.get(sha); ok && !bytes.Equal(again, content) {
						t.Errorf("concurrent read mutation changed cache for worker %d", worker)
						return
					}
				}
			}
		}(worker)
	}
	workers.Add(1)
	go func() {
		defer workers.Done()
		<-start
		for iteration := 0; iteration < 300; iteration++ {
			cache.setScope(Config{LedgerGitHubToken: fmt.Sprintf("fixture-token-%d", iteration%2)})
		}
	}()
	close(start)
	workers.Wait()
	assertGitHubValidationCacheAccounting(t, cache)
	cache.setScope(Config{LedgerGitHubToken: "final-fixture-scope"})
	if cache.bytes != 0 || len(cache.entries) != 0 {
		t.Fatal("scope reset after concurrent access retained content")
	}
	cache.put([]byte("final fixture"))
	if got, ok := cache.get(gitBlobSHA([]byte("final fixture"))); !ok || string(got) != "final fixture" {
		t.Fatal("cache is unusable after concurrent access and scope reset")
	}
	assertGitHubValidationCacheAccounting(t, cache)
}

func assertGitHubValidationCacheAccounting(t *testing.T, cache *githubValidationCache) {
	t.Helper()
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if len(cache.entries) > 512 || cache.bytes > 32<<20 || cache.bytes < 0 {
		t.Fatalf("cache resource limits exceeded: entries=%d bytes=%d", len(cache.entries), cache.bytes)
	}
	if cache.lru.Len() != len(cache.entries) {
		t.Fatalf("LRU has %d entries but map has %d", cache.lru.Len(), len(cache.entries))
	}
	actualBytes := 0
	for element := cache.lru.Front(); element != nil; element = element.Next() {
		blob := element.Value.(githubValidationBlob)
		if cache.entries[blob.sha] != element {
			t.Fatal("LRU entry does not match its map entry")
		}
		actualBytes += len(blob.content)
	}
	if cache.bytes != actualBytes {
		t.Fatalf("accounted bytes=%d, actual bytes=%d", cache.bytes, actualBytes)
	}
}
