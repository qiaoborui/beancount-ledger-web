package mobileagent

import (
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// transcriptBudget bounds the replayed transcript, in encoded bytes. A
// transcript past it drops its oldest turns down to transcriptKeep of the
// budget, so a trim happens once every several turns and the prompt cache
// keeps its prefix in between.
const (
	transcriptBudget = 320_000
	transcriptKeep   = 0.6
)

func encodeTranscript(messages []agent.AgentMessage) (string, error) {
	raw, err := json.Marshal(stripImages(messages))
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func decodeTranscript(text string) ([]agent.AgentMessage, error) {
	var messages []agent.AgentMessage
	if err := json.Unmarshal([]byte(text), &messages); err != nil {
		return nil, err
	}
	for _, message := range messages {
		if message.System == nil && message.User == nil && message.Assistant == nil && message.ToolResult == nil {
			return nil, errors.New("transcript holds a message the on-device Agent never writes")
		}
	}
	return messages, nil
}

// withSystemPrompt puts today's prompt in the transcript's system message.
// PiG sends the transcript's own system message, not the option, so a
// conversation continued on a later day would otherwise keep the old date.
// The prompt changes only with the date or the edit mode, so on most turns
// this changes nothing and the cached prefix stays.
func withSystemPrompt(messages []agent.AgentMessage, prompt string) []agent.AgentMessage {
	out := make([]agent.AgentMessage, 0, len(messages))
	for _, message := range messages {
		if message.System != nil {
			system := *message.System
			if text, ok := system.Content.(ai.SystemText); !ok || string(text) != "" {
				system.Content = ai.SystemText(prompt)
			}
			message = agent.AgentMessage{System: &system}
		}
		out = append(out, message)
	}
	return out
}

// messageSizes is the encoded size of each message and of all of them, as
// the byte budget counts it; ok is false when a message does not encode.
func messageSizes(messages []agent.AgentMessage) (sizes []int, total int, ok bool) {
	sizes = make([]int, len(messages))
	for index, message := range messages {
		raw, err := json.Marshal(message)
		if err != nil {
			return nil, 0, false
		}
		sizes[index] = len(raw)
		total += len(raw)
	}
	return sizes, total, true
}

// trimTranscript drops whole turns from the front, each starting at a user
// message, until the rest fits. It never returns a transcript that starts
// with a model message or a tool result.
func trimTranscript(messages []agent.AgentMessage, budget int) []agent.AgentMessage {
	sizes, total, ok := messageSizes(messages)
	if !ok {
		return nil
	}
	if total <= budget {
		return messages
	}
	target := int(float64(budget) * transcriptKeep)
	// The system message that opens the transcript carries the tool
	// declarations and stays, and so does the summary of a compaction after
	// it, which stands for turns already gone; everything after them goes
	// turn by turn.
	head := 0
	for head < len(messages) && messages[head].System != nil {
		head++
	}
	head = compactionEnd(messages, head)
	start := head
	for start < len(messages) && total > target {
		total -= sizes[start]
		start++
		for start < len(messages) && messages[start].User == nil {
			total -= sizes[start]
			start++
		}
	}
	return append(slices.Clone(messages[:head]), messages[start:]...)
}

// stoppedToolText is the result of a tool call a stopped turn left without
// one: providers refuse a tool call that has no result.
const stoppedToolText = "用户停止了这一轮，工具没有执行完"

// stoppedTurn is what a turn the user stopped leaves: the text of the last
// model message, as the reply, and the transcript so far, closed so the next
// question can follow it. start is where the turn's messages begin. A
// request the stop cut off before it wrote a word does not count as the
// last message. The transcript is empty when the model had said nothing
// yet; the shell then keeps the previous one, as after a failure.
func stoppedTurn(messages []agent.AgentMessage, start int) (reply, transcript string) {
	start = min(start, len(messages))
	sanitized := sanitizeAfterAbort(messages, start)
	if assistant := lastAssistant(sanitized[min(start, len(sanitized)):]); assistant != nil {
		reply = partialText(assistant)
	}
	if len(sanitized) <= start {
		return reply, ""
	}
	transcript, err := encodeTranscript(sanitized)
	if err != nil {
		return reply, ""
	}
	return reply, transcript
}

// partialText is the text of a message, cut where the stream stopped, which
// may be inside a character.
func partialText(assistant *agent.AssistantMessage) string {
	return strings.TrimSpace(strings.TrimRight(strings.ToValidUTF8(assistantText(assistant.Content), ""), "\uFFFD"))
}

// sanitizeAfterAbort makes the transcript of a stopped turn one a provider
// accepts. The message the stop cut off keeps only its text, or goes when
// it has none; a tool call left without a result gets one saying the user
// stopped it; and the questions of the turn nothing answered are dropped
// from the end, so the next question does not follow another one.
func sanitizeAfterAbort(messages []agent.AgentMessage, start int) []agent.AgentMessage {
	out := make([]agent.AgentMessage, 0, len(messages)+2)
	for index := 0; index < len(messages); index++ {
		message := messages[index]
		assistant := message.Assistant
		if assistant == nil {
			out = append(out, message)
			continue
		}
		if assistant.ErrorMessage != "" || assistant.StopReason == ai.StopReasonAborted || assistant.StopReason == ai.StopReasonError {
			// What a cut-off call asked for may be incomplete and never ran:
			// only the text stays.
			if text := partialText(assistant); text != "" {
				out = append(out, agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant",
					Content: []ai.AssistantContentBlock{ai.TextContent{Text: text}}, StopReason: ai.StopReasonStop,
					Timestamp: assistant.Timestamp, API: assistant.API, Provider: assistant.Provider, ModelID: assistant.ModelID}})
			}
			continue
		}
		out = append(out, message)
		var calls []ai.ToolCall
		for _, block := range assistant.Content {
			if call, ok := block.(ai.ToolCall); ok {
				calls = append(calls, call)
			}
		}
		if len(calls) == 0 {
			continue
		}
		answered := map[string]bool{}
		for index+1 < len(messages) && messages[index+1].ToolResult != nil {
			index++
			answered[messages[index].ToolResult.ToolCallID] = true
			out = append(out, messages[index])
		}
		for _, call := range calls {
			if !answered[call.ID] {
				out = append(out, agent.AgentMessage{ToolResult: &agent.ToolResultMessage{Role: "toolResult", ToolCallID: call.ID,
					ToolName: call.Name, Content: []ai.ToolResultMessageContent{ai.TextContent{Text: stoppedToolText}},
					IsError: true, Timestamp: time.Now().UnixMilli()}})
			}
		}
	}
	for len(out) > start && out[len(out)-1].User != nil {
		out = out[:len(out)-1]
	}
	return out
}
