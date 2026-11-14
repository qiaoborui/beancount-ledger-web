package mobileagent

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

// skillLedger is a committed ledger that carries the given skills, keyed by
// their workspace-relative path.
func skillLedger(t *testing.T, files map[string]string) string {
	t.Helper()
	root := committedWorkspace(t)
	for name, content := range files {
		file := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func skillFile(name, description, body string) string {
	return "---\nname: " + name + "\ndescription: " + description + "\n---\n\n" + body + "\n"
}

func discovered(t *testing.T, root string, disabled ...string) ([]skill, []skillProblem) {
	t.Helper()
	set, err := openSkills(root, nil, disabled)
	if err != nil {
		t.Fatal(err)
	}
	defer set.close()
	return set.discover()
}

func skillNames(skills []skill) []string {
	names := make([]string, 0, len(skills))
	for _, item := range skills {
		names = append(names, item.Name+"|"+item.Source)
	}
	return names
}

func TestParseSkillReadsTheFrontmatterShapesSkillsUse(t *testing.T) {
	for label, test := range map[string]struct {
		content, wantName, wantDescription, wantBody string
	}{
		"plain": {content: "---\nname: alipay\ndescription: 导入支付宝账单\n---\n\n正文\n", wantName: "alipay", wantDescription: "导入支付宝账单", wantBody: "正文"},
		"quoted": {content: "---\nname: \"alipay\"\ndescription: \"导入支付宝：CSV 与对账\"\n---\n正文\n",
			wantName: "alipay", wantDescription: "导入支付宝：CSV 与对账", wantBody: "正文"},
		"folded description": {content: "---\nname: alipay\ndescription: >\n  导入支付宝账单，\n  对账后再写入\n---\n正文\n",
			wantName: "alipay", wantDescription: "导入支付宝账单， 对账后再写入", wantBody: "正文"},
		"comment": {content: "---\nname: alipay # 名字\ndescription: 导入\nglobs:\n  - \"**/*.bean\"\n---\n正文\n",
			wantName: "alipay", wantDescription: "导入", wantBody: "正文"},
		"bom and crlf": {content: "\ufeff---\r\nname: alipay\r\ndescription: 导入\r\n---\r\n正文\r\n",
			wantName: "alipay", wantDescription: "导入", wantBody: "正文"},
		"dots terminator": {content: "---\nname: alipay\ndescription: 导入\n...\n正文\n",
			wantName: "alipay", wantDescription: "导入", wantBody: "正文"},
		"no description": {content: "---\nname: alipay\n---\n正文\n", wantName: "alipay", wantBody: "正文"},
	} {
		name, description, body, _, err := parseSkill(test.content)
		if err != nil {
			t.Fatalf("%s: %v", label, err)
		}
		if name != test.wantName || description != test.wantDescription || body != test.wantBody {
			t.Errorf("%s: parsed %q / %q / %q", label, name, description, body)
		}
	}
}

func TestParseSkillRejectsFilesWithoutFrontmatter(t *testing.T) {
	for name, content := range map[string]string{
		"no frontmatter": "# 技能\n正文\n",
		"unterminated":   "---\nname: alipay\n正文\n",
		"empty file":     "",
		"leading blank":  "\n---\nname: alipay\n---\n正文\n",
	} {
		if _, _, _, _, err := parseSkill(content); err == nil {
			t.Errorf("%s parsed without error", name)
		}
	}
	// A file with frontmatter and no body parses, and is rejected by the
	// catalog for having nothing to say.
	if _, description, body, _, err := parseSkill("---\nname: alipay\ndescription: 导入\n---\n"); err != nil || description != "导入" || body != "" {
		t.Fatalf("frontmatter without body: %q %q %v", description, body, err)
	}
}

func TestBuiltinSkillsAreUsableOnDevice(t *testing.T) {
	skills, problems := discovered(t, committedWorkspace(t))
	if len(problems) != 0 {
		t.Fatalf("built-in skills have problems: %+v", problems)
	}
	var builtin []string
	for _, item := range skills {
		if item.Source == skillSourceBuiltin {
			builtin = append(builtin, item.Name)
		}
		if item.Description == "" || item.Body == "" {
			t.Errorf("%s is incomplete", item.Name)
		}
		if strings.Contains(item.Body, "```bash") || strings.Contains(item.Body, "python3 ") ||
			strings.Contains(item.Body, "double-entry-generator") {
			t.Errorf("%s tells the device assistant to run something it cannot", item.Name)
		}
	}
	for _, want := range []string{"alipay-bill-import", "beancount-bookkeeping", "wechat-bill-import"} {
		if !slices.Contains(builtin, want) {
			t.Errorf("built-in skill %s is missing; have %v", want, builtin)
		}
	}
	if len(builtin) < 3 {
		t.Fatalf("only %d built-in skills", len(builtin))
	}
	// Every tool a skill names must exist in this build, or the model will
	// call something that is not offered and the flow stops half way.
	known := knownToolNames(t)
	toolName := regexp.MustCompile(`^[a-z][a-z0-9]*(?:_[a-z0-9]+)+$`)
	for _, item := range skills {
		if item.Source != skillSourceBuiltin {
			continue
		}
		for _, piece := range strings.Split(item.Body, "`") {
			if name := strings.TrimSpace(piece); toolName.MatchString(name) && !known[name] {
				t.Errorf("%s mentions %q, which is not a tool of this build", item.Name, name)
			}
		}
	}
}

// knownToolNames is every tool a turn of this build can offer.
func knownToolNames(t *testing.T) map[string]bool {
	t.Helper()
	known := map[string]bool{"ask_user": true, "load_skill": true}
	for _, spec := range app.LocalAgentToolSpecs() {
		known[spec.Name] = true
	}
	files, err := openScratch(scratchCopy(t), "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	attached := &attachments{}
	sets := [][]agent.AgentTool{files.tools(), (&memoryFile{}).tools(), attached.tools(nil), (&historyIndex{}).tools(),
		// save_attachment and archive_statement come with a draft, as runTurnIn offers them.
		{attached.saveTool(files), attached.archiveTool(files)}}
	if session, err := newOnboardingSession(nil, time.Now()); err == nil {
		sets = append(sets, session.tools())
	}
	for _, tools := range sets {
		for _, tool := range tools {
			known[tool.Name()] = true
		}
	}
	return known
}

func TestLedgerSkillsOverrideBuiltinsAndListInOrder(t *testing.T) {
	root := skillLedger(t, map[string]string{
		"skills/alipay-bill-import/SKILL.md": skillFile("alipay-bill-import", "这本账的支付宝流程", "先看账单再对账。"),
		"skills/october-close/SKILL.md":      skillFile("october-close", "月底对账", "每月最后一天对账。"),
		"skills/_partial/SKILL.md":           "坏的",
		"skills/.git/SKILL.md":               "坏的",
		"skills/notes/README.md":             "没有 SKILL.md",
	})
	skills, problems := discovered(t, root)
	names := skillNames(skills)
	sorted := slices.Clone(names)
	slices.Sort(sorted)
	if !slices.Equal(names, sorted) {
		t.Fatalf("skills are not in a stable order: %v", names)
	}
	var alipay *skill
	for index := range skills {
		if skills[index].Name == "alipay-bill-import" {
			alipay = &skills[index]
		}
	}
	if alipay == nil || alipay.Source != skillSourceLedger || alipay.Description != "这本账的支付宝流程" {
		t.Fatalf("the ledger skill did not override the built-in one: %+v", alipay)
	}
	if !slices.Contains(names, "october-close|ledger") || slices.Contains(names, "notes|ledger") {
		t.Fatalf("ledger skills = %v", names)
	}
	if len(problems) != 1 || !strings.Contains(problems[0].Path, "notes") {
		t.Fatalf("problems = %+v", problems)
	}
}

func TestSkillPromptListsNamesAndDescriptionsOnly(t *testing.T) {
	root := skillLedger(t, map[string]string{
		"skills/monthly-close/SKILL.md": skillFile("monthly-close", "月底对账", "第一步：读流水。"),
		"skills/broken/SKILL.md":        "---\nname: Broken Name\ndescription: 大写不行\n---\n正文\n",
	})
	set, err := openSkills(root, nil, []string{"beancount-bookkeeping"})
	if err != nil {
		t.Fatal(err)
	}
	defer set.close()
	prompt := set.prompt(true)
	for _, want := range []string{"技能（skills）", "- monthly-close：月底对账", "- alipay-bill-import：", "load_skill", "create_skill", "update_skill", "delete_skill"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt misses %q:\n%s", want, prompt)
		}
	}
	for _, unwanted := range []string{"第一步：读流水", "beancount-bookkeeping", "Broken Name", "大写不行"} {
		if strings.Contains(prompt, unwanted) {
			t.Errorf("prompt carries %q:\n%s", unwanted, prompt)
		}
	}
	// A loose preference goes to memory.md only when the turn has one.
	if strings.Contains(set.prompt(false), "edit_memory") {
		t.Error("the skills prompt asks for edit_memory on a turn without memory")
	}
	if !strings.Contains(set.prompt(true), "edit_memory") {
		t.Error("the skills prompt does not say where a loose preference goes")
	}
}

func TestLoadSkillReturnsTheBodyAndItsFiles(t *testing.T) {
	root := skillLedger(t, map[string]string{
		"skills/monthly-close/SKILL.md": skillFile("monthly-close", "月底对账", "第一步：读流水。"),
	})
	set, err := openSkills(root, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer set.close()
	call := func(args map[string]any) (string, error) {
		raw, _ := json.Marshal(args)
		out, err := set.load(raw)
		if err != nil {
			return "", err
		}
		encoded, _ := json.Marshal(out)
		return string(encoded), nil
	}
	if out, err := call(map[string]any{"name": "monthly-close"}); err != nil || !strings.Contains(out, "第一步：读流水") ||
		!strings.Contains(out, `"path":"skills/monthly-close/SKILL.md"`) || !strings.Contains(out, `"source":"ledger"`) {
		t.Fatalf("ledger skill = %s, %v", out, err)
	}
	out, err := call(map[string]any{"name": "alipay-bill-import"})
	if err != nil || !strings.Contains(out, "columns.md") || !strings.Contains(out, `"path":"skills/alipay-bill-import/SKILL.md"`) {
		t.Fatalf("built-in skill = %s, %v", out, err)
	}
	out, err = call(map[string]any{"name": "alipay-bill-import", "file": "columns.md"})
	if err != nil || !strings.Contains(out, "收/付款方式") {
		t.Fatalf("built-in skill file = %s, %v", out, err)
	}
	if _, err := call(map[string]any{"name": "alipay-bill-import", "file": "nope.md"}); err == nil {
		t.Fatal("a missing built-in file was read")
	}
	if _, err := call(map[string]any{"name": "alipay-bill-import", "file": "../../main.bean"}); err == nil {
		t.Fatal("a path outside the skill was read")
	}
	if _, err := call(map[string]any{"name": "monthly-close", "file": "other.md"}); err == nil ||
		!strings.Contains(err.Error(), "read_file") {
		t.Fatalf("a ledger skill's file was read by load_skill: %v", err)
	}
	if _, err := call(map[string]any{"name": "missing"}); err == nil || !strings.Contains(err.Error(), "alipay-bill-import") {
		t.Fatalf("unknown skill: %v", err)
	}
	if _, err := call(map[string]any{}); err == nil {
		t.Fatal("an empty name was accepted")
	}
}

func TestDisabledSkillsAreNotListedOrLoadable(t *testing.T) {
	root := skillLedger(t, map[string]string{
		"skills/monthly-close/SKILL.md": skillFile("monthly-close", "月底对账", "第一步：读流水。"),
	})
	set, err := openSkills(root, nil, []string{"monthly-close"})
	if err != nil {
		t.Fatal(err)
	}
	defer set.close()
	if strings.Contains(set.prompt(true), "monthly-close") {
		t.Fatal("a disabled skill is in the prompt")
	}
	raw, _ := json.Marshal(map[string]any{"name": "monthly-close"})
	if _, err := set.load(raw); err == nil || !strings.Contains(err.Error(), "关闭") {
		t.Fatalf("a disabled skill loaded: %v", err)
	}
	catalog := decodeCatalog(t, SkillCatalogJSON(catalogRequest(root, "monthly-close")))
	if len(catalog.Skills) == 0 {
		t.Fatal("the catalog hid everything")
	}
	for _, item := range catalog.Skills {
		if item.Name == "monthly-close" && !item.Disabled {
			t.Fatal("the catalog does not mark the disabled skill")
		}
	}
}

func TestSkillLimitsSkipTheOffenderOnly(t *testing.T) {
	files := map[string]string{
		"skills/big/SKILL.md":       skillFile("big", "太大的技能", strings.Repeat("字", maxSkillBytes)),
		"skills/no-desc/SKILL.md":   "---\nname: no-desc\n---\n正文\n",
		"skills/bad-name/SKILL.md":  skillFile("Bad_Name", "名字不合规", "正文"),
		"skills/long-desc/SKILL.md": skillFile("long-desc", strings.Repeat("说", maxSkillDescriptionBytes), "正文"),
		"skills/empty/SKILL.md":     skillFile("empty", "没有正文", ""),
		"skills/good/SKILL.md":      skillFile("good", "能用的技能", "正文"),
	}
	root := skillLedger(t, files)
	skills, problems := discovered(t, root)
	var good bool
	for _, item := range skills {
		if item.Name == "good" {
			good = true
		}
		for _, bad := range []string{"big", "no-desc", "bad-name", "long-desc", "empty"} {
			if item.Name == bad {
				t.Errorf("%s was not skipped", bad)
			}
		}
	}
	if !good {
		t.Fatal("the good skill was skipped too")
	}
	if len(problems) != 5 {
		t.Fatalf("problems = %+v", problems)
	}
	// A skill too big to list is reported when it is asked for by name.
	set, err := openSkills(root, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer set.close()
	raw, _ := json.Marshal(map[string]any{"name": "big"})
	if _, err := set.load(raw); err == nil || !strings.Contains(err.Error(), "读不了") {
		t.Fatalf("a broken skill loaded: %v", err)
	}
}

func TestSkillCountIsCapped(t *testing.T) {
	files := map[string]string{}
	for index := 0; index < maxSkills+5; index++ {
		name := fmt.Sprintf("skill-%02d", index)
		files["skills/"+name+"/SKILL.md"] = skillFile(name, "第 "+name+" 个技能", "正文")
	}
	skills, problems := discovered(t, skillLedger(t, files))
	if len(skills) != maxSkills {
		t.Fatalf("listed %d skills, want %d", len(skills), maxSkills)
	}
	var capped bool
	for _, problem := range problems {
		capped = capped || strings.Contains(problem.Error, "太多")
	}
	if !capped {
		t.Fatalf("the cap was not reported: %+v", problems)
	}
	// The cap keeps the head of the sorted list, so the same skills survive
	// every turn.
	if !slices.IsSortedFunc(skills, func(a, b skill) int { return strings.Compare(a.Name, b.Name) }) ||
		!strings.HasPrefix(skills[len(skills)-1].Name, "skill-") {
		t.Fatalf("the cap did not keep the sorted head: %v", skillNames(skills))
	}
	for _, item := range skills {
		if item.Name == "wechat-bill-import" {
			t.Fatal("the cap dropped a built-in skill before a ledger one")
		}
	}
}

func TestSkillCatalogJSONListsBothSources(t *testing.T) {
	root := skillLedger(t, map[string]string{
		"skills/monthly-close/SKILL.md": skillFile("monthly-close", "月底对账", "第一步：读流水。"),
		"skills/broken/SKILL.md":        "没有 frontmatter",
	})
	catalog := decodeCatalog(t, SkillCatalogJSON(catalogRequest(root)))
	if !catalog.OK {
		t.Fatalf("catalog failed: %+v", catalog)
	}
	sources := map[string]string{}
	for _, item := range catalog.Skills {
		sources[item.Name] = item.Source
		if item.Body == "" || item.Description == "" || item.Path == "" {
			t.Errorf("%s is incomplete: %+v", item.Name, item)
		}
	}
	if sources["monthly-close"] != skillSourceLedger || sources["beancount-bookkeeping"] != skillSourceBuiltin {
		t.Fatalf("sources = %v", sources)
	}
	if len(catalog.Problems) != 1 || !strings.Contains(catalog.Problems[0].Error, "frontmatter") {
		t.Fatalf("problems = %+v", catalog.Problems)
	}
	bad := decodeCatalog(t, SkillCatalogJSON(`{"version":2,"workspaceRoot":"/ledger"}`))
	if bad.OK || bad.Error == "" {
		t.Fatalf("a wrong version was accepted: %+v", bad)
	}
	relative := decodeCatalog(t, SkillCatalogJSON(`{"version":1,"workspaceRoot":"ledger"}`))
	if relative.OK || !strings.Contains(relative.Error, "absolute") {
		t.Fatalf("a relative root was accepted: %+v", relative)
	}
}

func catalogRequest(root string, disabled ...string) string {
	raw, _ := json.Marshal(map[string]any{"version": 1, "workspaceRoot": root, "disabledSkills": disabled})
	return string(raw)
}

// skillCatalogResponse is what SkillCatalogJSON returns, as the app reads it.
type skillCatalogResponse struct {
	Version int    `json:"version"`
	OK      bool   `json:"ok"`
	Error   string `json:"error"`
	Skills  []struct {
		Name        string `json:"name"`
		Description string `json:"description"`
		Source      string `json:"source"`
		Path        string `json:"path"`
		Body        string `json:"body"`
		Disabled    bool   `json:"disabled"`
	} `json:"skills"`
	Problems []skillProblem `json:"problems"`
}

func decodeCatalog(t *testing.T, response string) skillCatalogResponse {
	t.Helper()
	var catalog skillCatalogResponse
	if err := json.Unmarshal([]byte(response), &catalog); err != nil {
		t.Fatalf("catalog %s: %v", response, err)
	}
	return catalog
}

func TestATurnListsSkillsAndLoadsThem(t *testing.T) {
	root := skillLedger(t, map[string]string{
		"skills/monthly-close/SKILL.md": skillFile("monthly-close", "月底对账", "先读本月流水，再看未对上的账单。"),
	})
	var systemPrompt, skillResult string
	useFaux(t,
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			systemPrompt = systemText(request)
			return ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
				ai.FauxToolCall("load_skill", map[string]any{"name": "monthly-close"}, &ai.FauxToolCallOptions{ID: "call_skill"}),
			}}.AssistantMessage(), nil
		}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			skillResult = lastToolResultText(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好，按流程来。")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": root, "provider": "faux", "model": "faux-1",
		"message": "月底了，帮我对一下账"})
	if !response.OK || len(response.ToolCalls) != 1 || response.ToolCalls[0].IsError {
		t.Fatalf("unexpected response: %+v", response)
	}
	if !strings.Contains(systemPrompt, "- monthly-close：月底对账") || !strings.Contains(systemPrompt, "- alipay-bill-import：") {
		t.Fatalf("the prompt does not list the skills:\n%s", systemPrompt)
	}
	if !strings.Contains(skillResult, "先读本月流水") {
		t.Fatalf("load_skill returned %s", skillResult)
	}
}

func TestDisabledSkillsReachTheTurn(t *testing.T) {
	var systemPrompt string
	useFaux(t,
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			systemPrompt = systemText(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好。")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t), "provider": "faux",
		"model": "faux-1", "message": "你好", "disabledSkills": []string{"alipay-bill-import"}})
	if !response.OK {
		t.Fatalf("unexpected response: %+v", response)
	}
	if strings.Contains(systemPrompt, "alipay-bill-import") || !strings.Contains(systemPrompt, "wechat-bill-import") {
		t.Fatalf("disabledSkills did not filter the prompt:\n%s", systemPrompt)
	}
}

func TestASkillWrittenThisTurnIsLoadableAtOnce(t *testing.T) {
	committed, draft := committedWorkspace(t), scratchCopy(t)
	var loaded string
	useFaux(t,
		toolStep("write_file", map[string]any{"path": "skills/my-close/SKILL.md",
			"content": skillFile("my-close", "我自己的月底流程", "先导出记账提醒的空白天。")}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			return ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
				ai.FauxToolCall("load_skill", map[string]any{"name": "my-close"}, &ai.FauxToolCallOptions{ID: "call_skill"}),
			}}.AssistantMessage(), nil
		}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			loaded = lastToolResultText(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("记住了。")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committed, "scratchRoot": draft,
		"provider": "faux", "model": "faux-1", "message": "以后月底都这样对账"})
	if !response.OK || !response.Edited || len(response.ToolCalls) != 2 {
		t.Fatalf("unexpected response: %+v", response)
	}
	if !strings.Contains(loaded, "先导出记账提醒的空白天") || !strings.Contains(loaded, `"source":"ledger"`) {
		t.Fatalf("a skill written this turn was not readable: %s", loaded)
	}
	if _, err := os.Stat(filepath.Join(committed, "skills", "my-close", "SKILL.md")); err == nil {
		t.Fatal("the skill reached the committed generation")
	}
}

// systemText is the system prompt the model was given.
func systemText(request ai.TranscriptContext) string {
	for _, message := range request.Messages() {
		system, ok := message.(ai.SystemMessage)
		if !ok {
			continue
		}
		switch content := system.Content.(type) {
		case ai.SystemText:
			return string(content)
		case ai.SystemTextBlocks:
			var text strings.Builder
			for _, block := range content {
				text.WriteString(block.Text)
			}
			return text.String()
		}
	}
	return ""
}

func TestSkillsComeBeforeTheMemory(t *testing.T) {
	memory := filepath.Join(t.TempDir(), "memory.md")
	if err := os.WriteFile(memory, []byte("- 美团记餐饮\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var systemPrompt string
	useFaux(t,
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			systemPrompt = systemText(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好。")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t), "provider": "faux",
		"model": "faux-1", "message": "你好", "memoryPath": memory})
	if !response.OK {
		t.Fatalf("unexpected response: %+v", response)
	}
	skills, remembered := strings.Index(systemPrompt, "可用技能："), strings.Index(systemPrompt, "记忆（memory.md）")
	if skills < 0 || remembered < 0 || skills > remembered {
		t.Fatalf("the memory no longer ends the prompt (skills %d, memory %d)", skills, remembered)
	}
}

func TestRenderedSkillReadsBackUnchanged(t *testing.T) {
	description := `导入 "建行" 账单: 先看余额 #2`
	body := "第一步：登录\n第二步：导出 CSV"
	content := renderSkill("ccb-bill-import", description, body, false)
	name, gotDescription, gotBody, deleted, err := parseSkill(content)
	if err != nil {
		t.Fatal(err)
	}
	if name != "ccb-bill-import" || gotDescription != description || gotBody != body || deleted {
		t.Fatalf("round trip = %q %q %q %v\n%s", name, gotDescription, gotBody, deleted, content)
	}
	// The delete mark survives the round trip too, and nothing else changes.
	_, _, keptBody, marked, err := parseSkill(renderSkill("ccb-bill-import", description, body, true))
	if err != nil || !marked || keptBody != body {
		t.Fatalf("tombstone round trip = %v %v %q", marked, err, keptBody)
	}
}

// skillTurn opens a turn's skills over a fresh draft of the ledger, the way a
// turn that may edit does.
func skillTurn(t *testing.T) (*skillSet, *scratch) {
	t.Helper()
	files, err := openScratch(scratchCopy(t), "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(files.close)
	set, err := openSkills("", files, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(set.close)
	return set, files
}

// callSkillTool runs one of the skill tools the way the model does.
func callSkillTool(t *testing.T, set *skillSet, name string, args map[string]any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	for _, tool := range set.tools() {
		if tool.Name() != name {
			continue
		}
		output, err := tool.Execute(context.Background(), "", raw, nil)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		var result map[string]any
		if err := json.Unmarshal([]byte(toolResultText(output.Content)), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	t.Fatalf("no tool named %s", name)
	return nil
}

func TestCreateSkillWritesALedgerSkillIntoTheDraft(t *testing.T) {
	set, files := skillTurn(t)
	result := callSkillTool(t, set, "create_skill", map[string]any{
		"name": "ccb-bill-import", "description": "导入建行账单", "body": "1. 打开账单\n2. 逐笔核对",
	})
	if result["path"] != "skills/ccb-bill-import/SKILL.md" || result["source"] != skillSourceLedger {
		t.Fatalf("result = %v", result)
	}
	if !files.wasEdited() {
		t.Fatal("a skill written into the draft must count as an edit")
	}
	skills, problems := set.discover()
	if len(problems) != 0 {
		t.Fatalf("problems = %v", problems)
	}
	found := false
	for _, item := range skills {
		if item.Name == "ccb-bill-import" {
			found = true
			if item.Description != "导入建行账单" || !strings.Contains(item.Body, "逐笔核对") {
				t.Fatalf("skill = %+v", item)
			}
		}
	}
	if !found {
		t.Fatalf("the new skill is not listed: %v", skillNames(skills))
	}
}

func TestCreateSkillRefusesANameThatIsTaken(t *testing.T) {
	set, _ := skillTurn(t)
	if _, err := set.create(json.RawMessage(`{"name":"alipay-bill-import","description":"x","body":"y"}`)); err == nil {
		t.Fatal("a built-in name must be refused")
	}
	callSkillTool(t, set, "create_skill", map[string]any{"name": "mine", "description": "说明", "body": "步骤"})
	if _, err := set.create(json.RawMessage(`{"name":"mine","description":"x","body":"y"}`)); err == nil {
		t.Fatal("a ledger name must be refused")
	}
}

func TestUpdateSkillCopiesABuiltinIntoTheLedger(t *testing.T) {
	set, _ := skillTurn(t)
	result := callSkillTool(t, set, "update_skill", map[string]any{
		"name": "alipay-bill-import", "body": "我们家的支付宝流程：先看余额，再逐笔核对。",
	})
	if result["source"] != skillSourceLedger {
		t.Fatalf("result = %v", result)
	}
	skills, _ := set.discover()
	for _, item := range skills {
		if item.Name != "alipay-bill-import" {
			continue
		}
		if item.Source != skillSourceLedger || !strings.Contains(item.Body, "我们家的支付宝流程") {
			t.Fatalf("skill = %+v", item)
		}
		if item.Description == "" {
			t.Fatal("update must keep the description it did not touch")
		}
		// The built-in's extra files do not follow the ledger copy: its folder
		// is the ledger's own.
		if len(item.Files) != 0 {
			t.Fatalf("files = %v", item.Files)
		}
		return
	}
	t.Fatalf("the copied skill is not listed: %v", skillNames(skills))
}

func TestDeleteSkillRemovesALedgerSkillFolder(t *testing.T) {
	set, files := skillTurn(t)
	callSkillTool(t, set, "create_skill", map[string]any{"name": "mine", "description": "说明", "body": "步骤"})
	if err := files.root.WriteFile("skills/mine/columns.md", []byte("a,b"), 0o600); err != nil {
		t.Fatal(err)
	}
	callSkillTool(t, set, "delete_skill", map[string]any{"name": "mine"})
	if _, err := files.root.Stat("skills/mine"); err == nil {
		t.Fatal("the folder must be gone")
	}
	for _, item := range mustDiscover(t, set) {
		if item.Name == "mine" {
			t.Fatal("a deleted skill must not be listed")
		}
	}
}

func TestDeleteSkillLeavesATombstoneForABuiltin(t *testing.T) {
	set, files := skillTurn(t)
	callSkillTool(t, set, "delete_skill", map[string]any{"name": "wechat-bill-import"})
	data, err := files.root.ReadFile("skills/wechat-bill-import/SKILL.md")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "deleted: true") {
		t.Fatalf("tombstone = %s", data)
	}
	for _, item := range mustDiscover(t, set) {
		if item.Name == "wechat-bill-import" {
			t.Fatal("a deleted built-in must not be listed")
		}
	}
	// load_skill says why instead of pretending the skill never existed.
	if _, err := set.load(json.RawMessage(`{"name":"wechat-bill-import"}`)); err == nil || !strings.Contains(err.Error(), "删掉") {
		t.Fatalf("load error = %v", err)
	}
	// update_skill brings it back, with the body the tombstone kept.
	callSkillTool(t, set, "update_skill", map[string]any{"name": "wechat-bill-import"})
	for _, item := range mustDiscover(t, set) {
		if item.Name == "wechat-bill-import" {
			if item.Source != skillSourceLedger || !strings.Contains(item.Body, "微信") {
				t.Fatalf("restored = %+v", item)
			}
			return
		}
	}
	t.Fatal("update_skill must restore a deleted built-in")
}

func TestSkillToolsOnlyWriteWithADraft(t *testing.T) {
	root := committedWorkspace(t)
	set, err := openSkills(root, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer set.close()
	for _, tool := range set.tools() {
		if tool.Name() != "load_skill" {
			t.Fatalf("a read-only turn must not offer %s", tool.Name())
		}
	}
	if _, err := set.create(json.RawMessage(`{"name":"mine","description":"说明","body":"步骤"}`)); err == nil {
		t.Fatal("creating a skill needs a draft")
	}
}

func TestCreateSkillChecksTheNameAndTheLimits(t *testing.T) {
	set, _ := skillTurn(t)
	for label, args := range map[string]string{
		"bad name":       `{"name":"CCB Import","description":"说明","body":"步骤"}`,
		"empty body":     `{"name":"mine","description":"说明","body":"  "}`,
		"no description": `{"name":"mine","body":"步骤"}`,
		"too long":       `{"name":"mine","description":"说明","body":"` + strings.Repeat("步", maxSkillBytes) + `"}`,
	} {
		if _, err := set.create(json.RawMessage(args)); err == nil {
			t.Fatalf("%s was accepted", label)
		}
	}
}

func mustDiscover(t *testing.T, set *skillSet) []skill {
	t.Helper()
	skills, problems := set.discover()
	if len(problems) != 0 {
		t.Fatalf("problems = %v", problems)
	}
	return skills
}

func TestCreateSkillStopsAtTheListLimit(t *testing.T) {
	files, err := openScratch(scratchCopy(t), "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	for index := 0; index < maxSkills; index++ {
		file := fmt.Sprintf("skills/filler-%02d/SKILL.md", index)
		if err := files.write(file, []byte(skillFile(fmt.Sprintf("filler-%02d", index), "占位", "正文"))); err != nil {
			t.Fatal(err)
		}
	}
	set, err := openSkills("", files, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer set.close()
	if _, err := set.create(json.RawMessage(`{"name":"one-more","description":"说明","body":"步骤"}`)); err == nil {
		t.Fatal("a create past the list limit must be refused")
	}
}
