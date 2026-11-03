package mobileagent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/MichaelKinsy/PiG/ai"
)

// transcriptText is everything a request carries, as JSON, for asserting
// that some text reached the model.
func transcriptText(t *testing.T, request ai.TranscriptContext) string {
	t.Helper()
	raw, err := json.Marshal(request.Messages())
	if err != nil {
		t.Fatal(err)
	}
	var decoded any
	_ = json.Unmarshal(raw, &decoded)
	var out strings.Builder
	var walk func(any)
	walk = func(value any) {
		switch value := value.(type) {
		case string:
			out.WriteString(value + "\n")
		case []any:
			for _, item := range value {
				walk(item)
			}
		case map[string]any:
			for _, item := range value {
				walk(item)
			}
		}
	}
	walk(decoded)
	return out.String()
}

func TestMemoryIsInThePromptAndToolsRewriteIt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runtime", "agent-memory.md")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("## 账户与分类\n- 星巴克记 Expenses:Food:Coffee\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var firstRequest string
	var tools []string
	useFaux(t,
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			firstRequest = transcriptText(t, request)
			tools = offeredTools(request)
			return ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
				ai.FauxToolCall("edit_memory", map[string]any{"old_string": "", "new_string": "- 美团外卖记 Expenses:Food:Delivery"}, &ai.FauxToolCallOptions{ID: "m1"}),
			}}.AssistantMessage(), nil
		}),
		toolStep("edit_memory", map[string]any{"old_string": "Expenses:Food:Coffee", "new_string": "Expenses:Food:Cafe"}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("记住了。")}, StopReason: "stop"}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "apiKey": "test", "memoryPath": path, "message": "以后美团外卖都记外卖"})
	if !response.OK || !response.MemoryUpdated {
		t.Fatalf("unexpected response: %+v", response)
	}
	if !strings.Contains(firstRequest, "星巴克记 Expenses:Food:Coffee") || !strings.Contains(firstRequest, "记忆（memory.md）") {
		t.Fatalf("memory did not reach the prompt:\n%s", firstRequest)
	}
	if !slices.Contains(tools, "edit_memory") || !slices.Contains(tools, "write_memory") {
		t.Fatalf("memory tools not offered: %v", tools)
	}
	saved, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := "## 账户与分类\n- 星巴克记 Expenses:Food:Cafe\n- 美团外卖记 Expenses:Food:Delivery\n"
	if string(saved) != want {
		t.Fatalf("memory = %q, want %q", saved, want)
	}
}

func TestMemoryRefusesSecretsAndOversizedContent(t *testing.T) {
	memory, err := openMemory(filepath.Join(t.TempDir(), "memory.md"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := memory.edit(json.RawMessage(`{"old_string":"","new_string":"- 招行卡号 6225 8812 3456 7890"}`)); err == nil {
		t.Fatal("a card number was remembered")
	}
	if _, err := memory.write(json.RawMessage(`{"content":"` + strings.Repeat("长", maxMemoryBytes) + `"}`)); err == nil {
		t.Fatal("oversized memory was written")
	}
	if memory.wasUpdated() {
		t.Fatal("a refused write marked the memory updated")
	}
	if _, err := memory.edit(json.RawMessage(`{"old_string":"不存在","new_string":"x"}`)); err == nil {
		t.Fatal("a missing old_string was accepted")
	}
}

func TestTurnWithoutMemoryPathOffersNoMemoryTools(t *testing.T) {
	var tools []string
	var prompt string
	useFaux(t, ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		tools, prompt = offeredTools(request), transcriptText(t, request)
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好")}, StopReason: "stop"}.AssistantMessage(), nil
	}))
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "apiKey": "test", "message": "hi"})
	if !response.OK || response.MemoryUpdated || slices.Contains(tools, "edit_memory") || strings.Contains(prompt, "memory.md") {
		t.Fatalf("memory leaked into a turn without it: %+v %v", response, tools)
	}
}
