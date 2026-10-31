package mobileagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"strings"
	"sync"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// Checker runs the app's own Beancount validation over a workspace. The
// shell implements it, so bean_check applies exactly the rules a commit is
// validated with. Check returns an empty string when the ledger is valid,
// and otherwise the diagnostics.
type Checker interface {
	Check(workspaceRoot, entrypoint string) string
}

var (
	checkerMu sync.Mutex
	checker   Checker
)

// SetChecker installs the validator bean_check calls. The shell sets it
// before the first turn that may edit.
func SetChecker(c Checker) {
	checkerMu.Lock()
	checker = c
	checkerMu.Unlock()
}

func currentChecker() Checker {
	checkerMu.Lock()
	defer checkerMu.Unlock()
	return checker
}

const (
	maxFileBytes    = 4 << 20
	maxReadLines    = 2000
	defaultReadSpan = 400
)

// scratch is the ledger copy one turn may edit. It is opened as an os.Root,
// so no path, symlink included, resolves outside it.
type scratch struct {
	root       *os.Root
	dir        string
	entrypoint string
	mu         sync.Mutex
	edited     bool
}

func openScratch(dir, entrypoint string) (*scratch, error) {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, fmt.Errorf("scratch workspace: %w", err)
	}
	return &scratch{root: root, dir: dir, entrypoint: entrypoint}, nil
}

func (s *scratch) close() { _ = s.root.Close() }

// beanPath accepts a workspace-relative path to a .bean file.
func beanPath(name string) (string, error) {
	name = strings.TrimSpace(name)
	clean := path.Clean(strings.ReplaceAll(name, "\\", "/"))
	if name == "" || path.IsAbs(clean) || clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("path %q must be relative to the ledger root", name)
	}
	if path.Ext(clean) != ".bean" {
		return "", fmt.Errorf("path %q: only .bean files can be read or written", name)
	}
	for _, part := range strings.Split(clean, "/") {
		if strings.HasPrefix(part, ".") {
			return "", fmt.Errorf("path %q: hidden files are not part of the ledger", name)
		}
	}
	return clean, nil
}

func (s *scratch) read(name string) (string, []byte, error) {
	clean, err := beanPath(name)
	if err != nil {
		return "", nil, err
	}
	info, err := s.root.Stat(clean)
	if err != nil {
		return "", nil, fmt.Errorf("%s: %w", clean, fs.ErrNotExist)
	}
	if !info.Mode().IsRegular() || info.Size() > maxFileBytes {
		return "", nil, fmt.Errorf("%s is not a regular file under 4 MB", clean)
	}
	data, err := s.root.ReadFile(clean)
	return clean, data, err
}

func (s *scratch) write(clean string, data []byte) error {
	if len(data) > maxFileBytes {
		return errors.New("files are limited to 4 MB")
	}
	if dir := path.Dir(clean); dir != "." {
		if err := s.root.MkdirAll(dir, 0o700); err != nil {
			return err
		}
	}
	if err := s.root.WriteFile(clean, data, 0o600); err != nil {
		return err
	}
	s.mu.Lock()
	s.edited = true
	s.mu.Unlock()
	return nil
}

func (s *scratch) wasEdited() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.edited
}

// fileTools are the coding-agent style tools over the scratch copy.
func (s *scratch) tools() []agent.AgentTool {
	str := func(description string) map[string]any {
		return map[string]any{"type": "string", "description": description}
	}
	num := func(description string) map[string]any {
		return map[string]any{"type": "integer", "description": description}
	}
	object := func(properties map[string]any, required ...string) map[string]any {
		if required == nil {
			required = []string{}
		}
		return map[string]any{"type": "object", "properties": properties, "required": required, "additionalProperties": false}
	}
	return []agent.AgentTool{
		fileTool{name: "list_files", title: "列出账本文件",
			description: "列出账本里所有 .bean 文件和大小。入口文件是 " + s.entrypoint + "。",
			parameters:  object(map[string]any{}), run: s.listFiles},
		fileTool{name: "read_file", title: "读取文件",
			description: "读取一个 .bean 文件，每行带行号（行号后是一个制表符，之后才是原文）。大文件用 offset 和 limit 分段读。",
			parameters: object(map[string]any{"path": str("相对账本根目录的路径"), "offset": num("从第几行开始，1 起，默认 1"),
				"limit": num("最多读几行，默认 400，最大 2000")}, "path"), run: s.readFile},
		fileTool{name: "edit_file", title: "修改文件",
			description: "在一个 .bean 文件里把 old_string 精确替换为 new_string。old_string 必须和文件原文逐字一致（不含行号），且只出现一次；要替换全部出现处时设 replace_all。先 read_file 再改。",
			parameters: object(map[string]any{"path": str("相对账本根目录的路径"), "old_string": str("要替换的原文"),
				"new_string": str("替换后的文本"), "replace_all": map[string]any{"type": "boolean", "description": "替换全部出现处"}},
				"path", "old_string", "new_string"), run: s.editFile},
		fileTool{name: "write_file", title: "写入文件",
			description: "新建一个 .bean 文件，或用 content 整份覆盖已有文件。改已有文件的局部时用 edit_file。新文件需要被入口文件 include 才会生效。",
			parameters:  object(map[string]any{"path": str("相对账本根目录的路径"), "content": str("完整的文件内容")}, "path", "content"),
			run:         s.writeFile},
		fileTool{name: "bean_check", title: "校验账本",
			description: "用 App 内置的 Beancount 校验整份草稿账本，返回错误及所在文件和行号。改完后必须调用，直到通过。",
			parameters:  object(map[string]any{}), run: s.beanCheck},
	}
}

func (s *scratch) listFiles(json.RawMessage) (any, error) {
	type entry struct {
		Path  string `json:"path"`
		Bytes int64  `json:"bytes"`
	}
	files := []entry{}
	err := fs.WalkDir(s.root.FS(), ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if name != "." && strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.Type().IsRegular() && path.Ext(name) == ".bean" {
			info, err := d.Info()
			if err != nil {
				return err
			}
			files = append(files, entry{Path: name, Bytes: info.Size()})
		}
		return nil
	})
	return map[string]any{"entrypoint": s.entrypoint, "files": files}, err
}

func (s *scratch) readFile(raw json.RawMessage) (any, error) {
	var input struct {
		Path   string `json:"path"`
		Offset int    `json:"offset"`
		Limit  int    `json:"limit"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	clean, data, err := s.read(input.Path)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	if len(data) == 0 {
		lines = nil
	}
	start := max(input.Offset, 1)
	limit := input.Limit
	if limit <= 0 {
		limit = defaultReadSpan
	}
	limit = min(limit, maxReadLines)
	var out strings.Builder
	end := min(start-1+limit, len(lines))
	for index := start - 1; index < end; index++ {
		fmt.Fprintf(&out, "%6d\t%s\n", index+1, lines[index])
	}
	result := map[string]any{"path": clean, "totalLines": len(lines), "content": out.String()}
	if end < len(lines) {
		result["next"] = fmt.Sprintf("还有 %d 行，用 offset=%d 继续读", len(lines)-end, end+1)
	}
	return result, nil
}

func (s *scratch) editFile(raw json.RawMessage) (any, error) {
	var input struct {
		Path       string `json:"path"`
		OldString  string `json:"old_string"`
		NewString  string `json:"new_string"`
		ReplaceAll bool   `json:"replace_all"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	if input.OldString == "" {
		return nil, errors.New("old_string is empty; use write_file to create a file")
	}
	if input.OldString == input.NewString {
		return nil, errors.New("old_string and new_string are the same")
	}
	clean, data, err := s.read(input.Path)
	if err != nil {
		return nil, err
	}
	text := string(data)
	count := strings.Count(text, input.OldString)
	switch {
	case count == 0:
		return nil, fmt.Errorf("old_string was not found in %s; read_file again and copy the text exactly, without line numbers", clean)
	case count > 1 && !input.ReplaceAll:
		return nil, fmt.Errorf("old_string appears %d times in %s; include more surrounding lines to make it unique, or set replace_all", count, clean)
	}
	replaced := 1
	if input.ReplaceAll {
		text, replaced = strings.ReplaceAll(text, input.OldString, input.NewString), count
	} else {
		text = strings.Replace(text, input.OldString, input.NewString, 1)
	}
	if err := s.write(clean, []byte(text)); err != nil {
		return nil, err
	}
	return map[string]any{"path": clean, "replacements": replaced}, nil
}

func (s *scratch) writeFile(raw json.RawMessage) (any, error) {
	var input struct {
		Path    string `json:"path"`
		Content string `json:"content"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	clean, err := beanPath(input.Path)
	if err != nil {
		return nil, err
	}
	created := true
	if info, err := s.root.Stat(clean); err == nil {
		if !info.Mode().IsRegular() {
			return nil, fmt.Errorf("%s is not a regular file", clean)
		}
		created = false
	}
	content := input.Content
	if content != "" && !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	if err := s.write(clean, []byte(content)); err != nil {
		return nil, err
	}
	return map[string]any{"path": clean, "created": created, "bytes": len(content)}, nil
}

func (s *scratch) beanCheck(json.RawMessage) (any, error) {
	c := currentChecker()
	if c == nil {
		return nil, errors.New("bean_check is not available in this build")
	}
	if problems := strings.TrimSpace(c.Check(s.dir, s.entrypoint)); problems != "" {
		return map[string]any{"ok": false, "errors": problems}, nil
	}
	return map[string]any{"ok": true}, nil
}

type fileTool struct {
	name, title, description string
	parameters               map[string]any
	run                      func(json.RawMessage) (any, error)
}

func (t fileTool) Name() string  { return t.name }
func (t fileTool) Label() string { return t.title }
func (t fileTool) Schema() ai.ToolSchema {
	return ai.ToolSchema{Name: t.name, Description: t.description, Parameters: t.parameters}
}
func (fileTool) ExecutionMode() agent.ToolExecutionMode { return agent.ToolModeSequential }

func (t fileTool) Execute(ctx context.Context, _ string, params json.RawMessage, _ agent.ToolUpdateCallback) (agent.AgentToolResult, error) {
	if err := ctx.Err(); err != nil {
		return agent.AgentToolResult{}, err
	}
	if len(strings.TrimSpace(string(params))) == 0 {
		params = json.RawMessage(`{}`)
	}
	output, err := t.run(params)
	if err != nil {
		return agent.AgentToolResult{}, err
	}
	raw, err := json.Marshal(output)
	if err != nil {
		return agent.AgentToolResult{}, err
	}
	return agent.AgentToolResult{Content: []ai.ToolResultMessageContent{ai.TextContent{Text: string(raw)}}, Details: map[string]any{}}, nil
}
