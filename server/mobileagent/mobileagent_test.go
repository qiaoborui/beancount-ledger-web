package mobileagent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

const testLedger = `option "operating_currency" "CNY"
2026-01-01 open Assets:Cash CNY
2026-01-01 open Expenses:Food CNY
2026-01-05 * "午饭"
  Expenses:Food  25.00 CNY
  Assets:Cash   -25.00 CNY
`

func committedWorkspace(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "generations", "initial", "workspace")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "main.bean"), []byte(testLedger), 0o600); err != nil {
		t.Fatal(err)
	}
	return root
}

// useFaux scripts the provider and restores the real stream afterwards.
func useFaux(t *testing.T, steps ...ai.FauxResponseStep) *ai.FauxProviderHandle {
	t.Helper()
	provider := ai.NewFauxProvider(ai.FauxConfig{})
	provider.SetResponses(steps)
	model := &ai.Model{ID: "faux-1", Provider: provider, ProviderMeta: ai.ProviderMetadata{API: "faux", ProviderID: "faux"}}
	previousStream, previousResolve := streamFn, resolveModel
	streamFn = func(ctx context.Context, model *ai.Model, transcript ai.TranscriptContext, options ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
		return model.Provider.Stream(ctx, transcript, options)
	}
	resolveModel = func(string, string) *ai.Model { return model }
	t.Cleanup(func() { streamFn, resolveModel = previousStream, previousResolve })
	return provider
}

func runTurnFor(t *testing.T, request map[string]any) turnResponseV1 {
	t.Helper()
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var response turnResponseV1
	if err := json.Unmarshal([]byte(RunTurnJSON(string(raw))), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestRunTurnCallsLedgerToolsAndReturnsReply(t *testing.T) {
	var seenToolOutput string
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("get_accounts", map[string]any{"activeOnly": true}, &ai.FauxToolCallOptions{ID: "call_accounts"}),
		}}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			seenToolOutput = lastToolResultText(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("你有 2 个启用账户。")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "apiKey": "test", "message": "我有哪些账户？"})
	if !response.OK || response.Reply != "你有 2 个启用账户。" {
		t.Fatalf("unexpected response: %+v", response)
	}
	if len(response.ToolCalls) != 1 || response.ToolCalls[0].Name != "get_accounts" || response.ToolCalls[0].IsError {
		t.Fatalf("unexpected tool calls: %+v", response.ToolCalls)
	}
	if string(response.ToolCalls[0].Arguments) != `{"activeOnly":true}` {
		t.Fatalf("tool call arguments = %s", response.ToolCalls[0].Arguments)
	}
	if !strings.Contains(seenToolOutput, "Expenses:Food") {
		t.Fatalf("model did not receive ledger accounts: %s", seenToolOutput)
	}
}

func TestRunTurnRejectsToolsOutsideTheCatalog(t *testing.T) {
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("append_transactions", map[string]any{"entries": []any{}}, &ai.FauxToolCallOptions{ID: "call_write"}),
		}}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("暂不支持写入。")}}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "帮我记一笔"})
	if !response.OK || len(response.ToolCalls) != 1 || !response.ToolCalls[0].IsError {
		t.Fatalf("write tool was not rejected: %+v", response)
	}
}

func TestRunTurnRejectsStagingAndEndpointFields(t *testing.T) {
	root := committedWorkspace(t)
	for _, extra := range []map[string]any{{"staging": true}, {"path": "/api/ledger/bootstrap"}, {"host": "https://example.com"}} {
		request := map[string]any{"version": 1, "workspaceRoot": root, "provider": "faux", "model": "faux-1", "message": "hi"}
		for key, value := range extra {
			request[key] = value
		}
		useFaux(t)
		if response := runTurnFor(t, request); response.OK || response.Error == "" {
			t.Fatalf("request %v accepted: %+v", extra, response)
		}
	}
}

func TestCancelTurnStopsARunningTurn(t *testing.T) {
	useFaux(t)
	started := make(chan struct{})
	// The model call blocks until the turn's context ends, like a slow provider.
	streamFn = func(ctx context.Context, _ *ai.Model, _ ai.TranscriptContext, _ ai.StreamOptions) (*ai.AssistantMessageEventStream, error) {
		close(started)
		<-ctx.Done()
		return nil, ctx.Err()
	}
	done := make(chan turnResponseV1)
	go func() {
		done <- runTurnFor(t, map[string]any{"version": 1, "turnId": "turn-1", "workspaceRoot": committedWorkspace(t),
			"provider": "faux", "model": "faux-1", "message": "这个月花了多少"})
	}()
	<-started
	CancelTurn("turn-1")
	response := <-done
	if response.OK || !response.Cancelled {
		t.Fatalf("turn was not cancelled: %+v", response)
	}
}

func TestToolCatalogIsReadOnly(t *testing.T) {
	var catalog struct {
		Tools []struct{ Name string } `json:"tools"`
	}
	if err := json.Unmarshal([]byte(ToolCatalogJSON()), &catalog); err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, tool := range catalog.Tools {
		names = append(names, tool.Name)
	}
	if got := strings.Join(names, ","); got != "get_bql_capabilities,validate_bql,run_bql,search_transactions,get_ledger_summary,get_accounts" {
		t.Fatalf("catalog = %s", got)
	}
}

func lastToolResultText(request ai.TranscriptContext) string {
	messages := request.Messages()
	for index := len(messages) - 1; index >= 0; index-- {
		if result, ok := messages[index].(ai.ToolResultMessage); ok {
			var text strings.Builder
			for _, block := range result.Content {
				if value, ok := block.(ai.TextContent); ok {
					text.WriteString(value.Text)
				}
			}
			return text.String()
		}
	}
	return ""
}

var _ agent.StreamFn = streamFn

func TestReadToolsRunAgainstTheCommittedGeneration(t *testing.T) {
	calls := []ai.FauxContentBlock{
		ai.FauxToolCall("get_ledger_summary", map[string]any{"start": "2026-01-01", "end": "2026-01-31"}, &ai.FauxToolCallOptions{ID: "call_summary"}),
		ai.FauxToolCall("search_transactions", map[string]any{"query": "午饭"}, &ai.FauxToolCallOptions{ID: "call_search"}),
		ai.FauxToolCall("run_bql", map[string]any{"query": "SELECT account, sum(value) AS total FROM postings WHERE account LIKE 'Expenses:%' GROUP BY account"}, &ai.FauxToolCallOptions{ID: "call_bql"}),
	}
	var outputs []string
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: calls}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			for _, message := range request.Messages() {
				if result, ok := message.(ai.ToolResultMessage); ok {
					for _, block := range result.Content {
						if value, ok := block.(ai.TextContent); ok {
							outputs = append(outputs, result.ToolName+": "+value.Text)
						}
					}
				}
			}
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("一月餐饮 25 元。")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t), "sensitiveUnlocked": true,
		"provider": "faux", "model": "faux-1", "message": "一月吃饭花了多少？"})
	if !response.OK || len(response.ToolCalls) != 3 {
		t.Fatalf("unexpected response: %+v", response)
	}
	for _, call := range response.ToolCalls {
		if call.IsError {
			t.Fatalf("tool %s failed: %v", call.Name, outputs)
		}
	}
	joined := strings.Join(outputs, "\n")
	if !strings.Contains(joined, "25") || !strings.Contains(joined, `"file":"main.bean"`) || strings.Contains(joined, "generations") {
		t.Fatalf("tool outputs miss the amount or expose the container path: %s", joined)
	}
}

func TestModelCatalogOffersKeyProviders(t *testing.T) {
	var catalog struct {
		Providers []struct {
			ID     string
			Models []struct{ ID string }
		}
	}
	if err := json.Unmarshal([]byte(ModelCatalogJSON()), &catalog); err != nil {
		t.Fatal(err)
	}
	if len(catalog.Providers) != len(catalogProviders) || catalog.Providers[0].ID != "anthropic" {
		t.Fatalf("providers = %+v", catalog.Providers)
	}
	for _, provider := range catalog.Providers {
		if len(provider.Models) == 0 {
			t.Fatalf("provider %s lists no models", provider.ID)
		}
		if resolveModel(provider.ID, provider.Models[0].ID) == nil {
			t.Fatalf("%s/%s does not resolve", provider.ID, provider.Models[0].ID)
		}
	}
}

func TestRunTurnReportsAnUnavailableModelHandle(t *testing.T) {
	useFaux(t)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t), "modelHandle": "gone",
		"provider": "faux", "model": "faux-1", "message": "hi"})
	if response.OK || !response.ModelUnavailable {
		t.Fatalf("stale handle not reported: %+v", response)
	}
}
