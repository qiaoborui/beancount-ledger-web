package mobileagent

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/MichaelKinsy/PiG/agent"

	"github.com/borui/beancount-ledger-web/server/agentmemory"
	"github.com/borui/beancount-ledger-web/server/internal/app"
)

// maxMemoryBytes bounds MEMORY.md, the part of the memory every system
// prompt carries; topic files are read on demand.
const maxMemoryBytes = agentmemory.MaxIndexBytes

// memoryRules tell the model how the memory folder works and when to change
// it. They follow the main prompt only when the shell sends a memory folder.
const memoryRules = `

记忆（memory/ 目录，MEMORY.md 是入口）：
- 记忆是以前的对话里记下的、关于这位用户和这本账的长期偏好与习惯，按主题分成几个 Markdown 文件。回答和改账时照着做；用户这次明确说的优先。
- 本提示末尾的 <memory path="MEMORY.md"> 是总览，每次都会带上：只放每次对话都用得上的少数规则（回答口径、最常用的账户），以及指向主题文件的一两句提示。
- <memory-files> 列出其余的主题文件和它们的一句话说明。说明和当前问题有关时，先用 read_memory 读那个文件再回答或改账；无关的不用读。
- 以下情况记一条：用户说「记住」「以后」「每次」「下次」之类；用户纠正了你选的账户、分类、payee 写法或回答方式；同一类操作（某商户总记到某账户、每月固定的账单或还款、常查的口径）在对话里第二次出现。
- 记到哪里：通用规则进 MEMORY.md；某一类的细节进主题文件，例如 merchants.md（商户→账户）、accounts/credit-cards.md（账单日、还款）、recurring.md（固定收支）、imports.md（导入习惯）。文件名用小写英文、数字和 -，最多两层目录；新建文件时用 description 参数写一句「什么时候该读它」。已有合适的文件就写进去，不要为一两条新建文件。
- 一条一行，以「- 」开头，写成下次可以直接照做的话，例如「- 美团外卖记 Expenses:Food:Delivery，payee 写商户名」。同一件事已经记过就用 edit_memory 改那一行，不要重复；用户说忘掉、或某条不对，就删掉或改正那一行。
- MEMORY.md 超过约 3 KB 时，把成块的细节挪进主题文件（write_memory 新文件，再从 MEMORY.md 删掉），MEMORY.md 只留总览。
- 不记一次性的问题、查询结果和金额明细；绝不记密码、验证码、Token、银行卡号、证件号。
- 记忆改动会直接保存，不经过草稿和确认卡片，也会同步给云端的定时任务。改了记忆就在回答末尾用一句话告诉用户记了什么、记在哪个文件。`

// memoryReadOnlyRules replace the writing half of the rules on a turn that
// may only read the memory, such as an unattended run.
const memoryReadOnlyRules = `

记忆（memory/ 目录，MEMORY.md 是入口，只读）：
- 记忆是用户在手机上的对话里记下的长期偏好与习惯。回答和改账时照着做。
- 本提示末尾的 <memory path="MEMORY.md"> 是总览；<memory-files> 列出其余主题文件和一句话说明，和当前任务有关时先用 read_memory 读。
- 这次不能改记忆。觉得该记住的事写进结论，让用户之后决定。`

// memoryFile is the shell's memory folder for the open ledger. The shell
// names it by absolute path; the turn reads MEMORY.md and the index once and
// its tools change the files.
type memoryFile struct {
	folder   *agentmemory.Folder
	readOnly bool
	mu       sync.Mutex
	index    string
	catalog  []agentmemory.Entry
	updated  bool
}

// openMemory opens the memory folder at path. An older shell names the
// single memory.md; it is moved into the folder beside it.
func openMemory(path string) (*memoryFile, error) {
	folder, err := agentmemory.Open(path)
	if err != nil {
		return nil, fmt.Errorf("memory: %w", err)
	}
	snapshot, err := folder.Load()
	if err != nil {
		return nil, fmt.Errorf("memory: %w", err)
	}
	return &memoryFile{folder: folder, index: snapshot[agentmemory.IndexName], catalog: snapshot.Catalog()}, nil
}

// prompt is what the system prompt ends with. It is read once, so the
// prompt stays the same for the whole turn and the cache holds.
func (m *memoryFile) prompt() string {
	rules := memoryRules
	if m.readOnly {
		rules = memoryReadOnlyRules
	}
	return rules + "\n\n" + m.text()
}

// text is MEMORY.md and the index of topic files, as the prompt carries them.
func (m *memoryFile) text() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	index := strings.TrimSpace(m.index)
	if index == "" {
		index = "（还是空的）"
	}
	if len(m.index) > agentmemory.IndexSoftBytes && !m.readOnly {
		index += fmt.Sprintf("\n\n（MEMORY.md 已有 %d 字节，超过约 3 KB：这次有空就把成块的细节挪进主题文件。）", len(m.index))
	}
	files := agentmemory.IndexText(m.catalog)
	if files == "" {
		files = "（还没有主题文件）"
	}
	return "记忆：\n<memory path=\"MEMORY.md\">\n" + index + "\n</memory>\n<memory-files>\n" + files + "\n</memory-files>"
}

// summary is MEMORY.md and the topic files' descriptions, for the tool-free
// assists; empty when there is no memory.
func (m *memoryFile) summary() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	index := strings.TrimSpace(m.index)
	files := agentmemory.IndexText(m.catalog)
	if files == "" {
		return index
	}
	return strings.TrimSpace(index + "\n\n其他记忆文件：\n" + files)
}

func (m *memoryFile) wasUpdated() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.updated
}

func (m *memoryFile) tools() []agent.AgentTool {
	str := func(description string) map[string]any {
		return map[string]any{"type": "string", "description": description}
	}
	pathParameter := str("记忆文件路径，例如 MEMORY.md、merchants.md、accounts/credit-cards.md；不写就是 MEMORY.md")
	tools := []agent.AgentTool{
		fileTool{name: "read_memory", title: "读取记忆",
			description: "读一个记忆文件的全文。MEMORY.md 已在系统提示末尾，不用读；<memory-files> 里和当前问题有关的主题文件用这个读。",
			parameters:  objectParameters(map[string]any{"path": pathParameter}, "path"),
			run:         m.read},
	}
	if m.readOnly {
		return tools
	}
	return append(tools,
		fileTool{name: "edit_memory", title: "更新记忆",
			description: "修改一个记忆文件。old_string 为空时，把 new_string 作为新的一行或几行追加到文件末尾（文件不存在就新建，这时要给 description）；否则把 old_string（必须原样出现且只出现一次）替换成 new_string，new_string 为空就是删掉那一段。改主题文件前先用 read_memory 看原文。",
			parameters: objectParameters(map[string]any{"path": pathParameter,
				"old_string":  str("要替换或删除的原文；追加时留空"),
				"new_string":  str("新内容，例如「- 星巴克记 Expenses:Food:Coffee」"),
				"description": str("新建主题文件时必填：一句话说明什么时候该读它，例如「信用卡账单日、还款日和还款账户」；改已有文件时留空")},
				"path", "old_string", "new_string", "description"),
			run: m.edit},
		fileTool{name: "write_memory", title: "整理记忆",
			description: "用 content 整份覆盖一个记忆文件（不存在就新建），用于新建主题文件、合并重复、重新分组、把 MEMORY.md 的细节挪出去。会丢掉没写进 content 的内容，所以要基于那个文件的完整原文来写。content 为空就删掉这个文件。",
			parameters: objectParameters(map[string]any{"path": pathParameter,
				"content":     str("完整的新内容，Markdown；主题文件不用自己写 front matter"),
				"description": str("主题文件的一句话说明，什么时候该读它；MEMORY.md 不用")},
				"path", "content", "description"),
			run: m.write},
	)
}

func (m *memoryFile) read(raw json.RawMessage) (any, error) {
	var input struct {
		Path string `json:"path"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	path, err := agentmemory.CleanPath(input.Path)
	if err != nil {
		return nil, err
	}
	content, err := m.folder.Read(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("没有记忆文件 %s；现有的见 <memory-files>", path)
	}
	if err != nil {
		return nil, err
	}
	return map[string]any{"path": path, "content": content}, nil
}

func (m *memoryFile) edit(raw json.RawMessage) (any, error) {
	var input struct {
		Path        string `json:"path"`
		OldString   string `json:"old_string"`
		NewString   string `json:"new_string"`
		Description string `json:"description"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	path, err := agentmemory.CleanPath(input.Path)
	if err != nil {
		return nil, err
	}
	content, err := m.folder.Read(path)
	exists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if strings.TrimSpace(input.OldString) == "" {
		addition := strings.TrimSpace(input.NewString)
		if addition == "" {
			return nil, errors.New("old_string 和 new_string 都是空的")
		}
		if !exists && path != agentmemory.IndexName && strings.TrimSpace(input.Description) == "" {
			return nil, fmt.Errorf("%s 还不存在；新建主题文件要给 description，一句话说明什么时候该读它", path)
		}
		content = strings.TrimRight(content, "\n")
		if content != "" {
			content += "\n"
		}
		content += addition
	} else {
		if !exists {
			return nil, fmt.Errorf("没有记忆文件 %s", path)
		}
		switch count := strings.Count(content, input.OldString); {
		case count == 0:
			return nil, fmt.Errorf("%s 里找不到 old_string，请先 read_memory 再逐字复制", path)
		case count > 1:
			return nil, fmt.Errorf("old_string 在 %s 里出现了 %d 次，多带一些上下文让它唯一", path, count)
		}
		content = strings.Replace(content, input.OldString, input.NewString, 1)
	}
	if path != agentmemory.IndexName && strings.TrimSpace(input.Description) != "" {
		content = agentmemory.WithDescription(content, input.Description)
	}
	saved, err := m.save(path, content)
	if err != nil {
		return nil, err
	}
	return map[string]any{"ok": true, "path": path, "content": saved}, nil
}

func (m *memoryFile) write(raw json.RawMessage) (any, error) {
	var input struct {
		Path        string `json:"path"`
		Content     string `json:"content"`
		Description string `json:"description"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	path, err := agentmemory.CleanPath(input.Path)
	if err != nil {
		return nil, err
	}
	content := input.Content
	if strings.TrimSpace(content) != "" && path != agentmemory.IndexName {
		if strings.TrimSpace(input.Description) != "" {
			content = agentmemory.WithDescription(content, input.Description)
		} else if meta, _ := agentmemory.SplitFrontMatter(content); meta["description"] == "" {
			// Keep the description the file had.
			if old, err := m.folder.Read(path); err == nil {
				if previous, _ := agentmemory.SplitFrontMatter(old); strings.TrimSpace(previous["description"]) != "" {
					content = agentmemory.WithDescription(content, previous["description"])
				}
			} else if errors.Is(err, os.ErrNotExist) {
				return nil, fmt.Errorf("%s 还不存在；新建主题文件要给 description，一句话说明什么时候该读它", path)
			}
		}
	}
	saved, err := m.save(path, content)
	if err != nil {
		return nil, err
	}
	if saved == "" {
		return map[string]any{"ok": true, "path": path, "deleted": true}, nil
	}
	return map[string]any{"ok": true, "path": path, "bytes": len(saved)}, nil
}

// save checks and writes one file, then refreshes the turn's view of the
// folder for later tool results; the prompt itself does not change.
func (m *memoryFile) save(path, content string) (string, error) {
	content = agentmemory.Normalize(content)
	if app.ContainsSensitiveAgentContent(content) {
		return "", errors.New("记忆里不能有密码、验证码、Token、证件号或完整的卡号")
	}
	if content == "" {
		if _, err := m.folder.Delete(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
	} else if _, err := m.folder.Write(path, content); err != nil {
		return "", err
	}
	m.mu.Lock()
	m.updated = true
	m.mu.Unlock()
	return content, nil
}
