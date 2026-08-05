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

func TestAgentGatewayProxiesTurnAndMintsCapability(t *testing.T) {
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
	if received["sessionId"] != "session-test" || received["capabilityToken"] == "" || received["systemPrompt"] == "" {
		t.Fatalf("unexpected forwarded turn: %#v", received)
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
		callbackRequest, err := http.NewRequest(http.MethodGet, ledgerURL+"/api/internal/agent/tools", nil)
		if err != nil {
			callbackResult <- err
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		callbackRequest.Header.Set("X-Agent-Service-Token", "agent-secret")
		callbackResponse, err := (&http.Client{Timeout: 750 * time.Millisecond}).Do(callbackRequest)
		if err != nil {
			callbackResult <- err
			http.Error(w, err.Error(), http.StatusGatewayTimeout)
			return
		}
		defer callbackResponse.Body.Close()
		if callbackResponse.StatusCode != http.StatusOK {
			err := fmt.Errorf("tools callback status=%d", callbackResponse.StatusCode)
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
		t.Fatalf("Agent tools callback failed: %v", err)
	}
}

func TestAgentCapabilityRejectsTamperingAndWrongLedger(t *testing.T) {
	server := testAgentServer(t)
	server.cfg.AgentServiceToken = "agent-secret"
	token, err := server.mintAgentCapabilityToken(agentCapabilityClaims{
		SessionID: "session-test", ClusterID: ledgerClusterID(server.cfg), SensitiveUnlocked: true, ExpiresAt: time.Now().Add(time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := server.parseAgentCapabilityToken(token + "x"); err == nil {
		t.Fatal("tampered capability token must be rejected")
	}
	server.cfg.LedgerClusterID = "another-ledger"
	if _, err := server.parseAgentCapabilityToken(token); err == nil {
		t.Fatal("capability token from another ledger must be rejected")
	}
}

func TestInternalAgentToolsRequireServiceToken(t *testing.T) {
	server := testAgentServer(t)
	server.cfg.AgentServiceToken = "agent-secret"
	router := newRouter(server.cfg, server)
	unauthorized := requestWithCookies(router, http.MethodGet, "/api/internal/agent/tools", "", nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized tools status=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}
	req := httptest.NewRequest(http.MethodGet, "/api/internal/agent/tools", nil)
	req.Header.Set("X-Agent-Service-Token", "agent-secret")
	res := httptest.NewRecorder()
	router.ServeHTTP(res, req)
	if res.Code != http.StatusOK || !strings.Contains(res.Body.String(), "append_transactions") {
		t.Fatalf("tools status=%d body=%s", res.Code, res.Body.String())
	}
}

func TestAgentCapabilityExecutionResponseUsesEmptyArtifactArray(t *testing.T) {
	response := agentCapabilityExecutionResponse(agentToolExecution{
		ModelOutput:  map[string]any{"ok": true},
		ClientOutput: map[string]any{"ok": true},
	})
	payload, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(payload), `"artifacts":[]`) {
		t.Fatalf("empty artifacts must be encoded as an array: %s", payload)
	}
}

func TestWriteCapabilityRequiresMatchingPreviewConfirmation(t *testing.T) {
	server := testAgentServer(t)
	server.cfg.AgentServiceToken = "agent-secret"
	router := newRouter(server.cfg, server)
	capability, err := server.mintAgentCapabilityToken(agentCapabilityClaims{
		SessionID: "session-write", ClusterID: ledgerClusterID(server.cfg),
		SensitiveUnlocked: true, Context: AgentPageContext{SensitiveUnlocked: true},
		AllowedTools: []string{"upsert_memory"},
		ExpiresAt: time.Now().Add(time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	arguments := map[string]any{"kind": "preference", "title": "月度汇总", "instruction": "优先给出简洁的月度汇总。"}
	body, _ := json.Marshal(map[string]any{"arguments": arguments})
	request := func(path string, payload []byte) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(string(payload)))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+capability)
		res := httptest.NewRecorder()
		router.ServeHTTP(res, req)
		return res
	}

	preview := request("/api/internal/agent/tools/upsert_memory/preview", body)
	if preview.Code != http.StatusOK {
		t.Fatalf("preview status=%d body=%s", preview.Code, preview.Body.String())
	}
	var previewBody struct {
		ConfirmationToken string `json:"confirmationToken"`
	}
	if err := json.Unmarshal(preview.Body.Bytes(), &previewBody); err != nil || previewBody.ConfirmationToken == "" {
		t.Fatalf("preview confirmation token missing: body=%s err=%v", preview.Body.String(), err)
	}
	withoutConfirmation := request("/api/internal/agent/tools/upsert_memory/execute", body)
	if withoutConfirmation.Code != http.StatusForbidden {
		t.Fatalf("write without confirmation status=%d body=%s", withoutConfirmation.Code, withoutConfirmation.Body.String())
	}
	executeBody, _ := json.Marshal(map[string]any{"arguments": arguments, "confirmationToken": previewBody.ConfirmationToken})
	executed := request("/api/internal/agent/tools/upsert_memory/execute", executeBody)
	if executed.Code != http.StatusOK {
		t.Fatalf("confirmed write status=%d body=%s", executed.Code, executed.Body.String())
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
	examples, ok := capabilities["examples"].([]string)
	if !ok || !strings.Contains(strings.Join(examples, "\n"), "account LIKE 'Expenses:%'") {
		t.Fatalf("BQL capabilities must include a valid expense query: %#v", capabilities)
	}
	fieldNotes, ok := capabilities["fieldNotes"].(map[string]any)
	if !ok || !strings.Contains(fmt.Sprint(fieldNotes["type"]), "expense, income, transfer") {
		t.Fatalf("BQL capabilities must explain type values: %#v", capabilities)
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
		if !ok || !tool.RequiresApproval || tool.ReadOnly {
			t.Fatalf("transaction write tool %q must require approval: %#v", name, tool)
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
