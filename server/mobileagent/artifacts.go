package mobileagent

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/MichaelKinsy/PiG/agent"
)

const (
	// savedArtifactDir is where the shell keeps the ledger's artifacts,
	// one JSON file per artifact, beside agent-history.
	savedArtifactDir = "agent-artifacts"
	// savedArtifactList bounds one listing.
	savedArtifactList = 40
)

// artifactID is the shape of an artifact's id, and of its file name.
var artifactID = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,47}$`)

// artifactPrompt tells the model when to write an artifact instead of a
// visual, and how to change one it wrote before. The shell saves every
// `artifact` block of a finished reply; the model only reads them back.
const artifactPrompt = `

产物（artifact）：
- 用户要的是以后还会再打开、反复看或继续改的东西（月报、预算表、资产或负债面板、某个专题的分析页、对比页、清单式的小工具），或者说「做一个」「生成一个页面 / 面板 / 报告」「存下来」时，在回复里写一个 artifact 代码块，而不是 visual。App 会把它存成一个产物：对话里显示成一张卡片，点开全屏查看，之后在侧边栏的「产物」里还能打开、看历史版本。
- 格式与 visual 相同，外加 id、title 和一句 summary：
` + "```artifact" + `
{"id":"food-2026","title":"2026 年餐饮支出","summary":"按月、按商户看餐饮花销","subtitle":"数据截至 2026-11-16","unit":"元","blocks":[...]}
` + "```" + `
- id 用小写字母、数字和连字符，最多 48 个字符。新产物用一个不重复的 id。
- 修改已有的产物：沿用原来的 id，App 会存成新版本。不在本次对话里的产物，先用 list_artifacts 找到 id，再用 read_artifact 读出当前内容；回复里要写出改完的完整产物，没改的部分原样保留，不能只写改动。用户说「刷新」「更新数据」时，按原来的结构重新查询再写一遍。
- 一次回答最多一个 artifact 代码块。产物可以比 visual 完整：顶层最多 12 个块，用 section、tabs 组织更多内容；数字同样必须来自工具结果，在 subtitle 写明数据截至哪天。
- 代码块之外只用一两句话说明产物里有什么，不要重复其内容。一次性的问题仍然用 visual、chart 或文字回答。`

// artifactFileV1 is the shell's record of one artifact. Every version keeps
// the block as the reply wrote it, so it reads back exactly.
type artifactFileV1 struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Summary   string `json:"summary,omitempty"`
	UpdatedAt string `json:"updatedAt"`
	Versions  []struct {
		Number  int    `json:"number"`
		SavedAt string `json:"savedAt"`
		Spec    string `json:"spec"`
	} `json:"versions"`
}

// artifactShelf reads the artifacts the shell saved beside the ledger.
type artifactShelf struct {
	dir string
}

// openArtifacts locates the ledger's artifacts; a turn without an absolute
// runtime directory has none.
func openArtifacts(runtimeRoot string) *artifactShelf {
	root := strings.TrimSpace(runtimeRoot)
	if root == "" || !filepath.IsAbs(root) {
		return nil
	}
	return &artifactShelf{dir: filepath.Join(root, savedArtifactDir)}
}

func (s *artifactShelf) load(id string) (artifactFileV1, error) {
	var file artifactFileV1
	if !artifactID.MatchString(id) {
		return file, fmt.Errorf("id %q 不是有效的产物 id；用 list_artifacts 查看已有的产物", id)
	}
	data, err := os.ReadFile(filepath.Join(s.dir, id+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return file, fmt.Errorf("没有 id 为 %q 的产物；用 list_artifacts 查看已有的产物", id)
	}
	if err != nil {
		return file, err
	}
	if err := json.Unmarshal(data, &file); err != nil || len(file.Versions) == 0 {
		return file, fmt.Errorf("产物 %q 读不出来", id)
	}
	if file.ID == "" {
		file.ID = id
	}
	return file, nil
}

func (s *artifactShelf) list(raw json.RawMessage) (any, error) {
	var input struct {
		Query string `json:"query"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	query := strings.ToLower(strings.TrimSpace(input.Query))
	entries, err := os.ReadDir(s.dir)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]any{"artifacts": []any{}, "note": "还没有保存过产物"}, nil
	}
	if err != nil {
		return nil, err
	}
	type row struct {
		ID        string `json:"id"`
		Title     string `json:"title"`
		Summary   string `json:"summary,omitempty"`
		UpdatedAt string `json:"updatedAt"`
		Versions  int    `json:"versions"`
	}
	rows := []row{}
	for _, entry := range entries {
		name := entry.Name()
		if !entry.Type().IsRegular() || !strings.HasSuffix(name, ".json") {
			continue
		}
		file, err := s.load(strings.TrimSuffix(name, ".json"))
		if err != nil {
			continue
		}
		if query != "" && !strings.Contains(strings.ToLower(file.ID+" "+file.Title+" "+file.Summary), query) {
			continue
		}
		rows = append(rows, row{ID: file.ID, Title: file.Title, Summary: file.Summary, UpdatedAt: file.UpdatedAt, Versions: len(file.Versions)})
	}
	sort.SliceStable(rows, func(left, right int) bool {
		return historyTime(rows[left].UpdatedAt).After(historyTime(rows[right].UpdatedAt))
	})
	if len(rows) > savedArtifactList {
		rows = rows[:savedArtifactList]
	}
	return map[string]any{"artifacts": rows}, nil
}

func (s *artifactShelf) read(raw json.RawMessage) (any, error) {
	var input struct {
		ID      string `json:"id"`
		Version int    `json:"version"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	file, err := s.load(strings.TrimSpace(input.ID))
	if err != nil {
		return nil, err
	}
	version := file.Versions[len(file.Versions)-1]
	if input.Version > 0 {
		found := false
		for _, candidate := range file.Versions {
			if candidate.Number == input.Version {
				version, found = candidate, true
			}
		}
		if !found {
			return nil, fmt.Errorf("产物 %q 没有第 %d 版，现有 %d 个版本", file.ID, input.Version, len(file.Versions))
		}
	}
	output := map[string]any{"id": file.ID, "title": file.Title, "version": version.Number,
		"versions": len(file.Versions), "savedAt": version.SavedAt}
	// The block goes back as JSON, not as a string of it, so the model edits
	// the structure it wrote.
	var spec any
	if json.Unmarshal([]byte(version.Spec), &spec) == nil {
		output["artifact"] = spec
	} else {
		output["artifact"] = version.Spec
	}
	return output, nil
}

func (s *artifactShelf) tools() []agent.AgentTool {
	return []agent.AgentTool{
		fileTool{name: "list_artifacts", title: "查看产物",
			description: "列出这本账保存的产物（artifact），按更新时间从新到旧：id、标题、一句说明和版本数。要修改或刷新以前做的产物时先用它找 id。",
			parameters: objectParameters(map[string]any{
				"query": map[string]any{"type": "string", "description": "可选关键词，在 id、标题和说明里匹配"},
			}),
			run: s.list},
		fileTool{name: "read_artifact", title: "读取产物",
			description: "按 id 读取一个产物的完整内容（与 artifact 代码块相同的 JSON），默认最新版本。修改时以它为底稿，改完在回复里写出完整的 artifact 代码块，沿用同一个 id。",
			parameters: objectParameters(map[string]any{
				"id":      map[string]any{"type": "string", "description": "list_artifacts 返回的产物 id"},
				"version": map[string]any{"type": "integer", "description": "可选，读取第几版；不填是最新版", "minimum": 1},
			}, "id"),
			run: s.read},
	}
}
