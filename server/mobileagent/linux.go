package mobileagent

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// LinuxRunner runs a shell command in the App's built-in Linux (an Alpine
// userland on an in-process AArch64 interpreter). The shell implements it;
// a build without the engine never installs one, and then the bash tool is
// not offered at all.
//
// Run takes a linuxRunRequest as JSON and answers a linuxRunResult as JSON.
// It blocks until the command ends, times out, or is cancelled. Cancel stops
// the run with that id; it may be called from another goroutine while Run is
// still blocked.
type LinuxRunner interface {
	Run(requestJSON string) string
	Cancel(id string)
}

var (
	linuxMu     sync.Mutex
	linuxRunner LinuxRunner
	linuxRunSeq atomic.Int64
)

// SetLinuxRunner installs the runner behind the bash tool. nil removes it.
func SetLinuxRunner(r LinuxRunner) {
	linuxMu.Lock()
	linuxRunner = r
	linuxMu.Unlock()
}

func currentLinuxRunner() LinuxRunner {
	linuxMu.Lock()
	defer linuxMu.Unlock()
	return linuxRunner
}

type linuxRunRequest struct {
	ID string `json:"id"`
	// Workspace is the host directory mounted at /workspace in the guest.
	Workspace      string `json:"workspace"`
	Command        string `json:"command"`
	TimeoutSeconds int    `json:"timeoutSeconds"`
	// MaxOutputBytes bounds what the runner keeps; it keeps the start and
	// the end and drops the middle.
	MaxOutputBytes int `json:"maxOutputBytes"`
}

type linuxRunResult struct {
	ExitCode int    `json:"exitCode"`
	Output   string `json:"output"`
	// OutputBytes is how much the command printed, kept or not.
	OutputBytes int64  `json:"outputBytes"`
	Truncated   bool   `json:"truncated"`
	TimedOut    bool   `json:"timedOut"`
	Cancelled   bool   `json:"cancelled"`
	Error       string `json:"error,omitempty"`
}

const (
	defaultBashTimeout = 120
	maxBashTimeout     = 600
	maxBashOutput      = 30_000
	maxBashCommand     = 16_000
)

const bashToolDescription = "在 App 内置的 Linux（Alpine 3.22，aarch64）里用 /bin/sh 运行一条命令，返回退出码和合并后的输出（stdout 和 stderr）。" +
	"当前目录是 /workspace，也就是本对话的草稿账本：在这里改的文件和用 edit_file 改的一样，会出现在变更卡里，所以只改你打算改的账本文件，临时文件和画的图放到 /tmp。" +
	"可以用 apk add 装软件（需要联网，例如 apk add python3 py3-pandas py3-matplotlib bash jq），装过的会保留。" +
	"这是在手机上解释执行的 Linux，比电脑慢 10 到 30 倍：先用 BQL 和账本工具能做的就不要用它；需要计算、批量处理文本或转换文件格式时再用。" +
	"命令默认 120 秒超时，最多 600 秒；输出太长会截掉中间部分。看不到 /workspace 以外的手机文件。"

// LinuxToolPrompt is appended to the system prompt when bash is offered.
const linuxToolPrompt = "\n\n## 内置 Linux\n" +
	"你有 bash 工具：一台在手机里运行的 Alpine Linux，/workspace 就是草稿账本。BQL、搜索和文件工具能完成的事不要用它；" +
	"需要 python 计算、批量改写文本、解析 CSV/Excel、或者 BQL 表达不了的统计时再用。第一次用 python 前先 `apk add python3`（需要的话再加 py3-pandas 等）。" +
	"用它改了账本文件后，和其他改动一样要 bean_check。\n"

func (s *scratch) bashTool(runner LinuxRunner) fileTool {
	return fileTool{name: "bash", title: "运行命令",
		description: bashToolDescription,
		parameters: objectParameters(map[string]any{
			"command":         map[string]any{"type": "string", "description": "要运行的 shell 命令，可以是多行脚本"},
			"timeout_seconds": map[string]any{"type": "integer", "description": "超时秒数，默认 120，最多 600"},
		}, "command"),
		runContext: func(ctx context.Context, raw json.RawMessage) (any, error) { return s.bash(ctx, runner, raw) },
	}
}

func (s *scratch) bash(ctx context.Context, runner LinuxRunner, raw json.RawMessage) (any, error) {
	var input struct {
		Command        string `json:"command"`
		TimeoutSeconds int    `json:"timeout_seconds"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	command := strings.TrimSpace(input.Command)
	if command == "" {
		return nil, errors.New("command is required")
	}
	if len(command) > maxBashCommand {
		return nil, fmt.Errorf("command must be at most %d bytes; put a long script in a file under /tmp first", maxBashCommand)
	}
	timeout := input.TimeoutSeconds
	if timeout <= 0 {
		timeout = defaultBashTimeout
	}
	if timeout > maxBashTimeout {
		timeout = maxBashTimeout
	}
	before, err := treeFingerprint(s.dir)
	if err != nil {
		return nil, err
	}
	request := linuxRunRequest{
		ID:             fmt.Sprintf("bash-%d", linuxRunSeq.Add(1)),
		Workspace:      s.dir,
		Command:        command,
		TimeoutSeconds: timeout,
		MaxOutputBytes: maxBashOutput,
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	// The runner enforces the timeout itself; this one is a backstop for a
	// runner that does not come back, with room for the install and boot the
	// first call pays for.
	done := make(chan string, 1)
	go func() { done <- runner.Run(string(encoded)) }()
	backstop := time.NewTimer(time.Duration(timeout)*time.Second + 2*time.Minute)
	defer backstop.Stop()
	var answer string
	select {
	case answer = <-done:
	case <-ctx.Done():
		runner.Cancel(request.ID)
		// The guest may still be writing into the draft; wait briefly so the
		// draft is not changed after the turn has moved on.
		select {
		case <-done:
		case <-time.After(5 * time.Second):
		}
		s.afterBash(before)
		return nil, ctx.Err()
	case <-backstop.C:
		runner.Cancel(request.ID)
		s.afterBash(before)
		return nil, errors.New("内置 Linux 没有响应")
	}
	var result linuxRunResult
	if err := json.Unmarshal([]byte(answer), &result); err != nil {
		return nil, fmt.Errorf("内置 Linux 的回复无法解析: %w", err)
	}
	changed, removed := s.afterBash(before)
	if result.Error != "" {
		return nil, errors.New(result.Error)
	}
	out := map[string]any{"exit_code": result.ExitCode, "output": result.Output}
	if result.Truncated {
		out["note"] = fmt.Sprintf("输出共 %d 字节，只保留了开头和结尾", result.OutputBytes)
	}
	if result.TimedOut {
		out["timed_out"] = true
		out["note"] = fmt.Sprintf("超过 %d 秒，命令已被终止", timeout)
	}
	if result.Cancelled {
		out["cancelled"] = true
	}
	if len(changed) > 0 {
		out["changed_files"] = changed
	}
	if len(removed) > 0 {
		out["removed_links"] = removed
	}
	return out, nil
}

// afterBash removes what the guest may have left in the draft that the host
// must never follow, and marks the draft edited when its files changed.
func (s *scratch) afterBash(before map[string]fileStamp) (changed, removed []string) {
	removed = removeUnsafeEntries(s.dir)
	after, err := treeFingerprint(s.dir)
	if err != nil {
		s.markEdited()
		return nil, removed
	}
	changed = diffFingerprints(before, after)
	if len(changed) > 0 || len(removed) > 0 {
		s.markEdited()
	}
	return changed, removed
}

type fileStamp struct {
	size    int64
	modTime int64
	mode    fs.FileMode
}

// treeFingerprint lists the workspace's regular files with size and
// modification time; that is enough to tell which files a command touched.
func treeFingerprint(root string) (map[string]fileStamp, error) {
	stamps := map[string]fileStamp{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if p == root {
				return err
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return nil
		}
		stamps[filepath.ToSlash(rel)] = fileStamp{size: info.Size(), modTime: info.ModTime().UnixNano(), mode: info.Mode()}
		return nil
	})
	return stamps, err
}

func diffFingerprints(before, after map[string]fileStamp) []string {
	changed := []string{}
	for p, stamp := range after {
		if old, ok := before[p]; !ok || old != stamp {
			changed = append(changed, p)
		}
	}
	for p := range before {
		if _, ok := after[p]; !ok {
			changed = append(changed, p)
		}
	}
	sort.Strings(changed)
	if len(changed) > 100 {
		changed = append(changed[:100], fmt.Sprintf("……共 %d 个", len(changed)))
	}
	return changed
}

// removeUnsafeEntries deletes symbolic links, sockets, pipes and device
// files under root. A link the guest made means one thing inside the guest
// and another on the host — `/etc/passwd` in the guest is a different file
// from the host's — and the App's own reads and its commit of the draft must
// never be pointed outside the draft by one.
func removeUnsafeEntries(root string) []string {
	removed := []string{}
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == root {
			return nil
		}
		if d.Type()&(fs.ModeSymlink|fs.ModeNamedPipe|fs.ModeSocket|fs.ModeDevice|fs.ModeCharDevice|fs.ModeIrregular) == 0 {
			return nil
		}
		if os.Remove(p) == nil {
			if rel, err := filepath.Rel(root, p); err == nil {
				removed = append(removed, filepath.ToSlash(rel))
			}
		}
		return nil
	})
	sort.Strings(removed)
	return removed
}

// ExtractRootfsJSON unpacks a .tar.gz root filesystem for the built-in Linux.
// The request is {"archive": path, "destination": path}; the answer is "" on
// success and otherwise the error. The destination must not exist yet: the
// shell unpacks into a fresh directory and renames it into place.
func ExtractRootfsJSON(requestJSON string) string {
	var request struct {
		Archive     string `json:"archive"`
		Destination string `json:"destination"`
	}
	if err := json.Unmarshal([]byte(requestJSON), &request); err != nil {
		return err.Error()
	}
	if err := extractRootfs(request.Archive, request.Destination); err != nil {
		return err.Error()
	}
	return ""
}

// Limits a damaged or hostile archive cannot get past.
const (
	maxRootfsEntries = 200_000
	maxRootfsBytes   = 2 << 30
)

func extractRootfs(archive, destination string) error {
	if archive == "" || destination == "" {
		return errors.New("archive and destination are required")
	}
	if _, err := os.Lstat(destination); err == nil {
		return fmt.Errorf("%s already exists", destination)
	}
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer gz.Close()
	if err := os.MkdirAll(destination, 0o755); err != nil {
		return err
	}
	root, err := os.OpenRoot(destination)
	if err != nil {
		return err
	}
	defer root.Close()
	reader := tar.NewReader(gz)
	var entries int
	var total int64
	type dirMode struct {
		name string
		mode fs.FileMode
	}
	var dirs []dirMode
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		entries++
		if entries > maxRootfsEntries {
			return errors.New("archive has too many entries")
		}
		name, ok := rootfsEntryName(header.Name)
		if !ok {
			return fmt.Errorf("unsafe path in archive: %q", header.Name)
		}
		if name == "" {
			continue
		}
		if dir := path.Dir(name); dir != "." {
			if err := root.MkdirAll(dir, 0o755); err != nil {
				return err
			}
		}
		// Permission bits only: no setuid, setgid or sticky bit leaves the
		// archive, and the owner can always read and write what it unpacked.
		mode := fs.FileMode(header.Mode).Perm() | 0o600
		switch header.Typeflag {
		case tar.TypeDir:
			if err := root.MkdirAll(name, 0o755); err != nil {
				return err
			}
			dirs = append(dirs, dirMode{name, mode | 0o700})
		case tar.TypeReg:
			total += header.Size
			if total > maxRootfsBytes {
				return errors.New("archive is too large")
			}
			out, err := root.OpenFile(name, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
			if err != nil {
				return err
			}
			_, copyErr := io.Copy(out, io.LimitReader(reader, header.Size))
			closeErr := out.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
			if err := root.Chmod(name, mode); err != nil {
				return err
			}
		case tar.TypeSymlink:
			// The target is the guest's, resolved inside the guest's root;
			// it is stored as it is and never followed here.
			_ = root.Remove(name)
			if err := root.Symlink(header.Linkname, name); err != nil {
				return err
			}
		case tar.TypeLink:
			target, ok := rootfsEntryName(header.Linkname)
			if !ok || target == "" {
				return fmt.Errorf("unsafe hard link in archive: %q", header.Linkname)
			}
			_ = root.Remove(name)
			if err := root.Link(target, name); err != nil {
				return err
			}
		default:
			// Device nodes, fifos and the like: the guest's /dev is its own.
		}
	}
	// Directory modes last, so a read-only directory did not stop its own
	// contents from being written.
	for i := len(dirs) - 1; i >= 0; i-- {
		if err := root.Chmod(dirs[i].name, dirs[i].mode); err != nil {
			return err
		}
	}
	return nil
}

// rootfsEntryName cleans an archive path to one relative to the root.
// It answers false for a path that climbs out of it.
func rootfsEntryName(raw string) (string, bool) {
	name := strings.TrimPrefix(raw, "./")
	name = strings.TrimLeft(name, "/")
	if name == "" || name == "." {
		return "", true
	}
	clean := path.Clean(name)
	if clean == ".." || strings.HasPrefix(clean, "../") {
		return "", false
	}
	return clean, true
}
