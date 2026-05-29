package app

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAIChatCanUsePiRuntimeCommand(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	wrapper := filepath.Join(t.TempDir(), "pi-wrapper.sh")
	script := `#!/usr/bin/env bash
set -euo pipefail
input="$(cat)"
python3 - "$input" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
assert payload["message"] == "咖啡 18"
print(json.dumps({
  "message": "Pi 可以这样记。",
  "plan": None,
  "sources": [{"title": "ledger MCP", "kind": "tool"}],
  "entries": [{
    "kind": "transaction",
    "date": payload["today"],
    "payee": "Cafe",
    "narration": "Coffee",
    "metadata": {},
    "tags": [],
    "postings": [
      {"account": "Expenses:Food", "amount": "18.00", "currency": "CNY"},
      {"account": "Assets:Cash", "amount": "-18.00", "currency": "CNY"}
    ],
    "confidence": 1,
    "needsReview": False,
    "questions": []
  }]
}, ensure_ascii=False))
PY
`
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	cfg.AIRuntime = "pi"
	cfg.PiAgentCommand = wrapper
	cfg.AgentToolToken = "agent-secret"
	cfg.PiAgentTimeout = 5
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodPost, "/api/ai/chat", `{"message":"咖啡 18","messages":[],"draftEntries":[]}`, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("pi chat status=%d body=%s", res.Code, res.Body.String())
	}
	var body ChatResult
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Message != "Pi 可以这样记。" || len(body.Entries) != 1 || body.Entries[0].Payee != "Cafe" || len(body.Sources) != 1 {
		t.Fatalf("unexpected pi chat response: %#v", body)
	}
}

func TestAIChatPiRuntimeFallsBackForEmptySources(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	wrapper := filepath.Join(t.TempDir(), "pi-wrapper.sh")
	script := `#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
python3 - <<'PY'
import json
print(json.dumps({
  "message": "查到了。",
  "plan": None,
  "sources": [{}, {"title": ""}],
  "entries": []
}, ensure_ascii=False))
PY
`
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	cfg.AIRuntime = "pi"
	cfg.PiAgentCommand = wrapper
	cfg.AgentToolToken = "agent-secret"
	cfg.PiAgentTimeout = 5
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodPost, "/api/ai/chat", `{"message":"查账","messages":[],"draftEntries":[]}`, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("pi chat status=%d body=%s", res.Code, res.Body.String())
	}
	var body ChatResult
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Sources) == 0 || body.Sources[0].Kind != "accounts" {
		t.Fatalf("expected fallback sources, got %#v", body.Sources)
	}
}

func TestAIChatPiRuntimeStreamsWrapperProgress(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	wrapper := filepath.Join(t.TempDir(), "pi-wrapper.sh")
	script := `#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
echo 'LEDGER_PI_EVENT {"type":"status","text":"Pi 正在调用账本工具"}' >&2
echo 'LEDGER_PI_EVENT {"type":"tool","tool":{"id":"ledger-query","name":"ledger.query_transactions","title":"Ledger MCP","status":"running","input":{"range":"today"}}}' >&2
echo 'LEDGER_PI_EVENT {"type":"message","text":"查到了。"}' >&2
echo 'LEDGER_PI_EVENT {"type":"tool","tool":{"id":"ledger-query","name":"ledger.query_transactions","title":"Ledger MCP","status":"completed","output":{"count":1}}}' >&2
python3 - <<'PY'
import json
print(json.dumps({
  "message": "查到了。",
  "plan": None,
  "sources": [{"title": "Ledger MCP", "kind": "tool"}],
  "entries": []
}, ensure_ascii=False))
PY
`
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	cfg.AIRuntime = "pi"
	cfg.PiAgentCommand = wrapper
	cfg.AgentToolToken = "agent-secret"
	cfg.PiAgentTimeout = 5
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodPost, "/api/ai/chat", `{"message":"查今天","messages":[],"draftEntries":[],"stream":true}`, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("pi stream status=%d body=%s", res.Code, res.Body.String())
	}
	body := res.Body.String()
	for _, want := range []string{"Pi 正在调用账本工具", "ledger.query_transactions", "查到了。"} {
		if !strings.Contains(body, want) {
			t.Fatalf("stream missing %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, "parseLedger") || strings.Contains(body, "validateBeancount") {
		t.Fatalf("pi stream should not include legacy tool cards:\n%s", body)
	}
}

func TestAIChatPiRuntimeRequiresCommand(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	cfg.AIRuntime = "pi"
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodPost, "/api/ai/chat", `{"message":"咖啡 18","messages":[],"draftEntries":[]}`, cookies)
	if res.Code != http.StatusBadRequest || !strings.Contains(res.Body.String(), "LEDGER_PI_COMMAND") {
		t.Fatalf("missing pi command status=%d body=%s", res.Code, res.Body.String())
	}
}
