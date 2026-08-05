package app

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAgentAccessTokenEncoding(t *testing.T) {
	id, secret, raw, err := newAgentAccessToken()
	if err != nil {
		t.Fatal(err)
	}
	parsedID, parsedSecret, ok := parseAgentAccessToken(raw)
	if !ok || parsedID != id || parsedSecret != secret {
		t.Fatalf("token round trip failed: id=%q secret=%q ok=%v", parsedID, parsedSecret, ok)
	}
	for _, invalid := range []string{"", "blw_agent_", "blw_agent_only-id", "wrong_" + id + "_" + secret} {
		if _, _, ok := parseAgentAccessToken(invalid); ok {
			t.Fatalf("invalid token accepted: %q", invalid)
		}
	}
	underscoreID := "___________A"
	underscoreSecret := "__________________________________________A"
	parsedID, parsedSecret, ok = parseAgentAccessToken(agentAccessTokenPrefix + underscoreID + "_" + underscoreSecret)
	if !ok || parsedID != underscoreID || parsedSecret != underscoreSecret {
		t.Fatalf("token with URL-safe underscores did not parse: id=%q secret=%q ok=%v", parsedID, parsedSecret, ok)
	}
}

func TestAgentAccessTokenManagementRequiresSensitiveUnlock(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	t.Setenv("AUTH_SECRET", "agent-access-token-test-secret")
	router := testRouter(t, cfg)
	cookies := loginCookies(t, router)
	lockedCookies := make([]*http.Cookie, 0, len(cookies))
	for _, cookie := range cookies {
		if cookie.Name != sensitiveCookieName {
			lockedCookies = append(lockedCookies, cookie)
		}
	}

	for _, method := range []string{http.MethodGet, http.MethodPost} {
		body := ""
		if method == http.MethodPost {
			body = `{"name":"Local Bub"}`
		}
		res := requestWithCookies(router, method, "/api/agent/access-tokens", body, lockedCookies)
		if res.Code != http.StatusLocked {
			t.Fatalf("locked token management status=%d method=%s body=%s", res.Code, method, res.Body.String())
		}
	}
}

func TestAgentAccessTokenNameLimitCountsCharacters(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	router := newRouter(server.cfg, server)
	name := strings.Repeat("账", 64)

	created := requestWithCookies(router, http.MethodPost, "/api/agent/access-tokens", `{"name":"`+name+`"}`, nil)

	if created.Code != http.StatusCreated {
		t.Fatalf("64-character token name status=%d body=%s", created.Code, created.Body.String())
	}
}

func TestAgentAccessTokenBootstrapIncludesWriteToolsAndIsRevocable(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	server.cfg.AgentServiceToken = "agent-service-secret"
	router := newRouter(server.cfg, server)

	created := requestWithCookies(router, http.MethodPost, "/api/agent/access-tokens", `{"name":"Laptop Bub"}`, nil)
	if created.Code != http.StatusCreated {
		t.Fatalf("create token status=%d body=%s", created.Code, created.Body.String())
	}
	var createBody struct {
		Token      string                  `json:"token"`
		Credential agentAccessTokenSummary `json:"credential"`
	}
	if err := json.Unmarshal(created.Body.Bytes(), &createBody); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(createBody.Token, "blw_agent_") || createBody.Credential.ID == "" {
		t.Fatalf("unexpected create response: %s", created.Body.String())
	}

	listed := requestWithCookies(router, http.MethodGet, "/api/agent/access-tokens", "", nil)
	if listed.Code != http.StatusOK || strings.Contains(listed.Body.String(), createBody.Token) || strings.Contains(listed.Body.String(), "secretHash") {
		t.Fatalf("token list leaked secret status=%d body=%s", listed.Code, listed.Body.String())
	}

	bootstrapRequest := httptest.NewRequest(http.MethodPost, "/api/agent/bootstrap", strings.NewReader(`{"sessionId":"cli:local","channel":"cli","context":{}}`))
	bootstrapRequest.Header.Set("Content-Type", "application/json")
	bootstrapRequest.Header.Set("Authorization", "Bearer "+createBody.Token)
	bootstrap := httptest.NewRecorder()
	router.ServeHTTP(bootstrap, bootstrapRequest)
	if bootstrap.Code != http.StatusOK {
		t.Fatalf("bootstrap status=%d body=%s", bootstrap.Code, bootstrap.Body.String())
	}
	var bootstrapBody struct {
		CapabilityToken string `json:"capabilityToken"`
		SystemPrompt    string `json:"systemPrompt"`
		Tools           []struct {
			Name     string `json:"name"`
			ReadOnly bool   `json:"readOnly"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(bootstrap.Body.Bytes(), &bootstrapBody); err != nil {
		t.Fatal(err)
	}
	if bootstrapBody.CapabilityToken == "" || len(bootstrapBody.Tools) == 0 {
		t.Fatalf("bootstrap missing capability or tools: %s", bootstrap.Body.String())
	}
	writeToolFound := false
	for _, tool := range bootstrapBody.Tools {
		if tool.Name == "append_transactions" {
			writeToolFound = true
			if tool.ReadOnly {
				t.Fatalf("append_transactions must be exposed as a write tool: %#v", tool)
			}
		}
	}
	if !writeToolFound {
		t.Fatalf("external bootstrap is missing append_transactions: %s", bootstrap.Body.String())
	}
	if !strings.Contains(bootstrapBody.SystemPrompt, "不会弹出程序审批框") || !strings.Contains(bootstrapBody.SystemPrompt, "紧邻上一条助手回复") {
		t.Fatalf("bootstrap system prompt must require cross-turn conversational confirmation: %s", bootstrapBody.SystemPrompt)
	}

	writeRequest := httptest.NewRequest(http.MethodPost, "/api/internal/agent/tools/append_transactions/execute", strings.NewReader(`{"arguments":{"entries":[]}}`))
	writeRequest.Header.Set("Content-Type", "application/json")
	writeRequest.Header.Set("Authorization", "Bearer "+bootstrapBody.CapabilityToken)
	writeResponse := httptest.NewRecorder()
	router.ServeHTTP(writeResponse, writeRequest)
	if writeResponse.Code != http.StatusBadRequest {
		t.Fatalf("write execute status=%d body=%s (want 400: empty entries rejected before write)", writeResponse.Code, writeResponse.Body.String())
	}

	revoked := requestWithCookies(router, http.MethodDelete, "/api/agent/access-tokens/"+createBody.Credential.ID, "", nil)
	if revoked.Code != http.StatusNoContent {
		t.Fatalf("revoke status=%d body=%s", revoked.Code, revoked.Body.String())
	}
	writeAfterRevoke := httptest.NewRecorder()
	requestAfterCapabilityRevoke := httptest.NewRequest(http.MethodPost, "/api/internal/agent/tools/append_transactions/execute", strings.NewReader(`{"arguments":{"entries":[]}}`))
	requestAfterCapabilityRevoke.Header.Set("Content-Type", "application/json")
	requestAfterCapabilityRevoke.Header.Set("Authorization", "Bearer "+bootstrapBody.CapabilityToken)
	router.ServeHTTP(writeAfterRevoke, requestAfterCapabilityRevoke)
	if writeAfterRevoke.Code != http.StatusUnauthorized {
		t.Fatalf("revoked token capability status=%d body=%s", writeAfterRevoke.Code, writeAfterRevoke.Body.String())
	}
	bootstrapAfterRevoke := httptest.NewRecorder()
	requestAfterRevoke := httptest.NewRequest(http.MethodPost, "/api/agent/bootstrap", strings.NewReader(`{"sessionId":"cli:local","channel":"cli"}`))
	requestAfterRevoke.Header.Set("Content-Type", "application/json")
	requestAfterRevoke.Header.Set("Authorization", "Bearer "+createBody.Token)
	router.ServeHTTP(bootstrapAfterRevoke, requestAfterRevoke)
	if bootstrapAfterRevoke.Code != http.StatusUnauthorized {
		t.Fatalf("revoked token bootstrap status=%d body=%s", bootstrapAfterRevoke.Code, bootstrapAfterRevoke.Body.String())
	}
}

func TestExpiredAndInvalidAgentAccessTokensAreRejected(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	router := newRouter(server.cfg, server)
	id, secret, raw, err := newAgentAccessToken()
	if err != nil {
		t.Fatal(err)
	}
	if err := server.writeAgentAccessTokens(t.Context(), agentAccessTokenStore{Tokens: []agentAccessTokenRecord{{
		ID: id, Name: "Expired", SecretHash: agentAccessSecretHash(secret),
		CreatedAt: time.Now().Add(-2 * time.Hour), ExpiresAt: time.Now().Add(-time.Hour),
	}}}); err != nil {
		t.Fatal(err)
	}
	for _, token := range []string{raw, "blw_agent_invalid_invalid"} {
		request := httptest.NewRequest(http.MethodPost, "/api/agent/model/chat/completions", strings.NewReader(`{"model":"ledger-agent","messages":[]}`))
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		router.ServeHTTP(response, request)
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("invalid model token status=%d token=%q body=%s", response.Code, token, response.Body.String())
		}
	}
}

func TestExternalAgentModelProxyKeepsProviderCredentialsServerSide(t *testing.T) {
	var received map[string]any
	fakeAI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" || r.Header.Get("Authorization") != "Bearer provider-secret" {
			t.Fatalf("unexpected provider request path=%s auth=%q", r.URL.Path, r.Header.Get("Authorization"))
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"ok"}}]}`))
	}))
	defer fakeAI.Close()
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	t.Setenv("LEDGER_AI_PROVIDER", "openai")
	t.Setenv("OPENAI_API_KEY", "provider-secret")
	t.Setenv("OPENAI_BASE_URL", fakeAI.URL)
	t.Setenv("OPENAI_MODEL", "server-model")
	server := testAgentServer(t)
	router := newRouter(server.cfg, server)

	created := requestWithCookies(router, http.MethodPost, "/api/agent/access-tokens", `{"name":"Laptop"}`, nil)
	var credential struct {
		Token string `json:"token"`
	}
	if created.Code != http.StatusCreated || json.Unmarshal(created.Body.Bytes(), &credential) != nil {
		t.Fatalf("create token status=%d body=%s", created.Code, created.Body.String())
	}
	request := httptest.NewRequest(http.MethodPost, "/api/agent/model/chat/completions", strings.NewReader(`{"model":"client-model","messages":[{"role":"user","content":"hi"}]}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+credential.Token)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)

	if response.Code != http.StatusOK || received["model"] != "server-model" || strings.Contains(response.Body.String(), "provider-secret") {
		t.Fatalf("model proxy status=%d received=%#v body=%s", response.Code, received, response.Body.String())
	}
}

func TestInternalAgentBootstrapUsesTelegramPromptAndToolSubset(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	server.cfg.AgentServiceToken = "gateway-secret"
	router := newRouter(server.cfg, server)

	unauthorized := requestWithCookies(router, http.MethodPost, "/api/internal/agent/bootstrap", `{"sessionId":"telegram:123","channel":"telegram"}`, nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("internal bootstrap without service token status=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}

	request := httptest.NewRequest(http.MethodPost, "/api/internal/agent/bootstrap", strings.NewReader(`{"sessionId":"telegram:123","channel":"telegram","context":{}}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Agent-Service-Token", "gateway-secret")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("internal bootstrap status=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		CapabilityToken string `json:"capabilityToken"`
		SystemPrompt    string `json:"systemPrompt"`
		Tools           []struct {
			Name        string `json:"name"`
			Description string `json:"description"`
			ReadOnly    bool   `json:"readOnly"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	foundWriteTool := false
	foundOpenPage := false
	descriptions := map[string]string{}
	for _, tool := range body.Tools {
		descriptions[tool.Name] = tool.Description
		if tool.Name == "append_transactions" && !tool.ReadOnly {
			foundWriteTool = true
		}
		if tool.Name == "open_page" {
			foundOpenPage = true
		}
	}
	if body.CapabilityToken == "" || !foundWriteTool {
		t.Fatalf("internal bootstrap missing capability or write tools: %s", response.Body.String())
	}
	if foundOpenPage {
		t.Fatalf("telegram bootstrap must not expose web-only open_page tool: %s", response.Body.String())
	}
	if !strings.Contains(body.SystemPrompt, "Telegram") ||
		!strings.Contains(body.SystemPrompt, "问候、闲聊或不明确的请求") ||
		!strings.Contains(body.SystemPrompt, "优先只调用 get_ledger_summary") ||
		!strings.Contains(body.SystemPrompt, "不要用 run_bql 重复验证") ||
		!strings.Contains(body.SystemPrompt, "不得用于一般账本查询、统计或探索") ||
		!strings.Contains(body.SystemPrompt, "结果是否已经足以回答用户原问题") ||
		!strings.Contains(body.SystemPrompt, "不得为了探索相邻问题而调用额外工具") ||
		!strings.Contains(body.SystemPrompt, "原问题确实需要时可以使用多个工具") ||
		!strings.Contains(body.SystemPrompt, "不会弹出程序审批框") ||
		!strings.Contains(body.SystemPrompt, "下一条消息明确确认") ||
		!strings.Contains(body.SystemPrompt, "sender_id") ||
		!strings.Contains(body.SystemPrompt, "确认写入") {
		t.Fatalf("telegram bootstrap must use the Telegram system prompt: %s", response.Body.String())
	}
	if !strings.Contains(descriptions["get_ledger_summary"], "首选工具") ||
		!strings.Contains(descriptions["run_bql"], "仅在 get_ledger_summary 无法回答") ||
		!strings.Contains(descriptions["run_bql"], "不要用它重复验证") ||
		!strings.Contains(descriptions["search_memories"], "不得用于一般账本查询、统计或探索") {
		t.Fatalf("telegram tool descriptions lack routing policy: %#v", descriptions)
	}
	claims, err := server.parseAgentCapabilityToken(body.CapabilityToken)
	if err != nil || claims.Subject != "channel:telegram" || claims.SessionID == "telegram:123" {
		t.Fatalf("unexpected internal bootstrap claims: %#v err=%v", claims, err)
	}
}

func TestAgentTelegramToolNamesOnlyRemovesWebNavigation(t *testing.T) {
	got := agentTelegramToolNames([]string{"get_accounts", "open_page", "append_transactions"})
	want := []string{"get_accounts", "append_transactions"}
	if len(got) != len(want) {
		t.Fatalf("telegram tool names = %v, want %v", got, want)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("telegram tool names = %v, want %v", got, want)
		}
	}
}
