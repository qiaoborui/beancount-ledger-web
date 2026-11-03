package mobileagent

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

const (
	maxAskQuestionRunes = 300
	maxAskOptionRunes   = 60
	minAskOptions       = 2
	maxAskOptions       = 6
)

// askV1 is a question the model puts to the user as a card of choices. The
// turn ends with it; the user's pick comes back as the next message.
type askV1 struct {
	Question string   `json:"question"`
	Options  []string `json:"options"`
	// Multiple lets the user pick more than one option.
	Multiple bool `json:"multiple,omitempty"`
}

// askTool is ask_user. Its result asks the loop to stop after the current
// tool batch, so the turn ends on the question instead of spending another
// model call to say it again.
type askTool struct {
	mu    sync.Mutex
	asked *askV1
}

func (*askTool) Name() string  { return "ask_user" }
func (*askTool) Label() string { return "向用户提问" }
func (*askTool) Schema() ai.ToolSchema {
	return ai.ToolSchema{Name: "ask_user", Description: "需要用户做选择才能继续时（分类拿不准、两边金额对不上要保留哪边、几种改法选哪种），用它在 App 里展示一张选项卡，而不是在回复里用文字反问。调用后这一轮立即结束，用户的选择会作为下一条消息发来。只在确实需要用户决定时用；能从账本推断的不要问。",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"question": map[string]any{"type": "string", "description": "要问的问题，一句话，写清楚是哪笔交易或哪个账户"},
				"options": map[string]any{"type": "array", "minItems": minAskOptions, "maxItems": maxAskOptions,
					"items":       map[string]any{"type": "string"},
					"description": "2 到 6 个简短的选项，每个不超过 60 字；用户也可以不选而直接输入"},
				"multiple": map[string]any{"type": "boolean", "description": "允许多选"},
			},
			"required":             []string{"question", "options"},
			"additionalProperties": false,
		}}
}
func (*askTool) ExecutionMode() agent.ToolExecutionMode { return agent.ToolModeSequential }

func (t *askTool) Execute(_ context.Context, _ string, params json.RawMessage, _ agent.ToolUpdateCallback) (agent.AgentToolResult, error) {
	ask, err := parseAsk(params)
	if err != nil {
		return agent.AgentToolResult{}, err
	}
	t.mu.Lock()
	t.asked = &ask
	t.mu.Unlock()
	return agent.AgentToolResult{
		Content:   []ai.ToolResultMessageContent{ai.TextContent{Text: "选项卡已经展示给用户。这一轮到此结束，用户的选择会作为下一条消息发来。"}},
		Details:   map[string]any{},
		Terminate: true,
	}, nil
}

func (t *askTool) question() *askV1 {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.asked
}

func parseAsk(params json.RawMessage) (askV1, error) {
	var ask askV1
	if err := json.Unmarshal(params, &ask); err != nil {
		return ask, errors.New("ask_user 的参数无效")
	}
	ask.Question = strings.TrimSpace(ask.Question)
	if ask.Question == "" || utf8.RuneCountInString(ask.Question) > maxAskQuestionRunes {
		return ask, errors.New("question 不能为空，最多 300 字")
	}
	options := make([]string, 0, len(ask.Options))
	seen := map[string]bool{}
	for _, option := range ask.Options {
		option = strings.TrimSpace(option)
		if option == "" || seen[option] {
			continue
		}
		if utf8.RuneCountInString(option) > maxAskOptionRunes {
			return ask, errors.New("每个选项最多 60 字")
		}
		seen[option] = true
		options = append(options, option)
	}
	if len(options) < minAskOptions || len(options) > maxAskOptions {
		return ask, errors.New("options 需要 2 到 6 个互不相同的选项")
	}
	ask.Options = options
	return ask, nil
}

// endsOnAsk reports a run that the ask_user tool ended: its last message is
// that tool's result, with no assistant reply after it.
func endsOnAsk(messages []agent.AgentMessage) bool {
	if len(messages) == 0 {
		return false
	}
	last := messages[len(messages)-1].ToolResult
	return last != nil && last.ToolName == "ask_user" && !last.IsError
}

// closeAsk appends the question as the assistant's reply, so the transcript
// ends on an assistant turn like any answered one and the user's pick
// follows it as an ordinary question. It copies the model identity of the
// assistant message that asked, which providers use to replay it.
func closeAsk(messages []agent.AgentMessage, ask *askV1) []agent.AgentMessage {
	reply := agent.AssistantMessage{Role: "assistant", Content: []ai.AssistantContentBlock{ai.TextContent{Text: ask.Question}},
		StopReason: ai.StopReasonStop, Timestamp: time.Now().UnixMilli()}
	for index := len(messages) - 1; index >= 0; index-- {
		if asked := messages[index].Assistant; asked != nil {
			reply.API, reply.Provider, reply.ModelID = asked.API, asked.Provider, asked.ModelID
			break
		}
	}
	return append(messages, agent.AgentMessage{Assistant: &reply})
}
