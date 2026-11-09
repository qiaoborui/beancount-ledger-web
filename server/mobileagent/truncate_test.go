package mobileagent

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

func truncateFor(t *testing.T, request map[string]any) truncateResponseV1 {
	t.Helper()
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var response truncateResponseV1
	if err := json.Unmarshal([]byte(TruncateTranscriptJSON(string(raw))), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

// threeTurns is a transcript of three questions: the first answered after a
// tool call and an empty reply the loop nudged, the second carrying the
// shell's system note, the third answered after another tool call.
func threeTurns(t *testing.T) string {
	t.Helper()
	user := func(text string) agent.AgentMessage {
		return agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(text)}}
	}
	reply := func(text string) agent.AgentMessage {
		return agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant", StopReason: ai.StopReasonStop,
			Content: []ai.AssistantContentBlock{ai.TextContent{Text: text}}}}
	}
	call := func(id string) agent.AgentMessage {
		return agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant", StopReason: ai.StopReasonToolUse,
			Content: []ai.AssistantContentBlock{ai.ToolCall{ID: id, Name: "get_accounts"}}}}
	}
	result := func(id string) agent.AgentMessage {
		return agent.AgentMessage{ToolResult: &agent.ToolResultMessage{Role: "toolResult", ToolCallID: id, ToolName: "get_accounts",
			Content: []ai.ToolResultMessageContent{ai.TextContent{Text: "[]"}}}}
	}
	transcript, err := encodeTranscript([]agent.AgentMessage{
		{System: &ai.SystemMessage{Content: ai.SystemText("prompt")}},
		user("第一问"), call("c1"), result("c1"), reply(""), user(nudgeEmptyReply), reply("第一答"),
		user("（系统提示：用户刚改了账本。）\n\n第二问"), reply("第二答"),
		user("第三问"), call("c3"), result("c3"), reply("第三答"),
	})
	if err != nil {
		t.Fatal(err)
	}
	return transcript
}

func TestTruncateKeepsWholeUserTurns(t *testing.T) {
	transcript := threeTurns(t)
	for keep, wantLast := range map[int]string{1: "第一答", 2: "第二答"} {
		response := truncateFor(t, map[string]any{"version": 1, "transcript": transcript, "keepUserTurns": keep})
		if !response.OK || response.UserTurns != 3 {
			t.Fatalf("keep %d: %+v", keep, response)
		}
		messages, err := decodeTranscript(response.Transcript)
		if err != nil {
			t.Fatal(err)
		}
		last := messages[len(messages)-1].Assistant
		if last == nil || assistantText(last.Content) != wantLast {
			t.Fatalf("keep %d ends with %+v", keep, messages[len(messages)-1])
		}
		assertEveryCallAnswered(t, messages)
		turns := 0
		for _, message := range messages {
			if isUserTurn(message) {
				turns++
			}
		}
		if turns != keep {
			t.Fatalf("keep %d kept %d questions", keep, turns)
		}
	}
}

func TestTruncateHandlesTheEnds(t *testing.T) {
	transcript := threeTurns(t)
	for _, request := range []map[string]any{{"keepUserTurns": 3}, {"dropUserTurns": 0}} {
		request["version"], request["transcript"] = 1, transcript
		response := truncateFor(t, request)
		if !response.OK || response.Transcript != transcript || response.UserTurns != 3 {
			t.Fatalf("%v changed the transcript: %+v", request, response)
		}
	}
	for _, request := range []map[string]any{{"keepUserTurns": 0}, {"dropUserTurns": 3}} {
		request["version"], request["transcript"] = 1, transcript
		response := truncateFor(t, request)
		messages, err := decodeTranscript(response.Transcript)
		if !response.OK || err != nil || len(messages) != 1 || messages[0].System == nil {
			t.Fatalf("%v = %+v (%v)", request, response, err)
		}
	}
	// A cut past the recorded questions means the shell's count and the
	// transcript disagree; it fails instead of keeping the turn.
	for _, request := range []map[string]any{{"keepUserTurns": 4}, {"keepUserTurns": 100}, {"dropUserTurns": 4}} {
		request["version"], request["transcript"] = 1, transcript
		response := truncateFor(t, request)
		if response.OK || response.Error == "" || response.Transcript != "" || response.UserTurns != 3 {
			t.Fatalf("%v = %+v", request, response)
		}
	}
}

// Dropping counts from the end, so a transcript that lost its oldest turns
// still cuts at the question the shell meant.
func TestTruncateDropsFromTheEnd(t *testing.T) {
	full, err := decodeTranscript(threeTurns(t))
	if err != nil {
		t.Fatal(err)
	}
	second := 0
	for index, message := range full {
		if message.User != nil && strings.HasSuffix(userText(message.User.Content), "第二问") {
			second = index
		}
	}
	trimmed, err := encodeTranscript(append(full[:1:1], full[second:]...))
	if err != nil {
		t.Fatal(err)
	}
	response := truncateFor(t, map[string]any{"version": 1, "transcript": trimmed, "dropUserTurns": 1})
	if !response.OK || response.UserTurns != 2 {
		t.Fatalf("drop 1 = %+v", response)
	}
	messages, err := decodeTranscript(response.Transcript)
	if err != nil {
		t.Fatal(err)
	}
	if last := messages[len(messages)-1].Assistant; last == nil || assistantText(last.Content) != "第二答" {
		t.Fatalf("drop 1 ends with %+v", messages[len(messages)-1])
	}
}

func TestTruncateRejectsBadInput(t *testing.T) {
	for name, request := range map[string]string{
		"not JSON":       `{"version":1,`,
		"version":        `{"version":2,"transcript":"[]","keepUserTurns":1}`,
		"negative":       `{"version":1,"transcript":"[]","keepUserTurns":-1}`,
		"negative drop":  `{"version":1,"transcript":"[]","dropUserTurns":-1}`,
		"both":           `{"version":1,"transcript":"[]","keepUserTurns":0,"dropUserTurns":0}`,
		"neither":        `{"version":1,"transcript":"[]"}`,
		"transcript":     `{"version":1,"transcript":"[{","keepUserTurns":1}`,
		"foreign":        `{"version":1,"transcript":"[{\"role\":\"robot\"}]","keepUserTurns":1}`,
		"unknown fields": `{"version":1,"transcript":"[]","keep":1}`,
	} {
		var response truncateResponseV1
		if err := json.Unmarshal([]byte(TruncateTranscriptJSON(request)), &response); err != nil {
			t.Fatal(err)
		}
		if response.OK || response.Error == "" || response.Version != 1 {
			t.Fatalf("%s: %+v", name, response)
		}
	}
}

// A nudge the loop really sent, read back from a returned transcript, is not
// a question.
func TestTruncateSkipsARealNudge(t *testing.T) {
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("")}}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("两个账户。")}}),
	)
	turn := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "我有哪些账户？"})
	if !turn.OK || turn.Reply != "两个账户。" || !strings.Contains(turn.Transcript, "上一条回复没有任何文字") {
		t.Fatalf("turn failed: %+v", turn)
	}
	response := truncateFor(t, map[string]any{"version": 1, "transcript": turn.Transcript, "keepUserTurns": 1})
	if !response.OK || response.UserTurns != 1 || response.Transcript != turn.Transcript {
		t.Fatalf("nudge counted as a question: %+v", response)
	}
}

func assertEveryCallAnswered(t *testing.T, messages []agent.AgentMessage) {
	t.Helper()
	answered := map[string]bool{}
	for _, message := range messages {
		if message.ToolResult != nil {
			answered[message.ToolResult.ToolCallID] = true
		}
	}
	for _, message := range messages {
		if message.Assistant == nil {
			continue
		}
		for _, block := range message.Assistant.Content {
			if call, ok := block.(ai.ToolCall); ok && !answered[call.ID] {
				t.Fatalf("tool call %s has no result", call.ID)
			}
		}
	}
}
