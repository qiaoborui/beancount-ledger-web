package mobileagent

import (
	"strings"
	"sync"
	"testing"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// cancelOn stops turnID the first time the observer sees an event of kind.
func cancelOn(turnID, kind string) func(turnEventV1) {
	var once sync.Once
	return func(event turnEventV1) {
		if event.Kind == kind {
			once.Do(func() { CancelTurn(turnID) })
		}
	}
}

// followUp asks one more question after a stopped turn and returns what
// the model was sent.
func followUp(t *testing.T, transcript string) []ai.Message {
	t.Helper()
	var seen []ai.Message
	useFaux(t, ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		seen = request.Messages()
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("接着说。")}, StopReason: "stop"}.AssistantMessage(), nil
	}))
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t), "provider": "faux", "model": "faux-1",
		"transcript": transcript, "message": "继续"})
	if !response.OK || response.Reply != "接着说。" {
		t.Fatalf("follow-up after a stop failed: %+v", response)
	}
	return seen
}

func TestStopMidReplyKeepsWhatWasWritten(t *testing.T) {
	full := strings.Repeat("这一段回答会被中途停下来。", 20)
	observer := &streamObserver{react: cancelOn("turn-stop-text", "text_delta")}
	observe(t, observer)
	usePacedFaux(t, 100, ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText(full)}}))
	response := streamedTurn(t, "turn-stop-text", nil)
	if !response.Cancelled || response.OK || response.StopReason != "aborted" {
		t.Fatalf("stop was not reported: %+v", response)
	}
	if response.Reply == "" || len(response.Reply) >= len(full) || !strings.HasPrefix(full, response.Reply) {
		t.Fatalf("reply = %q", response.Reply)
	}
	if len(response.Steps) != 1 || response.Steps[0].Kind != "text" || response.Usage == nil {
		t.Fatalf("steps %+v usage %+v", response.Steps, response.Usage)
	}
	messages, err := decodeTranscript(response.Transcript)
	if err != nil {
		t.Fatalf("stopped transcript does not decode: %v", err)
	}
	last := messages[len(messages)-1].Assistant
	if last == nil || last.StopReason != ai.StopReasonStop || last.ErrorMessage != "" || len(last.Content) != 1 ||
		assistantText(last.Content) != response.Reply {
		t.Fatalf("transcript ends with %+v", messages[len(messages)-1])
	}
	seen := followUp(t, response.Transcript)
	if len(seen) < 3 {
		t.Fatalf("follow-up saw %d messages", len(seen))
	}
	if assistant, ok := seen[len(seen)-2].(ai.AssistantMessage); !ok || len(assistant.Content) != 1 {
		t.Fatalf("follow-up did not see the partial reply: %+v", seen[len(seen)-2])
	}
}

func TestStopDuringToolsAnswersEveryCall(t *testing.T) {
	observer := &streamObserver{react: cancelOn("turn-stop-tool", "tool_start")}
	observe(t, observer)
	// The answer streams slowly enough that the stop lands in the tools or
	// before the answer is done.
	usePacedFaux(t, 400,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxText("我查一下。"),
			ai.FauxToolCall("get_accounts", map[string]any{"activeOnly": true}, &ai.FauxToolCallOptions{ID: "c1"}),
			ai.FauxToolCall("get_accounts", map[string]any{}, &ai.FauxToolCallOptions{ID: "c2"}),
		}}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText(strings.Repeat("账户情况如下。", 200))}}),
	)
	response := streamedTurn(t, "turn-stop-tool", nil)
	if !response.Cancelled || response.StopReason != "aborted" || response.Reply == "" {
		t.Fatalf("stop was not reported: %+v", response)
	}
	messages, err := decodeTranscript(response.Transcript)
	if err != nil {
		t.Fatalf("stopped transcript does not decode: %v", err)
	}
	assertEveryCallAnswered(t, messages)
	followUp(t, response.Transcript)
}

func TestStopBeforeAnyReplyKeepsThePreviousTranscript(t *testing.T) {
	observer := &streamObserver{react: cancelOn("turn-stop-early", "model")}
	observe(t, observer)
	usePacedFaux(t, 2, ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("很慢的回答")}}))
	response := streamedTurn(t, "turn-stop-early", map[string]any{"history": []map[string]string{
		{"role": "user", "content": "上一问"}, {"role": "assistant", "content": "上一答"}}})
	if !response.Cancelled || response.Reply != "" || response.Transcript != "" {
		t.Fatalf("stop before any reply = %+v", response)
	}
}

func TestSanitizeAfterAbortClosesTheTurn(t *testing.T) {
	system := agent.AgentMessage{System: &ai.SystemMessage{Content: ai.SystemText("prompt")}}
	user := func(text string) agent.AgentMessage {
		return agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(text)}}
	}
	calls := agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant", StopReason: ai.StopReasonToolUse,
		Content: []ai.AssistantContentBlock{ai.TextContent{Text: "我查一下。"},
			ai.ToolCall{ID: "a", Name: "get_accounts"}, ai.ToolCall{ID: "b", Name: "get_accounts"}}}}
	result := agent.AgentMessage{ToolResult: &agent.ToolResultMessage{Role: "toolResult", ToolCallID: "a", ToolName: "get_accounts",
		Content: []ai.ToolResultMessageContent{ai.TextContent{Text: "ok"}}}}
	cut := agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant", StopReason: ai.StopReasonAborted,
		Content: []ai.AssistantContentBlock{ai.ThinkingContent{Thinking: "嗯"}, ai.TextContent{Text: "半句\uFFFD"},
			ai.ToolCall{ID: "c", Name: "get_accounts"}}}}
	empty := agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant", StopReason: ai.StopReasonAborted}}

	out := sanitizeAfterAbort([]agent.AgentMessage{system, user("q"), calls, result, cut}, 1)
	if len(out) != 6 {
		t.Fatalf("sanitized to %d messages", len(out))
	}
	stopped := out[4].ToolResult
	if stopped == nil || stopped.ToolCallID != "b" || !stopped.IsError || toolResultText(stopped.Content) != stoppedToolText {
		t.Fatalf("open call b got %+v", out[4])
	}
	if last := out[5].Assistant; last == nil || last.StopReason != ai.StopReasonStop || len(last.Content) != 1 ||
		assistantText(last.Content) != "半句" {
		t.Fatalf("partial message = %+v", out[5])
	}
	assertEveryCallAnswered(t, out)

	// A stop before the model said anything leaves no transcript, and a
	// nudge nobody answered does not stay at the end.
	if reply, transcript := stoppedTurn([]agent.AgentMessage{system, user("q"), empty}, 1); reply != "" || transcript != "" {
		t.Fatalf("stop before any reply = %q, %q", reply, transcript)
	}
	out = sanitizeAfterAbort([]agent.AgentMessage{system, user("q"), calls, result, user(nudgeEmptyReply), empty}, 1)
	if out[len(out)-1].User != nil {
		t.Fatalf("transcript ends with a question: %+v", out[len(out)-1])
	}
}
