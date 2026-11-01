package mobileagent

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/MichaelKinsy/PiG/ai"
)

// sseReply writes one OpenAI chat-completions stream that answers text.
func sseReply(w http.ResponseWriter, text string) {
	w.Header().Set("Content-Type", "text/event-stream")
	chunk := func(delta map[string]any, finish any) {
		raw, _ := json.Marshal(map[string]any{"id": "c1", "object": "chat.completion.chunk", "created": 1, "model": "m",
			"choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}}})
		_, _ = fmt.Fprintf(w, "data: %s\n\n", raw)
	}
	chunk(map[string]any{"role": "assistant", "content": text}, nil)
	chunk(map[string]any{}, "stop")
	_, _ = io.WriteString(w, "data: [DONE]\n\n")
}

func customTurn(t *testing.T, baseURL string, history []map[string]string, message string) turnResponseV1 {
	t.Helper()
	request := map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t), "provider": "custom",
		"model": "m", "apiKey": "k", "message": message, "custom": map[string]any{"api": "openai-completions", "baseURL": baseURL + "/v1"}}
	if history != nil {
		request["history"] = history
	}
	return runTurnFor(t, request)
}

// The reported bug: the first question is answered, the second never is.
// Between turns the phone drops the connection the first turn kept alive;
// the second turn must not wait on it.
func TestSecondTurnDoesNotReuseTheFirstTurnsConnection(t *testing.T) {
	var mu sync.Mutex
	var bodies []string
	var conns atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		mu.Lock()
		bodies = append(bodies, string(raw))
		n := len(bodies)
		mu.Unlock()
		sseReply(w, fmt.Sprintf("回答 %d", n))
	}))
	server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			conns.Add(1)
		}
	}
	server.Start()
	defer server.Close()

	first := customTurn(t, server.URL, nil, "第一问")
	if !first.OK || first.Reply != "回答 1" {
		t.Fatalf("first turn: %+v", first)
	}
	second := customTurn(t, server.URL, []map[string]string{{"role": "user", "content": "第一问"}, {"role": "assistant", "content": first.Reply}}, "第二问")
	if !second.OK || second.Reply != "回答 2" {
		t.Fatalf("second turn: %+v", second)
	}
	if conns.Load() != 2 {
		t.Fatalf("turns shared a connection: %d connections for 2 turns", conns.Load())
	}
	if !strings.Contains(bodies[1], "第一问") || !strings.Contains(bodies[1], "回答 1") {
		t.Fatalf("second request did not replay the first exchange: %s", bodies[1])
	}
}

func TestStalledStreamFailsWithAVisibleError(t *testing.T) {
	previous := streamIdleTimeout
	streamIdleTimeout = 300 * time.Millisecond
	t.Cleanup(func() { streamIdleTimeout = previous })
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-release
	}))
	defer server.Close()
	defer close(release)

	started := time.Now()
	response := customTurn(t, server.URL, nil, "hi")
	if response.OK || !strings.Contains(response.Error, "没有任何响应") {
		t.Fatalf("stall not reported: %+v", response)
	}
	if elapsed := time.Since(started); elapsed > 20*time.Second {
		t.Fatalf("stall took %s to surface", elapsed)
	}
}

func TestTransientProviderErrorsAreRetried(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		if calls.Add(1) == 1 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = io.WriteString(w, `{"error":{"message":"overloaded"}}`)
			return
		}
		sseReply(w, "好了")
	}))
	defer server.Close()
	response := customTurn(t, server.URL, nil, "hi")
	if !response.OK || response.Reply != "好了" || calls.Load() != 2 {
		t.Fatalf("503 was not retried: calls=%d %+v", calls.Load(), response)
	}
}

func TestEmptyReplyIsAskedForAnAnswer(t *testing.T) {
	var nudged string
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{}, StopReason: "stop"}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			nudged = lastUserText(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("这个月花了 25 元。")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "这个月花了多少"})
	if !response.OK || response.Reply != "这个月花了 25 元。" || nudged != nudgeEmptyReply {
		t.Fatalf("empty reply not recovered: nudge=%q %+v", nudged, response)
	}
}

func TestEmptyReplyTwiceIsAnError(t *testing.T) {
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{}, StopReason: "stop"}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{}, StopReason: "stop"}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "hi"})
	if response.OK || response.Error == "" {
		t.Fatalf("an empty answer passed as a reply: %+v", response)
	}
}

func TestSpentToolBudgetStillAnswers(t *testing.T) {
	steps := make([]ai.FauxResponseStep, 0, maxTurns+1)
	for i := range maxTurns {
		steps = append(steps, ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("get_accounts", map[string]any{}, &ai.FauxToolCallOptions{ID: fmt.Sprintf("call_%d", i)}),
		}}))
	}
	var nudged string
	steps = append(steps, ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		nudged = lastUserText(request)
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("你有 2 个账户。")}, StopReason: "stop"}.AssistantMessage(), nil
	}))
	useFaux(t, steps...)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "我有哪些账户"})
	if !response.OK || response.Reply != "你有 2 个账户。" || nudged != nudgeToolBudget {
		t.Fatalf("spent budget did not end in an answer: nudge=%q %+v", nudged, response)
	}
}

func TestCancelBeforeTheTurnStartsStopsIt(t *testing.T) {
	useFaux(t, ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("不该回答")}}))
	CancelTurn("early-turn")
	response := runTurnFor(t, map[string]any{"version": 1, "turnId": "early-turn", "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "hi"})
	if !response.Cancelled || response.OK {
		t.Fatalf("early cancel was lost: %+v", response)
	}
	// The tombstone is spent: the id can run again.
	if _, ok := earlyCancels.Load("early-turn"); ok {
		t.Fatal("early cancel was kept after use")
	}
}

func TestHistoryDropsEmptyTurnsAndJoinsNeighbours(t *testing.T) {
	messages, err := historyMessages([]historyMessageV1{
		{Role: "user", Content: "一"}, {Role: "assistant", Content: "  "},
		{Role: "user", Content: "二"}, {Role: "assistant", Content: "答"},
		{Role: "user", Content: "三"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 || messages[0].User == nil || messages[1].Assistant == nil {
		t.Fatalf("unexpected history shape: %+v", messages)
	}
	if text := messages[0].User.Content; fmt.Sprint(text) == "" || !strings.Contains(fmt.Sprint(text), "一") || !strings.Contains(fmt.Sprint(text), "二") {
		t.Fatalf("questions were not joined: %v", text)
	}
	if _, err := historyMessages([]historyMessageV1{{Role: "system", Content: "x"}}); err == nil {
		t.Fatal("unknown role accepted")
	}
}

func TestIdleBodyFailsOnlyWhileReading(t *testing.T) {
	reader, writer := io.Pipe()
	var stalled atomic.Bool
	body := newIdleBody(reader, 100*time.Millisecond, &stalled)
	// Time outside Read does not count.
	time.Sleep(200 * time.Millisecond)
	go func() { _, _ = writer.Write([]byte("x")) }()
	if _, err := body.Read(make([]byte, 1)); err != nil {
		t.Fatalf("read after a pause outside Read failed: %v", err)
	}
	if _, err := body.Read(make([]byte, 1)); err != errStreamStalled || !stalled.Load() {
		t.Fatalf("silent read returned %v, stalled=%v", err, stalled.Load())
	}
}

func lastUserText(request ai.TranscriptContext) string {
	messages := request.Messages()
	for index := len(messages) - 1; index >= 0; index-- {
		if user, ok := messages[index].(ai.UserMessage); ok {
			switch content := user.Content.(type) {
			case ai.UserText:
				return string(content)
			case ai.UserContentBlocks:
				var text strings.Builder
				for _, block := range content {
					if value, ok := block.(ai.TextContent); ok {
						text.WriteString(value.Text)
					}
				}
				return text.String()
			}
		}
	}
	return ""
}
