package mobileagent

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// streamObserver records every event; delay slows each delivery down, and
// react sees each event as it arrives.
type streamObserver struct {
	mu     sync.Mutex
	events []turnEventV1
	delay  time.Duration
	react  func(turnEventV1)
}

func (s *streamObserver) Event(_, eventJSON string) {
	var event turnEventV1
	if err := json.Unmarshal([]byte(eventJSON), &event); err != nil {
		panic(err)
	}
	if !utf8.ValidString(event.Text) {
		panic("event text is not valid UTF-8")
	}
	if s.delay > 0 {
		time.Sleep(s.delay)
	}
	s.mu.Lock()
	s.events = append(s.events, event)
	s.mu.Unlock()
	if s.react != nil {
		s.react(event)
	}
}

func (s *streamObserver) recorded() []turnEventV1 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.events)
}

// kinds lists the event kinds with each run of one delta kind as one entry.
func kinds(events []turnEventV1) []string {
	var out []string
	for _, event := range events {
		if len(out) > 0 && isDelta(event.Kind) && out[len(out)-1] == event.Kind {
			continue
		}
		out = append(out, event.Kind)
	}
	return out
}

func joinedText(events []turnEventV1, kind string) string {
	var text strings.Builder
	for _, event := range events {
		if event.Kind == kind {
			text.WriteString(event.Text)
		}
	}
	return text.String()
}

func observe(t *testing.T, observer Observer) {
	t.Helper()
	SetObserver(observer)
	t.Cleanup(func() { SetObserver(nil) })
}

// usePacedFaux is useFaux with a provider that streams one token at a time
// at tokensPerSecond, so a test can act in the middle of a reply.
func usePacedFaux(t *testing.T, tokensPerSecond int, steps ...ai.FauxResponseStep) {
	t.Helper()
	one := 1
	provider := ai.NewFauxProvider(ai.FauxConfig{TokensPerSecond: tokensPerSecond, TokenSize: &ai.FauxTokenSize{Min: &one, Max: &one}})
	provider.SetResponses(steps)
	model := &ai.Model{ID: "faux-1", Provider: provider, ProviderMeta: ai.ProviderMetadata{API: "faux", ProviderID: "faux"}}
	previousStream, previousResolve := streamFn, resolveModel
	streamFn = func(ctx context.Context, model *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
		return model.Provider.Stream(ctx, transcript, options)
	}
	resolveModel = func(string, string) *ai.Model { return model }
	t.Cleanup(func() { streamFn, resolveModel = previousStream, previousResolve })
}

func streamedTurn(t *testing.T, turnID string, extra map[string]any) turnResponseV1 {
	t.Helper()
	request := map[string]any{"version": 1, "turnId": turnID, "streamEvents": true, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "我有哪些账户？"}
	for key, value := range extra {
		request[key] = value
	}
	return runTurnFor(t, request)
}

func toolThenAnswer() []ai.FauxResponseStep {
	return []ai.FauxResponseStep{
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxThinking("先想想要查哪些账户。"), ai.FauxText("我查一下。"),
			ai.FauxToolCall("get_accounts", map[string]any{"activeOnly": true}, &ai.FauxToolCallOptions{ID: "call_accounts"}),
		}}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("你有两个启用账户。")}}),
	}
}

func TestStreamedTurnReportsEventsInOrder(t *testing.T) {
	observer := &streamObserver{}
	observe(t, observer)
	useFaux(t, toolThenAnswer()...)
	response := streamedTurn(t, "turn-stream", nil)
	if !response.OK || response.Reply != "你有两个启用账户。" {
		t.Fatalf("turn failed: %+v", response)
	}
	events := observer.recorded()
	// PiG reports a message's usage when it ends, so the first message's
	// usage comes before its tool call.
	want := []string{"model", "thinking_delta", "thinking_end", "text_delta", "usage", "tool", "tool_start", "tool_end",
		"model", "text_delta", "usage"}
	if got := kinds(events); !slices.Equal(got, want) {
		t.Fatalf("events = %v, want %v", got, want)
	}
	if text := joinedText(events, "thinking_delta"); text != "先想想要查哪些账户。" {
		t.Fatalf("thinking = %q", text)
	}
	if text := joinedText(events, "text_delta"); text != "我查一下。你有两个启用账户。" {
		t.Fatalf("text = %q", text)
	}
	for _, event := range events {
		switch event.Kind {
		case "tool_start":
			if event.CallID != "call_accounts" || event.Name != "get_accounts" || string(event.Arguments) != `{"activeOnly":true}` {
				t.Fatalf("tool_start = %+v", event)
			}
		case "tool_end":
			if event.CallID != "call_accounts" || event.IsError || !strings.Contains(event.Preview, "Assets:Cash") {
				t.Fatalf("tool_end = %+v", event)
			}
		}
	}
	last := events[len(events)-1]
	if last.Usage == nil || response.Usage == nil || *last.Usage != *response.Usage {
		t.Fatalf("last usage event %+v, response usage %+v", last.Usage, response.Usage)
	}

	stepKinds := []string{}
	for _, step := range response.Steps {
		stepKinds = append(stepKinds, step.Kind)
	}
	if !slices.Equal(stepKinds, []string{"thinking", "text", "tool", "text"}) {
		t.Fatalf("steps = %+v", response.Steps)
	}
	if step := response.Steps[1]; step.Text != "我查一下。" {
		t.Fatalf("text before the tool call = %+v", step)
	}
	if step := response.Steps[2]; step.CallID != "call_accounts" || step.Name != "get_accounts" || step.Preview == "" {
		t.Fatalf("tool step = %+v", step)
	}
	if len(response.ToolCalls) != 1 || response.ToolCalls[0].CallID != "call_accounts" || response.ToolCalls[0].Preview == "" {
		t.Fatalf("tool calls = %+v", response.ToolCalls)
	}
}

func TestToolPreviewIsTheFirstCharacters(t *testing.T) {
	text := strings.Repeat("账", previewRunes+20)
	if got := firstRunes(text, previewRunes); utf8.RuneCountInString(got) != previewRunes || !strings.HasPrefix(text, got) {
		t.Fatalf("preview has %d characters", utf8.RuneCountInString(got))
	}
	if got := firstRunes("短", previewRunes); got != "短" {
		t.Fatalf("short preview = %q", got)
	}
}

func TestFeedJoinsDeltas(t *testing.T) {
	observer := &streamObserver{}
	observe(t, observer)
	feed := openEventFeed("turn-feed", true)
	want := ""
	for index := range 100 {
		letter := string(rune('a' + index%26))
		want += letter
		feed.send(turnEventV1{Kind: "text_delta", Text: letter})
	}
	feed.send(turnEventV1{Kind: "tool", Name: "get_accounts"})
	feed.send(turnEventV1{Kind: "thinking_delta", Text: "再"})
	feed.send(turnEventV1{Kind: "thinking_delta", Text: "想"})
	feed.close()
	events := observer.recorded()
	if len(events) >= 100 {
		t.Fatalf("100 deltas arrived as %d events", len(events))
	}
	if got := kinds(events); !slices.Equal(got, []string{"text_delta", "tool", "thinking_delta"}) {
		t.Fatalf("events = %v", got)
	}
	if text := joinedText(events, "text_delta"); text != want {
		t.Fatalf("text = %q, want %q", text, want)
	}
	if text := joinedText(events, "thinking_delta"); text != "再想" {
		t.Fatalf("thinking = %q", text)
	}
}

func TestFeedNeverCutsACharacter(t *testing.T) {
	observer := &streamObserver{}
	observe(t, observer)
	feed := openEventFeed("turn-bytes", true)
	// Byte by byte, well past the size that sends a delta on its own: the
	// observer panics on a delta that is not valid text.
	want := strings.Repeat("账本助手", 100)
	for index := range len(want) {
		feed.send(turnEventV1{Kind: "text_delta", Text: want[index : index+1]})
	}
	feed.close()
	events := observer.recorded()
	if len(events) < 2 {
		t.Fatalf("%d bytes arrived as %d events; the size limit never sent one", len(want), len(events))
	}
	if text := joinedText(events, "text_delta"); text != want {
		t.Fatalf("text lost bytes: %d of %d", len(text), len(want))
	}
	if complete, rest := splitIncompleteRune("账" + "本"[:2]); complete != "账" || rest != "本"[:2] {
		t.Fatalf("split = %q %q", complete, rest)
	}
}

func TestSlowObserverGetsEveryToolEvent(t *testing.T) {
	observer := &streamObserver{delay: 20 * time.Millisecond}
	observe(t, observer)
	first, last := "我分三次查一下账户和余额。", strings.Repeat("两个启用账户，余额都在。", 8)
	usePacedFaux(t, 2000,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxText(first),
			ai.FauxToolCall("get_accounts", map[string]any{"activeOnly": true}, &ai.FauxToolCallOptions{ID: "c1"}),
			ai.FauxToolCall("get_accounts", map[string]any{"activeOnly": false}, &ai.FauxToolCallOptions{ID: "c2"}),
			ai.FauxToolCall("get_accounts", map[string]any{}, &ai.FauxToolCallOptions{ID: "c3"}),
		}}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText(last)}}),
	)
	response := streamedTurn(t, "turn-slow", nil)
	if !response.OK {
		t.Fatalf("turn failed: %+v", response)
	}
	events := observer.recorded()
	starts, ends := map[string]int{}, map[string]int{}
	for _, event := range events {
		switch event.Kind {
		case "tool_start":
			starts[event.CallID]++
		case "tool_end":
			ends[event.CallID]++
		}
	}
	for _, id := range []string{"c1", "c2", "c3"} {
		if starts[id] != 1 || ends[id] != 1 {
			t.Fatalf("call %s: %d starts, %d ends; events %v", id, starts[id], ends[id], kinds(events))
		}
	}
	if text := joinedText(events, "text_delta"); text != first+last {
		t.Fatalf("text = %q", text)
	}
}

func TestUsageAddsUpTheTurn(t *testing.T) {
	useFaux(t, toolThenAnswer()...)
	response := streamedTurn(t, "", nil)
	if !response.OK || response.Usage == nil {
		t.Fatalf("turn failed: %+v", response)
	}
	messages, err := decodeTranscript(response.Transcript)
	if err != nil {
		t.Fatal(err)
	}
	var want usageV1
	for _, message := range messages {
		if usage := assistantUsage(message); usage != nil {
			want.Input += usage.Input
			want.Output += usage.Output
			want.CacheRead += usage.CacheRead
			want.CacheWrite += usage.CacheWrite
			want.ContextTokens = usage.Input + usage.Output + usage.CacheRead + usage.CacheWrite
		}
	}
	if want.Input == 0 || *response.Usage != want {
		t.Fatalf("usage = %+v, want %+v", *response.Usage, want)
	}
}

func assistantUsage(message agent.AgentMessage) *ai.Usage {
	if message.Assistant == nil {
		return nil
	}
	return message.Assistant.Usage
}

func TestUsageReportsTheModelsContextWindow(t *testing.T) {
	models := ai.GetBuiltinModels("anthropic")
	if len(models) == 0 {
		t.Skip("no built-in Anthropic model")
	}
	builtin := *models[0]
	provider := ai.NewFauxProvider(ai.FauxConfig{})
	provider.SetResponses([]ai.FauxResponseStep{ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("你好")}})})
	previousStream, previousResolve := streamFn, resolveModel
	streamFn = func(ctx context.Context, _ *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
		return provider.Stream(ctx, transcript, options)
	}
	resolveModel = func(string, string) *ai.Model { return &builtin }
	t.Cleanup(func() { streamFn, resolveModel = previousStream, previousResolve })
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "anthropic", "model": builtin.ID, "apiKey": "test", "message": "hi"})
	if !response.OK || response.Usage == nil {
		t.Fatalf("turn failed: %+v", response)
	}
	if response.Usage.ContextWindow == 0 || response.Usage.ContextWindow != builtin.Capabilities.ContextWindow {
		t.Fatalf("context window = %d, model has %d", response.Usage.ContextWindow, builtin.Capabilities.ContextWindow)
	}
}

// A window from the provider's list replaces the model's for the turn, also
// for a model nobody describes, and leaves the shared catalog model as it was.
func TestUsageReportsTheListedContextWindow(t *testing.T) {
	models := ai.GetBuiltinModels("anthropic")
	if len(models) == 0 {
		t.Skip("no built-in Anthropic model")
	}
	builtin := models[0]
	catalogWindow := builtin.Capabilities.ContextWindow
	previousStream, previousResolve := streamFn, resolveModel
	streamFn = func(ctx context.Context, _ *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
		provider := ai.NewFauxProvider(ai.FauxConfig{})
		provider.SetResponses([]ai.FauxResponseStep{ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("你好")}})})
		return provider.Stream(ctx, transcript, options)
	}
	resolveModel = func(string, string) *ai.Model { return builtin }
	t.Cleanup(func() { streamFn, resolveModel = previousStream, previousResolve })
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "anthropic", "model": builtin.ID, "apiKey": "test", "message": "hi", "contextWindow": 1_000_000})
	if !response.OK || response.Usage == nil || response.Usage.ContextWindow != 1_000_000 {
		t.Fatalf("turn = %+v", response)
	}
	if builtin.Capabilities.ContextWindow != catalogWindow {
		t.Fatalf("catalog model changed to %d", builtin.Capabilities.ContextWindow)
	}

	resolveModel = func(string, string) *ai.Model { return nil }
	response = runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "anthropic", "model": "claude-next-9", "apiKey": "test", "message": "hi", "contextWindow": 400_000})
	if !response.OK || response.Usage == nil || response.Usage.ContextWindow != 400_000 {
		t.Fatalf("assumed turn = %+v", response)
	}

	response = runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "anthropic", "model": builtin.ID, "apiKey": "test", "message": "hi", "contextWindow": -1})
	if response.OK {
		t.Fatalf("negative window accepted: %+v", response)
	}
}

// A call refused before it runs still reports the arguments the model gave,
// in its step and its tool_start, as its toolCalls entry does.
func TestRefusedCallKeepsItsArguments(t *testing.T) {
	observer := &streamObserver{}
	observe(t, observer)
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("delete_ledger", map[string]any{"path": "main.bean"}, &ai.FauxToolCallOptions{ID: "call_refused"}),
		}}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("这个工具不能用。")}}),
	)
	response := streamedTurn(t, "turn-refused", nil)
	if !response.OK {
		t.Fatalf("turn failed: %+v", response)
	}
	const want = `{"path":"main.bean"}`
	var step *stepV1
	for index := range response.Steps {
		if response.Steps[index].CallID == "call_refused" {
			step = &response.Steps[index]
		}
	}
	if step == nil || !step.IsError || string(step.Arguments) != want {
		t.Fatalf("refused step = %+v", step)
	}
	if len(response.ToolCalls) != 1 || string(response.ToolCalls[0].Arguments) != want {
		t.Fatalf("tool calls = %+v", response.ToolCalls)
	}
	started := false
	for _, event := range observer.recorded() {
		if event.Kind == "tool_start" && event.CallID == "call_refused" {
			started = string(event.Arguments) == want
		}
	}
	if !started {
		t.Fatalf("tool_start lost the arguments: %v", observer.recorded())
	}
}

// A message stopped before the provider reported usage carries zeros; the
// context stays what the last measured message held.
func TestStoppedMessageKeepsTheContextTokens(t *testing.T) {
	record := newTurnRecord(nil, 200000)
	end := func(reason ai.StopReason, usage ai.Usage) {
		_ = record.observe(context.Background(), agent.MessageEndEvent{Message: agent.AgentMessage{Assistant: &agent.AssistantMessage{
			Role: "assistant", StopReason: reason, Usage: &usage}}})
	}
	end(ai.StopReasonToolUse, ai.Usage{Input: 1600, Output: 20, CacheRead: 12})
	end(ai.StopReasonAborted, ai.Usage{})
	_, usage := record.result()
	if usage == nil || usage.ContextTokens != 1632 || usage.Input != 1600 || usage.ContextWindow != 200000 {
		t.Fatalf("usage = %+v", usage)
	}
}

// A custom endpoint's model takes the window and reply limit its list gave
// (issue #663); without them it keeps the common ones, and a catalog model
// keeps its own reply limit.
func TestCustomEndpointUsesTheListedLimits(t *testing.T) {
	var seen ai.ModelCapabilities
	previousStream := streamFn
	streamFn = func(ctx context.Context, model *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
		seen = model.Capabilities
		provider := ai.NewFauxProvider(ai.FauxConfig{})
		provider.SetResponses([]ai.FauxResponseStep{ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("你好")}})})
		return provider.Stream(ctx, transcript, options)
	}
	t.Cleanup(func() { streamFn = previousStream })
	custom := map[string]string{"api": "openai-completions", "baseURL": "https://gateway.example/v1"}
	turn := func(extra map[string]any) turnResponseV1 {
		request := map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t), "provider": "custom",
			"model": "antigravity/gemini-3.8-flash-tiered", "custom": custom, "apiKey": "test", "message": "hi"}
		for key, value := range extra {
			request[key] = value
		}
		return runTurnFor(t, request)
	}

	response := turn(map[string]any{"contextWindow": 1_048_576, "maxOutputTokens": 65_536})
	if !response.OK || response.Usage == nil || response.Usage.ContextWindow != 1_048_576 {
		t.Fatalf("listed turn = %+v", response)
	}
	if seen.ContextWindow != 1_048_576 || seen.MaxOutputTokens != 65_536 {
		t.Fatalf("model capabilities = %+v", seen)
	}

	response = turn(nil)
	if !response.OK || response.Usage == nil || response.Usage.ContextWindow != assumedContextWindow || seen.MaxOutputTokens != 8192 {
		t.Fatalf("unlisted turn = %+v, capabilities %+v", response, seen)
	}

	// A reply limit beyond the window is cut to it.
	if response = turn(map[string]any{"contextWindow": 32_768, "maxOutputTokens": 65_536}); !response.OK || seen.MaxOutputTokens != 32_768 {
		t.Fatalf("clamped turn = %+v, capabilities %+v", response, seen)
	}
	if response = turn(map[string]any{"maxOutputTokens": -1}); response.OK {
		t.Fatalf("negative reply limit accepted: %+v", response)
	}

	models := ai.GetBuiltinModels("anthropic")
	if len(models) == 0 {
		return
	}
	builtin := models[0]
	previousResolve := resolveModel
	resolveModel = func(string, string) *ai.Model { return builtin }
	t.Cleanup(func() { resolveModel = previousResolve })
	response = runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "anthropic", "model": builtin.ID, "apiKey": "test", "message": "hi", "maxOutputTokens": 1})
	if !response.OK || seen.MaxOutputTokens != builtin.Capabilities.MaxOutputTokens || seen.ContextWindow != builtin.Capabilities.ContextWindow {
		t.Fatalf("catalog turn = %+v, capabilities %+v, catalog %+v", response, seen, builtin.Capabilities)
	}
}
