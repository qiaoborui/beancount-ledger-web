package mobileagent

import (
	"encoding/json"
	"sync"
	"testing"

	"github.com/MichaelKinsy/PiG/ai"
)

type recordingObserver struct {
	mu     sync.Mutex
	turns  []string
	events []turnEventV1
}

func (r *recordingObserver) Event(turnID, eventJSON string) {
	var event turnEventV1
	if err := json.Unmarshal([]byte(eventJSON), &event); err != nil {
		panic(err)
	}
	r.mu.Lock()
	r.turns = append(r.turns, turnID)
	r.events = append(r.events, event)
	r.mu.Unlock()
}

func TestRunTurnReportsEachStepBeforeReturning(t *testing.T) {
	observer := &recordingObserver{}
	SetObserver(observer)
	t.Cleanup(func() { SetObserver(nil) })
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("get_accounts", map[string]any{"activeOnly": true}, &ai.FauxToolCallOptions{ID: "call_accounts"}),
		}}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("两个账户。")}}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "turnId": "turn-1", "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "我有哪些账户？"})
	if !response.OK {
		t.Fatalf("turn failed: %+v", response)
	}
	observer.mu.Lock()
	defer observer.mu.Unlock()
	kinds := []string{}
	for index, event := range observer.events {
		if observer.turns[index] != "turn-1" || event.Version != 1 {
			t.Fatalf("event %d = %q %+v", index, observer.turns[index], event)
		}
		kinds = append(kinds, event.Kind+":"+event.Name)
	}
	if want := []string{"model:", "tool:get_accounts", "model:"}; len(kinds) != len(want) || kinds[0] != want[0] || kinds[1] != want[1] || kinds[2] != want[2] {
		t.Fatalf("events = %v, want %v", kinds, want)
	}
	if string(observer.events[1].Arguments) != `{"activeOnly":true}` {
		t.Fatalf("tool arguments = %s", observer.events[1].Arguments)
	}
}

func TestRunTurnWithoutIDReportsNothing(t *testing.T) {
	observer := &recordingObserver{}
	SetObserver(observer)
	t.Cleanup(func() { SetObserver(nil) })
	useFaux(t, ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("你好")}}))
	if response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "hi"}); !response.OK {
		t.Fatalf("turn failed: %+v", response)
	}
	if len(observer.events) != 0 {
		t.Fatalf("events without a turn id: %+v", observer.events)
	}
}
