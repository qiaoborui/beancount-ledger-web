package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
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

func TestAgentGatewayProxiesTurnWithMCPContext(t *testing.T) {
	var received map[string]any
	fakeAgent := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/channels/web/messages" || r.Header.Get("X-Agent-Service-Token") != "agent-secret" {
			t.Fatalf("unexpected Agent request: %s token=%q", r.URL.Path, r.Header.Get("X-Agent-Service-Token"))
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("event: final\ndata: {\"status\":\"completed\"}\n\n"))
	}))
	defer fakeAgent.Close()

	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	server.cfg.AgentServiceURL = fakeAgent.URL
	server.cfg.AgentServiceToken = "agent-secret"
	res := requestWithCookies(newRouter(server.cfg, server), http.MethodPost, "/api/ai/agent/turn", `{"sessionId":"session-test","message":"看看本月支出"}`, nil)
	if res.Code != http.StatusOK || !strings.Contains(res.Body.String(), "event: final") {
		t.Fatalf("Agent proxy status=%d body=%s", res.Code, res.Body.String())
	}
	contextPayload, _ := received["context"].(map[string]any)
	if received["sessionId"] != "session-test" || received["systemPrompt"] == "" || received["mcpSystemPrompt"] == "" || received["capabilityToken"] == "" || contextPayload["sensitiveUnlocked"] != true {
		t.Fatalf("unexpected forwarded turn: %#v", received)
	}
	if strings.Contains(received["systemPrompt"].(string), "ledger_get_ledger_summary") || !strings.Contains(received["mcpSystemPrompt"].(string), "ledger_get_ledger_summary") {
		t.Fatalf("forwarded prompts must support legacy and MCP agents: %#v", received)
	}
}

func TestAgentGatewayDoesNotDeadlockWhenRuntimeConfigRefreshIsDueDuringCallback(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	server.cfg.AgentServiceToken = "agent-secret"
	server.runtimeConfig = &RuntimeConfigStore{}
	server.cfgRefreshedAt = time.Now()

	var ledgerURL string
	callbackResult := make(chan error, 1)
	fakeAgent := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/channels/web/messages" {
			http.Error(w, "unexpected Agent path", http.StatusNotFound)
			return
		}
		time.Sleep(2100 * time.Millisecond)
		callbackRequest, err := http.NewRequest(http.MethodPost, ledgerURL+"/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"deadlock-test","version":"1"}}}`))
		if err != nil {
			callbackResult <- err
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		callbackRequest.Header.Set("Authorization", "Bearer agent-secret")
		callbackRequest.Header.Set("Content-Type", "application/json")
		callbackRequest.Header.Set("Accept", "application/json, text/event-stream")
		callbackResponse, err := (&http.Client{Timeout: 750 * time.Millisecond}).Do(callbackRequest)
		if err != nil {
			callbackResult <- err
			http.Error(w, err.Error(), http.StatusGatewayTimeout)
			return
		}
		defer callbackResponse.Body.Close()
		if callbackResponse.StatusCode != http.StatusOK {
			err := fmt.Errorf("MCP callback status=%d", callbackResponse.StatusCode)
			callbackResult <- err
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		callbackResult <- nil
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("event: final\ndata: {\"status\":\"completed\"}\n\n"))
	}))
	defer fakeAgent.Close()
	server.cfg.AgentServiceURL = fakeAgent.URL

	ledgerServer := httptest.NewServer(newRouter(server.cfg, server))
	defer ledgerServer.Close()
	ledgerURL = ledgerServer.URL

	request, err := http.NewRequest(http.MethodPost, ledgerURL+"/api/ai/agent/turn", strings.NewReader(`{"sessionId":"session-test","message":"看看本月支出"}`))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 5 * time.Second}).Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), "event: final") {
		t.Fatalf("Agent proxy status=%d body=%s", response.StatusCode, body)
	}
	if err := <-callbackResult; err != nil {
		t.Fatalf("Agent MCP callback failed: %v", err)
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
	if !ok || model["amountUnit"] != "major" {
		t.Fatalf("unexpected model output: %#v", execution.ModelOutput)
	}
	rows, ok := model["rows"].([]map[string]any)
	if !ok || len(rows) != 1 || rows[0]["total"] != "12.00" {
		t.Fatalf("money must use major units for the model: %#v", model["rows"])
	}
}

func TestBQLCapabilitiesExplainExpenseFiltering(t *testing.T) {
	capabilities := bqlCapabilities()
	if capabilities["dialectVersion"] != bqlDialectVersion {
		t.Fatalf("unexpected BQL dialect version: %#v", capabilities["dialectVersion"])
	}
	examples, ok := capabilities["examples"].([]string)
	if !ok || !strings.Contains(strings.Join(examples, "\n"), "account LIKE 'Expenses:%'") {
		t.Fatalf("BQL capabilities must include a valid expense query: %#v", capabilities)
	}
	fieldNotes, ok := capabilities["fieldNotes"].(map[string]any)
	if !ok || !strings.Contains(fmt.Sprint(fieldNotes["type"]), "expense, income, transfer") {
		t.Fatalf("BQL capabilities must explain type values: %#v", capabilities)
	}
}

func TestValidateBQLToolReturnsStructuredResults(t *testing.T) {
	tool := testAgentServer(t).agentTools()["validate_bql"]
	valid, err := tool.Execute(context.Background(), json.RawMessage(`{"query":"SELECT date FROM transactions WHERE payee = 'Cafe'"}`), AgentPageContext{})
	if err != nil {
		t.Fatal(err)
	}
	validOutput := valid.ModelOutput.(map[string]any)
	if validOutput["valid"] != true || validOutput["dialectVersion"] != bqlDialectVersion || len(valid.Artifacts) != 1 {
		t.Fatalf("unexpected valid BQL result: %#v artifacts=%#v", validOutput, valid.Artifacts)
	}

	invalid, err := tool.Execute(context.Background(), json.RawMessage(`{"query":"SELECT date FROM transactions WHERE payee OR 'Cafe'"}`), AgentPageContext{})
	if err != nil {
		t.Fatalf("invalid BQL must return a structured validation result: %v", err)
	}
	invalidOutput := invalid.ModelOutput.(map[string]any)
	issue, ok := invalidOutput["error"].(bqlValidationIssue)
	if invalidOutput["valid"] != false || invalidOutput["dialectVersion"] != bqlDialectVersion || !ok {
		t.Fatalf("unexpected invalid BQL result: %#v", invalidOutput)
	}
	if issue.Code != "expected_operator" || issue.Clause != "WHERE" || issue.Position != 7 || !containsString(issue.Expected, "=") {
		t.Fatalf("unexpected structured validation issue: %#v", issue)
	}
	if len(invalid.Artifacts) != 0 {
		t.Fatalf("invalid BQL must not create artifacts: %#v", invalid.Artifacts)
	}
}

func TestAgentPromptsAvoidRedundantBQLValidation(t *testing.T) {
	for name, prompt := range map[string]string{
		"web":      agentSystemPrompt(AgentPageContext{}, nil),
		"telegram": agentTelegramSystemPrompt(AgentPageContext{}, nil),
	} {
		t.Run(name, func(t *testing.T) {
			if !strings.Contains(prompt, "需要") || !strings.Contains(prompt, "直接调用 run_bql") || !strings.Contains(prompt, "最多重试一次") {
				t.Fatalf("prompt must explain the direct execution flow: %q", prompt)
			}
			if strings.Contains(prompt, "先读取能力并校验") {
				t.Fatalf("prompt must not require redundant validation: %q", prompt)
			}
		})
	}
}

func TestAgentMemoryToolsRequireSensitiveUnlockAndRejectSecrets(t *testing.T) {
	server := testAgentServer(t)
	if _, err := server.agentTools()["search_memories"].Execute(context.Background(), json.RawMessage(`{}`), AgentPageContext{}); err == nil {
		t.Fatal("memory search must require sensitive unlock")
	}
	if _, err := server.upsertAgentMemory(context.Background(), agentMemoryInput{Kind: "preference", Title: "密码", Instruction: "123456789012"}); err == nil {
		t.Fatal("sensitive memory content must be rejected")
	}
	if err := (AgentTurnRequest{Message: "我的 OTP 是 123456"}).Validate(); err == nil {
		t.Fatal("sensitive Agent input must be rejected")
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

func TestLedgerSummaryAndSearchUseMajorUnitsForModelOutput(t *testing.T) {
	server := testAgentServer(t)
	summaryExecution, err := server.agentTools()["get_ledger_summary"].Execute(context.Background(), json.RawMessage(`{"start":"2026-05-01","end":"2026-06-01"}`), AgentPageContext{SensitiveUnlocked: true})
	if err != nil {
		t.Fatal(err)
	}
	output := summaryExecution.ModelOutput.(map[string]any)
	if output["amountUnit"] != "major" || output["summary"].(map[string]any)["expense"] != "12.00" {
		t.Fatalf("summary money must use major units: %#v", output)
	}
	searchExecution, err := server.agentTools()["search_transactions"].Execute(context.Background(), json.RawMessage(`{"query":"payee:Cafe"}`), AgentPageContext{SensitiveUnlocked: true})
	if err != nil {
		t.Fatal(err)
	}
	search := searchExecution.ModelOutput.(map[string]any)
	transactions := search["transactions"].([]map[string]any)
	postings := transactions[0]["postings"].([]map[string]any)
	if search["amountUnit"] != "major" || postings[0]["amount"] != "12.00" || postings[1]["amount"] != "-12.00" {
		t.Fatalf("search money must use major units: %#v", search)
	}
}

func TestLedgerAgentExposesCompleteTransactionWriteTools(t *testing.T) {
	tools := testAgentServer(t).agentTools()
	for _, name := range []string{"append_transactions", "update_transaction", "delete_transaction", "reverse_transaction"} {
		tool, ok := tools[name]
		if !ok || tool.ReadOnly {
			t.Fatalf("transaction write tool %q must be present and writable: %#v", name, tool)
		}
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
		txService:      NewTransactionServiceWithSnapshot(cache, writer, func() (*LedgerSnapshot, error) { return readService.Snapshot(context.Background()) }),
		queryPort:      readService,
		snapshotPort:   readService,
		limiter:        NewRateLimiter(),
	}
}
