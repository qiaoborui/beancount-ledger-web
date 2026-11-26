// Package agentmemory is the 账本助手's long-term memory: a folder of small
// Markdown files with MEMORY.md as its entry, shared by the phone's Agent,
// the ledger-automation host and any later cloud Agent.
//
// Layout (one folder per ledger):
//
//	MEMORY.md                 always in the system prompt: the short rules
//	                          that hold for every conversation
//	<topic>.md                read on demand, e.g. merchants.md
//	<group>/<topic>.md        one level of folders, e.g. accounts/credit-cards.md
//
// A topic file starts with a front matter whose description says when it is
// worth reading; the prompt lists every topic file with that line, so the
// index is generated and never goes stale:
//
//	---
//	description: 信用卡账单日、还款日和还款账户
//	---
//
// The package is dependency-free so the gomobile packages can import it.
package agentmemory

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"unicode/utf8"
)

const (
	// IndexName is the entry file, always loaded.
	IndexName = "MEMORY.md"
	// BranchName is the branch of the ledger repository the memory folder
	// is shared through.
	BranchName = "agent-memory"
	// MaxIndexBytes bounds MEMORY.md, which every prompt carries.
	MaxIndexBytes = 8000
	// IndexSoftBytes is where the model is asked to move sections out of
	// MEMORY.md into topic files.
	IndexSoftBytes = 3000
	// MaxFileBytes bounds one topic file.
	MaxFileBytes = 16000
	// MaxFiles bounds the folder.
	MaxFiles = 200
	// maxSegments is a topic file under at most two folders.
	maxSegments  = 3
	maxPathBytes = 120
	// LegacyName is the single memory.md of earlier versions, next to the
	// folder; Open moves it into MEMORY.md.
	legacySuffix = ".md"
)

// Snapshot is a memory folder as path → content.
type Snapshot map[string]string

// Equal reports whether two snapshots hold the same files.
func (s Snapshot) Equal(other Snapshot) bool {
	if len(s) != len(other) {
		return false
	}
	for path, content := range s {
		if theirs, ok := other[path]; !ok || theirs != content {
			return false
		}
	}
	return true
}

// Clone copies the snapshot.
func (s Snapshot) Clone() Snapshot {
	out := make(Snapshot, len(s))
	for path, content := range s {
		out[path] = content
	}
	return out
}

// CleanPath turns what a model or a user typed into a folder path, or says
// why it cannot be one. Paths are lower-case ASCII segments, so they survive
// Git, iCloud and case-insensitive file systems unchanged; ".md" is added
// when it is missing. MEMORY.md is the one upper-case name.
func CleanPath(raw string) (string, error) {
	path := strings.TrimSpace(strings.ReplaceAll(raw, "\\", "/"))
	path = strings.TrimPrefix(path, "./")
	path = strings.TrimLeft(path, "/")
	if path == "" || strings.EqualFold(path, IndexName) || strings.EqualFold(path, "MEMORY") {
		return IndexName, nil
	}
	if !strings.HasSuffix(path, ".md") {
		path += ".md"
	}
	if len(path) > maxPathBytes {
		return "", fmt.Errorf("记忆文件路径太长：%s", raw)
	}
	segments := strings.Split(path, "/")
	if len(segments) > maxSegments {
		return "", fmt.Errorf("记忆最多两层文件夹：%s", raw)
	}
	for index, segment := range segments {
		name := segment
		if index == len(segments)-1 {
			name = strings.TrimSuffix(segment, ".md")
		}
		if !validSegment(name) {
			return "", fmt.Errorf("记忆文件路径只能用小写字母、数字和 - _，每段以字母或数字开头：%s", raw)
		}
	}
	if strings.EqualFold(segments[len(segments)-1], IndexName) {
		return "", fmt.Errorf("MEMORY.md 只能在记忆根目录：%s", raw)
	}
	return path, nil
}

func validSegment(name string) bool {
	if name == "" || len(name) > 48 {
		return false
	}
	for index, char := range name {
		switch {
		case char >= 'a' && char <= 'z', char >= '0' && char <= '9':
		case (char == '-' || char == '_') && index > 0:
		default:
			return false
		}
	}
	return true
}

// IsMemoryPath reports whether path is a valid file of the folder, as
// written (already clean).
func IsMemoryPath(path string) bool {
	clean, err := CleanPath(path)
	return err == nil && clean == path
}

// Validate checks one file against the folder's limits.
func Validate(path, content string) error {
	if !utf8.ValidString(content) {
		return errors.New("记忆必须是 UTF-8 文本")
	}
	limit := MaxFileBytes
	if path == IndexName {
		limit = MaxIndexBytes
	}
	if len(content) > limit {
		return fmt.Errorf("%s 最多 %d 字节，现在是 %d 字节；把一部分挪到别的记忆文件，或合并、删掉过时的条目", path, limit, len(content))
	}
	return nil
}

// Normalize trims a file the way it is saved: no surrounding blank lines,
// one final newline, empty when there is nothing.
func Normalize(content string) string {
	content = strings.ReplaceAll(content, "\r\n", "\n")
	content = strings.TrimSpace(content)
	if content == "" {
		return ""
	}
	return content + "\n"
}

// ---- Front matter ----

// Description is the front matter's description, else the first heading or
// line of the file, cut to one short line.
func Description(content string) string {
	meta, body := SplitFrontMatter(content)
	if value := strings.TrimSpace(meta["description"]); value != "" {
		return shorten(value, 120)
	}
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(line), "#-* "))
		if line != "" {
			return shorten(line, 60)
		}
	}
	return ""
}

func shorten(value string, limit int) string {
	value = strings.Join(strings.Fields(value), " ")
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	runes := []rune(value)
	return string(runes[:limit]) + "…"
}

// SplitFrontMatter returns the `key: value` lines of a leading `---` block
// and the text after it. The first value of a key wins.
func SplitFrontMatter(content string) (map[string]string, string) {
	meta := map[string]string{}
	text := strings.ReplaceAll(content, "\r\n", "\n")
	if !strings.HasPrefix(text, "---\n") {
		return meta, text
	}
	rest := text[4:]
	end := strings.Index(rest, "\n---")
	if end < 0 {
		return meta, text
	}
	for _, line := range strings.Split(rest[:end], "\n") {
		key, value, ok := strings.Cut(line, ":")
		key = strings.ToLower(strings.TrimSpace(key))
		if !ok || key == "" {
			continue
		}
		if _, seen := meta[key]; !seen {
			meta[key] = strings.Trim(strings.TrimSpace(value), `"'`)
		}
	}
	body := rest[end+4:]
	body = strings.TrimPrefix(body, "\n")
	return meta, body
}

// WithDescription sets the front matter's description of content, adding
// the front matter when there is none. Other front matter keys stay.
func WithDescription(content, description string) string {
	description = strings.Join(strings.Fields(description), " ")
	if description == "" {
		return content
	}
	text := strings.ReplaceAll(content, "\r\n", "\n")
	var keep []string
	body := text
	if strings.HasPrefix(text, "---\n") {
		rest := text[4:]
		if end := strings.Index(rest, "\n---"); end >= 0 {
			for _, line := range strings.Split(rest[:end], "\n") {
				key, _, ok := strings.Cut(line, ":")
				if ok && strings.EqualFold(strings.TrimSpace(key), "description") {
					continue
				}
				if strings.TrimSpace(line) != "" {
					keep = append(keep, line)
				}
			}
			body = strings.TrimPrefix(rest[end+4:], "\n")
		}
	}
	lines := append([]string{"description: " + description}, keep...)
	return "---\n" + strings.Join(lines, "\n") + "\n---\n\n" + strings.TrimLeft(body, "\n")
}

// ---- The folder on disk ----

// locks serialises every change of one folder within the process: a turn's
// tools and a sync of the phone run in the same process.
var locks sync.Map

func lockFor(root string) *sync.Mutex {
	value, _ := locks.LoadOrStore(root, &sync.Mutex{})
	return value.(*sync.Mutex)
}

// Folder is one ledger's memory folder.
type Folder struct {
	root string
}

// Open opens the folder at root, an absolute path; it may not exist yet.
// A legacy memory.md at root+".md" (runtime/agent-memory.md beside
// runtime/agent-memory/) becomes MEMORY.md, or is appended to it.
func Open(root string) (*Folder, error) {
	root = filepath.Clean(root)
	if !filepath.IsAbs(root) {
		return nil, errors.New("memory folder must be an absolute path")
	}
	if strings.HasSuffix(root, legacySuffix) {
		root = strings.TrimSuffix(root, legacySuffix)
	}
	folder := &Folder{root: root}
	if err := folder.migrate(); err != nil {
		return nil, err
	}
	return folder, nil
}

// Root is the folder's absolute path.
func (f *Folder) Root() string { return f.root }

// Lock holds the folder against other changes in this process.
func (f *Folder) Lock() func() {
	mutex := lockFor(f.root)
	mutex.Lock()
	return mutex.Unlock
}

func (f *Folder) migrate() error {
	legacy := f.root + legacySuffix
	data, err := os.ReadFile(legacy)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("memory: %w", err)
	}
	unlock := f.Lock()
	defer unlock()
	old := Normalize(strings.ToValidUTF8(string(data), ""))
	if old != "" {
		current, err := f.readLocked(IndexName)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		merged := current
		if strings.TrimSpace(current) == "" {
			merged = old
		} else {
			// A device on an older version wrote memory.md again: keep its
			// lines that MEMORY.md does not have yet.
			have := map[string]bool{}
			for _, line := range strings.Split(current, "\n") {
				have[strings.TrimSpace(line)] = true
			}
			var added []string
			for _, line := range strings.Split(old, "\n") {
				if trimmed := strings.TrimSpace(line); trimmed != "" && !have[trimmed] && !strings.HasPrefix(trimmed, "#") {
					added = append(added, line)
				}
			}
			if len(added) > 0 {
				merged = strings.TrimRight(current, "\n") + "\n" + strings.Join(added, "\n")
			}
		}
		if merged != current {
			// An old memory can be up to the old limit; it is kept even when it
			// is over MEMORY.md's, and the prompt asks the model to split it.
			if err := f.writeLocked(IndexName, Normalize(merged)); err != nil {
				return err
			}
		}
	}
	if err := os.Remove(legacy); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func (f *Folder) file(path string) string {
	return filepath.Join(f.root, filepath.FromSlash(path))
}

// Read returns one file; a missing file is os.ErrNotExist.
func (f *Folder) Read(path string) (string, error) {
	clean, err := CleanPath(path)
	if err != nil {
		return "", err
	}
	unlock := f.Lock()
	defer unlock()
	return f.readLocked(clean)
}

func (f *Folder) readLocked(path string) (string, error) {
	data, err := os.ReadFile(f.file(path))
	if err != nil {
		return "", err
	}
	return strings.ToValidUTF8(string(data), ""), nil
}

// Write saves one file, or removes it when content is empty.
func (f *Folder) Write(path, content string) (string, error) {
	clean, err := CleanPath(path)
	if err != nil {
		return "", err
	}
	content = Normalize(content)
	if err := Validate(clean, content); err != nil {
		return "", err
	}
	unlock := f.Lock()
	defer unlock()
	if content != "" && clean != IndexName {
		if _, err := os.Stat(f.file(clean)); errors.Is(err, os.ErrNotExist) {
			snapshot, err := f.loadLocked()
			if err != nil {
				return "", err
			}
			if len(snapshot) >= MaxFiles {
				return "", fmt.Errorf("记忆最多 %d 个文件，请先合并", MaxFiles)
			}
		}
	}
	return clean, f.writeLocked(clean, content)
}

// Delete removes one file and any folder it leaves empty.
func (f *Folder) Delete(path string) (string, error) {
	clean, err := CleanPath(path)
	if err != nil {
		return "", err
	}
	unlock := f.Lock()
	defer unlock()
	if _, err := os.Stat(f.file(clean)); err != nil {
		return "", err
	}
	return clean, f.writeLocked(clean, "")
}

// writeLocked writes through a temporary file, so a crash never leaves a
// half-written memory; empty content removes the file.
func (f *Folder) writeLocked(path, content string) error {
	target := f.file(path)
	if content == "" {
		if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		f.pruneEmpty(filepath.Dir(target))
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(target), ".memory-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	_, err = temporary.WriteString(content)
	if closeErr := temporary.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Chmod(name, 0o600)
	}
	if err == nil {
		err = os.Rename(name, target)
	}
	if err != nil {
		_ = os.Remove(name)
	}
	return err
}

func (f *Folder) pruneEmpty(dir string) {
	for dir != f.root && strings.HasPrefix(dir, f.root+string(filepath.Separator)) {
		if err := os.Remove(dir); err != nil {
			return
		}
		dir = filepath.Dir(dir)
	}
}

// Load reads the whole folder. Files that are not memory files (temporary
// files, other names) are ignored.
func (f *Folder) Load() (Snapshot, error) {
	unlock := f.Lock()
	defer unlock()
	return f.loadLocked()
}

func (f *Folder) loadLocked() (Snapshot, error) {
	return LoadDir(f.root)
}

// LoadDir reads a memory folder that is not open, such as an exported
// branch; a missing folder is empty.
func LoadDir(root string) (Snapshot, error) {
	snapshot := Snapshot{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, os.ErrNotExist) && path == root {
				return filepath.SkipAll
			}
			return err
		}
		if entry.IsDir() {
			if path != root && strings.HasPrefix(entry.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if !entry.Type().IsRegular() {
			return nil
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if !IsMemoryPath(relative) {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		snapshot[relative] = strings.ToValidUTF8(string(data), "")
		return nil
	})
	if err != nil {
		return nil, err
	}
	return snapshot, nil
}

// Replace makes the folder hold exactly want, writing only what differs,
// as long as the folder still is expected; it reports whether it changed
// anything. A folder changed since expected was read is left alone and
// reported with ErrChanged.
func (f *Folder) Replace(expected, want Snapshot) (bool, error) {
	unlock := f.Lock()
	defer unlock()
	current, err := f.loadLocked()
	if err != nil {
		return false, err
	}
	if !current.Equal(expected) {
		return false, ErrChanged
	}
	changed := false
	for path, content := range want {
		if current[path] == content {
			continue
		}
		if err := f.writeLocked(path, content); err != nil {
			return changed, err
		}
		changed = true
	}
	for path := range current {
		if _, ok := want[path]; ok {
			continue
		}
		if err := f.writeLocked(path, ""); err != nil {
			return changed, err
		}
		changed = true
	}
	return changed, nil
}

// ErrChanged reports a folder that changed while it was being merged.
var ErrChanged = errors.New("memory folder changed during sync")

// ---- Index ----

// Entry is one topic file in the generated index.
type Entry struct {
	Path        string `json:"path"`
	Description string `json:"description"`
	Bytes       int    `json:"bytes"`
}

// Catalog lists the topic files of a snapshot, MEMORY.md left out, by path.
func (s Snapshot) Catalog() []Entry {
	entries := make([]Entry, 0, len(s))
	for path, content := range s {
		if path == IndexName {
			continue
		}
		entries = append(entries, Entry{Path: path, Description: Description(content), Bytes: len(content)})
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Path < entries[j].Path })
	return entries
}

// IndexText renders the catalog for a prompt, one line per file.
func IndexText(entries []Entry) string {
	if len(entries) == 0 {
		return ""
	}
	var builder strings.Builder
	for _, entry := range entries {
		builder.WriteString("- ")
		builder.WriteString(entry.Path)
		if entry.Description != "" {
			builder.WriteString(" — ")
			builder.WriteString(entry.Description)
		}
		builder.WriteString(fmt.Sprintf("（%s）\n", humanBytes(entry.Bytes)))
	}
	return strings.TrimRight(builder.String(), "\n")
}

func humanBytes(n int) string {
	if n < 1000 {
		return fmt.Sprintf("%d B", n)
	}
	return fmt.Sprintf("%.1f KB", float64(n)/1000)
}
