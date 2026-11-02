package mobileagent

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"regexp"
	"sort"
	"strings"
)

// The tools in this file round out the file tools so the Agent can work on
// the ledger directory the way a coding agent works on a repository: find
// files by pattern, search their text, copy and move them (folders too), and
// look at what the draft changes so far, like `git status` and `git diff`.

const (
	defaultGrepResults = 100
	maxGrepResults     = 300
	maxGrepContext     = 5
	maxDiffLines       = 600
)

// globRegexp turns a glob into an anchored regexp over slash-separated
// paths: `*` and `?` stay within one path segment, `**` crosses segments,
// and `{a,b}` is an alternative. A pattern without a slash matches the file
// name in any folder, as in `*.bean`.
func globRegexp(pattern string) (*regexp.Regexp, error) {
	pattern = strings.TrimPrefix(strings.ReplaceAll(strings.TrimSpace(pattern), "\\", "/"), "./")
	if pattern == "" {
		return nil, errors.New("pattern is empty")
	}
	if !strings.Contains(pattern, "/") {
		pattern = "**/" + pattern
	}
	var out strings.Builder
	out.WriteString("^")
	depth := 0
	for i := 0; i < len(pattern); i++ {
		switch c := pattern[i]; c {
		case '*':
			if i+1 < len(pattern) && pattern[i+1] == '*' {
				i++
				if i+1 < len(pattern) && pattern[i+1] == '/' {
					i++
					out.WriteString("(?:.*/)?")
				} else {
					out.WriteString(".*")
				}
			} else {
				out.WriteString("[^/]*")
			}
		case '?':
			out.WriteString("[^/]")
		case '{':
			depth++
			out.WriteString("(?:")
		case '}':
			if depth == 0 {
				out.WriteString(`\}`)
				continue
			}
			depth--
			out.WriteString(")")
		case ',':
			if depth > 0 {
				out.WriteString("|")
			} else {
				out.WriteString(",")
			}
		default:
			out.WriteString(regexp.QuoteMeta(string(c)))
		}
	}
	if depth != 0 {
		return nil, fmt.Errorf("pattern %q has an unclosed {", pattern)
	}
	out.WriteString("$")
	return regexp.Compile(out.String())
}

// walkFiles visits the regular, non-hidden files under start (a file or a
// folder) in path order.
func (s *scratch) walkFiles(start string, visit func(name string, d fs.DirEntry) error) error {
	return fs.WalkDir(s.root.FS(), start, func(name string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if name != "." && strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		return visit(name, d)
	})
}

func (s *scratch) startPath(raw string) (string, error) {
	if strings.TrimSpace(raw) == "" {
		return ".", nil
	}
	return workspacePath(raw)
}

func (s *scratch) grepFiles(raw json.RawMessage) (any, error) {
	var input struct {
		Pattern    string `json:"pattern"`
		Path       string `json:"path"`
		Glob       string `json:"glob"`
		IgnoreCase bool   `json:"ignore_case"`
		Context    int    `json:"context"`
		MaxResults int    `json:"max_results"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	if input.Pattern == "" {
		return nil, errors.New("pattern is empty")
	}
	expression := input.Pattern
	if input.IgnoreCase {
		expression = "(?i)" + expression
	}
	re, err := regexp.Compile(expression)
	if err != nil {
		return nil, fmt.Errorf("pattern is not a valid regular expression (RE2 syntax): %w", err)
	}
	var glob *regexp.Regexp
	if strings.TrimSpace(input.Glob) != "" {
		if glob, err = globRegexp(input.Glob); err != nil {
			return nil, err
		}
	}
	start, err := s.startPath(input.Path)
	if err != nil {
		return nil, err
	}
	limit := input.MaxResults
	if limit <= 0 {
		limit = defaultGrepResults
	}
	limit = min(limit, maxGrepResults)
	context := min(max(input.Context, 0), maxGrepContext)
	var out strings.Builder
	matches, filesMatched, skipped := 0, 0, 0
	truncated := false
	err = s.walkFiles(start, func(name string, d fs.DirEntry) error {
		if glob != nil && !glob.MatchString(name) {
			return nil
		}
		info, err := d.Info()
		if err != nil || info.Size() > maxFileBytes {
			skipped++
			return nil
		}
		data, err := s.root.ReadFile(name)
		if err != nil || isBinary(data) {
			return nil
		}
		lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
		shownUntil := -1
		found := false
		for index, line := range lines {
			if !re.MatchString(line) {
				continue
			}
			if matches >= limit {
				truncated = true
				return fs.SkipAll
			}
			matches++
			found = true
			from := max(index-context, shownUntil+1)
			if context > 0 && shownUntil >= 0 && from > shownUntil+1 {
				out.WriteString("--\n")
			}
			for near := from; near <= min(index+context, len(lines)-1); near++ {
				separator := "-"
				if near == index || (near > index && re.MatchString(lines[near])) {
					separator = ":"
				}
				fmt.Fprintf(&out, "%s%s%d%s%s\n", name, separator, near+1, separator, lines[near])
				shownUntil = near
			}
		}
		if found {
			filesMatched++
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	result := map[string]any{"matches": matches, "files": filesMatched, "content": out.String()}
	if truncated {
		result["truncated"] = fmt.Sprintf("只返回前 %d 处；缩小 path 或 glob，或调大 max_results（最多 %d）", limit, maxGrepResults)
	}
	if skipped > 0 {
		result["skipped"] = fmt.Sprintf("%d 个超过 4 MB 的文件没有搜索", skipped)
	}
	return result, nil
}

func (s *scratch) copyFile(raw json.RawMessage) (any, error) {
	var input struct {
		From      string `json:"from"`
		To        string `json:"to"`
		Overwrite bool   `json:"overwrite"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	from, err := workspacePath(input.From)
	if err != nil {
		return nil, err
	}
	to, err := workspacePath(input.To)
	if err != nil {
		return nil, err
	}
	if from == to {
		return nil, errors.New("from and to are the same file")
	}
	info, err := s.root.Lstat(from)
	if err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%s: %w", from, fs.ErrNotExist)
	}
	if info.Size() > maxAttachmentBytes {
		return nil, fmt.Errorf("%s is over %d MB", from, maxAttachmentBytes>>20)
	}
	if existing, err := s.root.Lstat(to); err == nil {
		if !existing.Mode().IsRegular() {
			return nil, fmt.Errorf("%s exists and is not a file", to)
		}
		if !input.Overwrite {
			return nil, fmt.Errorf("%s already exists; set overwrite to replace it", to)
		}
	}
	data, err := s.root.ReadFile(from)
	if err != nil {
		return nil, err
	}
	if err := s.writeLimited(to, data, maxAttachmentBytes); err != nil {
		return nil, err
	}
	return map[string]any{"from": from, "to": to, "bytes": len(data)}, nil
}

// draftChanges compares the draft with the committed ledger the turn reads.
func (s *scratch) draftChanges(raw json.RawMessage) (any, error) {
	var input struct {
		Path string `json:"path"`
	}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &input); err != nil {
			return nil, err
		}
	}
	if s.committed == "" {
		return nil, errors.New("the committed ledger is not available in this turn")
	}
	committed, err := os.OpenRoot(s.committed)
	if err != nil {
		return nil, err
	}
	defer committed.Close()
	start, err := s.startPath(input.Path)
	if err != nil {
		return nil, err
	}
	collect := func(root *os.Root) (map[string]int64, error) {
		files := map[string]int64{}
		err := fs.WalkDir(root.FS(), ".", func(name string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if name != "." && strings.HasPrefix(d.Name(), ".") {
				if d.IsDir() {
					return fs.SkipDir
				}
				return nil
			}
			if d.Type().IsRegular() && (start == "." || name == start || strings.HasPrefix(name, start+"/")) {
				info, err := d.Info()
				if err != nil {
					return err
				}
				files[name] = info.Size()
			}
			return nil
		})
		return files, err
	}
	before, err := collect(committed)
	if err != nil {
		return nil, err
	}
	after, err := collect(s.root)
	if err != nil {
		return nil, err
	}
	paths := make([]string, 0, len(before)+len(after))
	for name := range before {
		paths = append(paths, name)
	}
	for name := range after {
		if _, ok := before[name]; !ok {
			paths = append(paths, name)
		}
	}
	sort.Strings(paths)
	type change struct {
		Path    string `json:"path"`
		Change  string `json:"change"`
		Binary  bool   `json:"binary,omitempty"`
		Bytes   int64  `json:"bytes,omitempty"`
		Added   int    `json:"added,omitempty"`
		Removed int    `json:"removed,omitempty"`
	}
	changes := []change{}
	var diff strings.Builder
	diffLines := 0
	diffTruncated := false
	for _, name := range paths {
		oldSize, inOld := before[name]
		newSize, inNew := after[name]
		var oldData, newData []byte
		if inOld {
			if oldData, err = committed.ReadFile(name); err != nil {
				return nil, err
			}
		}
		if inNew {
			if newData, err = s.root.ReadFile(name); err != nil {
				return nil, err
			}
		}
		if inOld && inNew && bytes.Equal(oldData, newData) {
			continue
		}
		item := change{Path: name, Change: "modified"}
		switch {
		case !inOld:
			item.Change, item.Bytes = "added", newSize
		case !inNew:
			item.Change, item.Bytes = "deleted", oldSize
		}
		if isBinary(oldData) || isBinary(newData) || max(oldSize, newSize) > maxFileBytes {
			item.Binary = true
			if item.Bytes == 0 {
				item.Bytes = newSize
			}
			changes = append(changes, item)
			continue
		}
		hunks, added, removed := unifiedDiff(textLines(oldData), textLines(newData), 2)
		item.Added, item.Removed = added, removed
		changes = append(changes, item)
		if diffTruncated {
			continue
		}
		header := fmt.Sprintf("--- %s\n+++ %s\n", name, name)
		if !inOld {
			header = fmt.Sprintf("--- /dev/null\n+++ %s\n", name)
		} else if !inNew {
			header = fmt.Sprintf("--- %s\n+++ /dev/null\n", name)
		}
		diff.WriteString(header)
		for _, line := range hunks {
			if diffLines >= maxDiffLines {
				diffTruncated = true
				break
			}
			diff.WriteString(line)
			diff.WriteString("\n")
			diffLines++
		}
	}
	result := map[string]any{"changes": changes, "diff": diff.String()}
	if len(changes) == 0 {
		result["note"] = "草稿和账本一致，没有未写入的改动"
	}
	if diffTruncated {
		result["truncated"] = fmt.Sprintf("差异超过 %d 行，后面的省略了；用 path 只看某个文件或目录", maxDiffLines)
	}
	return result, nil
}

func textLines(data []byte) []string {
	if len(data) == 0 {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
}

// unifiedDiff returns the hunks of a line diff with the given context, and
// the counts of added and removed lines. Common leading and trailing lines
// are trimmed first; a middle too large to align is shown as replaced.
func unifiedDiff(old, new []string, context int) ([]string, int, int) {
	prefix := 0
	for prefix < len(old) && prefix < len(new) && old[prefix] == new[prefix] {
		prefix++
	}
	suffix := 0
	for suffix < len(old)-prefix && suffix < len(new)-prefix && old[len(old)-1-suffix] == new[len(new)-1-suffix] {
		suffix++
	}
	a, b := old[prefix:len(old)-suffix], new[prefix:len(new)-suffix]
	type op struct {
		kind byte // ' ', '-', '+'
		text string
		i, j int // 0-based line numbers in old and new
	}
	var ops []op
	for index := 0; index < prefix; index++ {
		ops = append(ops, op{' ', old[index], index, index})
	}
	if len(a)*len(b) <= 4_000_000 {
		// Longest common subsequence over the changed middle.
		lcs := make([][]int32, len(a)+1)
		for i := range lcs {
			lcs[i] = make([]int32, len(b)+1)
		}
		for i := len(a) - 1; i >= 0; i-- {
			for j := len(b) - 1; j >= 0; j-- {
				if a[i] == b[j] {
					lcs[i][j] = lcs[i+1][j+1] + 1
				} else {
					lcs[i][j] = max(lcs[i+1][j], lcs[i][j+1])
				}
			}
		}
		i, j := 0, 0
		for i < len(a) || j < len(b) {
			switch {
			case i < len(a) && j < len(b) && a[i] == b[j]:
				ops = append(ops, op{' ', a[i], prefix + i, prefix + j})
				i, j = i+1, j+1
			case i < len(a) && (j == len(b) || lcs[i+1][j] >= lcs[i][j+1]):
				// Removals before the insertions that replace them.
				ops = append(ops, op{'-', a[i], prefix + i, prefix + j})
				i++
			default:
				ops = append(ops, op{'+', b[j], prefix + i, prefix + j})
				j++
			}
		}
	} else {
		for i, line := range a {
			ops = append(ops, op{'-', line, prefix + i, prefix})
		}
		for j, line := range b {
			ops = append(ops, op{'+', line, prefix + len(a), prefix + j})
		}
	}
	for index := 0; index < suffix; index++ {
		ops = append(ops, op{' ', old[len(old)-suffix+index], len(old) - suffix + index, len(new) - suffix + index})
	}
	added, removed := 0, 0
	keep := make([]bool, len(ops))
	for index, o := range ops {
		if o.kind == ' ' {
			continue
		}
		if o.kind == '+' {
			added++
		} else {
			removed++
		}
		for near := max(0, index-context); near <= min(len(ops)-1, index+context); near++ {
			keep[near] = true
		}
	}
	var out []string
	for index := 0; index < len(ops); {
		if !keep[index] {
			index++
			continue
		}
		end := index
		for end < len(ops) && keep[end] {
			end++
		}
		oldCount, newCount := 0, 0
		for _, o := range ops[index:end] {
			if o.kind != '+' {
				oldCount++
			}
			if o.kind != '-' {
				newCount++
			}
		}
		out = append(out, fmt.Sprintf("@@ -%d,%d +%d,%d @@", ops[index].i+1, oldCount, ops[index].j+1, newCount))
		for _, o := range ops[index:end] {
			out = append(out, string(o.kind)+o.text)
		}
		index = end
	}
	return out, added, removed
}

// moveDirectory renames a whole folder of the draft.
func (s *scratch) moveDirectory(from, to string) (any, error) {
	if to == from || strings.HasPrefix(to, from+"/") {
		return nil, errors.New("a folder cannot be moved into itself")
	}
	if _, err := s.root.Lstat(to); err == nil {
		return nil, fmt.Errorf("%s already exists", to)
	}
	if strings.HasPrefix(s.entrypoint, from+"/") {
		return nil, errors.New("the folder holds the entrypoint, which cannot move")
	}
	count := 0
	if err := s.walkFiles(from, func(string, fs.DirEntry) error { count++; return nil }); err != nil {
		return nil, err
	}
	if dir := path.Dir(to); dir != "." {
		if err := s.root.MkdirAll(dir, 0o700); err != nil {
			return nil, err
		}
	}
	if err := s.root.Rename(from, to); err != nil {
		return nil, err
	}
	s.markEdited()
	return map[string]any{"from": from, "to": to, "files": count}, nil
}
