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
	// An older shell names the single memory.md; it moves into the folder.
	path := filepath.Join(t.TempDir(), "runtime", "agent-memory.md")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("## 账户与分类\n- 星巴克记 Expenses:Food:Coffee\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	folder := strings.TrimSuffix(path, ".md")
	if err := os.MkdirAll(filepath.Join(folder, "accounts"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, "accounts", "credit-cards.md"),
		[]byte("---\ndescription: 信用卡账单日和还款账户\n---\n\n- 招行信用卡 5 号出账\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var firstRequest, readResult string
	var tools []string
	useFaux(t,
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			firstRequest = transcriptText(t, request)
			tools = offeredTools(request)
			return ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
				ai.FauxToolCall("read_memory", map[string]any{"path": "accounts/credit-cards"}, &ai.FauxToolCallOptions{ID: "r1"}),
			}}.AssistantMessage(), nil
		}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			readResult = transcriptText(t, request)
			return ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
				ai.FauxToolCall("edit_memory", map[string]any{"path": "merchants", "old_string": "", "new_string": "- 美团外卖记 Expenses:Food:Delivery",
					"description": "商户该记到哪个账户"}, &ai.FauxToolCallOptions{ID: "m1"}),
			}}.AssistantMessage(), nil
		}),
		toolStep("edit_memory", map[string]any{"path": "MEMORY.md", "old_string": "Expenses:Food:Coffee", "new_string": "Expenses:Food:Cafe", "description": ""}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("记住了。")}, StopReason: "stop"}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "apiKey": "test", "memoryPath": path, "message": "以后美团外卖都记外卖"})
	if !response.OK || !response.MemoryUpdated {
		t.Fatalf("unexpected response: %+v", response)
	}
	for _, want := range []string{"星巴克记 Expenses:Food:Coffee", "MEMORY.md 是入口", "accounts/credit-cards.md — 信用卡账单日和还款账户"} {
		if !strings.Contains(firstRequest, want) {
			t.Fatalf("%q did not reach the prompt:\n%s", want, firstRequest)
		}
	}
	if strings.Contains(firstRequest, "招行信用卡 5 号出账") {
		t.Fatal("a topic file was put in the prompt instead of being read on demand")
	}
	if !strings.Contains(readResult, "招行信用卡 5 号出账") {
		t.Fatal("read_memory did not return the topic file")
	}
	for _, name := range []string{"read_memory", "edit_memory", "write_memory"} {
		if !slices.Contains(tools, name) {
			t.Fatalf("%s not offered: %v", name, tools)
		}
	}
	saved, err := os.ReadFile(filepath.Join(folder, "MEMORY.md"))
	if err != nil {
		t.Fatal(err)
	}
	if want := "## 账户与分类\n- 星巴克记 Expenses:Food:Cafe\n"; string(saved) != want {
		t.Fatalf("MEMORY.md = %q, want %q", saved, want)
	}
	merchants, err := os.ReadFile(filepath.Join(folder, "merchants.md"))
	if err != nil {
		t.Fatal(err)
	}
	if want := "---\ndescription: 商户该记到哪个账户\n---\n\n- 美团外卖记 Expenses:Food:Delivery\n"; string(merchants) != want {
		t.Fatalf("merchants.md = %q, want %q", merchants, want)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("the legacy memory.md is still there")
	}
}

func TestMemoryRefusesSecretsAndOversizedContent(t *testing.T) {
	memory, err := openMemory(filepath.Join(t.TempDir(), "agent-memory"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := memory.edit(json.RawMessage(`{"old_string":"","new_string":"- 招行卡号 6225 8812 3456 7890"}`)); err == nil {
		t.Fatal("a card number was remembered")
	}
	if _, err := memory.write(json.RawMessage(`{"content":"` + strings.Repeat("长", maxMemoryBytes) + `"}`)); err == nil {
		t.Fatal("oversized memory was written")
	}
	if _, err := memory.edit(json.RawMessage(`{"path":"merchants","old_string":"","new_string":"- x"}`)); err == nil {
		t.Fatal("a topic file was created without a description")
	}
	if _, err := memory.write(json.RawMessage(`{"path":"../escape","content":"- x"}`)); err == nil {
		t.Fatal("a path outside the folder was accepted")
	}
	if memory.wasUpdated() {
		t.Fatal("a refused write marked the memory updated")
	}
	if _, err := memory.edit(json.RawMessage(`{"old_string":"不存在","new_string":"x"}`)); err == nil {
		t.Fatal("a missing old_string was accepted")
	}
	// write_memory keeps a topic file's description and deletes with empty content.
	if _, err := memory.write(json.RawMessage(`{"path":"recurring","content":"- 房租 1 号","description":"固定收支"}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := memory.write(json.RawMessage(`{"path":"recurring","content":"- 房租每月 1 号"}`)); err != nil {
		t.Fatal(err)
	}
	if got, _ := memory.folder.Read("recurring.md"); got != "---\ndescription: 固定收支\n---\n\n- 房租每月 1 号\n" {
		t.Fatalf("recurring.md = %q", got)
	}
	if _, err := memory.write(json.RawMessage(`{"path":"recurring","content":""}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := memory.folder.Read("recurring.md"); !os.IsNotExist(err) {
		t.Fatal("an empty write did not delete the file")
	}
}

func TestReadOnlyMemoryOffersOnlyReading(t *testing.T) {
	memory, err := openMemory(filepath.Join(t.TempDir(), "agent-memory"))
	if err != nil {
		t.Fatal(err)
	}
	memory.readOnly = true
	var names []string
	for _, tool := range memory.tools() {
		names = append(names, tool.Name())
	}
	if !slices.Equal(names, []string{"read_memory"}) || !strings.Contains(memory.prompt(), "只读") {
		t.Fatalf("read-only memory: %v", names)
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
	if !response.OK || response.MemoryUpdated || slices.Contains(tools, "edit_memory") || strings.Contains(prompt, "MEMORY.md") {
		t.Fatalf("memory leaked into a turn without it: %+v %v", response, tools)
	}
}
