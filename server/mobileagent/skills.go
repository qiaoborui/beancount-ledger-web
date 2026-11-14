package mobileagent

import (
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/MichaelKinsy/PiG/agent"
)

// Skills are instructions the model loads only when it needs them: how to
// import a bank's statement, how this person likes the ledger kept. The
// prompt carries just their names and descriptions, so a conversation pays
// for them only when one is used.

const (
	// maxSkills bounds the list a turn carries; a ledger that grew a pile of
	// skill folders still gets a usable prompt.
	maxSkills = 40
	// maxSkillBytes bounds one SKILL.md. The body goes into a tool result and
	// from there into the transcript, so it stays small.
	maxSkillBytes = 16 << 10
	// maxSkillDescriptionBytes bounds the one line the prompt lists.
	maxSkillDescriptionBytes = 300
)

// skillSource names where a skill came from.
const (
	skillSourceBuiltin = "builtin"
	skillSourceLedger  = "ledger"
)

// skillNamePattern is the name a skill is loaded by: lowercase, digits and
// hyphens, as SKILL.md files elsewhere use.
var skillNamePattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$`)

// skill is one SKILL.md: a name and description for the prompt, and a body
// the model reads on demand.
type skill struct {
	Name        string
	Description string
	Body        string
	Source      string
	// Path is where the body lives: the embedded path of a built-in skill, or
	// the workspace-relative path of a ledger one.
	Path string
	// Files are the other files beside a built-in skill, which load_skill can
	// read. A ledger skill's files are read with read_file instead.
	Files []string
}

// skillProblem is one skill that was skipped. A broken file costs its own
// skill, never the turn.
type skillProblem struct {
	Path  string `json:"path"`
	Error string `json:"error"`
}

// builtinSkills holds the skills the app ships, rewritten for the on-device
// tools: no shell, no server, no helper scripts.
//
//go:embed skills
var builtinSkills embed.FS

// builtinSkillsOnce parses the embedded skills once per process; they never
// change while the app runs.
var builtinSkillsOnce = sync.OnceValues(readBuiltinSkills)

// skillsPrompt tells the model what skills are, when to read one, and when to
// write one. It follows the main prompt only for a turn that has a ledger.
const skillsPrompt = `

技能（skills）：
- 「可用技能」里每一条是一份做法说明：某类事该怎么在这本账上做。清单只有名字和一句说明，正文不在提示里，用到时用 load_skill 读。
- 用户要做的事和清单里的技能有关时（例如导入支付宝或微信账单、按这本账的规矩记账），先 load_skill 读正文，再照它做；正文里提到的工具都能直接调用。读完不要向用户复述技能内容，直接按它操作。
- 用户说「以后都这样做」「记住这个流程」，而内容是几步的做法，就写成账本里的技能：write_file 写 skills/<name>/SKILL.md，开头是 frontmatter（name 用小写字母、数字和连字符，description 一句说明什么时候用），下面是 Markdown 步骤。零散偏好（某商户记哪个账户、称呼习惯）不要建技能。
- 改已有的技能用 edit_file，路径看 load_skill 返回的 path。技能和其他文件一样走草稿，bean_check 通过后才会写入账本，也会随 Git 同步给其他设备。`

// openSkills is the turn's view of its skills: the built-in ones and those in
// the copy of the ledger it can see. A turn that may edit reads its draft, so
// a skill it writes becomes available at once.
func openSkills(workspaceRoot string, draft *scratch, disabled []string) (*skillSet, error) {
	set := &skillSet{disabled: map[string]bool{}}
	for _, name := range disabled {
		if name = strings.TrimSpace(name); name != "" {
			set.disabled[name] = true
		}
	}
	if draft != nil {
		set.root = draft.root
		return set, nil
	}
	dir := filepath.Clean(strings.TrimSpace(workspaceRoot))
	if dir == "" || !filepath.IsAbs(dir) {
		return nil, errors.New("workspaceRoot must be absolute")
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, fmt.Errorf("skills: %w", err)
	}
	set.root = root
	set.closeRoot = func() { _ = root.Close() }
	return set, nil
}

// skillSet reads the skills of one turn.
type skillSet struct {
	root *os.Root
	// closeRoot is set when this set opened the root itself; a draft's root
	// belongs to the turn.
	closeRoot func()
	disabled  map[string]bool
}

func (s *skillSet) close() {
	if s != nil && s.closeRoot != nil {
		s.closeRoot()
	}
}

// discover lists the skills of this turn: the built-in ones and the ledger's,
// a ledger skill replacing a built-in one of the same name. The order is by
// name, so the prompt lists them the same way every turn and the provider can
// serve the unchanged prefix from its cache.
func (s *skillSet) discover() ([]skill, []skillProblem) {
	builtin, problems := builtinSkillsOnce()
	byName := make(map[string]skill, len(builtin))
	for _, item := range builtin {
		byName[item.Name] = item
	}
	if s != nil && s.root != nil {
		ledger, ledgerProblems := s.ledgerSkills()
		problems = append(problems, ledgerProblems...)
		for _, item := range ledger {
			byName[item.Name] = item
		}
	}
	skills := make([]skill, 0, len(byName))
	for _, item := range byName {
		skills = append(skills, item)
	}
	sort.Slice(skills, func(i, j int) bool { return skills[i].Name < skills[j].Name })
	if len(skills) > maxSkills {
		problems = append(problems, skillProblem{Path: "skills", Error: fmt.Sprintf("技能太多，只列前 %d 个", maxSkills)})
		skills = skills[:maxSkills]
	}
	return skills, problems
}

// prompt is the skills section of the system prompt: what skills are for, and
// the names and descriptions of the ones the user kept on. With memory on, a
// loose preference still goes to memory.md rather than a skill.
func (s *skillSet) prompt(remembering bool) string {
	skills, _ := s.discover()
	var list strings.Builder
	listed := 0
	for _, item := range skills {
		if s.disabled[item.Name] {
			continue
		}
		fmt.Fprintf(&list, "\n- %s：%s", item.Name, item.Description)
		listed++
	}
	if listed == 0 {
		list.WriteString("（用户把技能都关了）")
	}
	prompt := skillsPrompt
	if remembering {
		prompt += "\n- 只是零散的偏好就记进记忆（edit_memory），不要为此建技能。"
	}
	return prompt + "\n\n可用技能：" + list.String()
}

// tool is load_skill, which returns a skill's body.
func (s *skillSet) tool() agent.AgentTool {
	str := func(description string) map[string]any {
		return map[string]any{"type": "string", "description": description}
	}
	return fileTool{name: "load_skill", title: "加载技能",
		description: "读取一份技能的完整正文，照着做。name 用「可用技能」清单里的名字。内置技能带附带文件时（结果里的 files），用 file 参数读其中一个；账本里的技能，其目录下的其他文件用 read_file 读。",
		parameters: objectParameters(map[string]any{
			"name": str("技能名，例如 alipay-bill-import"),
			"file": str("内置技能的附带文件，例如 columns.md；一般不用"),
		}, "name"),
		run: s.load}
}

func (s *skillSet) load(raw json.RawMessage) (any, error) {
	var input struct {
		Name string `json:"name"`
		File string `json:"file"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	name := strings.TrimSpace(input.Name)
	if name == "" {
		return nil, errors.New("name 是必填的，用「可用技能」清单里的名字")
	}
	if s.disabled[name] {
		return nil, fmt.Errorf("技能 %s 已被用户关闭，不要用它", name)
	}
	skills, problems := s.discover()
	for _, problem := range problems {
		// A broken skill has no name of its own, so it is matched by its file.
		if problem.Path == "skills/"+name+"/SKILL.md" {
			return nil, fmt.Errorf("技能 %s 读不了：%s", name, problem.Error)
		}
	}
	for _, item := range skills {
		if item.Name != name {
			continue
		}
		if file := strings.TrimSpace(input.File); file != "" {
			if item.Source != skillSourceBuiltin {
				return nil, fmt.Errorf("账本技能的附带文件用 read_file 读：%s", path.Join(path.Dir(item.Path), file))
			}
			content, err := readBuiltinSkillFile(item, file)
			if err != nil {
				return nil, err
			}
			return map[string]any{"name": item.Name, "source": item.Source, "file": file, "content": content}, nil
		}
		result := map[string]any{"name": item.Name, "description": item.Description, "source": item.Source,
			"path": item.Path, "content": item.Body}
		if len(item.Files) > 0 {
			result["files"] = item.Files
		}
		return result, nil
	}
	names := make([]string, 0, len(skills))
	for _, item := range skills {
		if !s.disabled[item.Name] {
			names = append(names, item.Name)
		}
	}
	if len(names) == 0 {
		return nil, fmt.Errorf("没有叫 %q 的技能，用户也没有打开任何技能", name)
	}
	return nil, fmt.Errorf("没有叫 %q 的技能；可用：%s", name, strings.Join(names, "、"))
}

// SkillCatalogJSON lists the skills for the app's 技能 page: the built-in ones
// and the ledger's own, with the body each one holds so the page can show it
// read-only. The page keeps the names the user turned off, so every skill is
// listed and the disabled ones are marked.
func SkillCatalogJSON(requestJSON string) string {
	type request struct {
		Version        int      `json:"version"`
		WorkspaceRoot  string   `json:"workspaceRoot"`
		DisabledSkills []string `json:"disabledSkills,omitempty"`
	}
	type entry struct {
		Name        string `json:"name"`
		Description string `json:"description"`
		Source      string `json:"source"`
		Path        string `json:"path"`
		Body        string `json:"body"`
		Disabled    bool   `json:"disabled,omitempty"`
	}
	var input request
	if err := json.Unmarshal([]byte(requestJSON), &input); err != nil {
		return encode(map[string]any{"version": 1, "ok": false, "error": "invalid skills request: " + err.Error()})
	}
	if input.Version != 1 {
		return encode(map[string]any{"version": 1, "ok": false, "error": "supported skills request version is 1"})
	}
	set, err := openSkills(input.WorkspaceRoot, nil, input.DisabledSkills)
	if err != nil {
		return encode(map[string]any{"version": 1, "ok": false, "error": err.Error()})
	}
	defer set.close()
	skills, problems := set.discover()
	entries := make([]entry, 0, len(skills))
	for _, item := range skills {
		entries = append(entries, entry{Name: item.Name, Description: item.Description, Source: item.Source,
			Path: item.Path, Body: item.Body, Disabled: set.disabled[item.Name]})
	}
	if problems == nil {
		problems = []skillProblem{}
	}
	return encode(map[string]any{"version": 1, "ok": true, "skills": entries, "problems": problems})
}

// ledgerSkills reads the SKILL.md files of the ledger's skills folder. A
// ledger without the folder simply has none.
func (s *skillSet) ledgerSkills() ([]skill, []skillProblem) {
	entries, err := fs.ReadDir(s.root.FS(), "skills")
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		return nil, []skillProblem{{Path: "skills", Error: err.Error()}}
	}
	var skills []skill
	var problems []skillProblem
	for _, entry := range entries {
		if !entry.IsDir() || skipSkillDir(entry.Name()) {
			continue
		}
		file := "skills/" + entry.Name() + "/SKILL.md"
		clean, err := workspacePath(file)
		if err != nil {
			problems = append(problems, skillProblem{Path: file, Error: err.Error()})
			continue
		}
		info, err := s.root.Stat(clean)
		if err != nil || !info.Mode().IsRegular() {
			problems = append(problems, skillProblem{Path: file, Error: "缺少 SKILL.md"})
			continue
		}
		if info.Size() > maxSkillBytes {
			problems = append(problems, skillProblem{Path: file, Error: fmt.Sprintf("正文最多 %d 字节，现在是 %d 字节", maxSkillBytes, info.Size())})
			continue
		}
		data, err := s.root.ReadFile(clean)
		if err != nil {
			problems = append(problems, skillProblem{Path: file, Error: err.Error()})
			continue
		}
		item, problem := buildSkill(file, string(data))
		if problem != nil {
			problems = append(problems, *problem)
			continue
		}
		item.Source, item.Path = skillSourceLedger, file
		skills = append(skills, item)
	}
	return skills, problems
}

// skipSkillDir leaves out folders that are not skills: hidden ones, and the
// "_" prefix that marks a partial.
func skipSkillDir(name string) bool {
	return name == "" || strings.HasPrefix(name, ".") || strings.HasPrefix(name, "_")
}

func readBuiltinSkills() ([]skill, []skillProblem) {
	entries, err := fs.ReadDir(builtinSkills, "skills")
	if err != nil {
		return nil, []skillProblem{{Path: "skills", Error: err.Error()}}
	}
	var skills []skill
	var problems []skillProblem
	for _, entry := range entries {
		if !entry.IsDir() || skipSkillDir(entry.Name()) {
			continue
		}
		dir := "skills/" + entry.Name()
		file := dir + "/SKILL.md"
		data, err := builtinSkills.ReadFile(file)
		if err != nil {
			problems = append(problems, skillProblem{Path: file, Error: "读不到 SKILL.md"})
			continue
		}
		item, problem := buildSkill(file, string(data))
		if problem != nil {
			problems = append(problems, *problem)
			continue
		}
		item.Source, item.Path = skillSourceBuiltin, file
		item.Files = builtinSkillFiles(dir)
		skills = append(skills, item)
	}
	return skills, problems
}

// builtinSkillFiles lists the files beside a built-in skill's SKILL.md, which
// load_skill reads for the model.
func builtinSkillFiles(dir string) []string {
	entries, err := fs.ReadDir(builtinSkills, dir)
	if err != nil {
		return nil
	}
	var files []string
	for _, entry := range entries {
		if entry.IsDir() || entry.Name() == "SKILL.md" || skipSkillDir(entry.Name()) {
			continue
		}
		files = append(files, entry.Name())
	}
	return files
}

func readBuiltinSkillFile(item skill, file string) (string, error) {
	file = strings.TrimSpace(strings.ReplaceAll(file, "\\", "/"))
	if !slices.Contains(item.Files, file) {
		if len(item.Files) == 0 {
			return "", fmt.Errorf("技能 %s 没有附带文件，正文已经在 load_skill 的结果里", item.Name)
		}
		return "", fmt.Errorf("技能 %s 没有 %s；附带文件有：%s", item.Name, file, strings.Join(item.Files, "、"))
	}
	data, err := builtinSkills.ReadFile(path.Dir(item.Path) + "/" + file)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

// buildSkill parses one SKILL.md and checks the limits the prompt relies on.
func buildSkill(where, content string) (skill, *skillProblem) {
	name, description, body, err := parseSkill(content)
	if err != nil {
		return skill{}, &skillProblem{Path: where, Error: err.Error()}
	}
	switch {
	case !skillNamePattern.MatchString(name):
		return skill{}, &skillProblem{Path: where, Error: fmt.Sprintf("name %q 要用 1–64 个小写字母、数字和连字符", name)}
	case description == "":
		return skill{}, &skillProblem{Path: where, Error: "缺少 description：写一句什么时候用这个技能"}
	case len(description) > maxSkillDescriptionBytes:
		return skill{}, &skillProblem{Path: where, Error: fmt.Sprintf("description 最多 %d 字节，现在是 %d 字节", maxSkillDescriptionBytes, len(description))}
	case body == "":
		return skill{}, &skillProblem{Path: where, Error: "正文是空的"}
	case len(body) > maxSkillBytes:
		return skill{}, &skillProblem{Path: where, Error: fmt.Sprintf("正文最多 %d 字节，现在是 %d 字节", maxSkillBytes, len(body))}
	}
	return skill{Name: name, Description: description, Body: body}, nil
}

// parseSkill reads the frontmatter of a SKILL.md and returns its name, its
// description and the body after the closing delimiter.
func parseSkill(content string) (name, description, body string, err error) {
	if !utf8.ValidString(content) {
		content = strings.ToValidUTF8(content, "")
	}
	content = strings.TrimPrefix(content, "\ufeff")
	content = strings.ReplaceAll(content, "\r\n", "\n")
	lines := strings.Split(content, "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return "", "", "", errors.New("缺少 frontmatter：文件开头要用 --- 包住 name 和 description")
	}
	end := -1
	for index := 1; index < len(lines); index++ {
		if trimmed := strings.TrimSpace(lines[index]); trimmed == "---" || trimmed == "..." {
			end = index
			break
		}
	}
	if end < 0 {
		return "", "", "", errors.New("frontmatter 没有结束的 ---")
	}
	fields := frontmatterFields(lines[1:end])
	return fields["name"], fields["description"], strings.TrimSpace(strings.Join(lines[end+1:], "\n")), nil
}

// frontmatterFields reads the scalar keys of a frontmatter block. It knows
// the shapes skills actually use — plain, quoted, and folded or literal
// blocks — without taking on a YAML parser for two fields, and it ignores
// every other key so a SKILL.md written for another agent still loads.
func frontmatterFields(lines []string) map[string]string {
	fields := map[string]string{}
	for index := 0; index < len(lines); index++ {
		line := lines[index]
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") || line != strings.TrimLeft(line, " \t") {
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		key = strings.ToLower(strings.TrimSpace(key))
		value = strings.TrimSpace(value)
		wanted := key == "name" || key == "description"
		switch value {
		case "", "|", ">", "|-", ">-", "|+", ">+":
			// A block value: everything after it that is indented or blank.
			var block []string
			for index+1 < len(lines) {
				next := lines[index+1]
				if strings.TrimSpace(next) != "" && next == strings.TrimLeft(next, " \t") {
					break
				}
				index++
				if text := strings.TrimSpace(next); text != "" {
					block = append(block, text)
				}
			}
			value = strings.Join(block, " ")
		default:
			value = unquoteYAML(value)
		}
		if _, seen := fields[key]; wanted && !seen {
			fields[key] = value
		}
	}
	return fields
}

// unquoteYAML drops the quotes around a scalar and a trailing comment after
// one, so hand-written frontmatter reads the same as the generator's.
func unquoteYAML(value string) string {
	if len(value) >= 2 {
		quote := value[0]
		if (quote == '"' || quote == '\'') && value[len(value)-1] == quote {
			inner := value[1 : len(value)-1]
			if quote == '"' {
				inner = strings.ReplaceAll(inner, `\"`, `"`)
				inner = strings.ReplaceAll(inner, `\\`, `\`)
			} else {
				inner = strings.ReplaceAll(inner, "''", "'")
			}
			return strings.TrimSpace(inner)
		}
	}
	if index := strings.Index(value, " #"); index >= 0 {
		value = value[:index]
	}
	return strings.TrimSpace(value)
}
