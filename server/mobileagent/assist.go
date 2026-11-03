package mobileagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

// The assist calls are small model requests without tools around a
// conversation: the questions the screen suggests before anything is asked,
// the likely next question after an answer, and a recap of a conversation.
// They use the user's model with thinking off and never touch the ledger
// files.

const (
	assistTimeout       = 75 * time.Second
	maxSuggestions      = 6
	maxSuggestionRunes  = 40
	maxRecapRunes       = 600
	maxAssistMessage    = 2000
	maxAssistTail       = 6
	maxRecapBytes       = 24000
	maxRecentQuestions  = 12
	defaultSuggestCount = 4
)

type assistRequestV1 struct {
	Version int `json:"version"`
	// The ledger to read facts from; optional. Only starter suggestions read
	// it.
	app.LocalRequest
	SensitiveUnlocked bool              `json:"sensitiveUnlocked"`
	Provider          string            `json:"provider"`
	Model             string            `json:"model"`
	APIKey            string            `json:"apiKey"`
	Custom            *customEndpointV1 `json:"custom,omitempty"`
	// MemoryPath is the ledger's memory.md, read but never written here.
	MemoryPath string `json:"memoryPath,omitempty"`
	// History is the visible conversation, oldest first. Suggestions with a
	// history predict the next question; without one they are starters.
	History []historyMessageV1 `json:"history,omitempty"`
	// Recent are questions asked lately in other conversations.
	Recent []string `json:"recent,omitempty"`
	Count  int      `json:"count,omitempty"`
}

type assistResponseV1 struct {
	Version     int      `json:"version"`
	OK          bool     `json:"ok"`
	Suggestions []string `json:"suggestions,omitempty"`
	Recap       string   `json:"recap,omitempty"`
	Error       string   `json:"error,omitempty"`
}

const starterPrompt = `你为一个记账 App 里的「账本助手」生成「试试」建议：用户点一下，建议就会原样作为用户的话发给助手。助手能查询、统计、搜索 Beancount 账本，也能改账（新增、改分类、批量整理），还能和上传的账单对账。

要求：
- 依据给出的账本概况、记忆和最近问过的问题，写出这位用户此刻最可能想问或想做的事。要具体：用账本里真实出现的分类、商户、账户和月份，不要编造没有的。
- 几条之间要有区别：比如一条看本月花销或异常、一条查某个商户或分类的明细、一条趋势或对比、一条整理或修改账目。记忆里提到的常做的事优先。
- 不要和最近问过的问题重复。
- 每条是用户口吻的一句中文，不超过 20 个字，不带编号和引号。
- 只输出一个 JSON 对象：{"suggestions":["…","…"]}`

const nextPrompt = `你在预测记账 App 里用户接下来最可能对「账本助手」说的一句话。App 会把它以浅色显示在输入框里，用户点发送就原样发出。

要求：
- 紧接着最后一条回答：如果助手在问问题或等确认，就写用户最自然的回答；否则写最可能的追问或下一步（细看某一项、换个时间范围、画图、把结论落实成改账等）。
- 改账的改动由用户在 App 的卡片上点按钮写入或放弃，不要预测「写入」「确认」「放弃」这类话。
- 参考记忆里的习惯。不要重复用户已经问过的话。
- 用户口吻的一句中文，不超过 25 个字，不带引号。
- 只输出一个 JSON 对象：{"suggestions":["最可能的一句","次可能的一句"]}`

const recapPrompt = `你为记账 App 里和「账本助手」的一段对话写回顾，放在对话最底下，让用户隔一段时间回来时马上想起做到哪了。

要求：
- 2 到 4 条要点，每条一行，以「- 」开头，总共不超过 150 个字。
- 依次覆盖（没有的就省略）：问了或做了什么；关键结论，带上关键数字；对账本做了什么改动、是否已经写入；还没做完的或建议的下一步。
- 只写对话里出现过的事实，不要编造。只输出要点本身。`

// SuggestJSON returns starter suggestions, or with a history, the likely
// next questions. The call blocks; the shell runs it off the main thread.
func SuggestJSON(requestJSON string) string {
	done := make(chan string, 1)
	go func() { done <- runAssist(requestJSON, suggest) }()
	return <-done
}

// RecapJSON returns a short recap of the conversation in history.
func RecapJSON(requestJSON string) string {
	done := make(chan string, 1)
	go func() { done <- runAssist(requestJSON, recap) }()
	return <-done
}

type assistKind int

const (
	suggest assistKind = iota
	recap
)

func runAssist(requestJSON string, kind assistKind) (responseJSON string) {
	defer func() {
		if recovered := recover(); recovered != nil {
			responseJSON = encode(assistResponseV1{Version: 1, Error: fmt.Sprint(recovered)})
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), assistTimeout)
	defer cancel()
	network := newTurnHTTP()
	defer network.close()
	response, err := assist(ctx, network, requestJSON, kind)
	if err != nil {
		return encode(assistResponseV1{Version: 1, Error: turnErrorText(ctx, network, err)})
	}
	response.Version, response.OK = 1, true
	return encode(response)
}

func assist(ctx context.Context, network *turnHTTP, requestJSON string, kind assistKind) (assistResponseV1, error) {
	decoder := json.NewDecoder(strings.NewReader(requestJSON))
	decoder.DisallowUnknownFields()
	var request assistRequestV1
	if err := decoder.Decode(&request); err != nil {
		return assistResponseV1{}, fmt.Errorf("invalid assist request: %w", err)
	}
	if request.Version != 1 {
		return assistResponseV1{}, errors.New("supported assist request version is 1")
	}
	captureCrashes(request.RuntimeRoot)
	model, assumed, err := requestModel(request.Provider, request.Model, request.Custom)
	if err != nil {
		return assistResponseV1{}, err
	}
	history := visibleHistory(request.History)
	var prompt, message string
	switch {
	case kind == recap:
		if len(history) == 0 {
			return assistResponseV1{}, errors.New("nothing to recap")
		}
		prompt, message = recapPrompt, recapMessage(history)
	case len(history) > 0:
		prompt, message = nextPrompt, nextMessage(history, memoryText(request.MemoryPath))
	default:
		facts := ""
		if request.WorkspaceRoot != "" {
			facts, err = ledgerFacts(request)
			if err != nil {
				return assistResponseV1{}, err
			}
		}
		prompt, message = starterPrompt, starterMessage(facts, memoryText(request.MemoryPath), request.Recent, request.Count)
	}
	reply, err := complete(ctx, network, model, assumed, request.APIKey, prompt, message)
	if err != nil {
		return assistResponseV1{}, err
	}
	if kind == recap {
		text := cleanRecap(reply)
		if text == "" {
			return assistResponseV1{}, errors.New("模型没有写出回顾")
		}
		return assistResponseV1{Recap: text}, nil
	}
	count := request.Count
	if count <= 0 {
		count = defaultSuggestCount
	}
	if len(history) > 0 {
		count = min(count, 3)
	}
	suggestions := parseSuggestions(reply, min(count, maxSuggestions), history)
	if len(suggestions) == 0 {
		return assistResponseV1{}, errors.New("模型没有给出建议")
	}
	return assistResponseV1{Suggestions: suggestions}, nil
}

// complete makes one request without tools and returns the text.
func complete(ctx context.Context, network *turnHTTP, model *ai.Model, assumed bool, key, prompt, message string) (string, error) {
	thinking, err := thinkingLevel(model, string(ai.ThinkingOff), assumed)
	if err != nil {
		return "", err
	}
	runner, err := agent.NewAgent(agent.AgentOptions{
		Model:         model,
		SystemPrompt:  prompt,
		MaxTurns:      1,
		ThinkingLevel: thinking,
		StreamFn: func(ctx context.Context, model *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
			if options.Fetch == nil {
				options.Fetch = network.client
			}
			delay := providerMaxRetryDelayMs
			return streamFn(ai.WithProviderRequestRetry(ctx, providerRetries, &delay), model, transcript, options)
		},
		GetAPIKey: func(string) (string, error) { return key, nil },
	})
	if err != nil {
		return "", err
	}
	produced, err := runner.Send(ctx, message)
	if err != nil {
		return "", err
	}
	return finalReply(produced)
}

// ledgerFacts reads the facts starters are drawn from, as compact JSON.
func ledgerFacts(request assistRequestV1) (string, error) {
	session, err := app.OpenLocalAgentSession(request.LocalRequest, request.SensitiveUnlocked)
	if err != nil {
		return "", err
	}
	facts, err := session.Facts(time.Now())
	if err != nil {
		return "", err
	}
	raw, err := json.Marshal(facts)
	return string(raw), err
}

// memoryText is memory.md, or empty when there is none.
func memoryText(path string) string {
	if path == "" {
		return ""
	}
	memory, err := openMemory(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(memory.snapshot())
}

func visibleHistory(history []historyMessageV1) []historyMessageV1 {
	kept := make([]historyMessageV1, 0, len(history))
	for _, entry := range history {
		content := strings.TrimSpace(entry.Content)
		if content == "" || (entry.Role != "user" && entry.Role != "assistant") {
			continue
		}
		kept = append(kept, historyMessageV1{Role: entry.Role, Content: content})
	}
	return kept
}

func starterMessage(facts, memory string, recent []string, count int) string {
	if count <= 0 {
		count = defaultSuggestCount
	}
	var out strings.Builder
	fmt.Fprintf(&out, "今天是 %s。请给出 %d 条建议。\n\n", time.Now().Format("2006-01-02"), min(count, maxSuggestions))
	if facts != "" {
		out.WriteString("账本概况（金额为元）：\n" + facts + "\n\n")
	}
	if memory != "" {
		out.WriteString("记忆：\n" + memory + "\n\n")
	}
	if len(recent) > 0 {
		out.WriteString("最近问过的问题：\n")
		for _, question := range recent[:min(len(recent), maxRecentQuestions)] {
			out.WriteString("- " + truncateRunes(oneLine(question), 80) + "\n")
		}
	}
	return out.String()
}

func nextMessage(history []historyMessageV1, memory string) string {
	var out strings.Builder
	if memory != "" {
		out.WriteString("记忆：\n" + memory + "\n\n")
	}
	out.WriteString("对话（最后几条）：\n")
	start := max(0, len(history)-maxAssistTail)
	for _, entry := range history[start:] {
		out.WriteString(roleLabel(entry.Role) + "：" + truncateRunes(entry.Content, maxAssistMessage) + "\n\n")
	}
	return out.String()
}

// recapMessage keeps the first question and as many of the latest messages
// as the budget allows.
func recapMessage(history []historyMessageV1) string {
	lines := make([]string, len(history))
	for index, entry := range history {
		lines[index] = roleLabel(entry.Role) + "：" + truncateRunes(entry.Content, maxAssistMessage)
	}
	kept, size := []string{}, len(lines[0])
	for index := len(lines) - 1; index > 0; index-- {
		if size+len(lines[index]) > maxRecapBytes {
			kept = append([]string{"……（中间省略）"}, kept...)
			break
		}
		size += len(lines[index])
		kept = append([]string{lines[index]}, kept...)
	}
	return "对话：\n\n" + strings.Join(append([]string{lines[0]}, kept...), "\n\n")
}

func roleLabel(role string) string {
	if role == "user" {
		return "用户"
	}
	return "助手"
}

var (
	fencePattern  = regexp.MustCompile("(?s)```(?:json)?\\s*(.*?)```")
	bulletPattern = regexp.MustCompile(`^(?:[-*•·]|\d+[.、)）])\s*`)
)

// parseSuggestions reads {"suggestions": [...]}, or failing that one
// suggestion per line, and keeps distinct short ones not already asked.
func parseSuggestions(reply string, count int, history []historyMessageV1) []string {
	text := strings.TrimSpace(reply)
	if match := fencePattern.FindStringSubmatch(text); match != nil {
		text = strings.TrimSpace(match[1])
	}
	var candidates []string
	if start, end := strings.Index(text, "{"), strings.LastIndex(text, "}"); start >= 0 && end > start {
		var parsed struct {
			Suggestions []string `json:"suggestions"`
		}
		if json.Unmarshal([]byte(text[start:end+1]), &parsed) == nil {
			candidates = parsed.Suggestions
		}
	}
	if candidates == nil {
		if start, end := strings.Index(text, "["), strings.LastIndex(text, "]"); start >= 0 && end > start {
			_ = json.Unmarshal([]byte(text[start:end+1]), &candidates)
		}
	}
	if candidates == nil {
		candidates = strings.Split(text, "\n")
	}
	asked := map[string]bool{}
	for _, entry := range history {
		if entry.Role == "user" {
			asked[normalized(entry.Content)] = true
		}
	}
	seen := map[string]bool{}
	out := []string{}
	for _, candidate := range candidates {
		candidate = strings.TrimSpace(bulletPattern.ReplaceAllString(oneLine(candidate), ""))
		candidate = strings.Trim(candidate, "\"'“”‘’「」 ")
		key := normalized(candidate)
		if candidate == "" || strings.ContainsAny(candidate, "{}[]") || utf8.RuneCountInString(candidate) > maxSuggestionRunes ||
			seen[key] || asked[key] {
			continue
		}
		seen[key] = true
		out = append(out, candidate)
		if len(out) == count {
			break
		}
	}
	return out
}

func cleanRecap(reply string) string {
	text := strings.TrimSpace(reply)
	if match := fencePattern.FindStringSubmatch(text); match != nil {
		text = strings.TrimSpace(match[1])
	}
	var lines []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if !strings.HasPrefix(line, "- ") {
			line = "- " + strings.TrimSpace(bulletPattern.ReplaceAllString(line, ""))
		}
		lines = append(lines, line)
	}
	return truncateRunes(strings.Join(lines, "\n"), maxRecapRunes)
}

func normalized(text string) string {
	return strings.Map(func(r rune) rune {
		if strings.ContainsRune(" \t\n？?。.!！，,", r) {
			return -1
		}
		return r
	}, strings.ToLower(text))
}

func oneLine(text string) string { return strings.Join(strings.Fields(text), " ") }

func truncateRunes(text string, limit int) string {
	if utf8.RuneCountInString(text) <= limit {
		return text
	}
	return string([]rune(text)[:limit]) + "…"
}
