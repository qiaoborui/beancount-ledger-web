package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestAIParseRouteUsesOpenAICompatibleChatCompletions(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	fakeAI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" {
			t.Fatalf("unexpected AI path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"{\"entries\":[{\"kind\":\"transaction\",\"date\":\"2026-05-02\",\"payee\":\"Shop\",\"narration\":\"Snack\",\"metadata\":{},\"tags\":[],\"postings\":[{\"account\":\"Expenses:Food\",\"amount\":\"8.00\",\"currency\":\"CNY\"},{\"account\":\"Assets:Cash\",\"amount\":\"-8.00\",\"currency\":\"CNY\"}],\"confidence\":1,\"needsReview\":false,\"questions\":[]}] }"}}]}`))
	}))
	defer fakeAI.Close()
	t.Setenv("LEDGER_AI_PROVIDER", "openai")
	t.Setenv("OPENAI_API_KEY", "test-key")
	t.Setenv("OPENAI_BASE_URL", fakeAI.URL)
	router := testRouter(t, cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodPost, "/api/ai/parse", `{"input":"买零食 8 元"}`, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("ai parse status=%d body=%s", res.Code, res.Body.String())
	}
	var body struct {
		Entries []LedgerEntry `json:"entries"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Entries) != 1 || body.Entries[0].Payee != "Shop" {
		t.Fatalf("unexpected AI entries: %#v", body.Entries)
	}
}

type queuedAgentModel struct {
	results []agentModelResult
}

func (m *queuedAgentModel) Complete(context.Context, string, []agentModelMessage, []agentToolSpec) (agentModelResult, error) {
	result := m.results[0]
	m.results = m.results[1:]
	return result, nil
}

type capturedAgentEvent struct {
	name    string
	payload any
}

func TestLedgerAgentExecutesReadToolsAndReturnsFinalMessage(t *testing.T) {
	server := testAgentServer(t)
	server.agentModel = &queuedAgentModel{results: []agentModelResult{
		{ToolCalls: []agentModelToolCall{{ID: "call-1", Type: "function", Function: agentModelFunctionCall{Name: "get_bql_capabilities", Arguments: `{}`}}}},
		{Content: "BQL 支持 postings 和 transactions。"},
	}}
	events := []capturedAgentEvent{}
	err := server.runAgentTurn(context.Background(), AgentTurnRequest{Message: "BQL 支持什么？"}, func(name string, payload any) error {
		events = append(events, capturedAgentEvent{name: name, payload: payload})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !hasAgentEvent(events, "tool_call") || !hasAgentEvent(events, "tool_result") || !hasAgentEvent(events, "message_delta") || !hasAgentEvent(events, "final") {
		t.Fatalf("missing agent events: %#v", events)
	}
}

func TestLedgerAgentRequiresApprovalBeforeWriting(t *testing.T) {
	server := testAgentServer(t)
	arguments := `{"entries":[{"kind":"transaction","date":"2026-05-08","payee":"Agent Cafe","narration":"Coffee","metadata":{},"tags":[],"postings":[{"account":"Expenses:Food","amount":"18.00","currency":"CNY"},{"account":"Assets:Cash","amount":"-18.00","currency":"CNY"}],"confidence":1,"needsReview":false,"questions":[]}]}`
	server.agentModel = &queuedAgentModel{results: []agentModelResult{{ToolCalls: []agentModelToolCall{{ID: "write-1", Type: "function", Function: agentModelFunctionCall{Name: "append_transactions", Arguments: arguments}}}}}}
	events := []capturedAgentEvent{}
	err := server.runAgentTurn(context.Background(), AgentTurnRequest{SessionID: "session-test-1", Message: "写入这笔咖啡", Context: AgentPageContext{SensitiveUnlocked: true}}, func(name string, payload any) error {
		events = append(events, capturedAgentEvent{name: name, payload: payload})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(mustRead(t, filepath.Join(server.cfg.LedgerRoot, "transactions", "2026", "05.bean"))), "Agent Cafe") {
		t.Fatal("agent wrote before approval")
	}
	var approval AgentApproval
	for _, event := range events {
		if event.name == "approval_required" {
			raw, _ := json.Marshal(event.payload)
			if err := json.Unmarshal(raw, &approval); err != nil {
				t.Fatal(err)
			}
		}
	}
	if approval.ID == "" {
		t.Fatalf("approval event missing: %#v", events)
	}
	if !hasAgentEvent(events, "artifact") {
		t.Fatalf("write approval must include a validated draft artifact: %#v", events)
	}
	if err := server.resolveAgentApproval(context.Background(), AgentApprovalRequest{SessionID: approval.SessionID, ApprovalID: approval.ID, Approved: true}, AgentPageContext{SensitiveUnlocked: true}, func(string, any) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(mustRead(t, filepath.Join(server.cfg.LedgerRoot, "transactions", "2026", "05.bean"))), "Agent Cafe") {
		t.Fatal("approved agent write was not applied")
	}
}

func testAgentServer(t *testing.T) *Server {
	t.Helper()
	cfg := testLedger(t)
	runtimeStore := newFilesystemRuntimeStore(cfg.RuntimeDir)
	cache := NewLedgerCache(cfg)
	readService := NewLedgerReadService(cache)
	writer := NewLedgerWriterWithRuntimeStore(cfg, cache, runtimeStore)
	return &Server{
		cfg:            cfg,
		runtimeStore:   runtimeStore,
		cache:          cache,
		writer:         writer,
		accountService: NewAccountService(cache, writer),
		queryPort:      readService,
		snapshotPort:   readService,
		limiter:        NewRateLimiter(),
	}
}

func hasAgentEvent(events []capturedAgentEvent, name string) bool {
	for _, event := range events {
		if event.name == name {
			return true
		}
	}
	return false
}
