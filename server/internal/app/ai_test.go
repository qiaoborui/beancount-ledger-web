package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
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
	t.Setenv("LEDGER_AI_PROVIDER", "")
	t.Setenv("DEEPSEEK_API_KEY", "")
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

func TestLedgerAgentUsesAvailableOpenAIConfigurationByDefault(t *testing.T) {
	fakeAI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" {
			t.Fatalf("unexpected AI path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"ready"}}]}`))
	}))
	defer fakeAI.Close()
	t.Setenv("LEDGER_AI_PROVIDER", "")
	t.Setenv("DEEPSEEK_API_KEY", "")
	t.Setenv("OPENAI_API_KEY", "test-key")
	t.Setenv("OPENAI_BASE_URL", fakeAI.URL)

	result, err := (openAICompatibleAgentClient{}).Complete(context.Background(), "system", []agentModelMessage{{Role: "user", Content: "hello"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if result.Content != "ready" {
		t.Fatalf("unexpected agent result: %#v", result)
	}
}

func TestRunBQLToolUsesMajorUnitsForModelOutput(t *testing.T) {
	server := testAgentServer(t)
	tool := server.agentTools()["run_bql"]
	execution, err := tool.Execute(context.Background(), json.RawMessage(`{"query":"SELECT month, sum(value) AS total FROM postings WHERE account LIKE 'Expenses:%' GROUP BY month ORDER BY month","valuationCurrency":"CNY","visualization":"line"}`), AgentPageContext{SensitiveUnlocked: true})
	if err != nil {
		t.Fatal(err)
	}
	model, ok := execution.ModelOutput.(map[string]any)
	if !ok {
		t.Fatalf("unexpected model output: %#v", execution.ModelOutput)
	}
	rows, ok := model["rows"].([]map[string]any)
	if !ok || len(rows) != 1 {
		t.Fatalf("unexpected model rows: %#v", model["rows"])
	}
	if rows[0]["total"] != "12.00" {
		t.Fatalf("money must use major units for the model: %#v", rows[0])
	}
	if model["amountUnit"] != "major" {
		t.Fatalf("model output must declare money units: %#v", model)
	}
}

func TestBQLCapabilitiesExplainExpenseFiltering(t *testing.T) {
	capabilities := bqlCapabilities()
	examples, ok := capabilities["examples"].([]string)
	if !ok || len(examples) == 0 || !strings.Contains(strings.Join(examples, "\n"), "account LIKE 'Expenses:%'") {
		t.Fatalf("BQL capabilities must include a valid expense query: %#v", capabilities)
	}
	fieldNotes, ok := capabilities["fieldNotes"].(map[string]any)
	if !ok || !strings.Contains(fmt.Sprint(fieldNotes["type"]), "expense, income, transfer") {
		t.Fatalf("BQL capabilities must explain type values: %#v", capabilities)
	}
}

type queuedAgentModel struct {
	results  []agentModelResult
	messages [][]agentModelMessage
}

func (m *queuedAgentModel) Complete(_ context.Context, _ string, messages []agentModelMessage, _ []agentToolSpec) (agentModelResult, error) {
	m.messages = append(m.messages, append([]agentModelMessage(nil), messages...))
	if len(m.results) == 0 {
		return agentModelResult{Content: "操作已完成。"}, nil
	}
	result := m.results[0]
	m.results = m.results[1:]
	return result, nil
}

type capturedAgentEvent struct {
	name    string
	payload any
}

type cancellationAwareAgentModel struct {
	calls         int
	secondStarted chan struct{}
	release       chan struct{}
}

func (m *cancellationAwareAgentModel) Complete(ctx context.Context, _ string, _ []agentModelMessage, _ []agentToolSpec) (agentModelResult, error) {
	m.calls++
	if m.calls == 1 {
		return agentModelResult{ToolCalls: []agentModelToolCall{{ID: "cancel-tool", Type: "function", Function: agentModelFunctionCall{Name: "get_bql_capabilities", Arguments: `{}`}}}}, nil
	}
	close(m.secondStarted)
	select {
	case <-ctx.Done():
		return agentModelResult{}, ctx.Err()
	case <-m.release:
		return agentModelResult{Content: "刷新后也应保留的最终答复。"}, nil
	}
}

func TestAgentTurnCompletesAfterClientRequestIsCancelled(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	model := &cancellationAwareAgentModel{secondStarted: make(chan struct{}), release: make(chan struct{})}
	server.agentModel = model
	router := newRouter(server.cfg, server)
	requestContext, cancel := context.WithCancel(context.Background())
	defer cancel()
	req := httptest.NewRequest(http.MethodPost, "/api/ai/agent/turn", strings.NewReader(`{"sessionId":"cancel-session","message":"读取 BQL 能力"}`)).WithContext(requestContext)
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		router.ServeHTTP(res, req)
		close(done)
	}()
	select {
	case <-model.secondStarted:
	case <-time.After(time.Second):
		t.Fatal("agent did not reach its second model call")
	}
	cancel()
	select {
	case <-done:
		t.Fatal("client cancellation must not stop the durable Agent turn")
	case <-time.After(25 * time.Millisecond):
	}
	close(model.release)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("agent turn did not finish after the model was released")
	}
	page, err := server.agentTimelinePage(context.Background(), "cancel-session", 0, agentTimelinePageLimit)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) == 0 || page.Items[len(page.Items)-1].Role != "assistant" || page.Items[len(page.Items)-1].Content != "刷新后也应保留的最终答复。" {
		t.Fatalf("cancelled request must still persist the final timeline item: %#v", page.Items)
	}
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

func TestLedgerAgentHandlesMoreThanEightToolRoundsInOneTask(t *testing.T) {
	server := testAgentServer(t)
	results := make([]agentModelResult, 0, 13)
	for turn := 0; turn < 12; turn++ {
		results = append(results, agentModelResult{ToolCalls: []agentModelToolCall{{ID: fmt.Sprintf("call-%d", turn), Type: "function", Function: agentModelFunctionCall{Name: "get_bql_capabilities", Arguments: `{}`}}}})
	}
	results = append(results, agentModelResult{Content: "已根据此前结果完成。"})
	model := &queuedAgentModel{results: results}
	server.agentModel = model
	events := []capturedAgentEvent{}
	err := server.runAgentTurn(context.Background(), AgentTurnRequest{SessionID: "round-limit", Message: "请分析账本", Context: AgentPageContext{SensitiveUnlocked: true}}, func(name string, payload any) error {
		events = append(events, capturedAgentEvent{name: name, payload: payload})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !hasAgentEvent(events, "final") || !strings.Contains(agentEventText(events, "message_delta"), "已根据此前结果完成") {
		t.Fatalf("agent must complete more than eight tool rounds in one task: %#v", events)
	}
	stored, found, err := server.readAgentSession(context.Background(), "round-limit")
	if err != nil || !found {
		t.Fatalf("agent session was not saved: found=%t err=%v", found, err)
	}
	if !containsAgentToolMessage(stored, "call-11") {
		t.Fatalf("tool results must be saved in the session: %#v", stored)
	}
	if len(model.messages) != 13 || !containsAgentToolMessage(model.messages[12], "call-11") {
		t.Fatalf("each model call must receive the durable preceding result: %#v", model.messages)
	}
}

func TestAgentMemoryRequiresApprovalAndSensitiveUnlock(t *testing.T) {
	server := testAgentServer(t)
	arguments := `{"kind":"preference","title":"月度汇总","instruction":"优先按月给出简洁汇总。"}`
	server.agentModel = &queuedAgentModel{results: []agentModelResult{{ToolCalls: []agentModelToolCall{{ID: "memory-1", Type: "function", Function: agentModelFunctionCall{Name: "upsert_memory", Arguments: arguments}}}}}}
	events := []capturedAgentEvent{}
	err := server.runAgentTurn(context.Background(), AgentTurnRequest{SessionID: "memory-session", Message: "记住我喜欢月度简洁汇总", Context: AgentPageContext{SensitiveUnlocked: true}}, func(name string, payload any) error {
		events = append(events, capturedAgentEvent{name: name, payload: payload})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !hasAgentEvent(events, "approval_required") || !hasAgentEvent(events, "artifact") {
		t.Fatalf("memory write must require approval and show its draft: %#v", events)
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
	if err := server.resolveAgentApproval(context.Background(), AgentApprovalRequest{SessionID: approval.SessionID, ApprovalID: approval.ID, Approved: true}, AgentPageContext{SensitiveUnlocked: true}, func(string, any) error { return nil }); err != nil {
		t.Fatal(err)
	}
	records, err := server.searchAgentMemories(context.Background(), "月度")
	if err != nil || len(records) != 1 || records[0].Instruction != "优先按月给出简洁汇总。" {
		t.Fatalf("approved memory was not saved: records=%#v err=%v", records, err)
	}
	if _, err := server.agentTools()["search_memories"].Execute(context.Background(), json.RawMessage(`{}`), AgentPageContext{}); err == nil {
		t.Fatal("memory search must require sensitive unlock")
	}
	if _, err := server.upsertAgentMemory(context.Background(), agentMemoryInput{Kind: "preference", Title: "密码", Instruction: "123456789012"}); err == nil {
		t.Fatal("sensitive memory content must be rejected")
	}
	if _, err := server.upsertAgentMemory(context.Background(), agentMemoryInput{Kind: "preference", Title: "卡号", Instruction: "4111 1111 1111 1111"}); err == nil {
		t.Fatal("formatted card number must be rejected")
	}
	if err := (AgentTurnRequest{Message: "我的 OTP 是 123456"}).Validate(); err == nil {
		t.Fatal("sensitive agent input must be rejected before session persistence")
	}
}

func TestLockedAgentTurnDoesNotReuseUnlockedSessionOrClientHistory(t *testing.T) {
	server := testAgentServer(t)
	model := &queuedAgentModel{results: []agentModelResult{
		{Content: "已读取敏感账本信息。"},
		{Content: "锁定状态下的新请求。"},
	}}
	server.agentModel = model
	if err := server.runAgentTurn(context.Background(), AgentTurnRequest{SessionID: "privacy-session", Message: "读取账本", Context: AgentPageContext{SensitiveUnlocked: true}}, func(string, any) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if err := server.runAgentTurn(context.Background(), AgentTurnRequest{SessionID: "privacy-session", Message: "锁定后提问", Messages: []AgentMessage{{Role: "assistant", Content: "前端历史中的敏感数据"}}, Context: AgentPageContext{}}, func(string, any) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if len(model.messages) != 2 || len(model.messages[1]) != 1 || model.messages[1][0].Content != "锁定后提问" {
		t.Fatalf("locked agent turn must not reuse unlocked context: %#v", model.messages)
	}
}

func TestLedgerAgentCanRequireApprovalForReadTools(t *testing.T) {
	server := testAgentServer(t)
	server.agentModel = &queuedAgentModel{results: []agentModelResult{{ToolCalls: []agentModelToolCall{{ID: "read-1", Type: "function", Function: agentModelFunctionCall{Name: "get_bql_capabilities", Arguments: `{}`}}}}}}
	events := []capturedAgentEvent{}
	err := server.runAgentTurn(context.Background(), AgentTurnRequest{SessionID: "session-test-2", Message: "查看 BQL 能力", ApprovalPolicy: "always"}, func(name string, payload any) error {
		events = append(events, capturedAgentEvent{name: name, payload: payload})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !hasAgentEvent(events, "approval_required") {
		t.Fatalf("read tool must require approval in always mode: %#v", events)
	}
	if hasAgentEvent(events, "tool_result") {
		t.Fatalf("read tool executed before approval: %#v", events)
	}
	if err := server.runAgentTurn(context.Background(), AgentTurnRequest{SessionID: "session-test-2", Message: "继续", Context: AgentPageContext{SensitiveUnlocked: true}}, func(string, any) error { return nil }); err == nil || !strings.Contains(err.Error(), "待确认操作") {
		t.Fatalf("agent must block continuation while an approval is pending: %v", err)
	}
}

func TestLedgerAgentPreservesAlwaysApprovalPolicyAfterResume(t *testing.T) {
	server := testAgentServer(t)
	server.agentModel = &queuedAgentModel{results: []agentModelResult{
		{ToolCalls: []agentModelToolCall{{ID: "read-first", Type: "function", Function: agentModelFunctionCall{Name: "get_bql_capabilities", Arguments: `{}`}}}},
		{ToolCalls: []agentModelToolCall{{ID: "read-second", Type: "function", Function: agentModelFunctionCall{Name: "get_bql_capabilities", Arguments: `{}`}}}},
	}}
	initial := []capturedAgentEvent{}
	if err := server.runAgentTurn(context.Background(), AgentTurnRequest{SessionID: "always-resume", Message: "逐项读取", ApprovalPolicy: "always", Context: AgentPageContext{SensitiveUnlocked: true}}, func(name string, payload any) error {
		initial = append(initial, capturedAgentEvent{name: name, payload: payload})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	approval := agentApprovalFromEvents(t, initial)
	resumed := []capturedAgentEvent{}
	if err := server.resolveAgentApproval(context.Background(), AgentApprovalRequest{SessionID: approval.SessionID, ApprovalID: approval.ID, Approved: true}, AgentPageContext{SensitiveUnlocked: true}, func(name string, payload any) error {
		resumed = append(resumed, capturedAgentEvent{name: name, payload: payload})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if !hasAgentEvent(resumed, "approval_required") || hasAgentToolEvent(resumed, "tool_result", "read-second") {
		t.Fatalf("always approval must remain active after continuation: %#v", resumed)
	}
}

func TestLedgerAgentRequiresApprovalBeforeWriting(t *testing.T) {
	installFakeBeanCheck(t)
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

func TestApprovedWriteResumesTheSameAgentTaskAndIsIdempotent(t *testing.T) {
	installFakeBeanCheck(t)
	server := testAgentServer(t)
	arguments := `{"entries":[{"kind":"transaction","date":"2026-05-08","payee":"Resume Cafe","narration":"Coffee","metadata":{},"tags":[],"postings":[{"account":"Expenses:Food","amount":"18.00","currency":"CNY"},{"account":"Assets:Cash","amount":"-18.00","currency":"CNY"}],"confidence":1,"needsReview":false,"questions":[]}]}`
	model := &queuedAgentModel{results: []agentModelResult{
		{ToolCalls: []agentModelToolCall{{ID: "write-resume", Type: "function", Function: agentModelFunctionCall{Name: "append_transactions", Arguments: arguments}}}},
		{Content: "已写入并完成后续核对。"},
	}}
	server.agentModel = model
	events := []capturedAgentEvent{}
	if err := server.runAgentTurn(context.Background(), AgentTurnRequest{SessionID: "resume-write", Message: "写入咖啡", Context: AgentPageContext{SensitiveUnlocked: true}}, func(name string, payload any) error {
		events = append(events, capturedAgentEvent{name: name, payload: payload})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	approval := agentApprovalFromEvents(t, events)
	events = nil
	if err := server.resolveAgentApproval(context.Background(), AgentApprovalRequest{SessionID: approval.SessionID, ApprovalID: approval.ID, Approved: true}, AgentPageContext{SensitiveUnlocked: true}, func(name string, payload any) error {
		events = append(events, capturedAgentEvent{name: name, payload: payload})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(agentEventText(events, "message_delta"), "已写入并完成后续核对") || len(model.messages) != 2 || !containsAgentToolMessage(model.messages[1], "write-resume") {
		t.Fatalf("approved result must resume sampling with the actual tool output: events=%#v messages=%#v", events, model.messages)
	}
	secondEvents := []capturedAgentEvent{}
	if err := server.resolveAgentApproval(context.Background(), AgentApprovalRequest{SessionID: approval.SessionID, ApprovalID: approval.ID, Approved: true}, AgentPageContext{SensitiveUnlocked: true}, func(name string, payload any) error {
		secondEvents = append(secondEvents, capturedAgentEvent{name: name, payload: payload})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(model.messages) != 2 || !hasAgentEvent(secondEvents, "final") {
		t.Fatalf("duplicate approval must replay its receipt without another model/tool run: events=%#v messages=%#v", secondEvents, model.messages)
	}
}

func TestAgentRejectsMalformedOrSchemaInvalidToolCallsBeforeExecution(t *testing.T) {
	tools := testAgentServer(t).agentTools()
	_, _, _, err := validateAgentToolCall(tools, agentModelToolCall{ID: "bad-json", Type: "function", Function: agentModelFunctionCall{Name: "get_bql_capabilities", Arguments: "{"}}, map[string]struct{}{})
	if err == nil || !strings.Contains(err.Error(), "malformed JSON") {
		t.Fatalf("malformed JSON must be rejected before execution: %v", err)
	}
	_, _, _, err = validateAgentToolCall(tools, agentModelToolCall{ID: "bad-schema", Type: "function", Function: agentModelFunctionCall{Name: "validate_bql", Arguments: `{"unknown":true}`}}, map[string]struct{}{})
	if err == nil || !strings.Contains(err.Error(), "not allowed") {
		t.Fatalf("schema-invalid call must be rejected before execution: %v", err)
	}
}

func TestAgentRejectsDuplicateToolCallIDsBeforeAnyCallRuns(t *testing.T) {
	server := testAgentServer(t)
	model := &queuedAgentModel{results: []agentModelResult{
		{ToolCalls: []agentModelToolCall{
			{ID: "duplicate", Type: "function", Function: agentModelFunctionCall{Name: "get_bql_capabilities", Arguments: `{}`}},
			{ID: "duplicate", Type: "function", Function: agentModelFunctionCall{Name: "append_transactions", Arguments: `{}`}},
		}},
		{Content: "已拒绝无效调用。"},
	}}
	server.agentModel = model
	events := []capturedAgentEvent{}
	if err := server.runAgentTurn(context.Background(), AgentTurnRequest{SessionID: "duplicate-calls", Message: "test"}, func(name string, payload any) error {
		events = append(events, capturedAgentEvent{name: name, payload: payload})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if hasAgentEvent(events, "approval_required") || hasAgentEvent(events, "tool_call") || !hasAgentToolEvent(events, "tool_result", "duplicate") {
		t.Fatalf("duplicate IDs must be rejected before executing or pausing: %#v", events)
	}
}

func TestLedgerSummaryUsesMajorUnitsForModelOutput(t *testing.T) {
	server := testAgentServer(t)
	execution, err := server.agentTools()["get_ledger_summary"].Execute(context.Background(), json.RawMessage(`{"start":"2026-05-01","end":"2026-06-01"}`), AgentPageContext{SensitiveUnlocked: true})
	if err != nil {
		t.Fatal(err)
	}
	output, ok := execution.ModelOutput.(map[string]any)
	if !ok || output["amountUnit"] != "major" {
		t.Fatalf("summary must state major units: %#v", execution.ModelOutput)
	}
	summary, ok := output["summary"].(map[string]any)
	if !ok || summary["expense"] != "12.00" {
		t.Fatalf("summary money must be a major-unit string: %#v", output)
	}
}

func TestAgentSessionCompactionKeepsToolCallAndResultTogether(t *testing.T) {
	t.Setenv("LEDGER_AI_HISTORY_TOKEN_BUDGET", "4096")
	messages := []agentModelMessage{{Role: "user", Content: "long task"}}
	for index := 0; index < 400; index++ {
		id := fmt.Sprintf("compact-%d", index)
		messages = append(messages,
			agentModelMessage{Role: "assistant", ToolCalls: []agentModelToolCall{{ID: id, Type: "function", Function: agentModelFunctionCall{Name: "get_bql_capabilities", Arguments: `{}`}}}},
			agentToolResultMessage(id, map[string]any{"ok": true}),
		)
	}
	trimmed := trimAgentSessionMessages(messages)
	if len(trimmed) >= len(messages) || trimmed[0].Role != "system" || hasUnresolvedAgentToolCalls(trimmed) {
		t.Fatalf("compaction must retain a valid tool transcript: %#v", trimmed)
	}
}

func TestAgentSessionKeepsSmallMessagesRegardlessOfMessageCount(t *testing.T) {
	messages := make([]agentModelMessage, 0, 200)
	for index := 0; index < 200; index++ {
		messages = append(messages, agentModelMessage{Role: "user", Content: "ok"})
	}
	trimmed := trimAgentSessionMessages(messages)
	if len(trimmed) != len(messages) {
		t.Fatalf("small messages must not be truncated by count: got %d want %d", len(trimmed), len(messages))
	}
}

func TestAgentRequestHistoryUsesTokenBudgetRatherThanMessageCount(t *testing.T) {
	history := make([]AgentMessage, 0, 200)
	for index := 0; index < 200; index++ {
		history = append(history, AgentMessage{Role: "user", Content: "ok"})
	}
	request := AgentTurnRequest{Message: "continue", Messages: history}
	if err := request.Validate(); err != nil {
		t.Fatalf("small history must not be rejected by message count: %v", err)
	}
	if got := agentMessagesFromRequest(history); len(got) != len(history) {
		t.Fatalf("request history must not be truncated by count: got %d want %d", len(got), len(history))
	}
}

func TestAgentTimelinePagesWithoutDiscardingHistory(t *testing.T) {
	server := testAgentServer(t)
	for index := 0; index < agentTimelinePageLimit+1; index++ {
		if err := server.appendAgentTimelineItem(context.Background(), "timeline-pages", agentTimelineMessage("user", fmt.Sprintf("message-%d", index))); err != nil {
			t.Fatal(err)
		}
	}
	latest, err := server.agentTimelinePage(context.Background(), "timeline-pages", 0, agentTimelinePageLimit)
	if err != nil || len(latest.Items) != agentTimelinePageLimit || latest.NextBefore == nil {
		t.Fatalf("latest timeline page = %#v, err=%v", latest, err)
	}
	earlier, err := server.agentTimelinePage(context.Background(), "timeline-pages", *latest.NextBefore, agentTimelinePageLimit)
	if err != nil || len(earlier.Items) != 1 || earlier.NextBefore != nil {
		t.Fatalf("earlier timeline page = %#v, err=%v", earlier, err)
	}
}

func TestLedgerAgentUpdatePreviewsOriginalBeancountAndRequiresApproval(t *testing.T) {
	installFakeBeanCheck(t)
	server := testAgentServer(t)
	file := filepath.Join(server.cfg.LedgerRoot, "transactions", "2026", "05.bean")
	hash := transactionHash([]string{`2026-05-01 * "Cafe" "Lunch" #work`, `  note: "noodles"`, "  Expenses:Food 12.00 CNY", "  Assets:Cash -12.00 CNY"})
	arguments := `{"source":{"file":"` + file + `","line":1,"hash":"` + hash + `"},"entry":{"kind":"transaction","date":"2026-05-01","payee":"Cafe","narration":"Dinner","metadata":{"note":"noodles"},"tags":["work"],"postings":[{"account":"Expenses:Food","amount":"13.80","currency":"CNY"},{"account":"Assets:Cash","amount":"-13.80","currency":"CNY"}],"confidence":1,"needsReview":false,"questions":[]}}`
	server.agentModel = &queuedAgentModel{results: []agentModelResult{{ToolCalls: []agentModelToolCall{{ID: "update-1", Type: "function", Function: agentModelFunctionCall{Name: "update_transaction", Arguments: arguments}}}}}}
	events := []capturedAgentEvent{}
	err := server.runAgentTurn(context.Background(), AgentTurnRequest{SessionID: "session-test-update", Message: "把午餐改成晚餐", Context: AgentPageContext{SensitiveUnlocked: true}}, func(name string, payload any) error {
		events = append(events, capturedAgentEvent{name: name, payload: payload})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(mustRead(t, file)), `"Dinner"`) {
		t.Fatal("agent updated before approval")
	}
	if !hasAgentArtifact(events, "transaction_change", `"Lunch"`, `"Dinner"`) {
		t.Fatalf("update approval must show original and replacement Beancount: %#v", events)
	}
	approval := agentApprovalFromEvents(t, events)
	if err := server.resolveAgentApproval(context.Background(), AgentApprovalRequest{SessionID: approval.SessionID, ApprovalID: approval.ID, Approved: true}, AgentPageContext{SensitiveUnlocked: true}, func(string, any) error { return nil }); err != nil {
		t.Fatal(err)
	}
	updated := string(mustRead(t, file))
	if !strings.Contains(updated, `"Dinner"`) || !strings.Contains(updated, "13.80 CNY") || strings.Contains(updated, `"Lunch"`) {
		t.Fatalf("approved update was not applied:\n%s", updated)
	}
}

func TestSearchTransactionsReturnsMajorUnitAmountsForAgent(t *testing.T) {
	server := testAgentServer(t)
	execution, err := server.agentTools()["search_transactions"].Execute(context.Background(), json.RawMessage(`{"query":"payee:Cafe"}`), AgentPageContext{SensitiveUnlocked: true})
	if err != nil {
		t.Fatal(err)
	}
	output, ok := execution.ModelOutput.(map[string]any)
	if !ok || output["amountUnit"] != "major" {
		t.Fatalf("search result must declare major units: %#v", execution.ModelOutput)
	}
	transactions, ok := output["transactions"].([]map[string]any)
	if !ok || len(transactions) != 1 {
		t.Fatalf("unexpected transactions: %#v", output["transactions"])
	}
	postings, ok := transactions[0]["postings"].([]map[string]any)
	if !ok || postings[0]["amount"] != "12.00" || postings[1]["amount"] != "-12.00" {
		t.Fatalf("agent must receive major unit strings, got %#v", transactions[0]["postings"])
	}
}

func TestLedgerAgentExposesCompleteTransactionWriteTools(t *testing.T) {
	tools := testAgentServer(t).agentTools()
	for _, name := range []string{"append_transactions", "update_transaction", "delete_transaction", "reverse_transaction"} {
		tool, ok := tools[name]
		if !ok || !tool.RequiresApproval {
			t.Fatalf("transaction write tool %q must be available and require approval: %#v", name, tool)
		}
	}
}

func agentApprovalFromEvents(t *testing.T, events []capturedAgentEvent) AgentApproval {
	t.Helper()
	for _, event := range events {
		if event.name != "approval_required" {
			continue
		}
		raw, _ := json.Marshal(event.payload)
		var approval AgentApproval
		if err := json.Unmarshal(raw, &approval); err != nil {
			t.Fatal(err)
		}
		return approval
	}
	t.Fatalf("approval event missing: %#v", events)
	return AgentApproval{}
}

func hasAgentArtifact(events []capturedAgentEvent, artifactType string, values ...string) bool {
	for _, event := range events {
		if event.name != "artifact" {
			continue
		}
		raw, _ := json.Marshal(event.payload)
		var artifact AgentArtifact
		if json.Unmarshal(raw, &artifact) != nil || artifact.Type != artifactType {
			continue
		}
		text := fmt.Sprint(artifact.Data)
		for _, value := range values {
			if !strings.Contains(text, value) {
				goto next
			}
		}
		return true
	next:
	}
	return false
}

func installFakeBeanCheck(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	name := "bean-check"
	content := "#!/bin/sh\nexit 0\n"
	if runtime.GOOS == "windows" {
		name = "bean-check.bat"
		content = "@exit /b 0\r\n"
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
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
		txService:      NewTransactionServiceWithSnapshot(cache, writer, func() (*LedgerSnapshot, error) { return readService.Snapshot(context.Background()) }),
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

func hasAgentToolEvent(events []capturedAgentEvent, name, id string) bool {
	for _, event := range events {
		if event.name != name {
			continue
		}
		payload, ok := event.payload.(map[string]any)
		if ok && payload["id"] == id {
			return true
		}
	}
	return false
}

func agentEventText(events []capturedAgentEvent, name string) string {
	parts := make([]string, 0, len(events))
	for _, event := range events {
		if event.name != name {
			continue
		}
		if payload, ok := event.payload.(map[string]any); ok {
			if text, ok := payload["text"].(string); ok {
				parts = append(parts, text)
			}
		}
	}
	return strings.Join(parts, "\n")
}

func containsAgentToolMessage(messages []agentModelMessage, callID string) bool {
	for _, message := range messages {
		if message.Role == "tool" && message.ToolCallID == callID {
			return true
		}
	}
	return false
}
