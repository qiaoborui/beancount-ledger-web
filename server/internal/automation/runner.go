package automation

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

// ModelConfig is the OpenAI- or Anthropic-compatible endpoint the Agent
// calls; on mibook it is the gateway on the same host.
type ModelConfig struct {
	// API is openai-completions, openai-responses or anthropic-messages.
	API      string
	BaseURL  string
	Model    string
	APIKey   string
	Thinking string
	// ContextWindow and MaxOutputTokens are the model's limits. A custom
	// endpoint is not in any catalog, so without them the Agent assumes a
	// 128k window and an 8192-token reply, and a reasoning model can spend
	// the whole reply thinking. Zero keeps the assumption.
	ContextWindow   int
	MaxOutputTokens int
}

// Config describes one runner.
type Config struct {
	// Home holds the mirror, the exported ledger, scratch copies and the
	// record worktree.
	Home       string
	Repo       string
	Branch     string
	RunsBranch string
	Entrypoint string
	Location   *time.Location
	Model      ModelConfig
	Notifier   Notifier
	// GenericNotifications hides amounts and payees from pushes.
	GenericNotifications bool
	// KeepRuns bounds how many run directories the record branch keeps.
	KeepRuns int
	// NewTaskGrace is how late a new task's first slot may still run; an
	// older slot is only recorded, so creating a task never fires it at
	// once for a time long past.
	NewTaskGrace time.Duration
	// RetryWindow is how long after its slot a degraded run is retried.
	RetryWindow time.Duration
	// RetryDelays are the waits between Agent attempts inside one run.
	RetryDelays []time.Duration
	CommitName  string
	CommitEmail string
	// RunTurn runs one Agent turn: mobileagent.RunTurnJSON.
	RunTurn func(requestJSON string) string
	Now     func() time.Time
	Logger  *slog.Logger
	// Sleep is replaced by tests.
	Sleep func(ctx context.Context, d time.Duration)
}

// Runner runs the scheduled tasks of one ledger.
type Runner struct{ cfg Config }

// NewRunner fills the defaults of cfg.
func NewRunner(cfg Config) (*Runner, error) {
	if cfg.Home == "" || !filepath.IsAbs(cfg.Home) {
		return nil, errors.New("home must be an absolute directory")
	}
	if cfg.Repo == "" {
		return nil, errors.New("repo is required")
	}
	if cfg.RunTurn == nil {
		return nil, errors.New("RunTurn is required")
	}
	if cfg.Model.BaseURL == "" || cfg.Model.Model == "" {
		return nil, errors.New("model base URL and model id are required")
	}
	defaults := []struct {
		value    *string
		fallback string
	}{{&cfg.Branch, "main"}, {&cfg.RunsBranch, "automation-runs"}, {&cfg.Entrypoint, "main.bean"},
		{&cfg.Model.API, "openai-completions"}, {&cfg.CommitName, "ledger-automation"},
		{&cfg.CommitEmail, "ledger-automation@localhost"}}
	for _, d := range defaults {
		if *d.value == "" {
			*d.value = d.fallback
		}
	}
	if cfg.Location == nil {
		cfg.Location = time.Local
	}
	if cfg.KeepRuns <= 0 {
		cfg.KeepRuns = 200
	}
	if cfg.NewTaskGrace <= 0 {
		cfg.NewTaskGrace = 15 * time.Minute
	}
	if cfg.RetryWindow <= 0 {
		cfg.RetryWindow = 2 * time.Hour
	}
	if cfg.RetryDelays == nil {
		cfg.RetryDelays = []time.Duration{30 * time.Second, 2 * time.Minute}
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.Sleep == nil {
		cfg.Sleep = func(ctx context.Context, d time.Duration) {
			select {
			case <-ctx.Done():
			case <-time.After(d):
			}
		}
	}
	return &Runner{cfg: cfg}, nil
}

func (r *Runner) mirrorDir() string { return filepath.Join(r.cfg.Home, "mirror.git") }
func (r *Runner) runsDir() string   { return filepath.Join(r.cfg.Home, "runs") }
func (r *Runner) sleep(ctx context.Context, d time.Duration) {
	r.cfg.Sleep(ctx, d)
}

// lock keeps two ticks from running at once; the second one returns.
func (r *Runner) lock() (func(), error) {
	if err := os.MkdirAll(r.cfg.Home, 0o700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(r.cfg.Home, "tick.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, ErrBusy
	}
	return func() { _ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN); file.Close() }, nil
}

// ErrBusy reports that another tick holds the lock.
var ErrBusy = errors.New("another tick is running")

// Result is what a tick did, for the log.
type Result struct {
	Commit   string            `json:"commit"`
	Ran      []string          `json:"ran"`
	Skipped  []string          `json:"skipped,omitempty"`
	Problems map[string]string `json:"problems,omitempty"`
}

// Tick runs every task that is due. force names tasks to run now whatever
// their schedule ("立即运行").
func (r *Runner) Tick(ctx context.Context, force ...string) (Result, error) {
	unlock, err := r.lock()
	if err != nil {
		return Result{}, err
	}
	defer unlock()
	sha, err := r.syncMirror(ctx)
	if err != nil {
		return Result{}, err
	}
	workspace, err := r.exportGeneration(ctx, sha)
	if err != nil {
		return Result{}, err
	}
	runs, err := r.openRuns(ctx)
	if err != nil {
		return Result{}, err
	}
	state, err := loadState(runs)
	if err != nil {
		return Result{}, err
	}
	tasks, problems, err := LoadTasks(workspace, r.cfg.Location)
	if err != nil {
		return Result{}, err
	}
	result := Result{Commit: sha, Problems: map[string]string{}}
	for id, problem := range problems {
		result.Problems[id] = problem.Error()
	}
	forced := map[string]bool{}
	for _, id := range force {
		forced[id] = true
	}
	now := r.cfg.Now()
	for _, task := range tasks {
		if !task.Enabled && !forced[task.ID] {
			continue
		}
		job, ok := r.due(task, state, now, forced[task.ID])
		if !ok {
			continue
		}
		if err := ctx.Err(); err != nil {
			return result, err
		}
		status := r.run(ctx, task, job, sha, workspace, runs, state)
		result.Ran = append(result.Ran, task.ID+":"+status)
		if err := state.save(runs); err != nil {
			return result, err
		}
		r.pruneRuns(runs)
		if err := r.commitRuns(ctx, runs, fmt.Sprintf("Run %s (%s)", task.ID, status)); err != nil {
			r.cfg.Logger.Warn("push run record", "task", task.ID, "err", err)
		}
	}
	for id := range forced {
		if !containsTask(tasks, id) {
			result.Problems[id] = "no such task"
		}
	}
	// Baselines written for new tasks still need saving.
	if err := state.save(runs); err != nil {
		return result, err
	}
	if err := r.commitRuns(ctx, runs, "Update automation state"); err != nil {
		r.cfg.Logger.Warn("push state", "err", err)
	}
	return result, nil
}

func containsTask(tasks []Task, id string) bool {
	for _, task := range tasks {
		if task.ID == id {
			return true
		}
	}
	return false
}

// job is one run to do: a new slot, or another attempt at a degraded one.
type job struct {
	slot  time.Time
	runID string
	retry *RetryState
}

func (r *Runner) due(task Task, state *State, now time.Time, forced bool) (job, bool) {
	current := state.Tasks[task.ID]
	if forced {
		slot := now.Truncate(time.Minute)
		return job{slot: slot, runID: runID(slot, task.ID, "manual")}, true
	}
	slot := task.Schedule.LatestSlot(now, task.Location)
	if slot.IsZero() {
		return job{}, false
	}
	if current == nil {
		if now.Sub(slot) > r.cfg.NewTaskGrace {
			state.Tasks[task.ID] = &TaskState{LastSlot: slot}
			return job{}, false
		}
		return job{slot: slot, runID: runID(slot, task.ID, "")}, true
	}
	if slot.After(current.LastSlot) {
		return job{slot: slot, runID: runID(slot, task.ID, "")}, true
	}
	if retry := current.Retry; retry != nil {
		if now.Sub(retry.Slot) > r.cfg.RetryWindow {
			current.Retry = nil
			current.LastStatus = "failed"
			return job{}, false
		}
		if !now.Before(retry.NextAt) {
			return job{slot: retry.Slot, runID: retry.RunID, retry: retry}, true
		}
	}
	return job{}, false
}

func runID(slot time.Time, taskID, suffix string) string {
	id := slot.UTC().Format("20060102T1504Z") + "-" + taskID
	if suffix != "" {
		id += "-" + suffix
	}
	return id
}

// RunRecord is runs/<id>/run.json.
type RunRecord struct {
	Version        int       `json:"version"`
	ID             string    `json:"id"`
	Task           string    `json:"task"`
	TaskName       string    `json:"taskName"`
	Slot           time.Time `json:"slot"`
	StartedAt      time.Time `json:"startedAt"`
	FinishedAt     time.Time `json:"finishedAt"`
	Commit         string    `json:"commit"`
	Status         string    `json:"status"`
	Attempts       int       `json:"attempts"`
	Error          string    `json:"error,omitempty"`
	ConversationID string    `json:"conversationId"`
	Summary        string    `json:"summary"`
	Findings       int       `json:"findings"`
	NewFindings    int       `json:"newFindings"`
	HasDraft       bool      `json:"hasDraft"`
	// DraftFiles are the ledger paths the draft changes; draft/base and
	// draft/after hold each one before and after.
	DraftFiles []string `json:"draftFiles,omitempty"`
	Model      string   `json:"model"`
	AuditMs    int64    `json:"auditMs,omitempty"`
	AgentMs    int64    `json:"agentMs,omitempty"`
}

// Status values of a run.
const (
	StatusOK       = "ok"
	StatusDegraded = "degraded"
	StatusFailed   = "failed"
)

func (r *Runner) run(ctx context.Context, task Task, job job, sha, workspace, runs string, state *State) string {
	started := r.cfg.Now()
	dir := filepath.Join(runs, "runs", job.runID)
	record := RunRecord{Version: 1, ID: job.runID, Task: task.ID, TaskName: task.Name, Slot: job.slot,
		StartedAt: started, Commit: sha, Model: firstNonEmpty(task.Model, r.cfg.Model.Model)}
	current := state.Tasks[task.ID]
	if current == nil {
		current = &TaskState{}
		state.Tasks[task.ID] = current
	}
	if job.retry != nil {
		// Another attempt keeps the run's findings and conversation id.
		var previous RunRecord
		if data, err := os.ReadFile(filepath.Join(dir, "run.json")); err == nil && json.Unmarshal(data, &previous) == nil {
			record.ConversationID = previous.ConversationID
			record.Findings, record.NewFindings = previous.Findings, previous.NewFindings
			record.Attempts = previous.Attempts
			record.Commit, sha = previous.Commit, previous.Commit
		}
	} else {
		current.LastSlot = job.slot
	}
	if record.ConversationID == "" {
		record.ConversationID = newUUID()
	}
	logger := r.cfg.Logger.With("task", task.ID, "run", job.runID)

	var report *app.AuditReport
	if task.Audit {
		auditStart := time.Now()
		audit, err := app.RunLocalAudit(app.LocalRequest{WorkspaceRoot: workspace, Entrypoint: r.cfg.Entrypoint},
			app.AuditOptions{Today: job.slot.In(task.Location).Format(time.DateOnly)})
		record.AuditMs = time.Since(auditStart).Milliseconds()
		if err != nil {
			logger.Warn("audit", "err", err)
		} else {
			report = &audit
			newCount, known := countNew(audit.Findings, current.Known)
			if job.retry == nil {
				record.Findings, record.NewFindings = len(audit.Findings), newCount
			}
			current.Known = known
			// The findings are saved before the model is called, so they
			// survive a model that cannot be reached.
			if err := writeJSON(filepath.Join(dir, "findings.json"), audit); err != nil {
				logger.Warn("write findings", "err", err)
			}
		}
	}

	// A degraded run retried later reads the commit it was planned on.
	if job.retry != nil && sha != "" {
		if exported, err := r.exportGeneration(ctx, sha); err == nil {
			workspace = exported
		}
	}
	reply, agentErr := r.runAgent(ctx, task, job, sha, workspace, dir, report, &record)
	record.FinishedAt = r.cfg.Now()
	switch {
	case agentErr == nil:
		record.Status = StatusOK
		record.Summary = summarize(reply)
		current.Retry = nil
	case job.slot.Add(r.cfg.RetryWindow).After(record.FinishedAt):
		record.Status = StatusDegraded
		record.Error = agentErr.Error()
		attempts := 1
		if job.retry != nil {
			attempts = job.retry.Attempts + 1
		}
		current.Retry = &RetryState{RunID: job.runID, Slot: job.slot, Attempts: attempts,
			NextAt: record.FinishedAt.Add(time.Duration(min(attempts, 3)) * 20 * time.Minute)}
	default:
		record.Status = StatusFailed
		record.Error = agentErr.Error()
		current.Retry = nil
	}
	if record.Summary == "" {
		record.Summary = findingSummary(report, record.Findings, record.NewFindings)
	}
	current.LastRunID, current.LastStatus, current.LastRunAt = job.runID, record.Status, record.FinishedAt
	if err := writeJSON(filepath.Join(dir, "run.json"), record); err != nil {
		logger.Warn("write run", "err", err)
	}
	logger.Info("run finished", "status", record.Status, "findings", record.Findings, "draft", record.HasDraft, "err", record.Error)
	r.notify(ctx, task, record, current)
	return record.Status
}

// runAgent asks the Agent, retrying a failed turn a few times. It writes
// the conversation, transcript and draft patch into dir.
func (r *Runner) runAgent(ctx context.Context, task Task, job job, sha, workspace, dir string,
	report *app.AuditReport, record *RunRecord) (string, error) {
	scratch, cleanup, err := r.openScratch(ctx, sha, job.runID)
	if err != nil {
		return "", err
	}
	defer cleanup()
	message := buildMessage(task, report, job.slot)
	request := map[string]any{
		"version": 1, "turnId": job.runID, "workspaceRoot": workspace,
		"runtimeRoot": filepath.Join(r.cfg.Home, "ledger", "runtime"), "entrypoint": r.cfg.Entrypoint,
		"provider": "custom", "model": record.Model, "apiKey": r.cfg.Model.APIKey,
		"custom":      map[string]string{"api": r.cfg.Model.API, "baseURL": r.cfg.Model.BaseURL},
		"thinking":    firstNonEmpty(task.Thinking, r.cfg.Model.Thinking),
		"scratchRoot": scratch, "conversationId": record.ConversationID, "message": message,
	}
	if r.cfg.Model.ContextWindow > 0 {
		request["contextWindow"] = r.cfg.Model.ContextWindow
	}
	if r.cfg.Model.MaxOutputTokens > 0 {
		request["maxOutputTokens"] = r.cfg.Model.MaxOutputTokens
	}
	raw, err := json.Marshal(request)
	if err != nil {
		return "", err
	}
	agentStart := time.Now()
	defer func() { record.AgentMs = time.Since(agentStart).Milliseconds() }()
	var response agentResponse
	for attempt := 0; ; attempt++ {
		record.Attempts++
		response = agentResponse{}
		if err := json.Unmarshal([]byte(r.cfg.RunTurn(string(raw))), &response); err != nil {
			response.Error = "unreadable Agent response: " + err.Error()
		}
		if response.OK || attempt >= len(r.cfg.RetryDelays) || ctx.Err() != nil {
			break
		}
		r.cfg.Logger.Warn("agent attempt failed", "task", task.ID, "attempt", attempt+1, "err", response.Error)
		r.sleep(ctx, r.cfg.RetryDelays[attempt])
	}
	if !response.OK {
		return "", errors.New(firstNonEmpty(response.Error, "the Agent did not answer"))
	}
	if response.Edited {
		patch, err := draftPatch(ctx, scratch)
		if err != nil {
			return "", fmt.Errorf("collect draft: %w", err)
		}
		if strings.TrimSpace(patch) != "" {
			if err := os.WriteFile(filepath.Join(dir, "draft.patch"), []byte(patch), 0o600); err != nil {
				return "", err
			}
			_ = os.RemoveAll(filepath.Join(dir, "draft"))
			files, err := writeDraftTrees(ctx, scratch, sha, dir)
			if err != nil {
				return "", fmt.Errorf("collect draft: %w", err)
			}
			record.HasDraft, record.DraftFiles = true, files
		}
	}
	if !record.HasDraft {
		_ = os.Remove(filepath.Join(dir, "draft.patch"))
		_ = os.RemoveAll(filepath.Join(dir, "draft"))
	}
	if response.Transcript != "" {
		if err := os.WriteFile(filepath.Join(dir, "transcript"), []byte(response.Transcript), 0o600); err != nil {
			return "", err
		}
	}
	conversation := savedConversation(record.ConversationID, job.runID, task, job.slot, record.StartedAt, r.cfg.Now(), response)
	if err := writeJSON(filepath.Join(dir, "conversation.json"), conversation); err != nil {
		return "", err
	}
	return response.Reply, nil
}

// agentResponse is the part of mobileagent's turn response a run keeps.
type agentResponse struct {
	OK         bool              `json:"ok"`
	Reply      string            `json:"reply"`
	Error      string            `json:"error"`
	Edited     bool              `json:"edited"`
	Transcript string            `json:"transcript"`
	ToolCalls  []json.RawMessage `json:"toolCalls"`
}

// automationPrompt frames an unattended run for the model.
const automationPrompt = `（系统提示：这是一次无人值守的定时任务运行，用户现在不在。
- 按下面的任务要求做完，最后用中文给出简短结论：发现了什么、建议怎么处理。
- 需要改账本时只改草稿（编辑文件工具），不要假设会被写入；用户之后会在手机上逐条确认。
- 用户此刻无法回答问题。拿不准的地方写进结论，让用户之后接着聊时决定，不要调用 ask_user。
- 账本数据以工具查询结果为准。）`

func buildMessage(task Task, report *app.AuditReport, slot time.Time) string {
	var builder strings.Builder
	builder.WriteString(automationPrompt)
	fmt.Fprintf(&builder, "\n\n任务：%s（计划时间 %s）\n\n%s", task.Name,
		slot.In(task.Location).Format("2006-01-02 15:04 MST"), task.Prompt)
	if report != nil {
		findings := report.Findings
		if len(findings) > 40 {
			findings = findings[:40]
		}
		data, _ := json.Marshal(findings)
		fmt.Fprintf(&builder, "\n\n确定性巡检结果（%d 条，规则检查，不一定都是问题，请逐条核实）：\n%s", len(report.Findings), data)
	}
	message := builder.String()
	// mobileagent takes at most 12000 bytes.
	for len(message) > 11500 {
		_, size := utf8.DecodeLastRuneInString(message)
		message = message[:len(message)-size]
	}
	return message
}

func countNew(findings []app.AuditFinding, known []string) (int, []string) {
	seen := map[string]bool{}
	for _, id := range known {
		seen[id] = true
	}
	count := 0
	current := make([]string, 0, len(findings))
	for _, finding := range findings {
		if !seen[finding.ID] {
			count++
		}
		current = append(current, finding.ID)
	}
	return count, mergeKnown(current)
}

func findingSummary(report *app.AuditReport, total, fresh int) string {
	if report == nil {
		return ""
	}
	if total == 0 {
		return "巡检没有发现问题"
	}
	return fmt.Sprintf("巡检发现 %d 个问题，其中 %d 个是新的", total, fresh)
}

// summarize is the first meaningful line of the reply, for a push.
func summarize(reply string) string {
	for _, line := range strings.Split(reply, "\n") {
		line = strings.TrimSpace(strings.Trim(strings.TrimSpace(line), "#>*-| "))
		if line == "" {
			continue
		}
		if utf8.RuneCountInString(line) > 120 {
			runes := []rune(line)
			line = string(runes[:120]) + "…"
		}
		return line
	}
	return ""
}

func (r *Runner) notify(ctx context.Context, task Task, record RunRecord, current *TaskState) {
	if r.cfg.Notifier == nil {
		return
	}
	n := Notification{Title: task.Name, URL: "ledger://automation/run?id=" + record.ID}
	switch record.Status {
	case StatusOK:
		n.Body = record.Summary
		if record.HasDraft {
			n.Body += "（有待确认的草稿）"
		}
	default:
		today := r.cfg.Now().In(task.Location).Format(time.DateOnly)
		if current.FailureNotifiedOn == today {
			return
		}
		current.FailureNotifiedOn = today
		n.Body = "助手这次没跑完"
		if record.Status == StatusDegraded {
			n.Body += "，稍后会重试"
		}
		if record.Summary != "" {
			n.Body += "。" + record.Summary
		}
	}
	if r.cfg.GenericNotifications {
		n.Body = "定时任务有新结果，打开 App 查看"
	}
	if err := r.cfg.Notifier.Notify(ctx, n); err != nil {
		r.cfg.Logger.Warn("notify", "task", task.ID, "err", err)
	}
}

// pruneRuns keeps the newest KeepRuns run directories.
func (r *Runner) pruneRuns(runs string) {
	entries, err := os.ReadDir(filepath.Join(runs, "runs"))
	if err != nil {
		return
	}
	names := []string{}
	for _, entry := range entries {
		if entry.IsDir() {
			names = append(names, entry.Name())
		}
	}
	if len(names) <= r.cfg.KeepRuns {
		return
	}
	sort.Strings(names)
	for _, name := range names[:len(names)-r.cfg.KeepRuns] {
		_ = os.RemoveAll(filepath.Join(runs, "runs", name))
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:]))
}

// savedConversation is the run as a conversation in the App's history
// format (LedgerAgentSavedConversation, version 1), so opening it on the
// phone continues it like any other conversation.
// automationRun names the run, so the App marks it in the history and finds
// the run's draft when it is first opened.
func savedConversation(id, runID string, task Task, slot, started, finished time.Time, response agentResponse) map[string]any {
	toolCalls := response.ToolCalls
	if toolCalls == nil {
		toolCalls = []json.RawMessage{}
	}
	assistant := map[string]any{"role": "assistant", "text": response.Reply, "toolCalls": toolCalls,
		"duration": finished.Sub(started).Seconds()}
	return map[string]any{
		"version":   1,
		"id":        id,
		"createdAt": started.UTC().Format(time.RFC3339),
		"updatedAt": finished.UTC().Format(time.RFC3339),
		"messages": []map[string]any{
			{"role": "user", "text": task.Prompt, "toolCalls": []any{}},
			assistant,
		},
		"unwrittenChange": false,
		"generatedTitle":  task.Name + " · " + slot.In(task.Location).Format("01-02 15:04"),
		"automationRun":   runID,
	}
}

// CheckReport is what `ledger-automation check` prints.
type CheckReport struct {
	Commit   string            `json:"commit"`
	Tasks    []CheckTask       `json:"tasks"`
	Problems map[string]string `json:"problems,omitempty"`
}

// CheckTask is one task as the scheduler sees it now.
type CheckTask struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Schedule   string     `json:"schedule"`
	Timezone   string     `json:"timezone"`
	Enabled    bool       `json:"enabled"`
	LatestSlot time.Time  `json:"latestSlot"`
	State      *TaskState `json:"state,omitempty"`
}

// Check loads the tasks without running any, to validate a setup.
func (r *Runner) Check(ctx context.Context) (CheckReport, error) {
	unlock, err := r.lock()
	if err != nil {
		return CheckReport{}, err
	}
	defer unlock()
	sha, err := r.syncMirror(ctx)
	if err != nil {
		return CheckReport{}, err
	}
	workspace, err := r.exportGeneration(ctx, sha)
	if err != nil {
		return CheckReport{}, err
	}
	state := &State{Tasks: map[string]*TaskState{}}
	if _, err := os.Stat(filepath.Join(r.runsDir(), ".git")); err == nil {
		if loaded, err := loadState(r.runsDir()); err == nil {
			state = loaded
		}
	}
	tasks, problems, err := LoadTasks(workspace, r.cfg.Location)
	if err != nil {
		return CheckReport{}, err
	}
	report := CheckReport{Commit: sha, Tasks: []CheckTask{}, Problems: map[string]string{}}
	for id, problem := range problems {
		report.Problems[id] = problem.Error()
	}
	now := r.cfg.Now()
	for _, task := range tasks {
		report.Tasks = append(report.Tasks, CheckTask{ID: task.ID, Name: task.Name, Schedule: task.Schedule.String(),
			Timezone: task.Location.String(), Enabled: task.Enabled, LatestSlot: task.Schedule.LatestSlot(now, task.Location),
			State: state.Tasks[task.ID]})
	}
	return report, nil
}
