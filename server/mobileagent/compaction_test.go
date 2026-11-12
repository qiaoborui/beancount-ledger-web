package mobileagent

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

const testContextWindow = 200_000

// conversation builds a transcript of turns questions "问题N", each answered
// "回答N". Turns listed in withTools first call get_accounts, with a result
// of resultBytes. The last answer carries usage, when given.
func conversation(turns int, usage *ai.Usage, resultBytes int, withTools ...int) []agent.AgentMessage {
	messages := []agent.AgentMessage{{System: &ai.SystemMessage{Content: ai.SystemText("prompt")}}}
	for turn := 1; turn <= turns; turn++ {
		messages = append(messages, agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(fmt.Sprintf("问题%d", turn))}})
		if slices.Contains(withTools, turn) {
			id := fmt.Sprintf("call_%d", turn)
			messages = append(messages,
				agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant", StopReason: ai.StopReasonToolUse,
					Content: []ai.AssistantContentBlock{ai.TextContent{Text: "我查一下。"}, ai.ToolCall{ID: id, Name: "get_accounts",
						Arguments: ai.JsonObject{"activeOnly": true}}}}},
				agent.AgentMessage{ToolResult: &agent.ToolResultMessage{Role: "toolResult", ToolCallID: id, ToolName: "get_accounts",
					Content: []ai.ToolResultMessageContent{ai.TextContent{Text: fmt.Sprintf("结果%d", turn) + strings.Repeat("账", resultBytes/3)}}}})
		}
		messages = append(messages, agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant", StopReason: ai.StopReasonStop,
			Content: []ai.AssistantContentBlock{ai.TextContent{Text: fmt.Sprintf("回答%d", turn)}}}})
	}
	if usage != nil {
		messages[len(messages)-1].Assistant.Usage = usage
	}
	return messages
}

func encoded(t *testing.T, messages []agent.AgentMessage) string {
	t.Helper()
	transcript, err := encodeTranscript(messages)
	if err != nil {
		t.Fatal(err)
	}
	return transcript
}

// usageAt is usage that fills share of the test context window.
func usageAt(share float64) *ai.Usage {
	held := int(testContextWindow * share)
	return &ai.Usage{Input: held / 2, CacheRead: held - held/2 - 1000, CacheWrite: 500, Output: 500}
}

// compactionProvider records each request, split into summary requests
// (no tools) and turn requests.
type compactionProvider struct {
	mu       sync.Mutex
	summary  []ai.TranscriptContext
	main     []ai.TranscriptContext
	requests []string
}

func (p *compactionProvider) summaries() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.summary)
}

func (p *compactionProvider) turns() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.main)
}

// useCompactionFaux scripts a provider with the test context window:
// summarize answers the summary requests, and turn requests get "好的".
func useCompactionFaux(t *testing.T, summarize func() ai.FauxResponse) *compactionProvider {
	t.Helper()
	recorder := &compactionProvider{}
	step := ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		recorder.mu.Lock()
		defer recorder.mu.Unlock()
		if len(offeredTools(request)) == 0 {
			recorder.summary = append(recorder.summary, request)
			recorder.requests = append(recorder.requests, "summary")
			return summarize().AssistantMessage(), nil
		}
		recorder.main = append(recorder.main, request)
		recorder.requests = append(recorder.requests, "turn")
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好的")}, StopReason: "stop",
			Usage: ai.Usage{Input: 20_000, Output: 10}}.AssistantMessage(), nil
	})
	steps := make([]ai.FauxResponseStep, 8)
	for index := range steps {
		steps[index] = step
	}
	provider := ai.NewFauxProvider(ai.FauxConfig{})
	provider.SetResponses(steps)
	model := &ai.Model{ID: "faux-1", Provider: provider, ProviderMeta: ai.ProviderMetadata{API: "faux", ProviderID: "faux"},
		Capabilities: ai.ModelCapabilities{ContextWindow: testContextWindow}}
	previousStream, previousResolve := streamFn, resolveModel
	streamFn = func(ctx context.Context, model *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
		return model.Provider.Stream(ctx, transcript, options)
	}
	resolveModel = func(string, string) *ai.Model { return model }
	t.Cleanup(func() { streamFn, resolveModel = previousStream, previousResolve })
	return recorder
}

func summaryText() ai.FauxResponse {
	return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("- 用户在核对 1 到 4 月的餐饮支出，合计 1820 元（需重新查询）。")}, StopReason: "stop"}
}

func compactionTurn(t *testing.T, turnID, transcript string) turnResponseV1 {
	t.Helper()
	return runTurnFor(t, map[string]any{"version": 1, "turnId": turnID, "streamEvents": true, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "transcript": transcript, "message": "新问题"})
}

// requestTexts lists the messages of a request other than system messages,
// as "user:…", "assistant:…" or "tool:…".
func requestTexts(request ai.TranscriptContext) []string {
	var out []string
	for _, message := range request.Messages() {
		switch message := message.(type) {
		case ai.UserMessage:
			out = append(out, "user:"+userText(message.Content))
		case ai.AssistantMessage:
			out = append(out, "assistant:"+assistantText(message.Content))
		case ai.ToolResultMessage:
			out = append(out, "tool:"+message.ToolCallID)
		}
	}
	return out
}

// cutOf is compactionCut with the messages' own sizes.
func cutOf(t *testing.T, messages []agent.AgentMessage) (head, cut, turns int, ok bool) {
	t.Helper()
	sizes, _, encodes := messageSizes(messages)
	if !encodes {
		t.Fatal("messages do not encode")
	}
	return compactionCut(messages, sizes)
}

var compactionModel = &ai.Model{ID: "faux-1", ProviderMeta: ai.ProviderMetadata{API: "faux", ProviderID: "faux"}}

func eventIndex(events []turnEventV1, kind string) int {
	return slices.IndexFunc(events, func(event turnEventV1) bool { return event.Kind == kind })
}

func TestCompactionSummarizesOlderTurns(t *testing.T) {
	observer := &streamObserver{}
	observe(t, observer)
	provider := useCompactionFaux(t, summaryText)
	transcript := encoded(t, conversation(8, usageAt(0.8), 0, 2, 6))
	response := compactionTurn(t, "turn-compact", transcript)
	if !response.OK || response.Reply != "好的" || !response.Compacted || response.CompactedTurns != 4 {
		t.Fatalf("compacted turn = %+v", response)
	}
	if !reflect.DeepEqual(provider.requests, []string{"summary", "turn"}) {
		t.Fatalf("requests = %v", provider.requests)
	}

	// The summary request: no tools, the summarizer's prompt and the four
	// older turns, the tool call of turn 2 included.
	summary := provider.summary[0]
	sent := transcriptText(t, summary)
	for _, want := range []string{"问题1", "问题4", "回答4", "get_accounts", "结果2", "重新查询账本"} {
		if !strings.Contains(sent, want) {
			t.Fatalf("summary request lacks %q:\n%s", want, sent)
		}
	}
	for _, unwanted := range []string{"问题5", "问题8", "新问题"} {
		if strings.Contains(sent, unwanted) {
			t.Fatalf("summary request holds %q:\n%s", unwanted, sent)
		}
	}

	// The turn request: system, the summary, the last four turns whole, and
	// the new question.
	texts := requestTexts(provider.main[0])
	if len(texts) < 2 || !strings.HasPrefix(texts[0], "user:"+compactionMarker) || !strings.Contains(texts[0], "1820 元") {
		t.Fatalf("turn request does not start with the summary: %v", texts)
	}
	want := []string{"assistant:" + compactionAck, "user:问题5", "assistant:回答5", "user:问题6", "assistant:我查一下。", "tool:call_6", "assistant:回答6",
		"user:问题7", "assistant:回答7", "user:问题8", "assistant:回答8", "user:新问题"}
	if !reflect.DeepEqual(texts[1:], want) {
		t.Fatalf("turn request = %v", texts)
	}
	if _, ok := provider.main[0].Messages()[0].(ai.SystemMessage); !ok {
		t.Fatal("turn request does not open with the system message")
	}

	events := observer.recorded()
	start, end, model := eventIndex(events, "compaction_start"), eventIndex(events, "compaction_end"), eventIndex(events, "model")
	if start < 0 || end <= start || model <= end || events[end].SummarizedTurns != 4 {
		t.Fatalf("events = %v (end %+v)", kinds(events), events[max(end, 0)])
	}

	messages, err := decodeTranscript(response.Transcript)
	if err != nil {
		t.Fatalf("compacted transcript does not decode: %v", err)
	}
	assertEveryCallAnswered(t, messages)
	if messages[0].System == nil || !isCompactionSummary(messages[1]) || !isCompactionAck(messages[2]) || isUserTurn(messages[2]) {
		t.Fatalf("transcript starts with %+v, %+v, %+v", messages[0], messages[1], messages[2])
	}
	questions := 0
	for _, message := range messages {
		if isUserTurn(message) {
			questions++
		}
	}
	if questions != 5 {
		t.Fatalf("compacted transcript holds %d questions", questions)
	}
}

func TestCompactionBelowThresholdKeepsThePrefix(t *testing.T) {
	observer := &streamObserver{}
	observe(t, observer)
	provider := useCompactionFaux(t, summaryText)
	messages := conversation(8, usageAt(0.7), 0, 2, 6)
	response := compactionTurn(t, "turn-below", encoded(t, messages))
	if !response.OK || response.Compacted || response.CompactedTurns != 0 || provider.summaries() != 0 || provider.turns() != 1 {
		t.Fatalf("below threshold: %+v, %d summaries", response, provider.summaries())
	}
	if eventIndex(observer.recorded(), "compaction_start") >= 0 {
		t.Fatalf("events = %v", kinds(observer.recorded()))
	}
	texts := requestTexts(provider.main[0])
	var want []string
	for _, message := range messages[1:] {
		switch {
		case message.User != nil:
			want = append(want, "user:"+userText(message.User.Content))
		case message.Assistant != nil:
			want = append(want, "assistant:"+assistantText(message.Assistant.Content))
		case message.ToolResult != nil:
			want = append(want, "tool:"+message.ToolResult.ToolCallID)
		}
	}
	if !reflect.DeepEqual(texts, append(want, "user:新问题")) {
		t.Fatalf("turn request = %v", texts)
	}

	// The compactor hands back the very messages it was given.
	given := withSystemPrompt(messages, "prompt")
	kept, turns, err := compactor{model: &ai.Model{Capabilities: ai.ModelCapabilities{ContextWindow: testContextWindow}}}.compact(context.Background(), given)
	if err != nil || turns != 0 || len(kept) != len(given) || &kept[0] != &given[0] {
		t.Fatalf("below threshold the messages changed: %d turns, %v", turns, err)
	}
}

func TestCompactionThresholdFromBytesWithoutUsage(t *testing.T) {
	// The last answer stopped before the provider reported usage.
	messages := conversation(8, &ai.Usage{}, 3000, 1, 2, 3, 4, 5, 6, 7, 8)
	raw, err := json.Marshal(messages)
	if err != nil {
		t.Fatal(err)
	}
	if estimate := contextEstimate(messages); estimate != len(raw)/3 {
		t.Fatalf("estimate = %d, transcript is %d bytes", estimate, len(raw))
	}
	if estimate := contextEstimate(conversation(8, usageAt(0.8), 3000, 1)); estimate != int(testContextWindow*0.8) {
		t.Fatalf("estimate from usage = %d", estimate)
	}
	if contextWindow(&ai.Model{}, false, 0) != assumedContextWindow ||
		contextWindow(&ai.Model{Capabilities: ai.ModelCapabilities{ContextWindow: 1_000_000}}, true, 0) != assumedContextWindow ||
		contextWindow(&ai.Model{Capabilities: ai.ModelCapabilities{ContextWindow: 1_000_000}}, true, 400_000) != 400_000 ||
		contextWindow(&ai.Model{Capabilities: ai.ModelCapabilities{ContextWindow: 200_000}}, false, 1_000_000) != 1_000_000 ||
		contextWindow(&ai.Model{Capabilities: ai.ModelCapabilities{ContextWindow: 1_000_000}}, false, 0) != 1_000_000 {
		t.Fatal("context window is not the model's, or the assumed one")
	}

	// A window the bytes fill to more than 75% compacts; one they fill to
	// half does not.
	estimate := contextEstimate(messages)
	summarized := 0
	summarize := func(window int) int {
		provider := ai.NewFauxProvider(ai.FauxConfig{})
		provider.SetResponses([]ai.FauxResponseStep{ai.FauxStaticStep(summaryText())})
		model := &ai.Model{ID: "faux-1", Provider: provider, ProviderMeta: ai.ProviderMetadata{API: "faux", ProviderID: "faux"},
			Capabilities: ai.ModelCapabilities{ContextWindow: window}}
		previous := streamFn
		streamFn = func(ctx context.Context, model *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
			summarized++
			return model.Provider.Stream(ctx, transcript, options)
		}
		defer func() { streamFn = previous }()
		network := newTurnHTTP()
		defer network.close()
		_, turns, err := compactor{network: network, model: model}.compact(context.Background(), messages)
		if err != nil {
			t.Fatal(err)
		}
		return turns
	}
	if turns := summarize(estimate * 2); turns != 0 || summarized != 0 {
		t.Fatalf("half full: %d turns, %d summaries", turns, summarized)
	}
	if turns := summarize(estimate * 5 / 4); turns != 4 || summarized != 1 {
		t.Fatalf("80%% full: %d turns, %d summaries", turns, summarized)
	}
}

func TestCompactionNeedsSixQuestions(t *testing.T) {
	provider := useCompactionFaux(t, summaryText)
	response := compactionTurn(t, "turn-five", encoded(t, conversation(5, usageAt(0.95), 0)))
	if !response.OK || response.Compacted || provider.summaries() != 0 {
		t.Fatalf("five questions were compacted: %+v", response)
	}

	// An earlier summary and the nudges are not questions.
	messages := conversation(5, usageAt(0.95), 0)
	messages = slices.Insert(messages, 1, agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(compactionMarker + "\n- 摘要")}})
	messages = slices.Insert(messages, 4, agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(nudgeEmptyReply)}},
		agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant", StopReason: ai.StopReasonStop,
			Content: []ai.AssistantContentBlock{ai.TextContent{Text: "补一句"}}}})
	if _, _, turns, ok := cutOf(t, messages); ok || turns != 0 {
		t.Fatalf("a summary or a nudge counted as a question: %d", turns)
	}
	response = compactionTurn(t, "turn-five-summary", encoded(t, messages))
	if !response.OK || response.Compacted || provider.summaries() != 0 {
		t.Fatalf("a compacted transcript with five questions was compacted again: %+v", response)
	}
}

func TestCompactionCutKeepsToolCallsWithTheirResults(t *testing.T) {
	// Turn 4, the last summarized, and turn 5, the first kept, both call
	// tools; a tool declaration sits in the summarized part; turn 3 was
	// nudged.
	messages := conversation(8, usageAt(0.8), 0, 4, 5)
	declaration := agent.AgentMessage{System: &ai.SystemMessage{Content: ai.SystemText(""), ToolsAdded: []ai.ToolSchema{{Name: "read_attachment"}}}}
	messages = slices.Insert(messages, 3, declaration)
	third := slices.IndexFunc(messages, func(message agent.AgentMessage) bool {
		return message.User != nil && userText(message.User.Content) == "问题3"
	})
	messages = slices.Insert(messages, third+1,
		agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant", StopReason: ai.StopReasonStop}},
		agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(nudgeEmptyReply)}})

	head, cut, turns, ok := cutOf(t, messages)
	if !ok || head != 1 || turns != 4 || userText(messages[cut].User.Content) != "问题5" {
		t.Fatalf("cut = head %d, cut %d, %d turns, %v", head, cut, turns, ok)
	}
	older := messages[head:cut]
	source := summarySource(older)
	for _, want := range []string{"用户：问题1", "助手：回答4", "助手调用工具 get_accounts：{\"activeOnly\":true}", "工具结果（get_accounts）：结果4"} {
		if !strings.Contains(source, want) {
			t.Fatalf("summary source lacks %q:\n%s", want, source)
		}
	}
	if strings.Contains(source, nudgeEmptyReply) || strings.Contains(source, "问题5") {
		t.Fatalf("summary source holds a nudge or a kept turn:\n%s", source)
	}

	compacted := compactedMessages(messages, head, cut, "- 摘要", compactionModel)
	if compacted[0].System == nil || compacted[1].System == nil || len(compacted[1].System.ToolsAdded) != 1 || !isCompactionSummary(compacted[2]) {
		t.Fatalf("compacted transcript opens with %+v", compacted[:3])
	}
	// The summary is answered, so the first kept question does not follow
	// another user message.
	if ack := compacted[3].Assistant; ack == nil || !isCompactionAck(compacted[3]) || ack.ModelID != "faux-1" || ack.Provider != "faux" || ack.API != "faux" {
		t.Fatalf("summary is not answered: %+v", compacted[3])
	}
	if !reflect.DeepEqual(compacted[4:], messages[cut:]) {
		t.Fatal("the kept turns changed")
	}
	assertEveryCallAnswered(t, compacted)
	calls := map[string]bool{}
	for _, message := range compacted {
		if message.Assistant != nil {
			for _, block := range message.Assistant.Content {
				if call, ok := block.(ai.ToolCall); ok {
					calls[call.ID] = true
				}
			}
		}
		if message.ToolResult != nil && !calls[message.ToolResult.ToolCallID] {
			t.Fatalf("tool result %s lost its call", message.ToolResult.ToolCallID)
		}
	}

	// An earlier summary goes into the next one.
	again := summarySource(compacted[2:])
	if !strings.Contains(again, "更早对话的摘要：\n- 摘要") || strings.Contains(again, compactionMarker) || strings.Contains(again, compactionAck) {
		t.Fatalf("earlier summary in source:\n%s", again)
	}
}

func TestCompactionFailureFallsBackToTheTrim(t *testing.T) {
	for name, summarize := range map[string]func() ai.FauxResponse{
		"error": func() ai.FauxResponse { return ai.FauxResponse{StopReason: "error", ErrorMessage: "overloaded"} },
		"empty": func() ai.FauxResponse {
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("  ")}, StopReason: "stop"}
		},
	} {
		t.Run(name, func(t *testing.T) {
			observer := &streamObserver{}
			observe(t, observer)
			provider := useCompactionFaux(t, summarize)
			response := compactionTurn(t, "turn-fallback-"+name, encoded(t, conversation(8, usageAt(0.8), 0, 2)))
			if !response.OK || response.Reply != "好的" || response.Compacted || provider.summaries() == 0 || provider.turns() != 1 {
				t.Fatalf("fallback: %+v, %d summaries", response, provider.summaries())
			}
			if strings.Contains(response.Transcript, compactionMarker) || !strings.Contains(response.Transcript, "问题1") {
				t.Fatal("a failed summary changed the transcript")
			}
			events := observer.recorded()
			end := eventIndex(events, "compaction_end")
			if eventIndex(events, "compaction_start") < 0 || end < 0 || events[end].SummarizedTurns != 0 {
				t.Fatalf("events = %v", kinds(events))
			}
		})
	}

	// A transcript past the byte budget is trimmed instead.
	provider := useCompactionFaux(t, func() ai.FauxResponse { return ai.FauxResponse{StopReason: "error", ErrorMessage: "overloaded"} })
	response := compactionTurn(t, "turn-fallback-trim", encoded(t, conversation(8, usageAt(0.8), 60_000, 1, 2, 3, 4, 5, 6, 7, 8)))
	if !response.OK || response.Compacted || provider.turns() != 1 {
		t.Fatalf("trim fallback: %+v", response)
	}
	texts := requestTexts(provider.main[0])
	if slices.Contains(texts, "user:问题1") || !slices.Contains(texts, "user:问题8") || !strings.HasPrefix(texts[0], "user:问题") {
		t.Fatalf("trimmed request = %v", texts)
	}
}

func TestCompactionTimeoutFallsBackToTheTrim(t *testing.T) {
	previousTimeout := compactionTimeout
	compactionTimeout = 50 * time.Millisecond
	t.Cleanup(func() { compactionTimeout = previousTimeout })
	provider := useCompactionFaux(t, summaryText)
	faux := streamFn
	streamFn = func(ctx context.Context, model *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
		if len(offeredTools(transcript)) == 0 {
			<-ctx.Done()
			return nil, ctx.Err()
		}
		return faux(ctx, model, transcript, options)
	}
	response := compactionTurn(t, "turn-timeout", encoded(t, conversation(8, usageAt(0.8), 0)))
	if !response.OK || response.Reply != "好的" || response.Compacted || provider.turns() != 1 {
		t.Fatalf("timed-out summary: %+v", response)
	}
}

func TestStopDuringCompactionKeepsThePreviousTranscript(t *testing.T) {
	provider := useCompactionFaux(t, summaryText)
	faux := streamFn
	streamFn = func(ctx context.Context, model *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
		if len(offeredTools(transcript)) == 0 {
			CancelTurn("turn-stop-compaction")
			<-ctx.Done()
			return nil, ctx.Err()
		}
		return faux(ctx, model, transcript, options)
	}
	response := compactionTurn(t, "turn-stop-compaction", encoded(t, conversation(8, usageAt(0.8), 0)))
	if !response.Cancelled || response.OK || response.Transcript != "" || response.Compacted || provider.turns() != 0 {
		t.Fatalf("stop during the summary = %+v", response)
	}
}

func TestCompactedTranscriptIsNotCompactedAgain(t *testing.T) {
	provider := useCompactionFaux(t, summaryText)
	first := compactionTurn(t, "turn-first", encoded(t, conversation(8, usageAt(0.8), 0)))
	if !first.Compacted {
		t.Fatalf("first turn was not compacted: %+v", first)
	}
	// The compacted turn's answer reported a small context; the next turn
	// replays it unchanged.
	second := compactionTurn(t, "turn-second", first.Transcript)
	if !second.OK || second.Compacted || provider.summaries() != 1 {
		t.Fatalf("follow-up was compacted again: %+v, %d summaries", second, provider.summaries())
	}
	if !strings.HasPrefix(requestTexts(provider.main[1])[0], "user:"+compactionMarker) {
		t.Fatal("follow-up lost the summary")
	}

	// Seven questions after a summary, below the threshold, stay as they are.
	messages := conversation(7, usageAt(0.5), 0)
	messages = slices.Insert(messages, 1, agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(compactionMarker + "\n- 摘要")}})
	third := compactionTurn(t, "turn-third", encoded(t, messages))
	if !third.OK || third.Compacted || provider.summaries() != 1 {
		t.Fatalf("below threshold after a summary: %+v", third)
	}
}

func TestTruncateDoesNotCountTheSummary(t *testing.T) {
	messages := conversation(2, nil, 0, 2)
	messages = slices.Insert(messages, 1, agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(compactionMarker + "\n- 摘要")}})
	transcript := encoded(t, messages)
	kept := truncateFor(t, map[string]any{"version": 1, "transcript": transcript, "keepUserTurns": 1})
	if !kept.OK || kept.UserTurns != 2 {
		t.Fatalf("keep 1: %+v", kept)
	}
	got, err := decodeTranscript(kept.Transcript)
	if err != nil || len(got) != 4 || !isCompactionSummary(got[1]) || userText(got[2].User.Content) != "问题1" {
		t.Fatalf("keep 1 = %s", kept.Transcript)
	}
	// Cutting every question keeps the summary of the turns before them.
	dropped := truncateFor(t, map[string]any{"version": 1, "transcript": transcript, "dropUserTurns": 2})
	got, err = decodeTranscript(dropped.Transcript)
	if !dropped.OK || err != nil || len(got) != 2 || got[0].System == nil || !isCompactionSummary(got[1]) {
		t.Fatalf("drop 2 = %+v", dropped)
	}
	if over := truncateFor(t, map[string]any{"version": 1, "transcript": transcript, "dropUserTurns": 3}); over.OK || over.UserTurns != 2 {
		t.Fatalf("drop 3 = %+v", over)
	}
}

func TestCompactionComesBeforeTheTrimWithALargeWindow(t *testing.T) {
	// Ten questions with tool results of 36 KB: past the byte budget while
	// the provider reports half of the 200000-token window.
	provider := useCompactionFaux(t, summaryText)
	messages := conversation(10, usageAt(0.5), 36_000, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
	if _, total, _ := messageSizes(messages); total <= transcriptBudget {
		t.Fatalf("transcript is %d bytes, within the budget", total)
	}
	response := compactionTurn(t, "turn-large-window", encoded(t, messages))
	if !response.OK || !response.Compacted || response.CompactedTurns != 6 || provider.summaries() != 1 {
		t.Fatalf("over the budget: %+v, %d summaries", response, provider.summaries())
	}
	texts := requestTexts(provider.main[0])
	if !strings.HasPrefix(texts[0], "user:"+compactionMarker) || texts[1] != "assistant:"+compactionAck || texts[2] != "user:问题7" {
		t.Fatalf("turn request = %v", texts[:3])
	}
	// The summary's tokens count in the turn's usage: with one turn
	// request, the sum is past what that request held.
	if usage := response.Usage; usage == nil || usage.Input+usage.Output+usage.CacheRead+usage.CacheWrite <= usage.ContextTokens {
		t.Fatalf("usage = %+v", response.Usage)
	}
}

func TestCompactionKeepsTheSummaryWhenKeptTurnsAreLarge(t *testing.T) {
	// The last four questions each carry 100 KB: together past what the trim
	// keeps, so fewer stay whole and the summary covers the rest.
	provider := useCompactionFaux(t, summaryText)
	response := compactionTurn(t, "turn-large-tail", encoded(t, conversation(8, usageAt(0.8), 100_000, 5, 6, 7, 8)))
	if !response.OK || !response.Compacted || response.CompactedTurns != 7 || provider.summaries() != 1 {
		t.Fatalf("large kept turns: %+v, %d summaries", response, provider.summaries())
	}
	if !strings.Contains(transcriptText(t, provider.summary[0]), "问题7") {
		t.Fatal("the summary does not cover the turns that no longer fit")
	}
	texts := requestTexts(provider.main[0])
	if !strings.HasPrefix(texts[0], "user:"+compactionMarker) || texts[1] != "assistant:"+compactionAck || texts[2] != "user:问题8" {
		t.Fatalf("turn request = %v", texts)
	}
	messages, err := decodeTranscript(response.Transcript)
	if err != nil || !isCompactionSummary(messages[1]) {
		t.Fatalf("returned transcript lost the summary: %v", err)
	}

	// The trim, when it still has to cut, keeps the summary and its answer
	// and drops the turns after them.
	big := conversation(3, nil, 150_000, 1, 2, 3)
	compacted := compactedMessages(big, 1, 1, "- 摘要", compactionModel)
	trimmed := trimTranscript(compacted, transcriptBudget)
	if len(trimmed) < 4 || !isCompactionSummary(trimmed[1]) || !isCompactionAck(trimmed[2]) || userText(trimmed[3].User.Content) != "问题3" {
		t.Fatalf("trim kept %d messages, opening %s", len(trimmed), encoded(t, trimmed[:min(len(trimmed), 3)]))
	}
}

func TestTruncateKeepsTheSummaryAndItsAnswer(t *testing.T) {
	messages := conversation(7, nil, 0)
	head, cut, _, _ := cutOf(t, messages)
	transcript := encoded(t, compactedMessages(messages, head, cut, "- 摘要", compactionModel))
	dropped := truncateFor(t, map[string]any{"version": 1, "transcript": transcript, "dropUserTurns": 4})
	got, err := decodeTranscript(dropped.Transcript)
	if !dropped.OK || dropped.UserTurns != 4 || err != nil || len(got) != 3 || !isCompactionSummary(got[1]) || !isCompactionAck(got[2]) {
		t.Fatalf("drop 4 = %+v", dropped)
	}
	kept := truncateFor(t, map[string]any{"version": 1, "transcript": transcript, "keepUserTurns": 1})
	if got, err = decodeTranscript(kept.Transcript); !kept.OK || err != nil || len(got) != 5 || userText(got[3].User.Content) != "问题4" {
		t.Fatalf("keep 1 = %+v", kept)
	}
}

// A custom endpoint whose list gave a 1M window is not compacted at 200k
// tokens, which is past 75% of the common 128k it gets without one.
func TestCustomEndpointCompactsAgainstTheListedWindow(t *testing.T) {
	summaries := 0
	previousStream := streamFn
	streamFn = func(ctx context.Context, _ *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
		reply := ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好的")}, StopReason: "stop"}
		if len(offeredTools(transcript)) == 0 {
			summaries++
			reply = summaryText()
		}
		provider := ai.NewFauxProvider(ai.FauxConfig{})
		provider.SetResponses([]ai.FauxResponseStep{ai.FauxStaticStep(reply)})
		return provider.Stream(ctx, transcript, options)
	}
	t.Cleanup(func() { streamFn = previousStream })
	transcript := encoded(t, conversation(8, &ai.Usage{Input: 199_000, Output: 1000}, 0))
	turn := func(window int) turnResponseV1 {
		request := map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t), "provider": "custom",
			"model": "antigravity/gemini-3.8-flash-tiered", "apiKey": "test", "message": "新问题", "transcript": transcript,
			"custom": map[string]string{"api": "openai-completions", "baseURL": "https://gateway.example/v1"}}
		if window > 0 {
			request["contextWindow"] = window
		}
		return runTurnFor(t, request)
	}
	if response := turn(1_048_576); !response.OK || response.Compacted || summaries != 0 {
		t.Fatalf("1M window: %+v, %d summaries", response, summaries)
	}
	if response := turn(0); !response.OK || !response.Compacted || summaries != 1 {
		t.Fatalf("assumed window: %+v, %d summaries", response, summaries)
	}
}
