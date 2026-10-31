// Package mobileagent runs the on-device ledger Agent: a PiG agent loop whose
// only tools are the read-only ledger tools of the local transport. The
// binding exposes scalar JSON functions, like mobilecore.
package mobileagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

const (
	maxTurns        = 12
	maxMessageBytes = 12000
	turnTimeout     = 3 * time.Minute
)

type turnRequestV1 struct {
	Version int `json:"version"`
	app.LocalRequest
	SensitiveUnlocked bool `json:"sensitiveUnlocked"`
	// Provider and Model name a PiG built-in model, for example
	// "anthropic" and "claude-sonnet-4-5". The shell owns the key.
	Provider string `json:"provider"`
	Model    string `json:"model"`
	APIKey   string `json:"apiKey"`
	// History is the prior visible conversation; tool calls are not replayed.
	History []historyMessageV1 `json:"history"`
	Message string             `json:"message"`
}

type historyMessageV1 struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type toolCallV1 struct {
	Name    string `json:"name"`
	IsError bool   `json:"isError"`
}

type turnResponseV1 struct {
	Version   int          `json:"version"`
	OK        bool         `json:"ok"`
	Reply     string       `json:"reply,omitempty"`
	ToolCalls []toolCallV1 `json:"toolCalls"`
	Error     string       `json:"error,omitempty"`
}

// streamFn is replaced by tests with a deterministic provider.
var streamFn agent.StreamFn = ai.StreamSimple

// resolveModel is replaced by tests with a deterministic model.
var resolveModel = func(provider, model string) *ai.Model { return ai.GetBuiltinModel(provider, model) }

// RunTurnJSON runs one user turn to completion and returns the final reply.
// The call blocks; the shell runs it off the main thread.
func RunTurnJSON(requestJSON string) (responseJSON string) {
	defer func() {
		if recovered := recover(); recovered != nil {
			responseJSON = encode(turnResponseV1{Version: 1, ToolCalls: []toolCallV1{}, Error: fmt.Sprint(recovered)})
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), turnTimeout)
	defer cancel()
	reply, calls, err := runTurn(ctx, requestJSON)
	if err != nil {
		return encode(turnResponseV1{Version: 1, ToolCalls: calls, Error: err.Error()})
	}
	return encode(turnResponseV1{Version: 1, OK: true, Reply: reply, ToolCalls: calls})
}

// ToolCatalogJSON lists the tools the on-device Agent can call.
func ToolCatalogJSON() string {
	specs := app.LocalAgentToolSpecs()
	tools := make([]map[string]string, 0, len(specs))
	for _, spec := range specs {
		tools = append(tools, map[string]string{"name": spec.Name, "title": spec.Title})
	}
	return encode(map[string]any{"version": 1, "tools": tools})
}

func runTurn(ctx context.Context, requestJSON string) (string, []toolCallV1, error) {
	calls := []toolCallV1{}
	decoder := json.NewDecoder(strings.NewReader(requestJSON))
	decoder.DisallowUnknownFields()
	var request turnRequestV1
	if err := decoder.Decode(&request); err != nil {
		return "", calls, fmt.Errorf("invalid Agent request: %w", err)
	}
	if request.Version != 1 {
		return "", calls, errors.New("supported Agent request version is 1")
	}
	message := strings.TrimSpace(request.Message)
	if message == "" || len(message) > maxMessageBytes {
		return "", calls, errors.New("message is required and must be at most 12000 bytes")
	}
	model := resolveModel(request.Provider, request.Model)
	if model == nil {
		return "", calls, fmt.Errorf("unknown model %s/%s", request.Provider, request.Model)
	}
	session, err := app.OpenLocalAgentSession(request.LocalRequest, request.SensitiveUnlocked)
	if err != nil {
		return "", calls, err
	}
	specs := app.LocalAgentToolSpecs()
	tools := make([]agent.AgentTool, 0, len(specs))
	allowed := make(map[string]bool, len(specs))
	for _, spec := range specs {
		tools = append(tools, ledgerTool{spec: spec, session: session})
		allowed[spec.Name] = true
	}
	history, err := historyMessages(request.History)
	if err != nil {
		return "", calls, err
	}
	key := request.APIKey
	runner, err := agent.NewAgent(agent.AgentOptions{
		InitialState: &agent.AgentInitialState{Messages: history},
		Model:        model,
		Tools:        tools,
		SystemPrompt: app.LocalAgentSystemPrompt(),
		MaxTurns:     maxTurns,
		StreamFn:     streamFn,
		GetAPIKey:    func(string) (string, error) { return key, nil },
		// Defense in depth: the loop must never run a tool outside the catalog.
		BeforeToolCallHooks: []agent.BeforeToolCallHook{func(_ context.Context, _, name string, _ json.RawMessage) agent.ToolCallHookResult {
			if !allowed[name] {
				return agent.ToolCallHookResult{Block: true, Reason: "tool is not available on this device"}
			}
			return agent.ToolCallHookResult{}
		}},
	})
	if err != nil {
		return "", calls, err
	}
	produced, err := runner.Send(ctx, message)
	for _, produced := range produced {
		if result := produced.ToolResult; result != nil {
			calls = append(calls, toolCallV1{Name: result.ToolName, IsError: result.IsError})
		}
	}
	if err != nil {
		return "", calls, err
	}
	for index := len(produced) - 1; index >= 0; index-- {
		if assistant := produced[index].Assistant; assistant != nil {
			if assistant.ErrorMessage != "" {
				return "", calls, errors.New(assistant.ErrorMessage)
			}
			return assistantText(assistant.Content), calls, nil
		}
	}
	return "", calls, errors.New("the model returned no reply")
}

func historyMessages(history []historyMessageV1) ([]agent.AgentMessage, error) {
	messages := make([]agent.AgentMessage, 0, len(history))
	timestamp := time.Now().UnixMilli()
	for _, entry := range history {
		switch entry.Role {
		case "user":
			messages = append(messages, agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(entry.Content), Timestamp: timestamp}})
		case "assistant":
			messages = append(messages, agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant",
				Content: []ai.AssistantContentBlock{ai.TextContent{Text: entry.Content}}, StopReason: ai.StopReasonStop, Timestamp: timestamp}})
		default:
			return nil, fmt.Errorf("unsupported history role %q", entry.Role)
		}
	}
	return messages, nil
}

func assistantText(content []ai.AssistantContentBlock) string {
	var parts []string
	for _, block := range content {
		if text, ok := block.(ai.TextContent); ok && strings.TrimSpace(text.Text) != "" {
			parts = append(parts, text.Text)
		}
	}
	return strings.Join(parts, "\n")
}

func encode(value any) string {
	raw, err := json.Marshal(value)
	if err != nil {
		return `{"version":1,"ok":false,"toolCalls":[],"error":"response encoding failed"}`
	}
	return string(raw)
}

type ledgerTool struct {
	spec    app.LocalAgentToolSpec
	session *app.LocalAgentSession
}

func (t ledgerTool) Name() string  { return t.spec.Name }
func (t ledgerTool) Label() string { return t.spec.Title }
func (t ledgerTool) Schema() ai.ToolSchema {
	return ai.ToolSchema{Name: t.spec.Name, Description: t.spec.Description, Parameters: t.spec.Parameters}
}
func (ledgerTool) ExecutionMode() agent.ToolExecutionMode { return agent.ToolModeSequential }

func (t ledgerTool) Execute(ctx context.Context, _ string, params json.RawMessage, _ agent.ToolUpdateCallback) (agent.AgentToolResult, error) {
	output, err := t.session.Execute(ctx, t.spec.Name, params)
	if err != nil {
		return agent.AgentToolResult{}, err
	}
	return agent.AgentToolResult{Content: []ai.ToolResultMessageContent{ai.TextContent{Text: string(output)}}, Details: map[string]any{}}, nil
}
