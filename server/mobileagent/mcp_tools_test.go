package mobileagent

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/MichaelKinsy/PiG/ai"
	"github.com/MichaelKinsy/PiG/mcp"
)

// fakeMCP is a Streamable HTTP MCP server with one page of tools: enough for
// the client to initialize, list and call. It records what it was asked, so a
// test can see the token and the arguments that left the device.
type fakeMCP struct {
	mu      sync.Mutex
	tools   []map[string]any
	calls   []fakeMCPCall
	headers http.Header
	// auth is the Authorization header the server requires; empty accepts any.
	auth string
	// initDelay and callDelay hold an answer back, to test a timeout and the
	// stop button.
	initDelay time.Duration
	callDelay time.Duration
	// callError answers with isError instead of a result.
	callError bool
	content   []map[string]any
	// started is closed when a tools/call arrives.
	started chan struct{}
	once    sync.Once
}

type fakeMCPCall struct {
	name string
	args map[string]any
}

func newFakeMCP(tools ...map[string]any) *fakeMCP {
	return &fakeMCP{tools: tools, started: make(chan struct{}), content: []map[string]any{{"type": "text", "text": "好的"}}}
}

func startFakeMCP(t *testing.T, fake *fakeMCP) string {
	t.Helper()
	server := httptest.NewServer(fake)
	t.Cleanup(server.Close)
	return server.URL
}

func (f *fakeMCP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	f.mu.Lock()
	f.headers = r.Header.Clone()
	auth := f.auth
	f.mu.Unlock()
	if auth != "" && r.Header.Get("Authorization") != auth {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	var message struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if err := json.Unmarshal(body, &message); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if len(message.ID) == 0 {
		// A notification, notifications/initialized included.
		w.WriteHeader(http.StatusAccepted)
		return
	}
	reply := func(result any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": message.ID, "result": result})
	}
	switch message.Method {
	case "initialize":
		if !waitOrCancel(r, f.initDelay) {
			return
		}
		reply(map[string]any{
			"protocolVersion": mcp.LatestProtocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "fake", "version": "1.0.0"},
		})
	case "tools/list":
		f.mu.Lock()
		tools := append([]map[string]any(nil), f.tools...)
		f.mu.Unlock()
		reply(map[string]any{"tools": tools})
	case "tools/call":
		var params struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		}
		_ = json.Unmarshal(message.Params, &params)
		f.mu.Lock()
		f.calls = append(f.calls, fakeMCPCall{name: params.Name, args: params.Arguments})
		delay, callError, content := f.callDelay, f.callError, f.content
		f.mu.Unlock()
		f.once.Do(func() { close(f.started) })
		if !waitOrCancel(r, delay) {
			return
		}
		reply(map[string]any{"content": content, "isError": callError})
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

// waitOrCancel waits delay, or gives up when the client goes away (a stopped
// turn or a timeout), so a test server never outlives its request.
func waitOrCancel(r *http.Request, delay time.Duration) bool {
	if delay <= 0 {
		return true
	}
	select {
	case <-time.After(delay):
		return true
	case <-r.Context().Done():
		return false
	}
}

func mcpTestTool(name, description string) map[string]any {
	return map[string]any{"name": name, "description": description,
		"inputSchema": map[string]any{"type": "object",
			"properties": map[string]any{"q": map[string]any{"type": "string"}}, "required": []any{"q"}}}
}

// systemPromptText is the instructions the model was given.
func systemPromptText(request ai.TranscriptContext) string {
	for _, message := range request.Messages() {
		if system, ok := message.(ai.SystemMessage); ok {
			if text, ok := system.Content.(ai.SystemText); ok {
				return string(text)
			}
		}
	}
	return ""
}

func TestMCPToolsAreCalledThroughTheTurn(t *testing.T) {
	fake := newFakeMCP(mcpTestTool("search_notes", "搜索笔记"))
	fake.auth = "Bearer secret"
	fake.content = []map[string]any{{"type": "text", "text": "找到 2 条笔记"}}
	url := startFakeMCP(t, fake)
	var prompt, output string
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("mcp__notes__search_notes", map[string]any{"q": "发票"}, &ai.FauxToolCallOptions{ID: "call_notes"}),
		}}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			prompt, output = systemPromptText(request), lastToolResultText(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("有 2 条相关笔记。")}}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "apiKey": "test", "message": "我记过发票吗",
		"mcpServers": []any{map[string]any{"id": "notes", "name": "我的笔记", "url": url,
			"headers": map[string]any{"Authorization": "Bearer secret"}}}})
	if !response.OK || response.Reply != "有 2 条相关笔记。" {
		t.Fatalf("unexpected response: %+v", response)
	}
	if len(response.ToolCalls) != 1 || response.ToolCalls[0].Name != "mcp__notes__search_notes" || response.ToolCalls[0].IsError {
		t.Fatalf("unexpected tool calls: %+v", response.ToolCalls)
	}
	if !strings.Contains(output, "找到 2 条笔记") {
		t.Fatalf("the model did not receive the tool result: %q", output)
	}
	// Rule 5 says there is no network; the MCP block is its stated exception.
	if !strings.Contains(prompt, "外部 MCP 服务器") || !strings.Contains(prompt, "不要把账本里的金额") {
		t.Fatalf("the MCP rules are missing from the prompt:\n%s", prompt)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if len(fake.calls) != 1 || fake.calls[0].name != "search_notes" {
		t.Fatalf("unexpected calls: %+v", fake.calls)
	}
	if fake.calls[0].args["q"] != "发票" {
		t.Fatalf("arguments did not reach the server: %+v", fake.calls[0].args)
	}
	if fake.headers.Get("Authorization") != "Bearer secret" {
		t.Fatalf("the token did not reach the server: %v", fake.headers)
	}
}

func TestMCPToolErrorIsReportedAsAToolError(t *testing.T) {
	fake := newFakeMCP(mcpTestTool("search_notes", "搜索笔记"))
	fake.callError = true
	fake.content = []map[string]any{{"type": "text", "text": "账本不存在"}}
	url := startFakeMCP(t, fake)
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("mcp__notes__search_notes", map[string]any{"q": "x"}, &ai.FauxToolCallOptions{ID: "call_notes"}),
		}}),
		ai.FauxFactoryStep(func(ai.TranscriptContext, ai.StreamOptions, *ai.FauxProviderState, *ai.Model) (ai.AssistantMessage, error) {
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("外部工具报错了。")}}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "搜一下",
		"mcpServers": []any{map[string]any{"id": "notes", "name": "我的笔记", "url": url}}})
	if !response.OK || len(response.ToolCalls) != 1 || !response.ToolCalls[0].IsError {
		t.Fatalf("the tool error was not reported: %+v", response)
	}
	if !strings.Contains(response.ToolCalls[0].ErrorText, "账本不存在") {
		t.Fatalf("unexpected error text: %q", response.ToolCalls[0].ErrorText)
	}
}

func TestUnreachableMCPServerIsNamedBeforeTheQuestion(t *testing.T) {
	server := httptest.NewServer(http.NotFoundHandler())
	url := server.URL
	server.Close()
	var question string
	useFaux(t, ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		for _, text := range requestTexts(request) {
			if strings.HasPrefix(text, "user:") {
				question = text
			}
		}
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好")}}.AssistantMessage(), nil
	}))
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "你好",
		"mcpServers": []any{map[string]any{"id": "notes", "name": "我的笔记", "url": url}}})
	if !response.OK {
		t.Fatalf("unexpected response: %+v", response)
	}
	if !strings.Contains(question, "连不上 MCP 服务器「我的笔记」") || !strings.HasSuffix(question, "你好") {
		t.Fatalf("the note is not before the question: %q", question)
	}
}

func TestMCPConnectTimeoutKeepsTheTurn(t *testing.T) {
	previous := mcpConnectTimeout
	mcpConnectTimeout = 200 * time.Millisecond
	t.Cleanup(func() { mcpConnectTimeout = previous })
	fake := newFakeMCP(mcpTestTool("search_notes", "搜索笔记"))
	fake.initDelay = 5 * time.Second
	url := startFakeMCP(t, fake)
	var question string
	useFaux(t, ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		for _, text := range requestTexts(request) {
			if strings.HasPrefix(text, "user:") {
				question = text
			}
		}
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好")}}.AssistantMessage(), nil
	}))
	started := time.Now()
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "你好",
		"mcpServers": []any{map[string]any{"id": "notes", "name": "我的笔记", "url": url}}})
	if !response.OK || len(response.ToolCalls) != 0 {
		t.Fatalf("a slow server failed the turn: %+v", response)
	}
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		t.Fatalf("the connect timeout did not bound the wait: %s", elapsed)
	}
	if !strings.Contains(question, "我的笔记") {
		t.Fatalf("the timeout was not reported: %q", question)
	}
}

func TestStoppingATurnCancelsAnMCPCall(t *testing.T) {
	fake := newFakeMCP(mcpTestTool("search_notes", "搜索笔记"))
	fake.callDelay = 30 * time.Second
	url := startFakeMCP(t, fake)
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("mcp__notes__search_notes", map[string]any{"q": "x"}, &ai.FauxToolCallOptions{ID: "call_notes"}),
		}}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好")}}),
	)
	raw, err := json.Marshal(map[string]any{"version": 1, "turnId": "mcp-stop", "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "搜一下",
		"mcpServers": []any{map[string]any{"id": "notes", "name": "我的笔记", "url": url}}})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan turnResponseV1, 1)
	go func() {
		var response turnResponseV1
		if err := json.Unmarshal([]byte(RunTurnJSON(string(raw))), &response); err != nil {
			done <- turnResponseV1{Error: err.Error()}
			return
		}
		done <- response
	}()
	select {
	case <-fake.started:
	case <-time.After(10 * time.Second):
		t.Fatal("the tool call never started")
	}
	CancelTurn("mcp-stop")
	select {
	case response := <-done:
		if !response.Cancelled {
			t.Fatalf("the stopped turn was not reported as stopped: %+v", response)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the stopped turn did not return")
	}
}

func TestMCPServersAreRefusedDuringOnboarding(t *testing.T) {
	fake := newFakeMCP(mcpTestTool("search_notes", "搜索笔记"))
	url := startFakeMCP(t, fake)
	useFaux(t)
	response := runTurnFor(t, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "message": "开账",
		"onboarding": map[string]any{"draft": map[string]any{"currency": "CNY"}},
		"mcpServers": []any{map[string]any{"id": "notes", "name": "我的笔记", "url": url}}})
	if response.OK || !strings.Contains(response.Error, "MCP") {
		t.Fatalf("onboarding accepted MCP servers: %+v", response)
	}
}

func TestMCPServerURLs(t *testing.T) {
	for _, value := range []string{"https://mcp.example.com/mcp", "http://localhost:3000/mcp",
		"http://127.0.0.1:8000/mcp", "http://192.168.1.8:8080", "http://10.0.0.4/mcp", "http://[::1]:9000/mcp",
		"http://mac.local:1234", "https://mcp.example.com/mcp"} {
		if _, err := mcpServerURL(value); err != nil {
			t.Fatalf("%s was refused: %v", value, err)
		}
	}
	for _, value := range []string{"", "mcp.example.com", "ftp://example.com/mcp", "http://example.com/mcp",
		"http://8.8.8.8/mcp", "https://user:pass@example.com/mcp", "https://example.com/mcp?key=1",
		"https://example.com/mcp#frag"} {
		if _, err := mcpServerURL(value); err == nil {
			t.Fatalf("%s was accepted", value)
		}
	}
}

func TestMCPHeadersAreChecked(t *testing.T) {
	if headers, err := mcpHeaders(map[string]string{"Authorization": "Bearer a b"}); err != nil || headers["Authorization"] != "Bearer a b" {
		t.Fatalf("a bearer token was refused: %v", err)
	}
	for _, headers := range []map[string]string{{"Bad Name": "x"}, {"Authorization": "Bearer a\nb"}, {"": "x"}} {
		if _, err := mcpHeaders(headers); err == nil {
			t.Fatalf("%v was accepted", headers)
		}
	}
}

func TestMCPToolNamesAreCleaned(t *testing.T) {
	name := mcpToolName(mcpServerV1{ID: "notes"}, "search notes")
	if name != "mcp__notes__search_notes" {
		t.Fatalf("name = %q", name)
	}
	// A Chinese name keeps nothing usable; the id still names the server.
	if name := mcpToolName(mcpServerV1{ID: "我的笔记"}, "搜索 笔记.v2"); name != "mcp__server__v2" {
		t.Fatalf("name = %q", name)
	}
	long := strings.Repeat("t", 100)
	name = mcpToolName(mcpServerV1{ID: "notes"}, long)
	if len(name) > mcpToolNameLimit || !strings.HasPrefix(name, "mcp__notes__") || strings.ContainsAny(name, " .:") {
		t.Fatalf("name = %q", name)
	}
	taken := map[string]bool{"mcp__notes__search": true}
	second := uniqueMCPToolName("mcp__notes__search", taken)
	if second != "mcp__notes__search_2" {
		t.Fatalf("name = %q", second)
	}
	taken[second] = true
	if third := uniqueMCPToolName("mcp__notes__search", taken); third != "mcp__notes__search_3" {
		t.Fatalf("name = %q", third)
	}
}

func TestMCPToolSchemasAreNormalized(t *testing.T) {
	// A server that writes "required": null breaks every provider before the
	// tool is called; the package's normalizer drops it.
	schema := mcpToolSchema(json.RawMessage(`{"type":"object","properties":{"q":{"type":"string"}},"required":null}`))
	if _, present := schema["required"]; present {
		t.Fatalf("required survived as %v", schema["required"])
	}
	if properties, ok := schema["properties"].(map[string]any); !ok || properties["q"] == nil {
		t.Fatalf("properties = %v", schema["properties"])
	}
	// A schema with nothing in it still looks like an object.
	schema = mcpToolSchema(nil)
	if schema["type"] != "object" || schema["properties"] == nil {
		t.Fatalf("empty schema = %v", schema)
	}
	// The server's own members are kept, and none of them is null.
	schema = mcpToolSchema(json.RawMessage(`{"type":"object","properties":{},"additionalProperties":true,"$defs":null}`))
	if schema["additionalProperties"] != true {
		t.Fatalf("additionalProperties = %v", schema["additionalProperties"])
	}
	if _, present := schema["$defs"]; present {
		t.Fatalf("a null member survived: %v", schema["$defs"])
	}
}

func TestMCPResultsCarryImagesOnlyForAModelThatSees(t *testing.T) {
	result := &mcp.CallToolResult{Content: []mcp.ContentBlock{{Type: mcp.ContentText, Text: "一张图"}}}
	image := mcp.ContentBlock{Type: mcp.ContentImage, Data: "aGk=", MimeType: "image/png"}
	result.Content = append(result.Content, image)
	without := mcpResultContent(result, false)
	if len(without) != 1 || !strings.Contains(without[0].(ai.TextContent).Text, "图片") {
		t.Fatalf("image sent to a model that cannot see: %+v", without)
	}
	with := mcpResultContent(result, true)
	if len(with) != 2 {
		t.Fatalf("image not sent to a model that sees: %+v", with)
	}
	if picture, ok := with[1].(ai.ImageContent); !ok || picture.Data != "aGk=" || picture.MimeType != "image/png" {
		t.Fatalf("unexpected image: %+v", with[1])
	}
}

func TestMCPResultsAreTruncated(t *testing.T) {
	result := &mcp.CallToolResult{Content: []mcp.ContentBlock{{Type: mcp.ContentText, Text: strings.Repeat("账", mcpResultRunes+50)}}}
	content := mcpResultContent(result, false)
	if len(content) != 1 {
		t.Fatalf("content = %+v", content)
	}
	text := content[0].(ai.TextContent).Text
	if !strings.HasSuffix(text, "（结果太长，只保留前 20000 个字）") {
		t.Fatalf("unexpected tail: %q", text[len(text)-40:])
	}
	if empty := mcpResultContent(&mcp.CallToolResult{}, false); len(empty) != 1 ||
		empty[0].(ai.TextContent).Text != "（工具没有返回内容）" {
		t.Fatalf("empty result = %+v", empty)
	}
}

func TestMCPToolLimits(t *testing.T) {
	many := make([]map[string]any, 0, 60)
	for index := range 60 {
		many = append(many, mcpTestTool(fmt.Sprintf("tool_%02d", index), ""))
	}
	fake := newFakeMCP(many...)
	url := startFakeMCP(t, fake)
	client := &http.Client{Timeout: 10 * time.Second}
	tools, err := openMCPTools(context.Background(), client, []mcpServerV1{{ID: "many", Name: "多工具", URL: url}}, false)
	if err != nil {
		t.Fatal(err)
	}
	defer tools.close()
	if len(tools.tools) != mcpServerToolLimit {
		t.Fatalf("tools = %d", len(tools.tools))
	}
	if !strings.Contains(tools.note, "只接入了前 40 个") {
		t.Fatalf("truncation not reported: %q", tools.note)
	}
	// Every server shares the total budget, in the order the shell sent them.
	fewer := make([]map[string]any, 0, 30)
	for index := range 30 {
		fewer = append(fewer, mcpTestTool(fmt.Sprintf("tool_%02d", index), ""))
	}
	second := newFakeMCP(fewer...)
	secondURL := startFakeMCP(t, second)
	third := newFakeMCP(fewer...)
	thirdURL := startFakeMCP(t, third)
	tools, err = openMCPTools(context.Background(), client, []mcpServerV1{
		{ID: "a", Name: "甲", URL: url}, {ID: "b", Name: "乙", URL: secondURL}, {ID: "c", Name: "丙", URL: thirdURL}}, false)
	if err != nil {
		t.Fatal(err)
	}
	defer tools.close()
	if len(tools.tools) != mcpTotalToolLimit {
		t.Fatalf("tools = %d", len(tools.tools))
	}
	if !strings.Contains(tools.note, "上限 80 个") {
		t.Fatalf("the total limit is not reported: %q", tools.note)
	}
	names := map[string]bool{}
	for _, tool := range tools.tools {
		if names[tool.Name()] {
			t.Fatalf("duplicate tool name %q", tool.Name())
		}
		names[tool.Name()] = true
	}
}

func TestMCPProbeListsTheServersOwnTools(t *testing.T) {
	fake := newFakeMCP(mcpTestTool("search_notes", "搜索笔记"))
	url := startFakeMCP(t, fake)
	request, err := json.Marshal(map[string]any{"version": 1,
		"server": map[string]any{"id": "notes", "name": "我的笔记", "url": url}})
	if err != nil {
		t.Fatal(err)
	}
	var response mcpProbeResponseV1
	if err := json.Unmarshal([]byte(MCPProbeJSON(string(request))), &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK || response.Name != "我的笔记" || len(response.Tools) != 1 || response.Tools[0].Name != "search_notes" {
		t.Fatalf("unexpected probe: %+v", response)
	}
	if response.Tools[0].Description != "搜索笔记" {
		t.Fatalf("description = %q", response.Tools[0].Description)
	}

	request, _ = json.Marshal(map[string]any{"version": 1, "server": map[string]any{"id": "bad", "name": "坏地址", "url": "http://example.com/mcp"}})
	if err := json.Unmarshal([]byte(MCPProbeJSON(string(request))), &response); err != nil {
		t.Fatal(err)
	}
	if response.OK || !strings.Contains(response.Error, "https") {
		t.Fatalf("a public http address passed the probe: %+v", response)
	}

	server := httptest.NewServer(http.NotFoundHandler())
	dead := server.URL
	server.Close()
	request, _ = json.Marshal(map[string]any{"version": 1, "server": map[string]any{"id": "dead", "name": "没开机", "url": dead}})
	if err := json.Unmarshal([]byte(MCPProbeJSON(string(request))), &response); err != nil {
		t.Fatal(err)
	}
	if response.OK || response.Error == "" || response.Name != "没开机" {
		t.Fatalf("an unreachable server passed the probe: %+v", response)
	}
}
