package mobileagent

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/MichaelKinsy/PiG/agent"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

// maxMemoryBytes bounds memory.md. It goes into every system prompt, so it
// stays small; the model is asked to merge entries when it grows.
const maxMemoryBytes = 8000

// memoryRules tell the model what memory.md is and when to change it. They
// follow the main prompt only when the shell sends a memory file.
const memoryRules = `

记忆（memory.md）：
- 本提示末尾的「记忆」是 memory.md 的内容：以前的对话里记下的、关于这位用户和这本账的长期偏好与习惯。回答和改账时照着做；用户这次明确说的优先。
- 以下情况用 edit_memory 记一条：用户说「记住」「以后」「每次」「下次」之类；用户纠正了你选的账户、分类、payee 写法或回答方式；同一类操作（某商户总记到某账户、每月固定的账单或还款、常查的口径）在对话里第二次出现。
- 只记以后还用得上的稳定规则。一条一行，以「- 」开头，写成下次可以直接照做的话，例如「- 美团外卖记 Expenses:Food:Delivery，payee 写商户名」「- 说"这个月"指自然月，金额保留两位小数」。可以放在「## 偏好」「## 账户与分类」「## 常做的事」这几个小标题下。
- 记之前先看已有记忆：同一件事已经记过就用 edit_memory 改那一行，不要重复；用户说忘掉、或某条不对，就删掉或改正那一行。记忆太长或太乱时用 write_memory 整理成更短的一份。
- 不记一次性的问题、查询结果和金额明细；绝不记密码、验证码、Token、银行卡号、证件号。
- 记忆改动会直接保存，不经过草稿和确认卡片。改了记忆就在回答末尾用一句话告诉用户记了什么。`

// memoryFile is the shell's memory.md for the open ledger. The shell names
// it by absolute path; the turn reads it once and its tools rewrite it.
type memoryFile struct {
	path    string
	mu      sync.Mutex
	content string
	updated bool
}

// openMemory reads memory.md at path; a missing file is an empty memory.
func openMemory(path string) (*memoryFile, error) {
	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return nil, errors.New("memoryPath must be absolute")
	}
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("memory: %w", err)
	}
	content := string(data)
	if !utf8.ValidString(content) {
		content = strings.ToValidUTF8(content, "")
	}
	return &memoryFile{path: path, content: content}, nil
}

// prompt is what the system prompt ends with.
func (m *memoryFile) prompt() string {
	content := strings.TrimSpace(m.snapshot())
	if content == "" {
		content = "（还是空的）"
	}
	return memoryRules + "\n\n记忆：\n<memory>\n" + content + "\n</memory>"
}

func (m *memoryFile) snapshot() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.content
}

func (m *memoryFile) wasUpdated() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.updated
}

// save writes content through a temporary file, so a crash never leaves a
// half-written memory.
func (m *memoryFile) save(content string) error {
	content = strings.TrimSpace(content)
	if content != "" {
		content += "\n"
	}
	if len(content) > maxMemoryBytes {
		return fmt.Errorf("记忆最多 %d 字节，现在是 %d 字节；请用 write_memory 合并、删掉过时的条目后再写", maxMemoryBytes, len(content))
	}
	if app.ContainsSensitiveAgentContent(content) {
		return errors.New("记忆里不能有密码、验证码、Token、证件号或完整的卡号")
	}
	if err := os.MkdirAll(filepath.Dir(m.path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(m.path), ".memory-*")
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
		err = os.Rename(name, m.path)
	}
	if err != nil {
		_ = os.Remove(name)
		return err
	}
	m.content = content
	m.updated = true
	return nil
}

func (m *memoryFile) tools() []agent.AgentTool {
	str := func(description string) map[string]any {
		return map[string]any{"type": "string", "description": description}
	}
	return []agent.AgentTool{
		fileTool{name: "edit_memory", title: "更新记忆",
			description: "修改长期记忆 memory.md（当前内容在系统提示末尾）。old_string 为空时，把 new_string 作为新的一行或几行追加到末尾；否则把 old_string（必须原样出现且只出现一次）替换成 new_string，new_string 为空就是删掉那一段。",
			parameters: objectParameters(map[string]any{"old_string": str("要替换或删除的原文；追加时留空"),
				"new_string": str("新内容，例如「- 星巴克记 Expenses:Food:Coffee」")}, "old_string", "new_string"),
			run: m.edit},
		fileTool{name: "write_memory", title: "整理记忆",
			description: "用 content 整份覆盖 memory.md，用于合并重复、删掉过时条目、重新分组。会丢掉没写进 content 的内容，所以要基于当前的完整记忆来写。",
			parameters:  objectParameters(map[string]any{"content": str("完整的新记忆，Markdown")}, "content"),
			run:         m.write},
	}
}

func (m *memoryFile) edit(raw json.RawMessage) (any, error) {
	var input struct {
		OldString string `json:"old_string"`
		NewString string `json:"new_string"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	content := m.content
	if strings.TrimSpace(input.OldString) == "" {
		addition := strings.TrimSpace(input.NewString)
		if addition == "" {
			return nil, errors.New("old_string 和 new_string 都是空的")
		}
		content = strings.TrimRight(content, "\n")
		if content != "" {
			content += "\n"
		}
		content += addition
	} else {
		switch count := strings.Count(content, input.OldString); {
		case count == 0:
			return nil, errors.New("记忆里找不到 old_string，请按系统提示里的记忆原文逐字复制")
		case count > 1:
			return nil, fmt.Errorf("old_string 在记忆里出现了 %d 次，多带一些上下文让它唯一", count)
		}
		content = strings.Replace(content, input.OldString, input.NewString, 1)
	}
	if err := m.save(content); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true, "memory": m.content}, nil
}

func (m *memoryFile) write(raw json.RawMessage) (any, error) {
	var input struct {
		Content string `json:"content"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.save(input.Content); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true, "bytes": len(m.content)}, nil
}
