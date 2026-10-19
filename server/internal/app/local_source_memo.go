package app

import (
	"os"
	"sync"
)

// Every native request recomputes the source version, and LedgerCache
// rechecks it, by hashing each included file. Committed generations never
// change, so remember each file's hash and include directives under its full
// stat identity. Any write changes the file's ctime and misses the memo.
type localSourceFacts struct {
	size        int
	contentHash [32]byte
	includes    []string
}

type localSourceMemoKey struct {
	path         string
	device       uint64
	inode        uint64
	size         int64
	modifiedNsec int64
	changedNsec  int64
}

const localSourceMemoLimit = 8192

var localSourceMemo struct {
	sync.Mutex
	entries map[localSourceMemoKey]localSourceFacts
}

func localSourceMemoKeyFor(path string, info os.FileInfo) (localSourceMemoKey, bool) {
	device, inode, changed, ok := localSourceStatIdentity(info)
	if !ok {
		return localSourceMemoKey{}, false
	}
	return localSourceMemoKey{path: path, device: device, inode: inode, size: info.Size(),
		modifiedNsec: info.ModTime().UnixNano(), changedNsec: changed}, true
}

func localSourceMemoLookup(key localSourceMemoKey) (localSourceFacts, bool) {
	localSourceMemo.Lock()
	defer localSourceMemo.Unlock()
	facts, ok := localSourceMemo.entries[key]
	return facts, ok
}

func localSourceMemoStore(key localSourceMemoKey, facts localSourceFacts) {
	localSourceMemo.Lock()
	defer localSourceMemo.Unlock()
	if localSourceMemo.entries == nil || len(localSourceMemo.entries) >= localSourceMemoLimit {
		localSourceMemo.entries = map[localSourceMemoKey]localSourceFacts{}
	}
	facts.includes = append([]string(nil), facts.includes...)
	localSourceMemo.entries[key] = facts
}

// localSourceStamps is the set of stat identities that produced one verified
// source version. If every file still has its recorded identity (path, device,
// inode, size, mtime, ctime) no content changed and no include was added, so
// the recorded version is still exact. Glob includes make this unprovable.
type localSourceStamps struct {
	keys     []localSourceMemoKey
	unusable bool
}

func (s *localSourceStamps) matches() bool {
	if s == nil || s.unusable || len(s.keys) == 0 {
		return false
	}
	for _, want := range s.keys {
		info, err := os.Lstat(want.path)
		if err != nil || !info.Mode().IsRegular() {
			return false
		}
		if got, ok := localSourceMemoKeyFor(want.path, info); !ok || got != want {
			return false
		}
	}
	return true
}
