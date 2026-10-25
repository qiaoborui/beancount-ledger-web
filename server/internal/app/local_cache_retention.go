package app

// Disk retention for the canonical read caches.
//
// Two caches now live under a ledger's runtime directory:
//
//   - canonical-stream/<version>.snap1 (or .records): the decoded model, ~8.4MB
//     for a 100k ledger.
//   - loader-cache/<digest>.picklecache: beancount's pinned load result, ~28MB
//     for the same ledger.
//
// Both are pure caches: the exporter stream is authoritative and anything
// missing is rebuilt. They are also unbounded by nature, because every source
// version produces a new entry, so a ledger that is edited often would keep one
// copy per version forever. This trims them to the most recent entries.

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	// One current entry plus a little history: enough that switching back to a
	// recently viewed version or range does not rebuild, without letting a
	// frequently edited ledger accumulate a copy per version.
	localCanonicalCacheEntries = 3
	// The loader cache entry is the expensive one (~28MB on a 100k ledger), and
	// a single ledger rarely alternates between more than a couple of versions.
	localLoaderCacheEntries = 2
	// Absolute ceiling for one ledger's runtime caches. Older entries are dropped
	// first; a single entry larger than this is kept, because rebuilding it would
	// cost more than the space it holds.
	localRuntimeCacheBudget = 160 << 20
)

// trimRuntimeCaches drops the least recently used entries of the two canonical
// caches. It never fails a caller: these files are rebuildable caches, so a
// cleanup problem must not affect a read or a write.
func trimRuntimeCaches(runtimeDir string) {
	if runtimeDir == "" {
		return
	}
	trimCacheDirectory(filepath.Join(runtimeDir, "canonical-stream"), localCanonicalCacheEntries,
		func(name string) bool { _, ok := localCanonicalStem(name); return ok })
	trimCacheDirectory(filepath.Join(runtimeDir, "loader-cache"), localLoaderCacheEntries,
		func(name string) bool { return strings.HasSuffix(name, ".picklecache") })
	trimRuntimeCacheBudget(runtimeDir)
}

type cacheEntry struct {
	path    string
	size    int64
	modTime int64
}

// trimCacheDirectory keeps at most keep entries, preferring the newest. Only
// names accepted by want are considered, so an unrelated file is never removed.
func trimCacheDirectory(directory string, keep int, want func(string) bool) {
	entries := listCacheEntries(directory, want)
	if len(entries) <= keep {
		return
	}
	// Newest first, so everything after the head is expendable.
	sort.Slice(entries, func(i, j int) bool { return entries[i].modTime > entries[j].modTime })
	for _, entry := range entries[keep:] {
		_ = os.Remove(entry.path)
	}
}

func listCacheEntries(directory string, want func(string) bool) []cacheEntry {
	items, err := os.ReadDir(directory)
	if err != nil {
		return nil
	}
	entries := make([]cacheEntry, 0, len(items))
	for _, item := range items {
		if !item.Type().IsRegular() || !want(item.Name()) {
			continue
		}
		info, err := item.Info()
		if err != nil {
			continue
		}
		entries = append(entries, cacheEntry{
			path:    filepath.Join(directory, item.Name()),
			size:    info.Size(),
			modTime: info.ModTime().UnixNano(),
		})
	}
	return entries
}

// trimRuntimeCacheBudget enforces the per-ledger ceiling across both caches.
// The most recent canonical-stream entry is always kept: dropping it would force
// a full re-read of the stream on the next request, which is the exact cost the
// snapshot exists to avoid.
func trimRuntimeCacheBudget(runtimeDir string) {
	streamDir := filepath.Join(runtimeDir, "canonical-stream")
	loaderDir := filepath.Join(runtimeDir, "loader-cache")
	stream := listCacheEntries(streamDir, func(name string) bool {
		_, ok := localCanonicalStem(name)
		return ok
	})
	loader := listCacheEntries(loaderDir, func(name string) bool {
		return strings.HasSuffix(name, ".picklecache")
	})
	total := int64(0)
	for _, entry := range stream {
		total += entry.size
	}
	for _, entry := range loader {
		total += entry.size
	}
	if total <= localRuntimeCacheBudget {
		return
	}
	newestStream := int64(-1)
	for _, entry := range stream {
		if entry.modTime > newestStream {
			newestStream = entry.modTime
		}
	}
	// Oldest first; skip the newest stream entry so the snapshot survives.
	all := append(append([]cacheEntry{}, stream...), loader...)
	sort.Slice(all, func(i, j int) bool { return all[i].modTime < all[j].modTime })
	for _, entry := range all {
		if total <= localRuntimeCacheBudget {
			return
		}
		if entry.modTime == newestStream && strings.HasPrefix(entry.path, streamDir+string(filepath.Separator)) {
			continue
		}
		if err := os.Remove(entry.path); err == nil {
			total -= entry.size
		}
	}
}
