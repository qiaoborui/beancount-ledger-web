package mobileagent

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// previewRunes bounds the start of a tool result the shell shows, and
// errorRunes the error a failed tool reports.
const (
	previewRunes = 300
	errorRunes   = 1000
)

// stepV1 is one thing the turn did, in order: a reasoning block, a piece of
// the reply, or a tool call.
type stepV1 struct {
	// Kind is "thinking", "text" or "tool".
	Kind string `json:"kind"`
	// Text is the reasoning or the reply; empty for redacted reasoning.
	Text string `json:"text,omitempty"`
	// DurationMs is how long the reasoning or the tool took.
	DurationMs int64           `json:"durationMs,omitempty"`
	Redacted   bool            `json:"redacted,omitempty"`
	CallID     string          `json:"callId,omitempty"`
	Name       string          `json:"name,omitempty"`
	Arguments  json.RawMessage `json:"arguments,omitempty"`
	IsError    bool            `json:"isError,omitempty"`
	Preview    string          `json:"preview,omitempty"`
	ErrorText  string          `json:"errorText,omitempty"`
}

// usageV1 is the tokens of a turn. Input, output and the cache counts add
// up every model message of the turn; ContextTokens is what the last one
// held in all, against the model's ContextWindow.
type usageV1 struct {
	Input         int `json:"input"`
	Output        int `json:"output"`
	CacheRead     int `json:"cacheRead"`
	CacheWrite    int `json:"cacheWrite"`
	ContextTokens int `json:"contextTokens"`
	ContextWindow int `json:"contextWindow"`
}

// turnRecord follows the lifecycle events of one turn's agent: it streams
// them to the observer and keeps the steps, usage and tool timings the
// response reports. The agent waits for each event, so nothing here blocks.
type turnRecord struct {
	feed *eventFeed

	mu       sync.Mutex
	steps    []stepV1
	usage    usageV1
	measured bool
	// thinking holds when each reasoning block of the streaming message
	// started and how long each took, by content index.
	thinkingStart map[int]time.Time
	thinkingTook  map[int]int64
	// tools maps a call id to its step.
	tools     map[string]int
	durations map[string]int64
}

func newTurnRecord(feed *eventFeed, contextWindow int) *turnRecord {
	return &turnRecord{feed: feed, usage: usageV1{ContextWindow: contextWindow},
		thinkingStart: map[int]time.Time{}, thinkingTook: map[int]int64{},
		tools: map[string]int{}, durations: map[string]int64{}}
}

// observe is the agent subscription.
func (r *turnRecord) observe(_ context.Context, event agent.AgentEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	switch event := event.(type) {
	case agent.MessageStartEvent:
		if event.Message.Assistant != nil {
			clear(r.thinkingStart)
			clear(r.thinkingTook)
		}
	case agent.MessageUpdateEvent:
		r.update(event.AssistantMessageEvent)
	case agent.MessageEndEvent:
		if assistant := event.Message.Assistant; assistant != nil {
			r.endMessage(assistant)
		}
	case agent.ToolExecutionEndEvent:
		r.endTool(event)
	}
	return nil
}

func (r *turnRecord) update(event ai.AssistantMessageEvent) {
	switch event := event.(type) {
	case ai.TextDeltaEvent:
		r.feed.send(turnEventV1{Kind: "text_delta", Text: event.Delta})
	case ai.ThinkingStartEvent:
		r.thinkingStart[event.ContentIndex] = time.Now()
	case ai.ThinkingDeltaEvent:
		r.feed.send(turnEventV1{Kind: "thinking_delta", Text: event.Delta})
	case ai.ThinkingEndEvent:
		var took int64
		if started, ok := r.thinkingStart[event.ContentIndex]; ok {
			took = time.Since(started).Milliseconds()
		}
		r.thinkingTook[event.ContentIndex] = took
		redacted := false
		if event.Partial != nil && event.ContentIndex < len(event.Partial.Content) {
			if block, ok := event.Partial.Content[event.ContentIndex].(ai.ThinkingContent); ok {
				redacted = block.Redacted
			}
		}
		r.feed.send(turnEventV1{Kind: "thinking_end", DurationMs: took, Redacted: redacted})
	}
}

// endMessage records a finished model message: its reasoning and text as
// steps, in the order written, and its tokens.
func (r *turnRecord) endMessage(assistant *agent.AssistantMessage) {
	for index, block := range assistant.Content {
		switch block := block.(type) {
		case ai.ThinkingContent:
			if block.Redacted {
				r.steps = append(r.steps, stepV1{Kind: "thinking", Redacted: true, DurationMs: r.thinkingTook[index]})
			} else if strings.TrimSpace(block.Thinking) != "" {
				r.steps = append(r.steps, stepV1{Kind: "thinking", Text: block.Thinking, DurationMs: r.thinkingTook[index]})
			}
		case ai.TextContent:
			if strings.TrimSpace(block.Text) != "" {
				r.steps = append(r.steps, stepV1{Kind: "text", Text: block.Text})
			}
		}
	}
	if usage := assistant.Usage; usage != nil {
		r.usage.Input += usage.Input
		r.usage.Output += usage.Output
		r.usage.CacheRead += usage.CacheRead
		r.usage.CacheWrite += usage.CacheWrite
		r.usage.ContextTokens = usage.Input + usage.CacheRead + usage.CacheWrite + usage.Output
	}
	r.measured = true
	usage := r.usage
	r.feed.send(turnEventV1{Kind: "usage", Usage: &usage})
}

// startTool records a call as it begins. An admitted call starts from the
// before-tool hook, right after its "tool" event; one refused before running
// starts when it ends.
func (r *turnRecord) startTool(callID, name string, arguments json.RawMessage) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.startToolLocked(callID, name, arguments)
}

func (r *turnRecord) startToolLocked(callID, name string, arguments json.RawMessage) {
	if _, started := r.tools[callID]; started {
		return
	}
	arguments = append(json.RawMessage(nil), arguments...)
	r.tools[callID] = len(r.steps)
	r.steps = append(r.steps, stepV1{Kind: "tool", CallID: callID, Name: name, Arguments: arguments})
	r.feed.send(turnEventV1{Kind: "tool_start", CallID: callID, Name: name, Arguments: arguments})
}

func (r *turnRecord) endTool(event agent.ToolExecutionEndEvent) {
	r.startToolLocked(event.ToolCallID, event.ToolName, nil)
	step := &r.steps[r.tools[event.ToolCallID]]
	text := toolResultText(event.Result.Content)
	step.IsError = event.IsError
	step.Preview = firstRunes(text, previewRunes)
	if event.IsError {
		step.ErrorText = firstRunes(strings.TrimSpace(text), errorRunes)
	}
	if event.DurationMs != nil {
		step.DurationMs = *event.DurationMs
		r.durations[event.ToolCallID] = *event.DurationMs
	}
	r.feed.send(turnEventV1{Kind: "tool_end", CallID: step.CallID, Name: step.Name, IsError: step.IsError,
		DurationMs: step.DurationMs, Preview: step.Preview, ErrorText: step.ErrorText})
}

// toolDuration is how long the call ran, zero when it did not.
func (r *turnRecord) toolDuration(callID string) int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.durations[callID]
}

// result is the steps and usage so far; usage is nil before any model
// message ended.
func (r *turnRecord) result() ([]stepV1, *usageV1) {
	r.mu.Lock()
	defer r.mu.Unlock()
	steps := append([]stepV1(nil), r.steps...)
	if !r.measured {
		return steps, nil
	}
	usage := r.usage
	return steps, &usage
}

func toolResultText(content []ai.ToolResultMessageContent) string {
	var parts []string
	for _, block := range content {
		if text, ok := block.(ai.TextContent); ok && text.Text != "" {
			parts = append(parts, text.Text)
		}
	}
	return strings.Join(parts, "\n")
}

// firstRunes keeps the first limit characters of text, without a mark.
func firstRunes(text string, limit int) string {
	count := 0
	for index := range text {
		if count == limit {
			return text[:index]
		}
		count++
	}
	return text
}
