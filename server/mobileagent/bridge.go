package mobileagent

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// The tool bridge lets a script in the built-in Linux call the assistant's
// tools, so the model can write one script that loops, filters and sums over
// many tool calls and prints only what it needs ("code mode"), instead of
// spending a turn on each call.
//
// It lives for one bash run: a listener on 127.0.0.1 with a fresh token,
// closed when the command ends. Every call goes through the allowlist below
// and the same AgentTool.Execute the model's own calls use, so a script can
// do nothing the model could not, and writes still land only in the draft.

// scriptableTools are the tools a script may call. Read-only tools, and the
// draft file tools, whose writes are no more than a command may already make
// to /workspace. Left out: bash (the runner takes one command at a time, so it
// would wait for itself), ask_user (ends the turn), and the tools that change
// memory, skills, App settings or delete files.
var scriptableTools = map[string]bool{
	"get_bql_capabilities": true, "validate_bql": true, "run_bql": true, "search_transactions": true,
	"get_ledger_summary": true, "get_accounts": true,
	"list_files": true, "grep_files": true, "read_file": true, "draft_changes": true, "bean_check": true,
	"edit_file": true, "write_file": true, "copy_file": true, "move_file": true,
	"list_attachments": true, "read_attachment": true,
	"list_saved_conversations": true, "read_saved_conversation": true,
}

const (
	maxBridgeCalls       = 200
	maxBridgeRequestBody = 5 << 20
	// guestClientDir is where the guest keeps the clients; it persists with
	// the rest of the guest's files.
	guestClientDir = "/usr/local/lib/ledger"
)

//go:embed guest/ledger.sh
var guestLedgerSh string

//go:embed guest/ledger.py
var guestLedgerPy string

// guestClientVersion changes whenever guest/ledger.sh or ledger.py does, so
// a guest that has an older copy gets the new one.
var guestClientVersion = func() string {
	sum := sha256.Sum256([]byte(guestLedgerSh + "\x00" + guestLedgerPy))
	return hex.EncodeToString(sum[:6])
}()

// clientDir is where the prefix installs the clients; tests point it at a
// temporary directory, since the host is not a guest.
var clientDir = guestClientDir

type toolBridge struct {
	tools    map[string]agent.AgentTool
	token    string
	url      string
	listener net.Listener
	server   *http.Server
	ctx      context.Context

	// mu runs one call at a time: the turn's tools assume they are called
	// in sequence, as the model calls them.
	mu     sync.Mutex
	seq    int
	counts map[string]int
	failed int
}

// scriptable picks the tools a script may call out of a turn's tools.
func scriptable(tools []agent.AgentTool) map[string]agent.AgentTool {
	out := map[string]agent.AgentTool{}
	for _, tool := range tools {
		if scriptableTools[tool.Name()] {
			out[tool.Name()] = tool
		}
	}
	return out
}

func startBridge(ctx context.Context, tools map[string]agent.AgentTool) (*toolBridge, error) {
	if len(tools) == 0 {
		return nil, errors.New("no tools to bridge")
	}
	secret := make([]byte, 24)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	b := &toolBridge{tools: tools, token: hex.EncodeToString(secret), listener: listener, ctx: ctx,
		url: "http://" + listener.Addr().String(), counts: map[string]int{}}
	b.server = &http.Server{Handler: http.HandlerFunc(b.serve), ReadHeaderTimeout: 10 * time.Second,
		BaseContext: func(net.Listener) context.Context { return ctx }}
	go func() { _ = b.server.Serve(listener) }()
	return b, nil
}

// stop closes the listener and waits briefly for a call in flight.
func (b *toolBridge) stop() {
	shutdown, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := b.server.Shutdown(shutdown); err != nil {
		_ = b.server.Close()
	}
}

// summary is what the model hears about the calls its script made.
func (b *toolBridge) summary() []map[string]any {
	b.mu.Lock()
	defer b.mu.Unlock()
	names := make([]string, 0, len(b.counts))
	for name := range b.counts {
		names = append(names, name)
	}
	sort.Strings(names)
	out := []map[string]any{}
	for _, name := range names {
		out = append(out, map[string]any{"tool": name, "count": b.counts[name]})
	}
	return out
}

func (b *toolBridge) totalCalls() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.seq
}

// serve answers JSON at /call, /tools and /tools/<name>, and the same under
// /text/ as a first line "ok" or "error" and then the payload, for the shell
// client, which has wget but no JSON parser and cannot read an error body.
func (b *toolBridge) serve(w http.ResponseWriter, r *http.Request) {
	given := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if subtle.ConstantTimeCompare([]byte(given), []byte(b.token)) != 1 {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	route, text := r.URL.Path, false
	if rest, ok := strings.CutPrefix(route, "/text"); ok {
		route, text = rest, true
	}
	var payload any
	var err error
	switch {
	case route == "/call" && r.Method == http.MethodPost:
		var result string
		if result, err = b.call(r); err == nil {
			payload = map[string]any{"ok": true, "result": result}
			if text {
				writeText(w, "ok", result)
				return
			}
		}
	case route == "/tools" && r.Method == http.MethodGet:
		list := b.list()
		payload = map[string]any{"ok": true, "tools": list}
		if text {
			var lines []string
			for _, item := range list {
				lines = append(lines, item["name"]+"\t"+item["description"])
			}
			writeText(w, "ok", strings.Join(lines, "\n"))
			return
		}
	case strings.HasPrefix(route, "/tools/") && r.Method == http.MethodGet:
		var described map[string]any
		if described, err = b.describe(strings.TrimPrefix(route, "/tools/")); err == nil {
			payload = map[string]any{"ok": true, "tool": described}
			if text {
				raw, _ := json.MarshalIndent(described, "", "  ")
				writeText(w, "ok", string(raw))
				return
			}
		}
	default:
		http.NotFound(w, r)
		return
	}
	if err != nil {
		if text {
			writeText(w, "error", err.Error())
			return
		}
		payload = map[string]any{"ok": false, "error": err.Error()}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(payload)
}

func writeText(w http.ResponseWriter, status, body string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = io.WriteString(w, status+"\n"+body)
}

func (b *toolBridge) call(r *http.Request) (string, error) {
	var request struct {
		Tool string          `json:"tool"`
		Args json.RawMessage `json:"args"`
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBridgeRequestBody+1))
	if err != nil {
		return "", err
	}
	if len(body) > maxBridgeRequestBody {
		return "", fmt.Errorf("请求超过 %d MB", maxBridgeRequestBody>>20)
	}
	if err := json.Unmarshal(body, &request); err != nil {
		return "", fmt.Errorf("请求不是合法 JSON: %w", err)
	}
	tool, ok := b.tools[request.Tool]
	if !ok {
		return "", fmt.Errorf("脚本不能调用 %q；ledger tools 列出能调用的工具", request.Tool)
	}
	if len(request.Args) == 0 || string(request.Args) == "null" {
		request.Args = json.RawMessage(`{}`)
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.ctx.Err(); err != nil {
		return "", err
	}
	if b.seq >= maxBridgeCalls {
		return "", fmt.Errorf("一次 bash 运行最多调用 %d 次工具", maxBridgeCalls)
	}
	b.seq++
	b.counts[request.Tool]++
	result, err := executeForScript(b.ctx, tool, fmt.Sprintf("script-%d", b.seq), request.Args)
	if err != nil {
		b.failed++
		return "", err
	}
	return result, nil
}

// executeForScript runs a tool and joins its text; a panic in a tool becomes
// an error for the script rather than the end of the App.
func executeForScript(ctx context.Context, tool agent.AgentTool, id string, args json.RawMessage) (text string, err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("%s 出错: %v", tool.Name(), recovered)
		}
	}()
	result, err := tool.Execute(ctx, id, args, nil)
	if err != nil {
		return "", err
	}
	var parts []string
	for _, block := range result.Content {
		if t, ok := block.(ai.TextContent); ok {
			parts = append(parts, t.Text)
		}
	}
	return strings.Join(parts, "\n"), nil
}

func (b *toolBridge) list() []map[string]string {
	names := make([]string, 0, len(b.tools))
	for name := range b.tools {
		names = append(names, name)
	}
	sort.Strings(names)
	out := make([]map[string]string, 0, len(names))
	for _, name := range names {
		description := b.tools[name].Schema().Description
		if line, _, cut := strings.Cut(description, "。"); cut {
			description = line + "。"
		}
		out = append(out, map[string]string{"name": name, "description": description})
	}
	return out
}

func (b *toolBridge) describe(name string) (map[string]any, error) {
	tool, ok := b.tools[name]
	if !ok {
		return nil, fmt.Errorf("脚本不能调用 %q；ledger tools 列出能调用的工具", name)
	}
	schema := tool.Schema()
	return map[string]any{"name": schema.Name, "description": schema.Description, "parameters": schema.Parameters}, nil
}

// guestPrefix is prepended to the model's command: it points the clients at
// this run's bridge, and installs or updates them in the guest first.
func (b *toolBridge) guestPrefix() string {
	dir := clientDir
	var prefix strings.Builder
	fmt.Fprintf(&prefix, "export LEDGER_URL='%s' LEDGER_TOKEN='%s' PATH=\"%s/bin:$PATH\" PYTHONPATH=\"%s${PYTHONPATH:+:$PYTHONPATH}\"\n",
		b.url, b.token, dir, dir)
	fmt.Fprintf(&prefix, "if [ \"$(cat '%s/VERSION' 2>/dev/null)\" != '%s' ]; then\n", dir, guestClientVersion)
	fmt.Fprintf(&prefix, "mkdir -p '%s/bin' && cat > '%s/bin/ledger' <<'LEDGER_SH_EOF'\n%sLEDGER_SH_EOF\n", dir, dir, ensureNewline(guestLedgerSh))
	fmt.Fprintf(&prefix, "cat > '%s/ledger.py' <<'LEDGER_PY_EOF'\n%sLEDGER_PY_EOF\n", dir, ensureNewline(guestLedgerPy))
	fmt.Fprintf(&prefix, "chmod 755 '%s/bin/ledger' && echo '%s' > '%s/VERSION'\n", dir, guestClientVersion, dir)
	prefix.WriteString("fi\n")
	return prefix.String()
}

func ensureNewline(s string) string {
	if strings.HasSuffix(s, "\n") {
		return s
	}
	return s + "\n"
}
