package app

import (
	"context"
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

func TestAgentAccessTokenBootstrapIsReadOnlyAndRevocable(t *testing.T) {
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
	for _, tool := range bootstrapBody.Tools {
		if !tool.ReadOnly || tool.Name == "append_transactions" {
			t.Fatalf("external bootstrap exposed write tool: %#v", tool)
		}
	}

	writeRequest := httptest.NewRequest(http.MethodPost, "/api/internal/agent/tools/append_transactions/execute", strings.NewReader(`{"arguments":{"entries":[]}}`))
	writeRequest.Header.Set("Content-Type", "application/json")
	writeRequest.Header.Set("Authorization", "Bearer "+bootstrapBody.CapabilityToken)
	writeResponse := httptest.NewRecorder()
	router.ServeHTTP(writeResponse, writeRequest)
	if writeResponse.Code != http.StatusForbidden {
		t.Fatalf("read-only capability write status=%d body=%s", writeResponse.Code, writeResponse.Body.String())
	}

	revoked := requestWithCookies(router, http.MethodDelete, "/api/agent/access-tokens/"+createBody.Credential.ID, "", nil)
	if revoked.Code != http.StatusNoContent {
		t.Fatalf("revoke status=%d body=%s", revoked.Code, revoked.Body.String())
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

type stubAgentTokenWrite struct {
	enabled bool
}

func (s stubAgentTokenWrite) AgentTokenWriteEnabled(context.Context) (bool, error) {
	return s.enabled, nil
}

func TestAgentAccessTokenBootstrapCanEnableWrite(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	server.cfg.AgentServiceToken = "agent-service-secret"
	server.agentTokenWrite = stubAgentTokenWrite{enabled: true}
	router := newRouter(server.cfg, server)

	created := requestWithCookies(router, http.MethodPost, "/api/agent/access-tokens", `{"name":"Local Write Bub"}`, nil)
	if created.Code != http.StatusCreated {
		t.Fatalf("create token status=%d body=%s", created.Code, created.Body.String())
	}
	var createBody struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(created.Body.Bytes(), &createBody); err != nil {
		t.Fatal(err)
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
			Name             string `json:"name"`
			ReadOnly         bool   `json:"readOnly"`
			RequiresApproval bool   `json:"requiresApproval"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(bootstrap.Body.Bytes(), &bootstrapBody); err != nil {
		t.Fatal(err)
	}
	if bootstrapBody.CapabilityToken == "" || len(bootstrapBody.Tools) == 0 {
		t.Fatalf("bootstrap missing capability or tools: %s", bootstrap.Body.String())
	}
	var writeTool *struct {
		Name             string `json:"name"`
		ReadOnly         bool   `json:"readOnly"`
		RequiresApproval bool   `json:"requiresApproval"`
	}
	for index := range bootstrapBody.Tools {
		tool := &bootstrapBody.Tools[index]
		if tool.Name == "append_transactions" {
			writeTool = tool
		}
	}
	if writeTool == nil {
		t.Fatalf("write-enabled external bootstrap is missing append_transactions: %s", bootstrap.Body.String())
	}
	if writeTool.ReadOnly || writeTool.RequiresApproval {
		t.Fatalf("write-enabled external bootstrap must expose append_transactions without approval: %#v", writeTool)
	}
	if !strings.Contains(bootstrapBody.SystemPrompt, "本地模式") || !strings.Contains(bootstrapBody.SystemPrompt, "询问确认") || !strings.Contains(bootstrapBody.SystemPrompt, "明确回复确认") {
		t.Fatalf("write-enabled bootstrap system prompt must require in-dialog confirmation before writes: %s", bootstrapBody.SystemPrompt)
	}

	claims, err := server.parseAgentCapabilityToken(bootstrapBody.CapabilityToken)
	if err != nil {
		t.Fatalf("parse capability token: %v", err)
	}
	if !claims.Trusted {
		t.Fatalf("write-enabled capability must be trusted: %#v", claims)
	}

	writeRequest := httptest.NewRequest(http.MethodPost, "/api/internal/agent/tools/append_transactions/execute", strings.NewReader(`{"arguments":{"entries":[]}}`))
	writeRequest.Header.Set("Content-Type", "application/json")
	writeRequest.Header.Set("Authorization", "Bearer "+bootstrapBody.CapabilityToken)
	writeResponse := httptest.NewRecorder()
	router.ServeHTTP(writeResponse, writeRequest)
	if writeResponse.Code != http.StatusBadRequest {
		t.Fatalf("trusted write execute status=%d body=%s (want 400: empty entries rejected before write)", writeResponse.Code, writeResponse.Body.String())
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
			Name     string `json:"name"`
			ReadOnly bool   `json:"readOnly"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	foundWriteTool := false
	foundOpenPage := false
	for _, tool := range body.Tools {
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
		!strings.Contains(body.SystemPrompt, "系统会自动展示") {
		t.Fatalf("telegram bootstrap must use the Telegram system prompt: %s", response.Body.String())
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
