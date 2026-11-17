package automation

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func run(t *testing.T, dir string, args ...string) string {
	t.Helper()
	command := exec.Command("git", args...)
	command.Dir = dir
	command.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	out, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

const testMain = `2026-01-01 open Assets:Card CNY
2026-01-01 open Expenses:Food CNY
2026-11-12 * "美团" "午饭"
  Expenses:Food  38.50 CNY
  Assets:Card
2026-11-13 * "美团" "午饭"
  Expenses:Food  38.50 CNY
  Assets:Card
`

// ledgerRepo is a bare "GitHub" repository holding a small ledger with one
// daily task, plus the working copy that pushed it.
func ledgerRepo(t *testing.T) (remote, work string) {
	t.Helper()
	base := t.TempDir()
	remote = filepath.Join(base, "remote.git")
	work = filepath.Join(base, "work")
	run(t, base, "init", "--bare", "--initial-branch=main", remote)
	run(t, base, "clone", "--quiet", remote, work)
	files := map[string]string{
		"main.bean":                  testMain,
		"automations/daily-audit.md": "---\nname: 每日巡检\nschedule: daily 21:00\ntimezone: Asia/Singapore\n---\n检查账本，有问题就起草修复。\n",
		"automations/broken.md":      "---\nschedule: never\n---\nx\n",
	}
	for name, body := range files {
		path := filepath.Join(work, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run(t, work, "add", "-A")
	run(t, work, "commit", "--quiet", "-m", "ledger")
	run(t, work, "push", "--quiet", "origin", "HEAD:main")
	return remote, work
}

type fakeAgent struct {
	mu       sync.Mutex
	requests []map[string]any
	fail     int
}

func (f *fakeAgent) RunTurn(raw string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var request map[string]any
	_ = json.Unmarshal([]byte(raw), &request)
	f.requests = append(f.requests, request)
	if f.fail > 0 {
		f.fail--
		return `{"version":1,"ok":false,"error":"connection refused","toolCalls":[]}`
	}
	scratch := request["scratchRoot"].(string)
	data, _ := os.ReadFile(filepath.Join(scratch, "main.bean"))
	fixed := strings.Replace(string(data), "2026-11-13 * \"美团\" \"午饭\"\n  Expenses:Food  38.50 CNY\n  Assets:Card\n", "", 1)
	_ = os.WriteFile(filepath.Join(scratch, "main.bean"), []byte(fixed), 0o600)
	return `{"version":1,"ok":true,"reply":"## 结论\n发现 1 笔疑似重复，已起草删除。","edited":true,"transcript":"[]","toolCalls":[{"name":"read_file","isError":false}]}`
}

type recordedNotifier struct{ sent []Notification }

func (r *recordedNotifier) Notify(_ context.Context, n Notification) error {
	r.sent = append(r.sent, n)
	return nil
}

func newTestRunner(t *testing.T, remote string, agent *fakeAgent, notifier Notifier, now *time.Time) *Runner {
	t.Helper()
	runner, err := NewRunner(Config{Home: filepath.Join(t.TempDir(), "home"), Repo: remote,
		Model:   ModelConfig{BaseURL: "http://127.0.0.1:3333/v1", Model: "test-model", APIKey: "k"},
		RunTurn: agent.RunTurn, Notifier: notifier, Now: func() time.Time { return *now },
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		Sleep:  func(context.Context, time.Duration) {}})
	if err != nil {
		t.Fatal(err)
	}
	return runner
}

func TestTickRunsDueTaskAndRecordsTheRun(t *testing.T) {
	remote, _ := ledgerRepo(t)
	sg, _ := time.LoadLocation("Asia/Singapore")
	now := time.Date(2026, 11, 17, 21, 3, 0, 0, sg)
	agent := &fakeAgent{}
	notifier := &recordedNotifier{}
	runner := newTestRunner(t, remote, agent, notifier, &now)

	result, err := runner.Tick(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Ran) != 1 || result.Ran[0] != "daily-audit:ok" || result.Problems["broken"] == "" {
		t.Fatalf("result = %+v", result)
	}
	request := agent.requests[0]
	if request["provider"] != "custom" || request["model"] != "test-model" ||
		!strings.Contains(request["message"].(string), "duplicate") ||
		!strings.Contains(request["message"].(string), "检查账本") {
		t.Fatalf("request = %v", request)
	}
	// The record branch reached the remote with the run.
	clone := filepath.Join(t.TempDir(), "runs")
	run(t, "", "clone", "--quiet", "--branch", "automation-runs", remote, clone)
	runDir := filepath.Join(clone, "runs", "20261117T1300Z-daily-audit")
	var record RunRecord
	data, err := os.ReadFile(filepath.Join(runDir, "run.json"))
	if err != nil {
		t.Fatal(err)
	}
	_ = json.Unmarshal(data, &record)
	if record.Status != StatusOK || !record.HasDraft || record.Findings != 1 || record.NewFindings != 1 ||
		record.Summary != "结论" {
		t.Fatalf("record = %+v", record)
	}
	patch, _ := os.ReadFile(filepath.Join(runDir, "draft.patch"))
	if !strings.Contains(string(patch), "-2026-11-13 * \"美团\"") {
		t.Fatalf("patch = %s", patch)
	}
	var conversation map[string]any
	data, _ = os.ReadFile(filepath.Join(runDir, "conversation.json"))
	_ = json.Unmarshal(data, &conversation)
	if conversation["id"] != record.ConversationID || len(conversation["messages"].([]any)) != 2 {
		t.Fatalf("conversation = %v", conversation)
	}
	if len(notifier.sent) != 1 || !strings.Contains(notifier.sent[0].Body, "草稿") ||
		notifier.sent[0].URL != "ledger://automation/run?id=20261117T1300Z-daily-audit" {
		t.Fatalf("notifications = %+v", notifier.sent)
	}
	// The ledger branch itself was never written.
	if log := run(t, "", "--git-dir", remote, "log", "--oneline", "main"); strings.Count(log, "\n") != 1 {
		t.Fatalf("main changed: %s", log)
	}

	// The same slot does not run twice.
	now = now.Add(5 * time.Minute)
	if result, err = runner.Tick(context.Background()); err != nil || len(result.Ran) != 0 {
		t.Fatalf("second tick = %+v, %v", result, err)
	}
	// A forced run goes now, and the same findings are no longer new.
	if result, err = runner.Tick(context.Background(), "daily-audit"); err != nil || len(result.Ran) != 1 {
		t.Fatalf("forced tick = %+v, %v", result, err)
	}
	if !strings.Contains(notifier.sent[1].Body, "结论") {
		t.Fatalf("notifications = %+v", notifier.sent)
	}
}

func TestTickSkipsOldSlotsOfANewTask(t *testing.T) {
	remote, _ := ledgerRepo(t)
	sg, _ := time.LoadLocation("Asia/Singapore")
	now := time.Date(2026, 11, 17, 9, 0, 0, 0, sg)
	agent := &fakeAgent{}
	runner := newTestRunner(t, remote, agent, nil, &now)
	if result, err := runner.Tick(context.Background()); err != nil || len(result.Ran) != 0 {
		t.Fatalf("tick = %+v, %v", result, err)
	}
	now = time.Date(2026, 11, 17, 21, 5, 0, 0, sg)
	if result, err := runner.Tick(context.Background()); err != nil || len(result.Ran) != 1 {
		t.Fatalf("tick at slot = %+v, %v", result, err)
	}
}

func TestDegradedRunKeepsFindingsAndRetries(t *testing.T) {
	remote, _ := ledgerRepo(t)
	sg, _ := time.LoadLocation("Asia/Singapore")
	now := time.Date(2026, 11, 17, 21, 1, 0, 0, sg)
	agent := &fakeAgent{fail: 3}
	notifier := &recordedNotifier{}
	runner := newTestRunner(t, remote, agent, notifier, &now)
	result, err := runner.Tick(context.Background())
	if err != nil || len(result.Ran) != 1 || result.Ran[0] != "daily-audit:degraded" {
		t.Fatalf("tick = %+v, %v", result, err)
	}
	if len(agent.requests) != 3 {
		t.Fatalf("attempts = %d", len(agent.requests))
	}
	findings := filepath.Join(runner.runsDir(), "runs", "20261117T1300Z-daily-audit", "findings.json")
	if _, err := os.Stat(findings); err != nil {
		t.Fatalf("findings not saved: %v", err)
	}
	if len(notifier.sent) != 1 || !strings.Contains(notifier.sent[0].Body, "重试") {
		t.Fatalf("notifications = %+v", notifier.sent)
	}
	// Too early for the retry.
	now = now.Add(5 * time.Minute)
	if result, _ := runner.Tick(context.Background()); len(result.Ran) != 0 {
		t.Fatalf("retried too early: %+v", result)
	}
	now = now.Add(20 * time.Minute)
	result, err = runner.Tick(context.Background())
	if err != nil || len(result.Ran) != 1 || result.Ran[0] != "daily-audit:ok" {
		t.Fatalf("retry = %+v, %v", result, err)
	}
	state, _ := loadState(runner.runsDir())
	if state.Tasks["daily-audit"].Retry != nil || state.Tasks["daily-audit"].LastStatus != StatusOK {
		t.Fatalf("state = %+v", state.Tasks["daily-audit"])
	}
}
