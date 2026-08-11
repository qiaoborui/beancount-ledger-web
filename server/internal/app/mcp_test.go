package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type mcpBearerTransport struct {
	token string
	base  http.RoundTripper
}

func (transport mcpBearerTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	clone := request.Clone(request.Context())
	clone.Header = request.Header.Clone()
	clone.Header.Set("Authorization", "Bearer "+transport.token)
	base := transport.base
	if base == nil {
		base = http.DefaultTransport
	}
	return base.RoundTrip(clone)
}

func TestMCPRequiresBearerAuthAndRejectsCrossOriginBrowserPosts(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	server.cfg.AgentServiceToken = "service-secret"
	router := newRouter(server.cfg, server)
	body := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}`

	for name, authorization := range map[string]string{
		"missing": "", "invalid": "Bearer wrong", "raw-token": "service-secret",
		"unsupported-scheme": "Basic service-secret", "extra-field": "Bearer service-secret trailing",
	} {
		t.Run(name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(body))
			request.Header.Set("Content-Type", "application/json")
			if authorization != "" {
				request.Header.Set("Authorization", authorization)
			}
			response := httptest.NewRecorder()
			router.ServeHTTP(response, request)
			if response.Code != http.StatusUnauthorized || response.Header().Get("WWW-Authenticate") == "" {
				t.Fatalf("status=%d headers=%v body=%s", response.Code, response.Header(), response.Body.String())
			}
		})
	}

	lowercaseScheme := httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(body))
	lowercaseScheme.Header.Set("Content-Type", "application/json")
	lowercaseScheme.Header.Set("Accept", "application/json, text/event-stream")
	lowercaseScheme.Header.Set("Authorization", "bearer service-secret")
	lowercaseResponse := httptest.NewRecorder()
	router.ServeHTTP(lowercaseResponse, lowercaseScheme)
	if lowercaseResponse.Code != http.StatusOK {
		t.Fatalf("case-insensitive bearer status=%d body=%s", lowercaseResponse.Code, lowercaseResponse.Body.String())
	}

	crossOrigin := httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(body))
	crossOrigin.Header.Set("Content-Type", "application/json")
	crossOrigin.Header.Set("Authorization", "Bearer service-secret")
	crossOrigin.Header.Set("Origin", "https://evil.example")
	crossOrigin.Header.Set("Sec-Fetch-Site", "cross-site")
	crossOriginResponse := httptest.NewRecorder()
	router.ServeHTTP(crossOriginResponse, crossOrigin)
	if crossOriginResponse.Code != http.StatusForbidden {
		t.Fatalf("cross-origin MCP status=%d body=%s", crossOriginResponse.Code, crossOriginResponse.Body.String())
	}
}

func TestMCPCrossOriginProtectionRunsBeforeAccessTokenAuthentication(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	token := storeMCPTestToken(t, server, "Browser")
	router := newRouter(server.cfg, server)
	body := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}`

	request := httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Origin", "https://evil.example")
	request.Header.Set("Sec-Fetch-Site", "cross-site")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("cross-origin MCP status=%d body=%s", response.Code, response.Body.String())
	}
	store, err := server.readAgentAccessTokens(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if len(store.Tokens) != 1 || store.Tokens[0].LastUsedAt != nil {
		t.Fatalf("cross-origin request authenticated before rejection: %#v", store.Tokens)
	}
}

func TestMCPServiceTokenSupportsCurrentAndLegacyProtocols(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	server.cfg.AgentServiceToken = "service-secret"
	httpServer := httptest.NewServer(newRouter(server.cfg, server))
	t.Cleanup(httpServer.Close)

	session := connectMCPTestClient(t, httpServer.URL, "service-secret")
	if got := session.InitializeResult().ProtocolVersion; got != "2026-07-28" {
		t.Fatalf("current MCP protocol = %q", got)
	}
	tools, err := session.ListTools(t.Context(), nil)
	if err != nil {
		t.Fatal(err)
	}
	names := mcpTestToolNames(tools.Tools)
	for _, name := range []string{"ledger_agent_context", "ledger_get_ledger_summary", "ledger_append_transactions"} {
		if !containsString(names, name) {
			t.Fatalf("service MCP tools missing %q: %v", name, names)
		}
	}
	if containsString(names, "ledger_open_page") || containsString(names, "open_page") {
		t.Fatalf("MCP must not expose browser-only navigation: %v", names)
	}
	result, err := session.CallTool(t.Context(), &mcp.CallToolParams{Name: "ledger_get_bql_capabilities"})
	if err != nil {
		t.Fatal(err)
	}
	envelope := mcpTestEnvelope(t, result)
	if envelope["modelOutput"] == nil || envelope["artifacts"] == nil || envelope["refreshLedger"] != false {
		t.Fatalf("unexpected MCP result envelope: %#v", envelope)
	}
	capabilities, _ := envelope["modelOutput"].(map[string]any)
	if capabilities["dialectVersion"] != float64(bqlDialectVersion) {
		t.Fatalf("unexpected MCP BQL dialect version: %#v", capabilities)
	}
	validationResult, err := session.CallTool(t.Context(), &mcp.CallToolParams{
		Name:      "ledger_validate_bql",
		Arguments: map[string]any{"query": "SELECT date FROM transactions WHERE payee OR 'Cafe'"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if validationResult.IsError {
		t.Fatalf("invalid BQL must be returned as validation data: %#v", validationResult)
	}
	validationEnvelope := mcpTestEnvelope(t, validationResult)
	validationOutput, _ := validationEnvelope["modelOutput"].(map[string]any)
	validationIssue, _ := validationOutput["error"].(map[string]any)
	if validationOutput["valid"] != false || validationOutput["dialectVersion"] != float64(bqlDialectVersion) || validationIssue["code"] != "expected_operator" || validationIssue["clause"] != "WHERE" || validationIssue["position"] != float64(7) {
		t.Fatalf("unexpected MCP validation result: %#v", validationOutput)
	}
	contextResult, err := session.CallTool(t.Context(), &mcp.CallToolParams{
		Name:      agentMCPContextToolName,
		Arguments: map[string]any{"channel": "telegram"},
	})
	if err != nil {
		t.Fatal(err)
	}
	contextEnvelope := mcpTestEnvelope(t, contextResult)
	modelOutput, _ := contextEnvelope["modelOutput"].(map[string]any)
	prompt, _ := modelOutput["systemPrompt"].(string)
	if !strings.Contains(prompt, "Telegram") || !strings.Contains(prompt, "ledger_get_ledger_summary") || !strings.Contains(prompt, "ledger_run_bql") || !strings.Contains(prompt, "ledger_validate_bql") || strings.Contains(prompt, " mcp.ledger_") {
		t.Fatalf("unexpected MCP context prompt: %q", prompt)
	}

	legacyBody := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"legacy-test","version":"1"}}}`
	legacyRequest, err := http.NewRequest(http.MethodPost, httpServer.URL+"/mcp", strings.NewReader(legacyBody))
	if err != nil {
		t.Fatal(err)
	}
	legacyRequest.Header.Set("Authorization", "Bearer service-secret")
	legacyRequest.Header.Set("Content-Type", "application/json")
	legacyRequest.Header.Set("Accept", "application/json, text/event-stream")
	legacyResponse, err := http.DefaultClient.Do(legacyRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer legacyResponse.Body.Close()
	var legacyPayload struct {
		Result struct {
			ProtocolVersion string `json:"protocolVersion"`
		} `json:"result"`
	}
	if legacyResponse.StatusCode != http.StatusOK || json.NewDecoder(legacyResponse.Body).Decode(&legacyPayload) != nil || legacyPayload.Result.ProtocolVersion != "2025-11-25" {
		t.Fatalf("legacy initialize status=%d payload=%#v", legacyResponse.StatusCode, legacyPayload)
	}

	secondSession := connectMCPTestClient(t, httpServer.URL, "service-secret")
	if _, err := secondSession.ListTools(t.Context(), nil); err != nil {
		t.Fatalf("independent stateless MCP request failed: %v", err)
	}
}

func TestMCPAccessTokenProvidesCompleteToolSet(t *testing.T) {
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	server := testAgentServer(t)
	token := storeMCPTestToken(t, server, "Local MCP")
	httpServer := httptest.NewServer(newRouter(server.cfg, server))
	t.Cleanup(httpServer.Close)

	session := connectMCPTestClient(t, httpServer.URL, token)
	tools, err := session.ListTools(t.Context(), nil)
	if err != nil {
		t.Fatal(err)
	}
	names := mcpTestToolNames(tools.Tools)
	if !containsString(names, "ledger_get_accounts") || !containsString(names, "ledger_append_transactions") {
		t.Fatalf("access token is missing MCP tools: %v", names)
	}
	contextResult, err := session.CallTool(t.Context(), &mcp.CallToolParams{
		Name: agentMCPContextToolName, Arguments: map[string]any{"channel": "external"},
	})
	if err != nil {
		t.Fatal(err)
	}
	contextEnvelope := mcpTestEnvelope(t, contextResult)
	modelOutput, _ := contextEnvelope["modelOutput"].(map[string]any)
	if strings.Contains(modelOutput["systemPrompt"].(string), "只读权限") {
		t.Fatalf("removed token scope leaked into MCP context: %#v", modelOutput)
	}
}

func connectMCPTestClient(t *testing.T, baseURL, token string) *mcp.ClientSession {
	t.Helper()
	httpClient := &http.Client{Transport: mcpBearerTransport{token: token}}
	client := mcp.NewClient(&mcp.Implementation{Name: "ledger-mcp-test", Version: "1"}, &mcp.ClientOptions{
		Capabilities: &mcp.ClientCapabilities{},
	})
	session, err := client.Connect(context.Background(), &mcp.StreamableClientTransport{
		Endpoint:             baseURL + "/mcp",
		HTTPClient:           httpClient,
		DisableStandaloneSSE: true,
		MaxRetries:           -1,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = session.Close() })
	return session
}

func storeMCPTestToken(t *testing.T, server *Server, name string) string {
	t.Helper()
	store, err := server.readAgentAccessTokens(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	id, secret, raw, err := newAgentAccessToken()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	store.Tokens = append(store.Tokens, agentAccessTokenRecord{
		ID: id, Name: name, SecretHash: agentAccessSecretHash(secret),
		CreatedAt: now, ExpiresAt: now.Add(time.Hour),
	})
	if err := server.writeAgentAccessTokens(t.Context(), store); err != nil {
		t.Fatal(err)
	}
	return raw
}

func mcpTestToolNames(tools []*mcp.Tool) []string {
	names := make([]string, 0, len(tools))
	for _, tool := range tools {
		names = append(names, tool.Name)
	}
	sort.Strings(names)
	return names
}

func mcpTestEnvelope(t *testing.T, result *mcp.CallToolResult) map[string]any {
	t.Helper()
	if len(result.Content) != 1 {
		t.Fatalf("unexpected MCP content: %#v", result.Content)
	}
	text, ok := result.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("unexpected MCP content type: %T", result.Content[0])
	}
	var envelope map[string]any
	if err := json.Unmarshal([]byte(text.Text), &envelope); err != nil {
		t.Fatalf("invalid MCP envelope %q: %v", text.Text, err)
	}
	return envelope
}
