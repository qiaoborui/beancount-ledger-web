package mobileagent

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/MichaelKinsy/PiG/agent"
)

const (
	// savedConversationDefault is how many conversations one listing returns by
	// default; savedConversationMax is its ceiling.
	savedConversationDefault = 8
	savedConversationMax     = 20
	savedMessageLimit        = 40
	savedMessageRunes        = 1200
	savedRecapRunes          = 160
	savedConversationDir     = "agent-history"
	// savedConversationScan bounds one listing to the newest conversations: a
	// phone should not parse the whole archive to answer one question.
	savedConversationScan = 60
)

// savedHistoryPrompt tells the model what the saved conversations are for. It sits
// before the memory prompt so memory.md stays the last, stable block.
const savedHistoryPrompt = `

历史对话：
- 除了本次对话，这台设备还保存着以前的对话。需要回忆以前的结论、用户提过的偏好或之前改过什么时，用 list_saved_conversations 查看，再用 read_saved_conversation 读细节。
- 只在确实需要时查。账本数据和金额一律重新查询或校验：历史对话里的旧结果、旧草稿都不算现在的事实，已写入的账目以账本为准。`

// savedConversationV1 is the shell's record of one conversation, saved at
// runtime/agent-history/<id>.json. Only what a recap needs is decoded: the
// record also carries attachments, unwritten drafts and write records that
// the model has no business reading back.
type savedConversationV1 struct {
	ID        string `json:"id"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
	Messages  []struct {
		Role string `json:"role"`
		Text string `json:"text"`
	} `json:"messages"`
}

// historyIndex reads the conversations the shell saved beside the ledger.
type historyIndex struct {
	dir     string
	current string
}

// openHistory locates the saved conversations of this ledger. A runtime
// directory without history simply offers nothing; a turn without a runtime
// root gets no history tools at all.
func openHistory(runtimeRoot, currentConversationID string) *historyIndex {
	root := strings.TrimSpace(runtimeRoot)
	if root == "" || !filepath.IsAbs(root) {
		return nil
	}
	return &historyIndex{dir: filepath.Join(root, savedConversationDir), current: strings.TrimSpace(currentConversationID)}
}

// conversationID reports whether name is one saved conversation's UUID.
func conversationID(name string) bool {
	if len(name) != 36 {
		return false
	}
	for index, char := range name {
		switch index {
		case 8, 13, 18, 23:
			if char != '-' {
				return false
			}
		default:
			isHex := (char >= '0' && char <= '9') || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')
			if !isHex {
				return false
			}
		}
	}
	return true
}

// savedConversationFile is one record on disk, before it is parsed.
type savedConversationFile struct {
	id       string
	path     string
	modified time.Time
}

// files lists the saved conversations of this ledger, newest first by file
// time, without the conversation being answered. Unreadable entries are
// skipped: a conversation the app could not write is not worth failing a turn
// over.
func (h *historyIndex) files() []savedConversationFile {
	entries, err := os.ReadDir(h.dir)
	if err != nil {
		return nil
	}
	files := make([]savedConversationFile, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if !entry.Type().IsRegular() || !strings.HasSuffix(name, ".json") {
			continue
		}
		id := strings.TrimSuffix(name, ".json")
		if !conversationID(id) || strings.EqualFold(id, h.current) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		files = append(files, savedConversationFile{id: id, path: filepath.Join(h.dir, name), modified: info.ModTime()})
	}
	sort.SliceStable(files, func(left, right int) bool {
		return files[left].modified.After(files[right].modified)
	})
	return files
}

// load decodes one saved conversation; a record from an older build that
// cannot be decoded is skipped like a missing one.
func loadConversation(file savedConversationFile) (savedConversationV1, bool) {
	data, err := os.ReadFile(file.path)
	if err != nil {
		return savedConversationV1{}, false
	}
	var conversation savedConversationV1
	if json.Unmarshal(data, &conversation) != nil {
		return savedConversationV1{}, false
	}
	if len(conversation.Messages) == 0 {
		return savedConversationV1{}, false
	}
	if conversation.ID == "" {
		conversation.ID = file.id
	}
	return conversation, true
}

// historyTime parses the record's ISO 8601 timestamp; an unparsable one sorts
// as the oldest rather than dropping the conversation.
func historyTime(value string) time.Time {
	parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(value))
	if err != nil {
		return time.Time{}
	}
	return parsed
}

// question and answer are the first question and the last reply, one line each.
func conversationQuestion(conversation savedConversationV1) string {
	for _, message := range conversation.Messages {
		if message.Role == "user" {
			if text := clipHistoryLine(message.Text, savedRecapRunes); text != "" {
				return text
			}
		}
	}
	return ""
}

func conversationAnswer(conversation savedConversationV1) string {
	for index := len(conversation.Messages) - 1; index >= 0; index-- {
		message := conversation.Messages[index]
		if message.Role == "assistant" {
			if text := clipHistoryLine(message.Text, savedRecapRunes); text != "" {
				return text
			}
		}
	}
	return ""
}

func conversationTurns(conversation savedConversationV1) int {
	turns := 0
	for _, message := range conversation.Messages {
		if message.Role == "user" {
			turns++
		}
	}
	return turns
}

// clipHistoryLine collapses a message to one line for a listing.
func clipHistoryLine(value string, limit int) string {
	text := strings.Join(strings.Fields(value), " ")
	if utf8.RuneCountInString(text) <= limit {
		return text
	}
	runes := []rune(text)
	return strings.TrimSpace(string(runes[:limit])) + "…"
}

// clipHistoryMessage keeps the line breaks of a message: an earlier reply may
// carry a draft the user wants to see as they saw it.
func clipHistoryMessage(value string, limit int) string {
	text := strings.TrimSpace(value)
	if utf8.RuneCountInString(text) <= limit {
		return text
	}
	runes := []rune(text)
	return strings.TrimSpace(string(runes[:limit])) + "…"
}

// toolLimit bounds one tool's limit argument.
func toolLimit(value, fallback, ceiling int) int {
	if value <= 0 {
		return fallback
	}
	if value > ceiling {
		return ceiling
	}
	return value
}

func (h *historyIndex) list(raw json.RawMessage) (any, error) {
	var input struct {
		Limit int    `json:"limit"`
		Query string `json:"query"`
	}
	if len(strings.TrimSpace(string(raw))) > 0 {
		if err := json.Unmarshal(raw, &input); err != nil {
			return nil, err
		}
	}
	limit := toolLimit(input.Limit, savedConversationDefault, savedConversationMax)
	needle := strings.ToLower(strings.TrimSpace(input.Query))
	type summary struct {
		Conversation  string `json:"conversation"`
		UpdatedAt     string `json:"updatedAt"`
		CreatedAt     string `json:"createdAt"`
		Turns         int    `json:"turns"`
		FirstQuestion string `json:"firstQuestion"`
		LastAnswer    string `json:"lastAnswer"`
	}
	// Newest by file time first: enough history to answer, not the whole
	// archive, so a keyword search on a phone stays a few dozen files.
	files := h.files()
	if len(files) > savedConversationScan {
		files = files[:savedConversationScan]
	}
	matched := make([]summary, 0, limit)
	for _, file := range files {
		conversation, ok := loadConversation(file)
		if !ok {
			continue
		}
		question := conversationQuestion(conversation)
		answer := conversationAnswer(conversation)
		if needle != "" && !strings.Contains(strings.ToLower(question+" "+answer), needle) {
			continue
		}
		matched = append(matched, summary{
			Conversation:  conversation.ID,
			CreatedAt:     conversation.CreatedAt,
			UpdatedAt:     conversation.UpdatedAt,
			Turns:         conversationTurns(conversation),
			FirstQuestion: question,
			LastAnswer:    answer,
		})
	}
	sort.SliceStable(matched, func(left, right int) bool {
		return historyTime(matched[left].UpdatedAt).After(historyTime(matched[right].UpdatedAt))
	})
	total := len(matched)
	if len(matched) > limit {
		matched = matched[:limit]
	}
	return map[string]any{"conversations": matched, "count": len(matched), "total": total}, nil
}

func (h *historyIndex) read(raw json.RawMessage) (any, error) {
	var input struct {
		Conversation string `json:"conversation"`
		Limit        int    `json:"limit"`
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	id := strings.TrimSpace(input.Conversation)
	if !conversationID(id) {
		return nil, errors.New("未知的对话 id，请先调用 list_saved_conversations 获取")
	}
	if strings.EqualFold(id, h.current) {
		return nil, errors.New("这是本次对话，前面的内容已经在上下文里")
	}
	data, err := os.ReadFile(filepath.Join(h.dir, id+".json"))
	if err != nil {
		return nil, fmt.Errorf("读取历史对话失败：%w", err)
	}
	var conversation savedConversationV1
	if err := json.Unmarshal(data, &conversation); err != nil {
		return nil, errors.New("这条历史对话记录无法解析")
	}
	limit := toolLimit(input.Limit, savedMessageLimit, savedMessageLimit)
	messages := make([]map[string]string, 0, limit)
	for _, message := range conversation.Messages {
		if message.Role != "user" && message.Role != "assistant" {
			continue
		}
		text := clipHistoryMessage(message.Text, savedMessageRunes)
		if text == "" {
			continue
		}
		messages = append(messages, map[string]string{"role": message.Role, "content": text})
	}
	if len(messages) == 0 {
		return nil, errors.New("这条历史对话没有可读取的消息")
	}
	if len(messages) > limit {
		messages = messages[len(messages)-limit:]
	}
	return map[string]any{
		"conversation": conversation.ID,
		"updatedAt":    conversation.UpdatedAt,
		"messages":     messages,
	}, nil
}

// tools are the read-only history tools; they touch no ledger and no draft.
func (h *historyIndex) tools() []agent.AgentTool {
	stringParameter := func(description string) map[string]any {
		return map[string]any{"type": "string", "description": description}
	}
	integerParameter := func(description string, minimum, maximum int) map[string]any {
		return map[string]any{"type": "integer", "description": description, "minimum": minimum, "maximum": maximum}
	}
	return []agent.AgentTool{
		fileTool{name: "list_saved_conversations", title: "查看历史对话",
			description: "列出本机保存的其他对话（不含当前这次），按最后更新时间从新到旧。每条给出 conversation id、起止时间、轮次和截断后的首个提问与最后一条回复。用户提到之前聊过的内容、需要回忆旧结论时用它，然后可以用 read_saved_conversation 读细节。",
			parameters: objectParameters(map[string]any{
				"limit": integerParameter(fmt.Sprintf("返回多少条，默认 %d", savedConversationDefault), 1, savedConversationMax),
				"query": stringParameter("可选关键词，只在首个提问和最后一条回复里匹配"),
			}),
			run: h.list},
		fileTool{name: "read_saved_conversation", title: "读取历史对话",
			description: "按 conversation id 读取一段历史对话的消息。只用于回忆上下文：账本数据和金额仍要重新查询，历史里的旧草稿不等于已经写入。",
			parameters: objectParameters(map[string]any{
				"conversation": stringParameter("list_saved_conversations 返回的 conversation id，原样传回"),
				"limit":        integerParameter(fmt.Sprintf("读取最近多少条消息，默认 %d", savedMessageLimit), 1, savedMessageLimit),
			}, "conversation"),
			run: h.read},
	}
}
