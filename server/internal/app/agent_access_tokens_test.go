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

func TestAgentAccessTokenScopesDefaultReadOnlyAndPreserveLegacyAccess(t *testing.T) {
	readScopes, err := normalizeAgentAccessScopes(nil)
	if err != nil || len(readScopes) != 1 || readScopes[0] != agentAccessScopeRead {
		t.Fatalf("default scopes = %v err=%v", readScopes, err)
	}
	writeScopes, err := normalizeAgentAccessScopes([]string{agentAccessScopeWrite})
	if err != nil || len(writeScopes) != 2 || !agentAccessTokenCanWrite(agentAccessTokenRecord{Scopes: writeScopes}) {
		t.Fatalf("write scopes = %v err=%v", writeScopes, err)
	}
	if agentAccessTokenCanWrite(agentAccessTokenRecord{Scopes: readScopes}) {
		t.Fatal("read-only token must not allow writes")
	}
	if !agentAccessTokenCanWrite(agentAccessTokenRecord{}) {
		t.Fatal("legacy token without scopes must retain write access")
	}
	if _, err := normalizeAgentAccessScopes([]string{"admin"}); err == nil {
		t.Fatal("unknown scopes must be rejected")
	}
}

func TestAgentAccessTokenAPIStoresScopesWithoutLeakingSecret(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	router := newRouter(server.cfg, server)
	created := requestWithCookies(router, http.MethodPost, "/api/agent/access-tokens", `{"name":"Laptop Bub","scopes":["write"]}`, nil)
	if created.Code != http.StatusCreated {
		t.Fatalf("create token status=%d body=%s", created.Code, created.Body.String())
	}
	var body struct {
		Token      string                  `json:"token"`
		Credential agentAccessTokenSummary `json:"credential"`
	}
	if err := json.Unmarshal(created.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(body.Token, agentAccessTokenPrefix) || strings.Join(body.Credential.Scopes, ",") != "read,write" {
		t.Fatalf("unexpected create response: %s", created.Body.String())
	}
	listed := requestWithCookies(router, http.MethodGet, "/api/agent/access-tokens", "", nil)
	if listed.Code != http.StatusOK || strings.Contains(listed.Body.String(), body.Token) || strings.Contains(listed.Body.String(), "secretHash") {
		t.Fatalf("token list leaked secret status=%d body=%s", listed.Code, listed.Body.String())
	}
	revoked := requestWithCookies(router, http.MethodDelete, "/api/agent/access-tokens/"+body.Credential.ID, "", nil)
	if revoked.Code != http.StatusNoContent {
		t.Fatalf("revoke status=%d body=%s", revoked.Code, revoked.Body.String())
	}
}

func TestLegacyBootstrapBridgeHonorsTokenScopes(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	server.cfg.AgentServiceToken = "agent-service-secret"
	router := newRouter(server.cfg, server)

	for _, testCase := range []struct {
		name      string
		scopes    []string
		wantWrite bool
	}{{"read", []string{agentAccessScopeRead}, false}, {"write", []string{agentAccessScopeRead, agentAccessScopeWrite}, true}} {
		t.Run(testCase.name, func(t *testing.T) {
			token := storeMCPTestToken(t, server, testCase.name, testCase.scopes)
			request := httptest.NewRequest(http.MethodPost, "/api/agent/bootstrap", strings.NewReader(`{"sessionId":"cli:local","channel":"cli","context":{}}`))
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set("Authorization", "Bearer "+token)
			response := httptest.NewRecorder()
			router.ServeHTTP(response, request)
			if response.Code != http.StatusOK {
				t.Fatalf("bootstrap status=%d body=%s", response.Code, response.Body.String())
			}
			var body struct {
				CapabilityToken string `json:"capabilityToken"`
				Deprecated      bool   `json:"deprecated"`
				Tools           []struct {
					Name string `json:"name"`
				} `json:"tools"`
			}
			if json.Unmarshal(response.Body.Bytes(), &body) != nil || body.CapabilityToken == "" || !body.Deprecated {
				t.Fatalf("invalid legacy bootstrap: %s", response.Body.String())
			}
			foundWrite := false
			for _, tool := range body.Tools {
				foundWrite = foundWrite || tool.Name == "append_transactions"
			}
			if foundWrite != testCase.wantWrite {
				t.Fatalf("write tool visibility=%v want=%v tools=%#v", foundWrite, testCase.wantWrite, body.Tools)
			}
		})
	}
}

func TestLegacyHostedAgentBridgeBootstrapsAndExecutes(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	server.cfg.AgentServiceToken = "gateway-secret"
	router := newRouter(server.cfg, server)

	request := httptest.NewRequest(http.MethodPost, "/api/internal/agent/bootstrap", strings.NewReader(`{"sessionId":"telegram:123","channel":"telegram","context":{}}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Agent-Service-Token", "gateway-secret")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	var body struct {
		CapabilityToken string `json:"capabilityToken"`
		Tools           []struct {
			Name string `json:"name"`
		} `json:"tools"`
	}
	if response.Code != http.StatusOK || json.Unmarshal(response.Body.Bytes(), &body) != nil || body.CapabilityToken == "" {
		t.Fatalf("internal legacy bootstrap status=%d body=%s", response.Code, response.Body.String())
	}
	for _, tool := range body.Tools {
		if tool.Name == "open_page" {
			t.Fatalf("Telegram legacy bootstrap exposed open_page: %s", response.Body.String())
		}
	}

	execute := httptest.NewRequest(http.MethodPost, "/api/internal/agent/tools/get_bql_capabilities/execute", strings.NewReader(`{"arguments":{}}`))
	execute.Header.Set("Content-Type", "application/json")
	execute.Header.Set("Authorization", "Bearer "+body.CapabilityToken)
	executeResponse := httptest.NewRecorder()
	router.ServeHTTP(executeResponse, execute)
	if executeResponse.Code != http.StatusOK || !strings.Contains(executeResponse.Body.String(), `"modelOutput"`) {
		t.Fatalf("internal legacy execute status=%d body=%s", executeResponse.Code, executeResponse.Body.String())
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
