package mobileagent

import (
	"encoding/json"
	"errors"
	"slices"

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
	raw, err := json.Marshal(messages)
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

// trimTranscript drops whole turns from the front, each starting at a user
// message, until the rest fits. It never returns a transcript that starts
// with a model message or a tool result.
func trimTranscript(messages []agent.AgentMessage, budget int) []agent.AgentMessage {
	sizes := make([]int, len(messages))
	total := 0
	for index, message := range messages {
		raw, err := json.Marshal(message)
		if err != nil {
			return nil
		}
		sizes[index] = len(raw)
		total += len(raw)
	}
	if total <= budget {
		return messages
	}
	target := int(float64(budget) * transcriptKeep)
	// The system message that opens the transcript carries the tool
	// declarations and stays; everything after it goes turn by turn.
	head := 0
	for head < len(messages) && messages[head].System != nil {
		head++
	}
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
