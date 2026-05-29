package app

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type PiAgentInput struct {
	Message      string        `json:"message"`
	Messages     []ChatMessage `json:"messages"`
	DraftEntries []LedgerEntry `json:"draftEntries"`
	Today        string        `json:"today"`
}

type piAgentCallbacks struct {
	onMessage func(string) error
	onStatus  func(string) error
	onTool    func(ChatToolEvent) error
}

func (s *Server) chatBookkeepingWithPi(message string, messages []ChatMessage, draft []LedgerEntry, today string) (ChatResult, error) {
	return s.runBookkeepingPiAgent(message, messages, draft, today, nil)
}

func (s *Server) runBookkeepingPiAgent(message string, messages []ChatMessage, draft []LedgerEntry, today string, callbacks *piAgentCallbacks) (ChatResult, error) {
	if strings.TrimSpace(s.cfg.PiAgentCommand) == "" {
		return ChatResult{}, fmt.Errorf("LEDGER_PI_COMMAND is required when LEDGER_AI_RUNTIME=pi")
	}
	if strings.TrimSpace(s.cfg.AgentToolToken) == "" {
		return ChatResult{}, fmt.Errorf("LEDGER_AGENT_TOOL_TOKEN is required when LEDGER_AI_RUNTIME=pi")
	}
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return ChatResult{}, err
	}
	accounts := activeAccounts(snapshot.Accounts)
	if _, err := validateAIEntries(draft, accounts); err != nil {
		return ChatResult{}, err
	}

	input := PiAgentInput{Message: message, Messages: messages, DraftEntries: draft, Today: today}
	raw, err := json.Marshal(input)
	if err != nil {
		return ChatResult{}, err
	}

	timeout := time.Duration(s.cfg.PiAgentTimeout) * time.Second
	if timeout <= 0 {
		timeout = 120 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, s.cfg.PiAgentCommand, s.cfg.PiAgentArgs...)
	cmd.Stdin = bytes.NewReader(raw)
	cmd.Env = append(os.Environ(),
		"LEDGER_AGENT_TOOL_BASE_URL="+env("LEDGER_AGENT_TOOL_BASE_URL", "http://127.0.0.1:"+s.cfg.Port),
		"LEDGER_AGENT_TOOL_TOKEN="+s.cfg.AgentToolToken,
	)

	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return ChatResult{}, err
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return ChatResult{}, err
	}

	if err := cmd.Start(); err != nil {
		return ChatResult{}, err
	}

	var stdout, stderr bytes.Buffer
	var callbackErr error
	var callbackMu sync.Mutex
	setCallbackErr := func(err error) {
		if err == nil {
			return
		}
		callbackMu.Lock()
		defer callbackMu.Unlock()
		if callbackErr == nil {
			callbackErr = err
			cancel()
		}
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(&stdout, stdoutPipe)
	}()
	go func() {
		defer wg.Done()
		scanner := bufio.NewScanner(stderrPipe)
		scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			if err := handlePiAgentProgressLine(line, callbacks); err != nil {
				setCallbackErr(err)
				continue
			}
			if !strings.HasPrefix(line, piProgressPrefix) {
				stderr.WriteString(line)
				stderr.WriteByte('\n')
			}
		}
	}()

	err = cmd.Wait()
	wg.Wait()
	callbackMu.Lock()
	streamErr := callbackErr
	callbackMu.Unlock()
	if streamErr != nil {
		return ChatResult{}, streamErr
	}
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if ctx.Err() == context.DeadlineExceeded {
			return ChatResult{}, fmt.Errorf("Pi agent timed out after %s", timeout)
		}
		if detail != "" {
			return ChatResult{}, fmt.Errorf("Pi agent failed: %s", detail)
		}
		return ChatResult{}, fmt.Errorf("Pi agent failed: %w", err)
	}

	var result ChatResult
	if err := json.Unmarshal([]byte(extractJSON(stdout.String())), &result); err != nil {
		return ChatResult{}, fmt.Errorf("Pi agent returned invalid JSON: %w", err)
	}
	entries, err := validateAIEntries(result.Entries, accounts)
	if err != nil {
		return ChatResult{}, err
	}
	if strings.TrimSpace(result.Message) == "" {
		result.Message = fmt.Sprintf("已更新 %d 条预览。", len(entries))
	}
	result.Plan = normalizeChatPlan(result.Plan)
	result.Entries = entries
	result.Sources = normalizePiChatSources(result.Sources, bookkeepingChatSources(entries, accounts, len(draft)))
	return result, nil
}

const piProgressPrefix = "LEDGER_PI_EVENT "

type piProgressEvent struct {
	Type string         `json:"type"`
	Text string         `json:"text"`
	Tool *ChatToolEvent `json:"tool"`
}

func handlePiAgentProgressLine(line string, callbacks *piAgentCallbacks) error {
	if callbacks == nil || !strings.HasPrefix(line, piProgressPrefix) {
		return nil
	}
	var event piProgressEvent
	if err := json.Unmarshal([]byte(strings.TrimPrefix(line, piProgressPrefix)), &event); err != nil {
		return nil
	}
	switch event.Type {
	case "message":
		if callbacks.onMessage != nil && strings.TrimSpace(event.Text) != "" {
			return callbacks.onMessage(event.Text)
		}
	case "status":
		if callbacks.onStatus != nil && strings.TrimSpace(event.Text) != "" {
			return callbacks.onStatus(event.Text)
		}
	case "tool":
		if callbacks.onTool != nil && event.Tool != nil {
			return callbacks.onTool(*event.Tool)
		}
	}
	return nil
}

func normalizePiChatSources(sources []ChatSource, fallback []ChatSource) []ChatSource {
	cleaned := make([]ChatSource, 0, len(sources))
	for _, source := range sources {
		if strings.TrimSpace(source.Title) == "" &&
			strings.TrimSpace(source.Description) == "" &&
			strings.TrimSpace(source.Kind) == "" &&
			strings.TrimSpace(source.Reference) == "" {
			continue
		}
		cleaned = append(cleaned, source)
	}
	if len(cleaned) == 0 {
		return fallback
	}
	return cleaned
}
