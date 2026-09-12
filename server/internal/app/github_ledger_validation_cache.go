package app

import (
	"container/list"
	"crypto/sha1"
	"fmt"
	"sync"
)

const (
	githubValidationCacheMaxBytes   = 32 << 20
	githubValidationCacheMaxEntries = 512
)

// The writer owns this bounded, memory-only cache. Keys are immutable Git blob
// identities, scoped to a single configured ledger and credential. Every write
// still resolves the current commit and its complete tree before using a blob.
type githubValidationCache struct {
	mu      sync.Mutex
	scope   string
	entries map[string]*list.Element
	lru     list.List
	bytes   int
}

type githubValidationBlob struct {
	sha     string
	content []byte
}

func gitBlobSHA(content []byte) string {
	hash := sha1.New() // Git's object identity, not a password/security hash.
	fmt.Fprintf(hash, "blob %d\x00", len(content))
	hash.Write(content)
	return fmt.Sprintf("%x", hash.Sum(nil))
}

func (c *githubValidationCache) setScope(cfg Config) {
	scope := sha256Hex([]byte(fmt.Sprintf("%q", []string{cfg.LedgerStorage, cfg.LedgerGitHubAPIURL, cfg.LedgerGitHubOwner, cfg.LedgerGitHubRepo, cfg.LedgerGitBranch, cfg.LedgerRoot, cfg.LedgerGitHubToken})))
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.scope != scope {
		c.scope = scope
		c.entries = make(map[string]*list.Element)
		c.lru.Init()
		c.bytes = 0
	}
}

func (c *githubValidationCache) get(sha string) ([]byte, bool) {
	if c == nil || sha == "" {
		return nil, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	element := c.entries[sha]
	if element == nil {
		return nil, false
	}
	c.lru.MoveToFront(element)
	return append([]byte(nil), element.Value.(githubValidationBlob).content...), true
}

func (c *githubValidationCache) put(content []byte) {
	if c == nil || len(content) > githubValidationCacheMaxBytes {
		return
	}
	sha := gitBlobSHA(content)
	c.mu.Lock()
	defer c.mu.Unlock()
	if element := c.entries[sha]; element != nil {
		c.lru.MoveToFront(element)
		return
	}
	if c.entries == nil {
		c.entries = make(map[string]*list.Element)
	}
	for c.bytes+len(content) > githubValidationCacheMaxBytes || len(c.entries) >= githubValidationCacheMaxEntries {
		oldest := c.lru.Back()
		blob := oldest.Value.(githubValidationBlob)
		c.bytes -= len(blob.content)
		delete(c.entries, blob.sha)
		c.lru.Remove(oldest)
	}
	blob := githubValidationBlob{sha: sha, content: append([]byte(nil), content...)}
	c.entries[sha] = c.lru.PushFront(blob)
	c.bytes += len(content)
}
