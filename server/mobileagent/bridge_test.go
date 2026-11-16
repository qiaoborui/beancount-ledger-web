package mobileagent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// hostLinux runs the command with the host's /bin/sh in the workspace, so a
// test exercises the real clients against the real bridge.
type hostLinux struct{ commands []string }

func (h *hostLinux) Run(requestJSON string) string {
	var request linuxRunRequest
	_ = json.Unmarshal([]byte(requestJSON), &request)
	h.commands = append(h.commands, request.Command)
	cmd := exec.Command("/bin/sh", "-c", request.Command)
	cmd.Dir = request.Workspace
	output, err := cmd.CombinedOutput()
	result := linuxRunResult{Output: string(output), OutputBytes: int64(len(output))}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		result.ExitCode = exit.ExitCode()
	} else if err != nil {
		result.Error = err.Error()
	}
	encoded, _ := json.Marshal(result)
	return string(encoded)
}

func (*hostLinux) Cancel(string) {}

func useClientDir(t *testing.T) {
	t.Helper()
	previous := clientDir
	clientDir = filepath.Join(t.TempDir(), "ledger-client")
	t.Cleanup(func() { clientDir = previous })
}

type echoTool struct {
	name  string
	calls int
}

func (t *echoTool) Name() string  { return t.name }
func (t *echoTool) Label() string { return t.name }
func (t *echoTool) Schema() ai.ToolSchema {
	return ai.ToolSchema{Name: t.name, Description: "回声。第二句不在列表里。", Parameters: objectParameters(map[string]any{})}
}
func (*echoTool) ExecutionMode() agent.ToolExecutionMode { return agent.ToolModeSequential }
func (t *echoTool) Execute(_ context.Context, _ string, params json.RawMessage, _ agent.ToolUpdateCallback) (agent.AgentToolResult, error) {
	t.calls++
	if strings.Contains(string(params), "boom") {
		return agent.AgentToolResult{}, errors.New("boom failed")
	}
	return agent.AgentToolResult{Content: []ai.ToolResultMessageContent{ai.TextContent{Text: string(params)}}}, nil
}

func bridgeRequest(t *testing.T, b *toolBridge, method, path, token, body string) (int, string) {
	t.Helper()
	request, err := http.NewRequest(method, b.url+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	client := &http.Client{Transport: &http.Transport{Proxy: nil}}
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	raw, _ := io.ReadAll(response.Body)
	return response.StatusCode, string(raw)
}

func TestBridgeGuardsItsTools(t *testing.T) {
	echo := &echoTool{name: "read_file"}
	tools := scriptable([]agent.AgentTool{echo, &echoTool{name: "bash"}, &echoTool{name: "ask_user"}})
	if len(tools) != 1 || tools["read_file"] == nil {
		t.Fatalf("scriptable = %v", tools)
	}
	b, err := startBridge(context.Background(), tools)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(b.url, "http://127.0.0.1:") {
		t.Fatalf("url = %s", b.url)
	}
	if status, _ := bridgeRequest(t, b, "POST", "/call", "", `{"tool":"read_file"}`); status != http.StatusUnauthorized {
		t.Fatalf("no token: %d", status)
	}
	if status, _ := bridgeRequest(t, b, "POST", "/call", "wrong", `{"tool":"read_file"}`); status != http.StatusUnauthorized {
		t.Fatalf("wrong token: %d", status)
	}
	if _, body := bridgeRequest(t, b, "POST", "/call", b.token, `{"tool":"bash","args":{}}`); !strings.Contains(body, `"ok":false`) {
		t.Fatalf("bash through the bridge: %s", body)
	}
	if _, body := bridgeRequest(t, b, "POST", "/call", b.token, `{"tool":"read_file","args":{"path":"a"}}`); !strings.Contains(body, `"result":"{\"path\":\"a\"}"`) {
		t.Fatalf("call: %s", body)
	}
	if _, body := bridgeRequest(t, b, "POST", "/text/call", b.token, `{"tool":"read_file","args":{"x":"boom"}}`); body != "error\nboom failed" {
		t.Fatalf("text error: %q", body)
	}
	if _, body := bridgeRequest(t, b, "GET", "/text/tools", b.token, ""); body != "ok\nread_file\t回声。" {
		t.Fatalf("tools: %q", body)
	}
	b.seq = maxBridgeCalls
	if _, body := bridgeRequest(t, b, "POST", "/call", b.token, `{"tool":"read_file"}`); !strings.Contains(body, "最多调用") {
		t.Fatalf("over the limit: %s", body)
	}
	if echo.calls != 2 {
		t.Fatalf("calls = %d", echo.calls)
	}
	b.stop()
	client := &http.Client{Transport: &http.Transport{Proxy: nil}}
	if _, err := client.Get(b.url + "/tools"); err == nil {
		t.Fatal("the bridge still answers after stop")
	}
}

func TestScriptsCallToolsThroughTheBridge(t *testing.T) {
	if _, err := exec.LookPath("wget"); err != nil {
		t.Skip("wget not installed")
	}
	useClientDir(t)
	runner := &hostLinux{}
	SetLinuxRunner(runner)
	t.Cleanup(func() { SetLinuxRunner(nil) })
	script := strings.Join([]string{
		`ledger tools | grep -c . | sed 's/^/tools=/'`,
		`ledger call read_file '{"path":"main.bean","limit":1}' | head -c 200 | grep -q 'main.bean' && echo read=ok`,
		`printf '%s' '{"path":"notes.bean","content":"; from a script\n"}' | ledger call write_file - > /dev/null && echo write=ok`,
		`ledger call bash '{"command":"true"}' 2>&1 | sed 's/^/bash=/'`,
		`ledger call get_accounts > /dev/null && echo accounts=ok`,
	}, "\n")
	_, pythonErr := exec.LookPath("python3")
	if pythonErr == nil {
		script += "\n" + `python3 -c 'from ledger import call, LedgerError
print("py=" + str(len(call("list_files")["files"])))
try:
    call("ask_user")
except LedgerError as e:
    print("pyerr=" + str(e)[:6])'`
	}
	committed, dir := committedWorkspace(t), scratchCopy(t)
	var output string
	useFaux(t,
		toolStep("bash", map[string]any{"command": script}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			output = lastToolResultText(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好了")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committed, "scratchRoot": dir,
		"provider": "faux", "model": "faux-1", "message": "用脚本看看"})
	if !response.OK || !response.Edited {
		t.Fatalf("response = %+v (%s)", response, output)
	}
	var result struct {
		ExitCode  int              `json:"exit_code"`
		Output    string           `json:"output"`
		ToolCalls []map[string]any `json:"tool_calls"`
		Changed   []string         `json:"changed_files"`
	}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		t.Fatalf("output %s: %v", output, err)
	}
	for _, want := range []string{"read=ok", "write=ok", "accounts=ok", "bash=ledger: 脚本不能调用 \"bash\""} {
		if !strings.Contains(result.Output, want) {
			t.Fatalf("missing %q in output:\n%s", want, result.Output)
		}
	}
	if strings.Contains(result.Output, "tools=0") || !strings.Contains(result.Output, "tools=") {
		t.Fatalf("tools listing:\n%s", result.Output)
	}
	if pythonErr == nil && (!strings.Contains(result.Output, "py=") || !strings.Contains(result.Output, "pyerr=脚本不能")) {
		t.Fatalf("python client:\n%s", result.Output)
	}
	if len(result.Changed) != 1 || result.Changed[0] != "notes.bean" {
		t.Fatalf("changed = %v", result.Changed)
	}
	data, err := os.ReadFile(filepath.Join(dir, "notes.bean"))
	if err != nil || !bytes.Equal(data, []byte("; from a script\n")) {
		t.Fatalf("notes.bean = %q, %v", data, err)
	}
	counted := map[string]float64{}
	for _, call := range result.ToolCalls {
		counted[call["tool"].(string)] = call["count"].(float64)
	}
	if counted["read_file"] != 1 || counted["write_file"] != 1 || counted["get_accounts"] != 1 || counted["bash"] != 0 {
		t.Fatalf("tool_calls = %v", result.ToolCalls)
	}
	if version, err := os.ReadFile(filepath.Join(clientDir, "VERSION")); err != nil || strings.TrimSpace(string(version)) != guestClientVersion {
		t.Fatalf("VERSION = %q, %v", version, err)
	}
	if len(runner.commands) != 1 || !strings.HasSuffix(runner.commands[0], script) {
		t.Fatalf("command = %q", runner.commands)
	}
}

func TestBashWithoutScriptToolsHasNoPrefix(t *testing.T) {
	dir := scratchCopy(t)
	files, err := openScratch(dir, "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	runner := &fakeLinux{act: func(linuxRunRequest) linuxRunResult { return linuxRunResult{} }}
	if _, err := files.bash(context.Background(), runner, json.RawMessage(`{"command":"true"}`)); err != nil {
		t.Fatal(err)
	}
	if runner.requests[0].Command != "true" {
		t.Fatalf("command = %q", runner.requests[0].Command)
	}
}
