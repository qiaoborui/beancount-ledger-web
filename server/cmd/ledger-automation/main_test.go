package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/automation"
)

// fakeGateway speaks the OpenAI chat completions stream, like the
// freellmapi gateway on mibook.
func fakeGateway(t *testing.T, calls *atomic.Int32) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/models") && r.Header.Get("Authorization") == "Bearer gateway-key" {
			// magpie's shape: the limits sit on each entry.
			fmt.Fprint(w, `{"object":"list","data":[{"id":"other","max_output_tokens":1},`+
				`{"id":"auto","object":"model","context_length":1048576,"max_output_tokens":32768}]}`)
			return
		}
		if !strings.HasSuffix(r.URL.Path, "/chat/completions") || r.Header.Get("Authorization") != "Bearer gateway-key" {
			http.Error(w, "unexpected request "+r.URL.Path, http.StatusUnauthorized)
			return
		}
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), "无人值守") {
			t.Errorf("request lacks the automation prompt: %s", body)
		}
		if !strings.Contains(string(body), "32768") {
			t.Errorf("request does not carry the listed reply limit: %s", body)
		}
		calls.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		chunk := func(delta map[string]any, finish any) {
			data, _ := json.Marshal(map[string]any{"id": "c1", "object": "chat.completion.chunk", "created": 1,
				"model": "m", "choices": []map[string]any{{"index": 0, "delta": delta, "finish_reason": finish}}})
			fmt.Fprintf(w, "data: %s\n\n", data)
		}
		chunk(map[string]any{"role": "assistant", "content": "巡检完成：发现 1 笔疑似重复。"}, nil)
		chunk(map[string]any{}, "stop")
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
}

func TestTickRunsTheRealAgentAgainstAnOpenAICompatibleGateway(t *testing.T) {
	var calls atomic.Int32
	gateway := fakeGateway(t, &calls)
	defer gateway.Close()

	base := t.TempDir()
	remote := filepath.Join(base, "remote.git")
	work := filepath.Join(base, "work")
	git := func(dir string, args ...string) {
		command := exec.Command("git", args...)
		command.Dir = dir
		command.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	git(base, "init", "--bare", "--initial-branch=main", remote)
	git(base, "clone", "--quiet", remote, work)
	_ = os.MkdirAll(filepath.Join(work, "automations"), 0o755)
	_ = os.WriteFile(filepath.Join(work, "main.bean"), []byte("2026-01-01 open Assets:Cash CNY\n"), 0o644)
	_ = os.WriteFile(filepath.Join(work, "automations", "daily.md"), []byte("---\nschedule: hourly\n---\n巡检账本\n"), 0o644)
	git(work, "add", "-A")
	git(work, "commit", "--quiet", "-m", "ledger")
	git(work, "push", "--quiet", "origin", "HEAD:main")

	env := map[string]string{
		"LEDGER_AUTOMATION_HOME":           filepath.Join(base, "home"),
		"LEDGER_AUTOMATION_REPO":           remote,
		"LEDGER_AUTOMATION_MODEL_BASE_URL": gateway.URL + "/v1",
		"LEDGER_AUTOMATION_MODEL":          "auto",
		"LEDGER_AUTOMATION_MODEL_KEY":      "gateway-key",
		"LEDGER_AUTOMATION_TIMEZONE":       "Asia/Singapore",
	}
	cfg, err := configFromEnv(func(key string) string { return env[key] }, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	runner, err := automation.NewRunner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	result, err := runner.Tick(ctx, "daily")
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Ran) != 1 || result.Ran[0] != "daily:ok" || calls.Load() != 1 {
		t.Fatalf("result = %+v, gateway calls = %d", result, calls.Load())
	}
	matches, _ := filepath.Glob(filepath.Join(base, "home", "runs", "runs", "*", "conversation.json"))
	if len(matches) != 1 {
		t.Fatalf("conversation files = %v", matches)
	}
	data, _ := os.ReadFile(matches[0])
	if !strings.Contains(string(data), "巡检完成") {
		t.Fatalf("conversation = %s", data)
	}
}

func TestConfigReadsSystemdCredentials(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "model-key"), []byte("from-credential\n"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "bark-key"), []byte("device"), 0o600)
	env := map[string]string{"CREDENTIALS_DIRECTORY": dir, "LEDGER_AUTOMATION_MODEL_KEY": "from-env",
		"STATE_DIRECTORY": "/var/lib/ledger-automation"}
	cfg, err := configFromEnv(func(key string) string { return env[key] }, slog.Default())
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Model.APIKey != "from-credential" || cfg.Home != "/var/lib/ledger-automation" || cfg.Notifier == nil {
		t.Fatalf("cfg = %+v", cfg)
	}
}
