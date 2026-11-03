package mobileagent

import (
	"testing"

	"github.com/MichaelKinsy/PiG/ai"
)

func TestAskUserEndsTheTurnOnTheQuestion(t *testing.T) {
	calls := 0
	useFaux(t,
		ai.FauxFactoryStep(func(ai.TranscriptContext, ai.StreamOptions, *ai.FauxProviderState, *ai.Model) (ai.AssistantMessage, error) {
			calls++
			return ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
				ai.FauxToolCall("ask_user", map[string]any{"question": "10-05 的 25 元归到哪？", "options": []any{"餐饮", "交通", " 餐饮 "}},
					&ai.FauxToolCallOptions{ID: "call_ask"}),
			}}.AssistantMessage(), nil
		}),
		ai.FauxFactoryStep(func(ai.TranscriptContext, ai.StreamOptions, *ai.FauxProviderState, *ai.Model) (ai.AssistantMessage, error) {
			calls++
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("不该再被调用")}}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "帮我分类"})
	if !response.OK || response.Reply != "10-05 的 25 元归到哪？" {
		t.Fatalf("unexpected response: %+v", response)
	}
	if calls != 1 {
		t.Fatalf("model called %d times, want 1", calls)
	}
	if response.Ask == nil || len(response.Ask.Options) != 2 || response.Ask.Options[0] != "餐饮" || response.Ask.Options[1] != "交通" {
		t.Fatalf("ask = %+v", response.Ask)
	}
	messages, err := decodeTranscript(response.Transcript)
	if err != nil {
		t.Fatal(err)
	}
	last := messages[len(messages)-1].Assistant
	if last == nil || assistantText(last.Content) != "10-05 的 25 元归到哪？" {
		t.Fatalf("transcript does not end on the question: %+v", messages[len(messages)-1])
	}
}

func TestAskUserRejectsTooFewOptions(t *testing.T) {
	if _, err := parseAsk([]byte(`{"question":"选哪个？","options":["A","A"]}`)); err == nil {
		t.Fatal("duplicate options accepted")
	}
	if _, err := parseAsk([]byte(`{"question":"","options":["A","B"]}`)); err == nil {
		t.Fatal("empty question accepted")
	}
}
