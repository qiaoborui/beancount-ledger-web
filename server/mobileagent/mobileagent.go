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
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

const (
	maxTurns        = 20
	maxEditTurns    = 40
	maxMessageBytes = 12000
	// turnTimeout is the hard bound of a whole turn. Stalls are caught much
	// sooner by the network budgets in transport.go; this only stops a
	// model that keeps working without converging.
	turnTimeout = 10 * time.Minute
	// bonusTurns are what a turn gets after its tool budget is spent, to
	// answer from what it already read.
	bonusTurns = 2
)

// Prompts the loop adds on its own when a turn ends without an answer.
const (
	nudgeEmptyReply = "（系统提示：上一条回复没有任何文字。请直接用中文回答用户的问题；需要的数据已经在上面的工具结果里。）"
	nudgeToolBudget = "（系统提示：这一轮的工具调用次数已经用完，不能再调用工具。请根据已经取得的结果直接用中文回答；没查完的部分说明还缺什么。）"
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
	// Thinking is the reasoning effort: off, minimal, low, medium, high,
	// xhigh or max. It is clamped to the nearest level the model supports;
	// empty means off.
	Thinking string `json:"thinking,omitempty"`
	// ScratchRoot, when set, is a private copy of the ledger the turn may
	// edit with file tools. The shell diffs it against the committed
	// generation and writes the change only after the user confirms.
	ScratchRoot string `json:"scratchRoot,omitempty"`
	// History is the prior visible conversation without tool calls, for a
	// conversation that has no transcript yet (one saved by an older build).
	History []historyMessageV1 `json:"history"`
	// Transcript is the transcript the previous turn of this conversation
	// returned, sent back unchanged; it replaces History when present.
	Transcript string `json:"transcript,omitempty"`
	// ConversationID keys the provider's prompt cache to the conversation.
	ConversationID string `json:"conversationId,omitempty"`
	// Attachments are the files of the conversation, each copied into the
	// runtime directory by the shell; those sent with this question are new.
	Attachments []attachmentV1 `json:"attachments,omitempty"`
	// MemoryPath is the ledger's memory.md, which the system prompt carries
	// and the memory tools rewrite; empty turns memory off.
	MemoryPath string `json:"memoryPath,omitempty"`
	// StreamEvents asks the observer for the streaming event kinds besides
	// "model" and "tool"; see turnEventV1.
	StreamEvents bool   `json:"streamEvents,omitempty"`
	Message      string `json:"message"`
}

type customEndpointV1 struct {
	API     string `json:"api"`
	BaseURL string `json:"baseURL"`
}

// thinkingLevels are the efforts a request may name, from least to most.
var thinkingLevels = []ai.ModelThinkingLevel{ai.ThinkingOff, ai.ThinkingMinimal, ai.ThinkingLow,
	ai.ThinkingMedium, ai.ThinkingHigh, ai.ThinkingXHigh, ai.ThinkingMax}

// thinkingLevel resolves the requested effort for model. For an assumed
// model nothing says whether it reasons, so asking for a level marks it as
// a reasoning model; levels it does not know are left to the server.
func thinkingLevel(model *ai.Model, requested string, assumed bool) (ai.ModelThinkingLevel, error) {
	level := ai.ModelThinkingLevel(requested)
	if level == "" {
		level = ai.ThinkingOff
	}
	if !slices.Contains(thinkingLevels, level) {
		return "", fmt.Errorf("unknown thinking level %q", requested)
	}
	if assumed && level != ai.ThinkingOff {
		model.ProviderMeta.Reasoning = true
	}
	return ai.ClampThinkingLevel(model, level), nil
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
	CallID    string          `json:"callId,omitempty"`
	// DurationMs is how long the tool ran; absent when it did not.
	DurationMs int64  `json:"durationMs,omitempty"`
	Preview    string `json:"preview,omitempty"`
	ErrorText  string `json:"errorText,omitempty"`
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
	// Edited reports that a file tool changed the scratch copy this turn.
	Edited bool `json:"edited,omitempty"`
	// MemoryUpdated reports that the turn rewrote memory.md.
	MemoryUpdated bool   `json:"memoryUpdated,omitempty"`
	Error         string `json:"error,omitempty"`
	// Transcript is everything the model saw and said, tool calls, results
	// and reasoning included, for the shell to send with the next question.
	// Only an answered turn returns one; after a failure the shell keeps the
	// previous transcript.
	Transcript string `json:"transcript,omitempty"`
	// Ask is a question the model put to the user with ask_user, to show as
	// a card of choices; the reply then repeats its question.
	Ask *askV1 `json:"ask,omitempty"`
	// Steps are the reasoning, text and tool calls of this turn, in order.
	Steps []stepV1 `json:"steps,omitempty"`
	// Usage is the turn's tokens; absent when no model message ended.
	Usage *usageV1 `json:"usage,omitempty"`
	// Compacted and CompactedTurns are reserved for a turn that summarized
	// older turns of its transcript; nothing sets them yet.
	Compacted      bool `json:"compacted,omitempty"`
	CompactedTurns int  `json:"compactedTurns,omitempty"`
}

// turnOutcome is what a turn hands back, also when it failed or was stopped
// part way.
type turnOutcome struct {
	reply, transcript  string
	calls              []toolCallV1
	steps              []stepV1
	usage              *usageV1
	edited, remembered bool
	ask                *askV1
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

// earlyCancels holds turnIds that were cancelled before their turn started,
// with the time of the cancel. The shell cancels from a task-cancellation
// handler that can fire before the native call registers its turn; without
// this the stopped turn would run to the end unseen.
var earlyCancels sync.Map

const earlyCancelTTL = 10 * time.Minute

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
	network := newTurnHTTP()
	defer network.close()
	out, err := runTurn(ctx, cancel, network, requestJSON)
	// A failed or cancelled turn may still have edited the scratch copy or
	// the memory.
	if errors.Is(ctx.Err(), context.Canceled) {
		return encode(turnResponseV1{Version: 1, Cancelled: true, ToolCalls: out.calls, Steps: out.steps, Usage: out.usage,
			Edited: out.edited, MemoryUpdated: out.remembered, Error: "cancelled"})
	}
	if err != nil {
		return encode(turnResponseV1{Version: 1, ToolCalls: out.calls, Steps: out.steps, Usage: out.usage, Edited: out.edited,
			MemoryUpdated: out.remembered, Error: turnErrorText(ctx, network, err), ModelUnavailable: errors.Is(err, app.ErrLocalModelUnavailable)})
	}
	return encode(turnResponseV1{Version: 1, OK: true, Reply: out.reply, ToolCalls: out.calls, Steps: out.steps, Usage: out.usage,
		Edited: out.edited, MemoryUpdated: out.remembered, Transcript: out.transcript, Ask: out.ask})
}

// turnErrorText says why a turn failed in words the user can act on; the
// provider's own message follows when there is one.
func turnErrorText(ctx context.Context, network *turnHTTP, err error) string {
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return fmt.Sprintf("这一轮超过 %d 分钟还没有答完，已经停止。可以把问题拆小一点再问。", int(turnTimeout/time.Minute))
	case network.stalled.Load():
		return fmt.Sprintf("模型服务 %d 秒没有任何响应，连接已断开（网络切换或服务繁忙时常见）。点重试即可。（%s）",
			int(streamIdleTimeout/time.Second), err.Error())
	case errors.Is(err, agent.ErrMaxTurnsReached) || strings.Contains(err.Error(), agent.ErrMaxTurnsReached.Error()):
		return "这一轮调用工具的次数太多，仍然没有得到答案。可以把问题说得更具体一些再试。"
	}
	return err.Error()
}

// CancelTurn stops the running turn started with turnID. A turn that has not
// started yet is stopped as soon as it does; finished turns are ignored.
func CancelTurn(turnID string) {
	if turnID == "" {
		return
	}
	if cancel, ok := runningTurns.LoadAndDelete(turnID); ok {
		cancel.(context.CancelFunc)()
		return
	}
	now := time.Now()
	earlyCancels.Store(turnID, now)
	earlyCancels.Range(func(key, value any) bool {
		if now.Sub(value.(time.Time)) > earlyCancelTTL {
			earlyCancels.Delete(key)
		}
		return true
	})
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
		// ThinkingLevels are the reasoning efforts the model accepts, from
		// least to most; ["off"] for a model without reasoning.
		ThinkingLevels []ai.ModelThinkingLevel `json:"thinkingLevels"`
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
				models = append(models, modelV1{ID: model.ID, Title: model.DisplayName, ThinkingLevels: ai.GetSupportedThinkingLevels(model)})
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

func runTurn(ctx context.Context, cancel context.CancelFunc, network *turnHTTP, requestJSON string) (turnOutcome, error) {
	out := turnOutcome{calls: []toolCallV1{}}
	var memory *memoryFile
	scratch, err := runTurnIn(ctx, cancel, network, requestJSON, &memory, &out)
	if scratch != nil {
		out.edited = scratch.wasEdited()
		scratch.close()
	}
	out.remembered = memory != nil && memory.wasUpdated()
	return out, err
}

// runTurnIn runs the turn into out; memory receives the turn's memory file as
// soon as it is open, so a failed turn still reports a memory it changed.
func runTurnIn(ctx context.Context, cancel context.CancelFunc, network *turnHTTP, requestJSON string, memory **memoryFile, out *turnOutcome) (*scratch, error) {
	var files *scratch
	decoder := json.NewDecoder(strings.NewReader(requestJSON))
	decoder.DisallowUnknownFields()
	var request turnRequestV1
	if err := decoder.Decode(&request); err != nil {
		return files, fmt.Errorf("invalid Agent request: %w", err)
	}
	if request.Version != 1 {
		return files, errors.New("supported Agent request version is 1")
	}
	captureCrashes(request.RuntimeRoot)
	if request.TurnID != "" {
		if _, loaded := runningTurns.LoadOrStore(request.TurnID, cancel); loaded {
			return files, errors.New("turnId is already running")
		}
		defer runningTurns.Delete(request.TurnID)
		if _, cancelled := earlyCancels.LoadAndDelete(request.TurnID); cancelled {
			cancel()
			return files, context.Canceled
		}
	}
	feed := openEventFeed(request.TurnID, request.StreamEvents)
	defer feed.close()
	message := strings.TrimSpace(request.Message)
	if message == "" || len(message) > maxMessageBytes {
		return files, errors.New("message is required and must be at most 12000 bytes")
	}
	model, assumed, err := requestModel(request.Provider, request.Model, request.Custom)
	if err != nil {
		return files, err
	}
	thinking, err := thinkingLevel(model, request.Thinking, assumed)
	if err != nil {
		return files, err
	}
	session, err := app.OpenLocalAgentSession(request.LocalRequest, request.SensitiveUnlocked)
	if err != nil {
		return files, err
	}
	specs := app.LocalAgentToolSpecs()
	tools := make([]agent.AgentTool, 0, len(specs)+14)
	allowed := make(map[string]bool, len(specs)+12)
	for _, spec := range specs {
		tools = append(tools, ledgerTool{spec: spec, session: session})
		allowed[spec.Name] = true
	}
	// ask_user is always offered: a question needs no ledger access.
	asking := &askTool{}
	tools = append(tools, asking)
	allowed[asking.Name()] = true
	turns := maxTurns
	if request.ScratchRoot != "" {
		if files, err = editableScratch(request); err != nil {
			return nil, err
		}
		for _, tool := range files.tools() {
			tools = append(tools, tool)
			allowed[tool.Name()] = true
		}
		turns = maxEditTurns
	}
	attached, err := openAttachments(request.Attachments, request.RuntimeRoot, supportsImages(model) && !assumed)
	if err != nil {
		return files, err
	}
	systemPrompt := app.LocalAgentSystemPrompt(files != nil)
	var remembered *memoryFile
	if request.MemoryPath != "" {
		if remembered, err = openMemory(request.MemoryPath); err != nil {
			return files, err
		}
		*memory = remembered
		for _, tool := range remembered.tools() {
			tools = append(tools, tool)
			allowed[tool.Name()] = true
		}
	}
	if attached != nil {
		for _, tool := range attached.tools(session) {
			tools = append(tools, tool)
			allowed[tool.Name()] = true
		}
		if files != nil {
			tool := attached.saveTool(files)
			tools = append(tools, tool)
			allowed[tool.Name()] = true
		}
		systemPrompt += attachmentPrompt
		message = withAttachmentNote(attached, message)
	}
	if history := openHistory(request.RuntimeRoot, request.ConversationID); history != nil {
		for _, tool := range history.tools() {
			tools = append(tools, tool)
			allowed[tool.Name()] = true
		}
		systemPrompt += savedHistoryPrompt
	}
	if remembered != nil {
		// Last, so the rules and tools before it stay one cacheable prefix.
		systemPrompt += remembered.prompt()
	}
	history, err := priorMessages(request, systemPrompt)
	if err != nil {
		return files, err
	}
	key := request.APIKey
	var argumentsMu sync.Mutex
	arguments := map[string]json.RawMessage{}
	// toolsSpent is set when the turn ran out of model calls: tools are then
	// refused and the model answers from what it has.
	var toolsSpent atomic.Bool
	var bonusCalls atomic.Int32
	record := newTurnRecord(feed, model.Capabilities.ContextWindow)
	defer func() { out.steps, out.usage = record.result() }()
	runner, err := agent.NewAgent(agent.AgentOptions{
		InitialState:  &agent.AgentInitialState{Messages: history},
		Model:         model,
		Tools:         tools,
		SystemPrompt:  systemPrompt,
		MaxTurns:      turns,
		ThinkingLevel: thinking,
		StreamFn: func(ctx context.Context, model *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
			if toolsSpent.Load() && bonusCalls.Add(1) > bonusTurns {
				return nil, agent.ErrMaxTurnsReached
			}
			feed.send(turnEventV1{Kind: "model"})
			if options.Fetch == nil {
				options.Fetch = network.client
			}
			delay := providerMaxRetryDelayMs
			return streamFn(ai.WithProviderRequestRetry(ctx, providerRetries, &delay), model, transcript, options)
		},
		GetAPIKey: func(string) (string, error) { return key, nil },
		// Defense in depth: the loop must never run a tool outside the catalog.
		BeforeToolCallHooks: []agent.BeforeToolCallHook{func(_ context.Context, id, name string, args json.RawMessage) agent.ToolCallHookResult {
			argumentsMu.Lock()
			arguments[id] = append(json.RawMessage(nil), args...)
			argumentsMu.Unlock()
			if !allowed[name] {
				return agent.ToolCallHookResult{Block: true, Reason: "tool is not available on this device"}
			}
			if toolsSpent.Load() {
				return agent.ToolCallHookResult{Block: true, Reason: "这一轮的工具调用次数已用完，请直接回答"}
			}
			feed.send(turnEventV1{Kind: "tool", Name: name, Arguments: append(json.RawMessage(nil), args...)})
			record.startTool(id, name, args)
			return agent.ToolCallHookResult{}
		}},
	})
	if err != nil {
		return files, err
	}
	if request.ConversationID != "" {
		runner.SetSessionID(request.ConversationID)
	}
	unsubscribe := runner.Subscribe(record.observe)
	defer unsubscribe()
	// A run returns the whole transcript, which starts with the one the turn
	// was given; this turn's calls are the results after those.
	priorResults := 0
	for _, message := range history {
		if message.ToolResult != nil {
			priorResults++
		}
	}
	seenResults := 0
	collect := func(produced []agent.AgentMessage) {
		argumentsMu.Lock()
		defer argumentsMu.Unlock()
		results := 0
		for _, produced := range produced {
			result := produced.ToolResult
			if result == nil {
				continue
			}
			results++
			if results <= priorResults || results <= seenResults {
				continue
			}
			seenResults = results
			call := toolCallV1{Name: result.ToolName, Arguments: arguments[result.ToolCallID], IsError: result.IsError,
				CallID: result.ToolCallID, DurationMs: record.toolDuration(result.ToolCallID)}
			text := toolResultText(result.Content)
			call.Preview = firstRunes(text, previewRunes)
			if result.IsError {
				call.ErrorText = firstRunes(strings.TrimSpace(text), errorRunes)
			}
			out.calls = append(out.calls, call)
		}
	}
	produced, err := runner.Send(ctx, message)
	collect(produced)
	// A turn that spent its tool budget, or ended without a word, gets one
	// more request asking for the answer, instead of leaving the user with
	// an error or an empty reply.
	nudge := ""
	if errors.Is(err, agent.ErrMaxTurnsReached) && ctx.Err() == nil {
		toolsSpent.Store(true)
		nudge = nudgeToolBudget
	} else if err == nil && needsAnswer(produced) && !endsOnAsk(produced) {
		nudge = nudgeEmptyReply
	}
	if nudge != "" {
		produced, err = runner.Send(ctx, nudge)
		collect(produced)
	}
	if err != nil {
		return files, err
	}
	ask := asking.question()
	messages := runner.Messages()
	var reply string
	if ask != nil && endsOnAsk(messages) {
		// The turn ended on the question: it is the reply.
		reply = ask.Question
		messages = closeAsk(messages, ask)
	} else if reply, err = finalReply(produced); err != nil {
		return files, err
	}
	out.reply, out.ask = reply, ask
	// The whole transcript goes back to the shell, which sends it with the
	// next question unchanged: the provider then sees the same prefix every
	// turn and serves it from its prompt cache.
	if transcript, err := encodeTranscript(messages); err == nil {
		out.transcript = transcript
	}
	return files, nil
}

// lastAssistant is the final model message of a run, if any.
func lastAssistant(produced []agent.AgentMessage) *agent.AssistantMessage {
	for index := len(produced) - 1; index >= 0; index-- {
		if assistant := produced[index].Assistant; assistant != nil {
			return assistant
		}
	}
	return nil
}

// needsAnswer reports a run that finished cleanly without any text for the
// user, as reasoning models sometimes do after a tool call.
func needsAnswer(produced []agent.AgentMessage) bool {
	assistant := lastAssistant(produced)
	return assistant != nil && assistant.ErrorMessage == "" && assistant.StopReason != ai.StopReasonLength &&
		strings.TrimSpace(assistantText(assistant.Content)) == ""
}

func finalReply(produced []agent.AgentMessage) (string, error) {
	assistant := lastAssistant(produced)
	if assistant == nil {
		return "", errors.New("模型没有返回回答")
	}
	if assistant.ErrorMessage != "" {
		return "", errors.New(assistant.ErrorMessage)
	}
	text := strings.TrimSpace(assistantText(assistant.Content))
	switch {
	case text != "" && assistant.StopReason == ai.StopReasonLength:
		return text + "\n\n（回答达到模型的输出长度上限，后面被截断了。）", nil
	case text != "":
		return text, nil
	case assistant.StopReason == ai.StopReasonLength:
		return "", errors.New("模型的输出达到长度上限，没有留下回答（思考强度较高时常见）。可以调低思考强度再试。")
	default:
		return "", errors.New("模型这次没有给出文字回答，点重试再问一次。")
	}
}

// requestModel resolves the model a request names. assumed is set for a
// model whose abilities nobody describes: a custom endpoint, or one the
// provider listed but the catalog does not know.
func requestModel(provider, id string, custom *customEndpointV1) (*ai.Model, bool, error) {
	if provider == customProvider {
		model, err := customModel(id, custom)
		return model, true, err
	}
	if custom != nil {
		return nil, false, errors.New("custom is only valid with provider custom")
	}
	if model := resolveModel(provider, id); model != nil {
		return model, false, nil
	}
	if model := listedModel(provider, id); model != nil {
		return model, true, nil
	}
	return nil, false, fmt.Errorf("unknown model %s/%s", provider, id)
}

// editableScratch opens the scratch copy named by request. It must be an
// absolute directory distinct from the committed generation the read tools
// use, so an edit can never reach published ledger files.
func editableScratch(request turnRequestV1) (*scratch, error) {
	dir := filepath.Clean(request.ScratchRoot)
	if !filepath.IsAbs(dir) {
		return nil, errors.New("scratchRoot must be absolute")
	}
	if committed, err := filepath.EvalSymlinks(request.WorkspaceRoot); err == nil {
		if resolved, err := filepath.EvalSymlinks(dir); err == nil && resolved == committed {
			return nil, errors.New("scratchRoot must not be the committed generation")
		}
	}
	entrypoint := request.Entrypoint
	if entrypoint == "" {
		entrypoint = "main.bean"
	}
	files, err := openScratch(dir, entrypoint)
	if err != nil {
		return nil, err
	}
	files.committed = request.WorkspaceRoot
	return files, nil
}

// priorMessages is what the turn starts from: the transcript the previous
// turn returned, trimmed when it outgrew its budget, or for a conversation
// without one, its visible history.
func priorMessages(request turnRequestV1, systemPrompt string) ([]agent.AgentMessage, error) {
	if strings.TrimSpace(request.Transcript) != "" {
		if messages, err := decodeTranscript(request.Transcript); err == nil {
			return withSystemPrompt(trimTranscript(messages, transcriptBudget), systemPrompt), nil
		}
		// An unreadable transcript (another build's format) costs the
		// conversation its tool results, not the turn.
	}
	return historyMessages(request.History)
}

// historyMessages replays the visible conversation. Providers reject empty
// turns and some reject two turns of one role in a row, so empty entries are
// dropped and neighbours of one role are joined.
func historyMessages(history []historyMessageV1) ([]agent.AgentMessage, error) {
	type turn struct{ role, content string }
	var turns []turn
	for _, entry := range history {
		if entry.Role != "user" && entry.Role != "assistant" {
			return nil, fmt.Errorf("unsupported history role %q", entry.Role)
		}
		content := strings.TrimSpace(entry.Content)
		if content == "" {
			continue
		}
		if last := len(turns) - 1; last >= 0 && turns[last].role == entry.Role {
			turns[last].content += "\n\n" + content
			continue
		}
		turns = append(turns, turn{entry.Role, content})
	}
	// The new question follows, so the replay must not end on a question.
	if last := len(turns) - 1; last >= 0 && turns[last].role == "user" {
		turns = turns[:last]
	}
	messages := make([]agent.AgentMessage, 0, len(turns))
	timestamp := time.Now().UnixMilli()
	for _, entry := range turns {
		switch entry.role {
		case "user":
			messages = append(messages, agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(entry.content), Timestamp: timestamp}})
		case "assistant":
			messages = append(messages, agent.AgentMessage{Assistant: &agent.AssistantMessage{Role: "assistant",
				Content: []ai.AssistantContentBlock{ai.TextContent{Text: entry.content}}, StopReason: ai.StopReasonStop, Timestamp: timestamp}})
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
