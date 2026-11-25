package automation

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/borui/beancount-ledger-web/server/agentmemory"
)

// Memory modes: whether a run reads the 账本助手's memory, and may change it.
const (
	MemoryWrite = "write"
	MemoryRead  = "read"
	MemoryOff   = "off"
)

// runMemory is the memory folder one run works on: the branch's tree at
// head, copied into dir, and that tree kept as the base of the merge when
// the run changed it.
type runMemory struct {
	dir  string
	head string
	base agentmemory.Snapshot
}

// openMemory fetches the memory branch and copies its files into a folder
// of the run's own. A missing branch is an empty memory. Failing to reach
// the branch never fails the run: it runs without memory.
func (r *Runner) openMemory(ctx context.Context, runID string) (*runMemory, error) {
	if r.cfg.MemoryMode == MemoryOff {
		return nil, nil
	}
	head, err := r.fetchMemory(ctx)
	if err != nil {
		return nil, err
	}
	base := agentmemory.Snapshot{}
	if head != "" {
		if base, err = r.memorySnapshot(ctx, head); err != nil {
			return nil, err
		}
	}
	dir := filepath.Join(r.cfg.Home, "memory", runID)
	_ = os.RemoveAll(dir)
	folder, err := agentmemory.Open(dir)
	if err != nil {
		return nil, err
	}
	if _, err := folder.Replace(agentmemory.Snapshot{}, base); err != nil {
		return nil, err
	}
	return &runMemory{dir: dir, head: head, base: base}, nil
}

func (m *runMemory) close() {
	if m != nil {
		_ = os.RemoveAll(m.dir)
	}
}

// fetchMemory updates refs/heads/<memory branch> in the mirror and returns
// its commit, empty when the branch does not exist yet.
func (r *Runner) fetchMemory(ctx context.Context) (string, error) {
	ref := "refs/heads/" + r.cfg.MemoryBranch
	if _, err := git(ctx, r.mirrorDir(), "fetch", "--quiet", "origin", "+"+ref+":"+ref); err != nil {
		if strings.Contains(err.Error(), "couldn't find remote ref") {
			_, _ = git(ctx, r.mirrorDir(), "update-ref", "-d", ref)
			return "", nil
		}
		return "", err
	}
	sha, err := git(ctx, r.mirrorDir(), "rev-parse", ref)
	return strings.TrimSpace(sha), err
}

// memorySnapshot reads the memory files of a commit in the mirror.
func (r *Runner) memorySnapshot(ctx context.Context, commit string) (agentmemory.Snapshot, error) {
	listing, err := git(ctx, r.mirrorDir(), "ls-tree", "-r", "-z", "--name-only", commit)
	if err != nil {
		return nil, err
	}
	snapshot := agentmemory.Snapshot{}
	for _, path := range strings.Split(listing, "\x00") {
		if path == "" || !agentmemory.IsMemoryPath(path) {
			continue
		}
		if len(snapshot) >= agentmemory.MaxFiles {
			break
		}
		content, err := git(ctx, r.mirrorDir(), "cat-file", "blob", commit+":"+path)
		if err != nil {
			return nil, err
		}
		snapshot[path] = strings.ToValidUTF8(content, "")
	}
	return snapshot, nil
}

// publishMemory pushes what the run changed in its memory folder, merged
// with whatever reached the branch meanwhile, the same way the phone does.
// It reports how many files changed.
func (r *Runner) publishMemory(ctx context.Context, memory *runMemory) (int, error) {
	if memory == nil || r.cfg.MemoryMode != MemoryWrite {
		return 0, nil
	}
	after, err := agentmemory.LoadDir(memory.dir)
	if err != nil {
		return 0, err
	}
	if after.Equal(memory.base) {
		return 0, nil
	}
	head, remote := memory.head, memory.base
	for attempt := 0; attempt < 4; attempt++ {
		merged := agentmemory.Merge(memory.base, after, remote)
		if merged.Equal(remote) {
			return 0, nil
		}
		commit, err := r.commitMemory(ctx, merged, head)
		if err != nil {
			return 0, err
		}
		if _, err = git(ctx, r.mirrorDir(), "push", "--quiet", "origin", commit+":refs/heads/"+r.cfg.MemoryBranch); err == nil {
			_, _ = git(ctx, r.mirrorDir(), "update-ref", "refs/heads/"+r.cfg.MemoryBranch, commit)
			return changedFiles(remote, merged), nil
		}
		r.cfg.Logger.Warn("push memory", "attempt", attempt+1, "err", err)
		// Someone else pushed: merge with what is there now.
		if head, err = r.fetchMemory(ctx); err != nil {
			return 0, err
		}
		remote = agentmemory.Snapshot{}
		if head != "" {
			if remote, err = r.memorySnapshot(ctx, head); err != nil {
				return 0, err
			}
		}
	}
	return 0, errors.New("the memory branch kept changing")
}

func changedFiles(from, to agentmemory.Snapshot) int {
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

// commitMemory writes the snapshot, with the branch's README, as a commit on
// parent through a private index, never touching a worktree.
func (r *Runner) commitMemory(ctx context.Context, snapshot agentmemory.Snapshot, parent string) (string, error) {
	mirror := r.mirrorDir()
	index, err := os.CreateTemp(r.cfg.Home, ".memory-index-*")
	if err != nil {
		return "", err
	}
	indexPath := index.Name()
	_ = index.Close()
	_ = os.Remove(indexPath)
	defer os.Remove(indexPath)
	files := map[string]string{"README.md": memoryReadme}
	for path, content := range snapshot {
		files[path] = content
	}
	paths := make([]string, 0, len(files))
	for path := range files {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	for _, path := range paths {
		blob, err := gitInput(ctx, mirror, nil, files[path], "hash-object", "-w", "--stdin")
		if err != nil {
			return "", err
		}
		if _, err := gitInput(ctx, mirror, []string{"GIT_INDEX_FILE=" + indexPath}, "",
			"update-index", "--add", "--cacheinfo", "100644,"+strings.TrimSpace(blob)+","+path); err != nil {
			return "", err
		}
	}
	tree, err := gitInput(ctx, mirror, []string{"GIT_INDEX_FILE=" + indexPath}, "", "write-tree")
	if err != nil {
		return "", err
	}
	args := []string{"-c", "user.name=" + r.cfg.CommitName, "-c", "user.email=" + r.cfg.CommitEmail,
		"commit-tree", strings.TrimSpace(tree), "-m", "Update assistant memory from an automation run"}
	if parent != "" {
		args = append(args, "-p", parent)
	}
	commit, err := gitInput(ctx, mirror, nil, "", args...)
	return strings.TrimSpace(commit), err
}

// gitInput runs git with extra environment and standard input.
func gitInput(ctx context.Context, dir string, env []string, input string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, "git", args...)
	command.Dir = dir
	command.Env = append(append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "LC_ALL=C"), env...)
	command.Stdin = strings.NewReader(input)
	output, err := command.Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return "", fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(exit.Stderr)))
		}
		return "", err
	}
	return string(output), nil
}

// memoryReadme matches the one the phone writes (mobilegit).
const memoryReadme = "# 账本助手的记忆\n\n" +
	"这个分支由手机上的账本助手和 ledger-automation 自动同步，内容与助手设置里的「记忆」一致。\n" +
	"MEMORY.md 是入口，每次对话都会带上；其他文件按需读取，开头的 description 说明什么时候该读。\n" +
	"可以在这里直接改，下次同步时会按行合并。\n"
