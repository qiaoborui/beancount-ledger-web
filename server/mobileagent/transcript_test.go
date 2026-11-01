package mobileagent

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// A follow-up sees the previous turn's tool results, so it can answer from
// them without reading the ledger again, and the provider sees the same
// prefix it saw last turn.
func TestFollowUpReplaysTheWholeTranscript(t *testing.T) {
	var firstSeen, secondSeen []ai.Message
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxThinking("先查账户"),
			ai.FauxToolCall("get_accounts", map[string]any{"activeOnly": true}, &ai.FauxToolCallOptions{ID: "call_accounts"}),
		}}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			firstSeen = request.Messages()
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("你有 2 个启用账户。")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			secondSeen = request.Messages()
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("其中支出账户是 Expenses:Food。")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	root := committedWorkspace(t)
	first := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": root, "provider": "faux", "model": "faux-1",
		"conversationId": "c1", "message": "我有哪些账户？"})
	if !first.OK || first.Transcript == "" {
		t.Fatalf("first turn returned no transcript: %+v", first)
	}
	second := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": root, "provider": "faux", "model": "faux-1",
		"conversationId": "c1", "transcript": first.Transcript,
		// History is ignored when a transcript is present.
		"history": []map[string]string{{"role": "user", "content": "不该出现"}, {"role": "assistant", "content": "不该出现"}},
		"message": "支出账户是哪个？"})
	if !second.OK || second.Reply != "其中支出账户是 Expenses:Food。" || len(second.ToolCalls) != 0 {
		t.Fatalf("follow-up: %+v", second)
	}
	// Turn 1's last request is user, assistant(tool call), tool result; turn 2
	// starts with exactly that, then the answer and the new question.
	if len(secondSeen) != len(firstSeen)+2 {
		t.Fatalf("follow-up saw %d messages, first turn's last request had %d", len(secondSeen), len(firstSeen))
	}
	for index := range firstSeen {
		before, _ := json.Marshal(firstSeen[index])
		after, _ := json.Marshal(secondSeen[index])
		if string(before) != string(after) {
			t.Fatalf("message %d changed between turns:\n%s\n%s", index, before, after)
		}
	}
	sawResult := false
	for _, message := range secondSeen {
		if result, ok := message.(ai.ToolResultMessage); ok {
			raw, _ := json.Marshal(result)
			sawResult = sawResult || strings.Contains(string(raw), "Expenses:Food")
		}
	}
	if !sawResult {
		t.Fatal("follow-up did not see the earlier tool result")
	}
	for _, message := range secondSeen {
		raw, _ := json.Marshal(message)
		if strings.Contains(string(raw), "不该出现") {
			t.Fatal("history was replayed next to the transcript")
		}
	}
	if !strings.Contains(second.Transcript, "支出账户是哪个") || !strings.Contains(second.Transcript, "call_accounts") {
		t.Fatalf("second transcript lost a turn: %s", second.Transcript)
	}
}

func TestFailedTurnReturnsNoTranscript(t *testing.T) {
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{}, StopReason: "stop"}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{}, StopReason: "stop"}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "hi"})
	if response.OK || response.Transcript != "" {
		t.Fatalf("failed turn returned a transcript: %+v", response)
	}
}

func TestUnreadableTranscriptFallsBackToHistory(t *testing.T) {
	var seen []ai.Message
	useFaux(t, ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		seen = request.Messages()
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好")}, StopReason: "stop"}.AssistantMessage(), nil
	}))
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t), "provider": "faux", "model": "faux-1",
		"transcript": "{not json", "history": []map[string]string{{"role": "user", "content": "早先的问题"}, {"role": "assistant", "content": "早先的回答"}},
		"message": "接着说"})
	if !response.OK || len(seen) != 4 || seen[0].(ai.SystemMessage).Content == nil {
		t.Fatalf("history fallback: %d messages, %+v", len(seen), response)
	}
}

func TestTrimTranscriptDropsWholeOldTurns(t *testing.T) {
	text := func(role, value string) agent.AgentMessage {
		if role == "user" {
			return agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(value)}}
		}
		return agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant",
			Content: []ai.AssistantContentBlock{ai.TextContent{Text: value}}, StopReason: ai.StopReasonStop}}
	}
	long := strings.Repeat("账", 400)
	var messages []agent.AgentMessage
	for turn := range 10 {
		messages = append(messages, text("user", long+string(rune('a'+turn))), text("assistant", long))
	}
	if kept := trimTranscript(messages, 1<<20); len(kept) != len(messages) {
		t.Fatalf("a transcript within budget was trimmed to %d", len(kept))
	}
	size := func(messages []agent.AgentMessage) int { raw, _ := json.Marshal(messages); return len(raw) }
	budget := size(messages) / 2
	kept := trimTranscript(messages, budget)
	if len(kept) == 0 || len(kept)%2 != 0 || kept[0].User == nil || size(kept) > int(float64(budget)*transcriptKeep)+16 {
		t.Fatalf("trimmed to %d messages, %d bytes, budget %d", len(kept), size(kept), budget)
	}
	if last := kept[len(kept)-1]; last.Assistant == nil {
		t.Fatal("the newest turn was cut")
	}
}

func TestReplayedTranscriptGetsTodaysSystemPrompt(t *testing.T) {
	var prompt string
	step := func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		for _, message := range request.Messages() {
			if system, ok := message.(ai.SystemMessage); ok {
				if text, ok := system.Content.(ai.SystemText); ok && text != "" {
					prompt = string(text)
				}
			}
		}
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好")}, StopReason: "stop"}.AssistantMessage(), nil
	}
	useFaux(t, ai.FauxFactoryStep(step), ai.FauxFactoryStep(step))
	root := committedWorkspace(t)
	first := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": root, "provider": "faux", "model": "faux-1", "message": "一"})
	stale := strings.Replace(first.Transcript, "当前日期：", "当前日期：2020-01-01 旧", 1)
	second := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": root, "provider": "faux", "model": "faux-1", "message": "二", "transcript": stale})
	if !second.OK || strings.Contains(prompt, "旧") || !strings.Contains(prompt, "当前日期：") {
		t.Fatalf("stale system prompt replayed: %q", prompt)
	}
	if strings.Count(second.Transcript, `"role":"system"`) != 1 {
		t.Fatalf("tool declarations were repeated: %s", second.Transcript)
	}
}

func TestFollowUpReportsOnlyItsOwnToolCalls(t *testing.T) {
	call := func(id string) ai.FauxResponseStep {
		return ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("get_accounts", map[string]any{}, &ai.FauxToolCallOptions{ID: id}),
		}})
	}
	answer := ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好")}, StopReason: "stop"})
	useFaux(t, call("call_1"), answer, call("call_2"), answer)
	root := committedWorkspace(t)
	first := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": root, "provider": "faux", "model": "faux-1", "message": "一"})
	second := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": root, "provider": "faux", "model": "faux-1", "message": "二", "transcript": first.Transcript})
	if len(first.ToolCalls) != 1 || len(second.ToolCalls) != 1 {
		t.Fatalf("tool calls: first %d, second %d", len(first.ToolCalls), len(second.ToolCalls))
	}
}
