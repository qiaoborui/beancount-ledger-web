// Package mobileagent runs the on-device ledger Agent: a PiG agent loop whose
// only tools are the read-only ledger tools of the local transport. The
// binding exposes scalar JSON functions, like mobilecore.
package mobileagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
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
	// TurnID lets CancelTurn stop this turn; optional.
	TurnID string `json:"turnId"`
	app.LocalRequest
	SensitiveUnlocked bool `json:"sensitiveUnlocked"`
	// Provider and Model name a PiG built-in model, for example
	// "anthropic" and "claude-sonnet-4-5". The shell owns the key.
	Provider string `json:"provider"`
	Model    string `json:"model"`
	APIKey   string `json:"apiKey"`
	// Custom describes the endpoint when Provider is "custom": any server
	// that speaks one of the supported wire protocols.
	Custom *customEndpointV1 `json:"custom,omitempty"`
	// History is the prior visible conversation; tool calls are not replayed.
	History []historyMessageV1 `json:"history"`
	Message string             `json:"message"`
}

type customEndpointV1 struct {
	API     string `json:"api"`
	BaseURL string `json:"baseURL"`
}

// customProvider is the catalog id of a user-supplied endpoint.
const customProvider = "custom"

// customAPIs are the wire protocols a custom endpoint may speak.
var customAPIs = map[string]bool{"openai-completions": true, "openai-responses": true, "anthropic-messages": true}

// customModel builds a model for a user-supplied endpoint. Base URLs are
// taken in the OpenAI form ending in /v1; PiG's Anthropic client appends
// /v1/messages itself, so a trailing /v1 is dropped for that protocol.
func customModel(id string, endpoint *customEndpointV1) (*ai.Model, error) {
	if endpoint == nil || !customAPIs[endpoint.API] {
		return nil, errors.New("custom endpoint needs api openai-completions, openai-responses or anthropic-messages")
	}
	id = strings.TrimSpace(id)
	if id == "" {
		return nil, errors.New("custom endpoint needs a model id")
	}
	base, err := url.Parse(strings.TrimSpace(endpoint.BaseURL))
	if err != nil || (base.Scheme != "https" && base.Scheme != "http") || base.Host == "" || base.User != nil || base.RawQuery != "" || base.Fragment != "" {
		return nil, errors.New("custom endpoint needs an http(s) base URL without credentials or query")
	}
	baseURL := strings.TrimRight(base.String(), "/")
	if endpoint.API == "anthropic-messages" {
		baseURL = strings.TrimSuffix(baseURL, "/v1")
	}
	return &ai.Model{ID: id, DisplayName: id,
		ProviderMeta: ai.ProviderMetadata{ProviderID: customProvider, API: ai.API(endpoint.API), BaseURL: baseURL},
		Capabilities: ai.ModelCapabilities{SupportsToolUse: true, ContextWindow: 128000, MaxOutputTokens: 8192}}, nil
}

type historyMessageV1 struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type toolCallV1 struct {
	Name string `json:"name"`
	// Arguments are what the model asked for, so the shell can show the BQL
	// or date range each read used.
	Arguments json.RawMessage `json:"arguments,omitempty"`
	IsError   bool            `json:"isError"`
}

type turnResponseV1 struct {
	Version   int  `json:"version"`
	OK        bool `json:"ok"`
	Cancelled bool `json:"cancelled,omitempty"`
	// ModelUnavailable asks the shell to register the generation again and
	// retry; nothing reached the model.
	ModelUnavailable bool         `json:"modelUnavailable,omitempty"`
	Reply            string       `json:"reply,omitempty"`
	ToolCalls        []toolCallV1 `json:"toolCalls"`
	Error            string       `json:"error,omitempty"`
}

// streamFn is replaced by tests with a deterministic provider.
var streamFn agent.StreamFn = ai.StreamSimple

// resolveModel is replaced by tests with a deterministic model.
var resolveModel = func(provider, model string) *ai.Model { return ai.GetBuiltinModel(provider, model) }

// CrashLogName is the file in the runtime root that receives the report of
// a fatal Go error. A goroutine panic aborts the whole app in a bound
// library, so the shell reads this file on the next launch to show it.
const CrashLogName = "agent-crash.log"

var crashOutput sync.Once

func captureCrashes(runtimeRoot string) {
	if runtimeRoot == "" {
		return
	}
	crashOutput.Do(func() {
		file, err := os.OpenFile(filepath.Join(runtimeRoot, CrashLogName), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			return
		}
		defer file.Close()
		_ = debug.SetCrashOutput(file, debug.CrashOptions{})
	})
}

// runningTurns maps a request's turnId to the cancel function of its turn.
var runningTurns sync.Map

// RunTurnJSON runs one user turn to completion and returns the final reply.
// The call blocks; the shell runs it off the main thread.
func RunTurnJSON(requestJSON string) string {
	// Swift calls in through a cgo callback, whose goroutine is locked to the calling thread. PiG drives its stream with iter.Pull coroutines, and the runtime aborts the process when a goroutine on another thread resumes a coroutine created on a locked one, so the turn runs on a goroutine of its own.
	done := make(chan string, 1)
	go func() { done <- runTurnJSON(requestJSON) }()
	return <-done
}

func runTurnJSON(requestJSON string) (responseJSON string) {
	defer func() {
		if recovered := recover(); recovered != nil {
			responseJSON = encode(turnResponseV1{Version: 1, ToolCalls: []toolCallV1{}, Error: fmt.Sprint(recovered)})
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), turnTimeout)
	defer cancel()
	reply, calls, err := runTurn(ctx, cancel, requestJSON)
	if errors.Is(ctx.Err(), context.Canceled) {
		return encode(turnResponseV1{Version: 1, Cancelled: true, ToolCalls: calls, Error: "cancelled"})
	}
	if err != nil {
		return encode(turnResponseV1{Version: 1, ToolCalls: calls, Error: err.Error(),
			ModelUnavailable: errors.Is(err, app.ErrLocalModelUnavailable)})
	}
	return encode(turnResponseV1{Version: 1, OK: true, Reply: reply, ToolCalls: calls})
}

// CancelTurn stops the running turn started with turnID. Unknown or finished
// turns are ignored.
func CancelTurn(turnID string) {
	if cancel, ok := runningTurns.LoadAndDelete(turnID); ok {
		cancel.(context.CancelFunc)()
	}
}

// catalogProviders are the PiG providers the settings screen offers, in order.
// Each authenticates with a plain API key, which the shell keeps in Keychain.
var catalogProviders = []struct{ ID, Title string }{
	{"anthropic", "Anthropic"},
	{"openai", "OpenAI"},
	{"google", "Google Gemini"},
	{"deepseek", "DeepSeek"},
	{"moonshotai", "Moonshot（Kimi）"},
	{"zai", "智谱 Z.ai"},
	{"openrouter", "OpenRouter"},
	// Lists no models: the shell asks for the protocol, base URL and model id.
	{customProvider, "自定义"},
}

// ModelCatalogJSON lists the chat models of each offered provider.
func ModelCatalogJSON() string {
	type modelV1 struct {
		ID    string `json:"id"`
		Title string `json:"title"`
	}
	type providerV1 struct {
		ID     string    `json:"id"`
		Title  string    `json:"title"`
		Models []modelV1 `json:"models"`
	}
	providers := make([]providerV1, 0, len(catalogProviders))
	for _, provider := range catalogProviders {
		models := []modelV1{}
		for _, model := range ai.GetBuiltinModels(provider.ID) {
			if model.Type == "" || model.Type == ai.ModelTypeChat {
				models = append(models, modelV1{ID: model.ID, Title: model.DisplayName})
			}
		}
		providers = append(providers, providerV1{ID: provider.ID, Title: provider.Title, Models: models})
	}
	return encode(map[string]any{"version": 1, "providers": providers})
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

func runTurn(ctx context.Context, cancel context.CancelFunc, requestJSON string) (string, []toolCallV1, error) {
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
	captureCrashes(request.RuntimeRoot)
	if request.TurnID != "" {
		if _, loaded := runningTurns.LoadOrStore(request.TurnID, cancel); loaded {
			return "", calls, errors.New("turnId is already running")
		}
		defer runningTurns.Delete(request.TurnID)
	}
	message := strings.TrimSpace(request.Message)
	if message == "" || len(message) > maxMessageBytes {
		return "", calls, errors.New("message is required and must be at most 12000 bytes")
	}
	var model *ai.Model
	var err error
	if request.Provider == customProvider {
		if model, err = customModel(request.Model, request.Custom); err != nil {
			return "", calls, err
		}
	} else if request.Custom != nil {
		return "", calls, errors.New("custom is only valid with provider custom")
	} else if model = resolveModel(request.Provider, request.Model); model == nil {
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
	var argumentsMu sync.Mutex
	arguments := map[string]json.RawMessage{}
	runner, err := agent.NewAgent(agent.AgentOptions{
		InitialState: &agent.AgentInitialState{Messages: history},
		Model:        model,
		Tools:        tools,
		SystemPrompt: app.LocalAgentSystemPrompt(),
		MaxTurns:     maxTurns,
		StreamFn:     streamFn,
		GetAPIKey:    func(string) (string, error) { return key, nil },
		// Defense in depth: the loop must never run a tool outside the catalog.
		BeforeToolCallHooks: []agent.BeforeToolCallHook{func(_ context.Context, id, name string, args json.RawMessage) agent.ToolCallHookResult {
			argumentsMu.Lock()
			arguments[id] = append(json.RawMessage(nil), args...)
			argumentsMu.Unlock()
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
			argumentsMu.Lock()
			calls = append(calls, toolCallV1{Name: result.ToolName, Arguments: arguments[result.ToolCallID], IsError: result.IsError})
			argumentsMu.Unlock()
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
