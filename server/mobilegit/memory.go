package mobilegit

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"

	"github.com/borui/beancount-ledger-web/server/agentmemory"
)

// memoryBaseName, in the branch's private cache, holds the commit this
// device and the branch last agreed on: the base of the next merge.
const memoryBaseName = "agent-memory-base"

// maxMemorySyncAttempts bounds the retries when another device or the
// automation host pushes between this sync's fetch and push.
const maxMemorySyncAttempts = 3

// syncMemory merges the 账本助手's memory folder (input.Directory) with the
// branch input.Branch of the ledger repository (agentmemory.BranchName),
// which the ledger-automation host reads and writes too. Per file, against
// the commit both last agreed on: one-sided changes win, a change beats a
// deletion, and a file changed on both sides is merged line by line. The
// merge is written to the folder, and pushed when the branch lacks it.
func syncMemory(ctx context.Context, repository *git.Repository, input request) (any, error) {
	directory, err := disjointDirectory(input.Directory, input.StorageRoot)
	if err != nil {
		return nil, err
	}
	folder, err := agentmemory.Open(directory)
	if err != nil {
		return nil, err
	}
	basePath := filepath.Join(input.StorageRoot, memoryBaseName)
	for attempt := 0; attempt < maxMemorySyncAttempts; attempt++ {
		fetched, err := fetch(ctx, repository, input)
		if err != nil {
			return nil, err
		}
		state := fetched.(map[string]any)
		remoteHead, _ := state["remoteHead"].(string)
		remote := agentmemory.Snapshot{}
		if remoteHead != "" {
			if remote, err = readMemorySnapshot(ctx, repository, plumbing.NewHash(remoteHead)); err != nil {
				return nil, err
			}
		}
		base := agentmemory.Snapshot{}
		if raw, err := os.ReadFile(basePath); err == nil {
			if hash, err := parseCommit(strings.TrimSpace(string(raw)), true); err == nil && !hash.IsZero() {
				if snapshot, err := readMemorySnapshot(ctx, repository, hash); err == nil {
					base = snapshot
				}
			}
		}
		local, err := folder.Load()
		if err != nil {
			return nil, err
		}
		merged := agentmemory.Merge(base, local, remote)
		pulled := changedPaths(local, merged)
		if pulled > 0 {
			if _, err := folder.Replace(local, merged); errors.Is(err, agentmemory.ErrChanged) {
				// A turn wrote the folder meanwhile: merge again.
				continue
			} else if err != nil {
				return nil, err
			}
		}
		pushed := 0
		head := remoteHead
		if !merged.Equal(remote) && (remoteHead != "" || len(merged) > 0) {
			commit, err := commitMemorySnapshot(ctx, repository, merged, remoteHead)
			if err != nil {
				return nil, err
			}
			publish := input
			publish.Commit = commit.String()
			publish.ExpectedRemoteHead = &remoteHead
			if _, err := push(ctx, repository, publish); err != nil {
				var bridge *bridgeError
				if errors.As(err, &bridge) && bridge.Code == "git.remote_changed" || isRejectedPush(err) {
					continue
				}
				return nil, err
			}
			head = commit.String()
			pushed = changedPaths(remote, merged)
		}
		if head != "" {
			if err := os.WriteFile(basePath, []byte(head+"\n"), 0o600); err != nil {
				return nil, err
			}
		}
		return map[string]any{"remoteHead": head, "pulled": pulled, "pushed": pushed, "files": len(merged)}, nil
	}
	return nil, fail("remote_changed", "The memory branch kept changing during sync; try again later")
}

func isRejectedPush(err error) bool {
	message := err.Error()
	return strings.Contains(message, "non-fast-forward") || strings.Contains(message, "fetch first") ||
		strings.Contains(message, "reference has changed")
}

// changedPaths counts the files that differ between two snapshots.
func changedPaths(from, to agentmemory.Snapshot) int {
	count := 0
	for path, content := range to {
		if old, ok := from[path]; !ok || old != content {
			count++
		}
	}
	for path := range from {
		if _, ok := to[path]; !ok {
			count++
		}
	}
	return count
}

// readMemorySnapshot reads the memory files of a commit; anything else on
// the branch (a README, files of a newer version) is ignored.
func readMemorySnapshot(ctx context.Context, repository *git.Repository, hash plumbing.Hash) (agentmemory.Snapshot, error) {
	commit, err := repository.CommitObject(hash)
	if err != nil {
		return nil, err
	}
	tree, err := commit.Tree()
	if err != nil {
		return nil, err
	}
	snapshot := agentmemory.Snapshot{}
	walker := object.NewTreeWalker(tree, true, nil)
	defer walker.Close()
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		name, entry, err := walker.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if !entry.Mode.IsFile() || !agentmemory.IsMemoryPath(name) {
			continue
		}
		if len(snapshot) >= agentmemory.MaxFiles {
			return nil, fail("limit_exceeded", "The memory branch has too many files")
		}
		blob, err := repository.BlobObject(entry.Hash)
		if err != nil {
			return nil, err
		}
		if blob.Size > 4*agentmemory.MaxFileBytes {
			continue
		}
		reader, err := blob.Reader()
		if err != nil {
			return nil, err
		}
		data, err := io.ReadAll(io.LimitReader(reader, blob.Size+1))
		_ = reader.Close()
		if err != nil {
			return nil, err
		}
		snapshot[name] = strings.ToValidUTF8(string(data), "")
	}
	return snapshot, nil
}

// commitMemorySnapshot writes the snapshot as a commit on parent (empty for
// the branch's first commit). A README explains the branch to whoever opens
// it on GitHub.
func commitMemorySnapshot(ctx context.Context, repository *git.Repository, snapshot agentmemory.Snapshot, parent string) (plumbing.Hash, error) {
	files := map[string]string{"README.md": memoryBranchReadme}
	for path, content := range snapshot {
		files[path] = content
	}
	tree, err := writeMemoryTree(ctx, repository, files, "")
	if err != nil {
		return plumbing.ZeroHash, err
	}
	signature := object.Signature{Name: "Ledger Mobile", Email: "ledger@localhost", When: time.Now().UTC()}
	commit := &object.Commit{Author: signature, Committer: signature, Message: "Update assistant memory\n", TreeHash: tree}
	if parent != "" {
		commit.ParentHashes = []plumbing.Hash{plumbing.NewHash(parent)}
	}
	encoded := repository.Storer.NewEncodedObject()
	if err := commit.Encode(encoded); err != nil {
		return plumbing.ZeroHash, err
	}
	return repository.Storer.SetEncodedObject(encoded)
}

const memoryBranchReadme = "# 账本助手的记忆\n\n" +
	"这个分支由手机上的账本助手和 ledger-automation 自动同步，内容与助手设置里的「记忆」一致。\n" +
	"MEMORY.md 是入口，每次对话都会带上；其他文件按需读取，开头的 description 说明什么时候该读。\n" +
	"可以在这里直接改，下次同步时会按行合并。\n"

// writeMemoryTree stores files (path → content, relative to prefix) as a
// tree and returns its hash.
func writeMemoryTree(ctx context.Context, repository *git.Repository, files map[string]string, prefix string) (plumbing.Hash, error) {
	if err := ctx.Err(); err != nil {
		return plumbing.ZeroHash, err
	}
	blobs := map[string]string{}
	folders := map[string]map[string]string{}
	for path, content := range files {
		name, rest, nested := strings.Cut(path, "/")
		if nested {
			if folders[name] == nil {
				folders[name] = map[string]string{}
			}
			folders[name][rest] = content
		} else {
			blobs[name] = content
		}
	}
	var entries []object.TreeEntry
	for name, content := range blobs {
		encoded := repository.Storer.NewEncodedObject()
		encoded.SetType(plumbing.BlobObject)
		writer, err := encoded.Writer()
		if err != nil {
			return plumbing.ZeroHash, err
		}
		if _, err := writer.Write([]byte(content)); err != nil {
			return plumbing.ZeroHash, err
		}
		if err := writer.Close(); err != nil {
			return plumbing.ZeroHash, err
		}
		hash, err := repository.Storer.SetEncodedObject(encoded)
		if err != nil {
			return plumbing.ZeroHash, err
		}
		entries = append(entries, object.TreeEntry{Name: name, Mode: filemode.Regular, Hash: hash})
	}
	for name, nested := range folders {
		hash, err := writeMemoryTree(ctx, repository, nested, prefix+name+"/")
		if err != nil {
			return plumbing.ZeroHash, err
		}
		entries = append(entries, object.TreeEntry{Name: name, Mode: filemode.Dir, Hash: hash})
	}
	// Git orders a folder as if its name ended with "/".
	key := func(entry object.TreeEntry) string {
		if entry.Mode == filemode.Dir {
			return entry.Name + "/"
		}
		return entry.Name
	}
	sort.Slice(entries, func(i, j int) bool { return key(entries[i]) < key(entries[j]) })
	tree := &object.Tree{Entries: entries}
	encoded := repository.Storer.NewEncodedObject()
	if err := tree.Encode(encoded); err != nil {
		return plumbing.ZeroHash, err
	}
	return repository.Storer.SetEncodedObject(encoded)
}
