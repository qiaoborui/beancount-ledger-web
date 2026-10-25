package app

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeCacheFile(t *testing.T, path string, size int, modTime time.Time) {
	t.Helper()
	if err := os.WriteFile(path, make([]byte, size), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, modTime, modTime); err != nil {
		t.Fatal(err)
	}
}

// Every source version adds an entry, so the cache must keep only the newest
// few or a frequently edited ledger grows without bound.
func TestTrimRuntimeCachesKeepsNewestEntries(t *testing.T) {
	runtimeDir := t.TempDir()
	streamDir := filepath.Join(runtimeDir, "canonical-stream")
	loaderDir := filepath.Join(runtimeDir, "loader-cache")
	for _, dir := range []string{streamDir, loaderDir} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now()
	for i := 0; i < localCanonicalCacheEntries+2; i++ {
		name := fmt.Sprintf("%032x.snap1", i)
		writeCacheFile(t, filepath.Join(streamDir, name), 16, now.Add(-time.Duration(i)*time.Minute))
	}
	for i := 0; i < localLoaderCacheEntries+2; i++ {
		name := fmt.Sprintf("%064x.picklecache", i)
		writeCacheFile(t, filepath.Join(loaderDir, name), 16, now.Add(-time.Duration(i)*time.Minute))
	}
	trimRuntimeCaches(runtimeDir)

	streams, _ := os.ReadDir(streamDir)
	if len(streams) != localCanonicalCacheEntries {
		t.Fatalf("kept %d snapshots, want %d", len(streams), localCanonicalCacheEntries)
	}
	loaders, _ := os.ReadDir(loaderDir)
	if len(loaders) != localLoaderCacheEntries {
		t.Fatalf("kept %d pickle caches, want %d", len(loaders), localLoaderCacheEntries)
	}
	// The newest entries are the ones that survive.
	if _, err := os.Stat(filepath.Join(streamDir, fmt.Sprintf("%032x.snap1", 0))); err != nil {
		t.Fatalf("newest snapshot was removed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(loaderDir, fmt.Sprintf("%064x.picklecache", 0))); err != nil {
		t.Fatalf("newest pickle cache was removed: %v", err)
	}
}

// Unrelated files must never be removed; the directories hold other artifacts.
func TestTrimRuntimeCachesIgnoresForeignFiles(t *testing.T) {
	runtimeDir := t.TempDir()
	streamDir := filepath.Join(runtimeDir, "canonical-stream")
	if err := os.MkdirAll(streamDir, 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	for i := 0; i < localCanonicalCacheEntries+2; i++ {
		writeCacheFile(t, filepath.Join(streamDir, fmt.Sprintf("%032x.snap1", i)), 8, now.Add(-time.Duration(i)*time.Minute))
	}
	foreign := filepath.Join(streamDir, "notes.txt")
	writeCacheFile(t, foreign, 8, now.Add(-24*time.Hour))
	// A name that is not 32 hex characters is not a cache entry.
	badStem := filepath.Join(streamDir, "not-a-cache.snap1")
	writeCacheFile(t, badStem, 8, now.Add(-24*time.Hour))

	trimRuntimeCaches(runtimeDir)

	for _, path := range []string{foreign, badStem} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("foreign file %s was removed: %v", filepath.Base(path), err)
		}
	}
}

// The per-ledger ceiling trims the oldest entries once both caches together
// exceed it, and it never drops the newest snapshot.
func TestTrimRuntimeCachesEnforcesBudget(t *testing.T) {
	runtimeDir := t.TempDir()
	streamDir := filepath.Join(runtimeDir, "canonical-stream")
	loaderDir := filepath.Join(runtimeDir, "loader-cache")
	for _, dir := range []string{streamDir, loaderDir} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now()
	// Each file is large enough that a couple of them exceed the ceiling.
	size := int(localRuntimeCacheBudget/3) + 1
	newestSnapshot := filepath.Join(streamDir, fmt.Sprintf("%032x.snap1", 0))
	writeCacheFile(t, newestSnapshot, size, now)
	writeCacheFile(t, filepath.Join(streamDir, fmt.Sprintf("%032x.snap1", 1)), size, now.Add(-time.Minute))
	writeCacheFile(t, filepath.Join(loaderDir, fmt.Sprintf("%064x.picklecache", 0)), size, now.Add(-2*time.Minute))

	trimRuntimeCaches(runtimeDir)

	total := int64(0)
	for _, dir := range []string{streamDir, loaderDir} {
		items, err := os.ReadDir(dir)
		if err != nil {
			t.Fatal(err)
		}
		for _, item := range items {
			info, err := item.Info()
			if err != nil {
				t.Fatal(err)
			}
			total += info.Size()
		}
	}
	if total > localRuntimeCacheBudget {
		t.Fatalf("cache still holds %d bytes, budget %d", total, localRuntimeCacheBudget)
	}
	if _, err := os.Stat(newestSnapshot); err != nil {
		t.Fatalf("newest snapshot must survive the budget trim: %v", err)
	}
}

// A missing runtime directory is normal (nothing loaded yet) and must not panic.
func TestTrimRuntimeCachesToleratesMissingDirectories(t *testing.T) {
	trimRuntimeCaches("")
	trimRuntimeCaches(filepath.Join(t.TempDir(), "absent"))
}
