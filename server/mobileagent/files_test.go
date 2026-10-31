package mobileagent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MichaelKinsy/PiG/ai"
)

type fakeChecker struct{ calls []string }

func (c *fakeChecker) Check(root, entrypoint string) string {
	c.calls = append(c.calls, root+"|"+entrypoint)
	data, _ := os.ReadFile(filepath.Join(root, entrypoint))
	if strings.Contains(string(data), "Expenses:Nope") {
		return "main.bean:9: Invalid reference to unknown account 'Expenses:Nope'"
	}
	return ""
}

func scratchCopy(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "scratch")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.bean"), []byte(testLedger), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

func toolStep(name string, args map[string]any) ai.FauxResponseStep {
	return ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
		ai.FauxToolCall(name, args, &ai.FauxToolCallOptions{ID: "call_" + name}),
	}})
}

func TestFileToolsEditTheScratchCopyOnly(t *testing.T) {
	checker := &fakeChecker{}
	SetChecker(checker)
	t.Cleanup(func() { SetChecker(nil) })
	committed, dir := committedWorkspace(t), scratchCopy(t)
	var outputs []string
	record := func(request ai.TranscriptContext) { outputs = append(outputs, lastToolResultText(request)) }
	step := func(name string, args map[string]any) ai.FauxResponseStep {
		return ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			record(request)
			return ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
				ai.FauxToolCall(name, args, &ai.FauxToolCallOptions{ID: "call_" + name}),
			}}.AssistantMessage(), nil
		})
	}
	useFaux(t,
		toolStep("list_files", map[string]any{}),
		step("read_file", map[string]any{"path": "main.bean", "offset": 4, "limit": 1}),
		step("edit_file", map[string]any{"path": "main.bean", "old_string": "  Expenses:Food  25.00 CNY\n  Assets:Cash   -25.00 CNY",
			"new_string": "  Expenses:Food  26.00 CNY\n  Assets:Cash   -26.00 CNY"}),
		step("write_file", map[string]any{"path": "2026/02.bean", "content": "2026-02-01 * \"早饭\"\n  Expenses:Food  8 CNY\n  Assets:Cash"}),
		step("bean_check", map[string]any{}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			record(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("改动已准备好，请确认。")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committed, "scratchRoot": dir,
		"provider": "faux", "model": "faux-1", "message": "午饭改成 26"})
	if !response.OK || !response.Edited || len(response.ToolCalls) != 5 {
		t.Fatalf("unexpected response: %+v", response)
	}
	for _, call := range response.ToolCalls {
		if call.IsError {
			t.Fatalf("%s failed: %+v", call.Name, outputs)
		}
	}
	if !strings.Contains(outputs[0], `"path":"main.bean"`) || !strings.Contains(outputs[1], `     4\t2026-01-05 * \"午饭\"`) ||
		!strings.Contains(outputs[1], "offset=5") || !strings.Contains(outputs[4], `"ok":true`) {
		t.Fatalf("tool outputs = %q", outputs)
	}
	edited, _ := os.ReadFile(filepath.Join(dir, "main.bean"))
	if !strings.Contains(string(edited), "26.00 CNY") {
		t.Fatalf("scratch was not edited:\n%s", edited)
	}
	created, _ := os.ReadFile(filepath.Join(dir, "2026", "02.bean"))
	if !strings.HasSuffix(string(created), "Assets:Cash\n") {
		t.Fatalf("new file = %q", created)
	}
	if original, _ := os.ReadFile(filepath.Join(committed, "main.bean")); string(original) != testLedger {
		t.Fatal("the committed generation changed")
	}
	if len(checker.calls) != 1 || checker.calls[0] != dir+"|main.bean" {
		t.Fatalf("checker calls = %v", checker.calls)
	}
}

func TestFileToolsRejectPathsOutsideTheLedger(t *testing.T) {
	dir := scratchCopy(t)
	outside := filepath.Join(t.TempDir(), "secret.bean")
	if err := os.WriteFile(outside, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "link.bean")); err != nil {
		t.Fatal(err)
	}
	files, err := openScratch(dir, "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	for _, name := range []string{"../secret.bean", outside, "notes.txt", ".git/config.bean", "link.bean", ""} {
		raw, _ := json.Marshal(map[string]any{"path": name})
		if _, err := files.readFile(raw); err == nil {
			t.Errorf("read %q was allowed", name)
		}
		raw, _ = json.Marshal(map[string]any{"path": name, "content": "x"})
		if _, err := files.writeFile(raw); err == nil {
			t.Errorf("write %q was allowed", name)
		}
	}
	if data, _ := os.ReadFile(outside); string(data) != "secret" {
		t.Fatal("a write escaped the scratch copy")
	}
	if files.wasEdited() {
		t.Fatal("rejected writes marked the scratch edited")
	}
}

func TestEditFileNeedsAUniqueExactMatch(t *testing.T) {
	files, err := openScratch(scratchCopy(t), "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	edit := func(old, replacement string, all bool) error {
		raw, _ := json.Marshal(map[string]any{"path": "main.bean", "old_string": old, "new_string": replacement, "replace_all": all})
		_, err := files.editFile(raw)
		return err
	}
	if err := edit("Expenses:Dining", "x", false); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("missing text: %v", err)
	}
	if err := edit("CNY", "USD", false); err == nil || !strings.Contains(err.Error(), "appears") {
		t.Fatalf("ambiguous text: %v", err)
	}
	if err := edit("CNY", "USD", true); err != nil {
		t.Fatalf("replace_all: %v", err)
	}
	if !files.wasEdited() {
		t.Fatal("edit was not recorded")
	}
}

func TestFileToolsNeedAScratchCopy(t *testing.T) {
	useFaux(t,
		toolStep("write_file", map[string]any{"path": "main.bean", "content": "x"}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("不能改。")}}),
	)
	committed := committedWorkspace(t)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committed,
		"provider": "faux", "model": "faux-1", "message": "改一下"})
	if !response.OK || response.Edited || len(response.ToolCalls) != 1 || !response.ToolCalls[0].IsError {
		t.Fatalf("file tool ran without a scratch copy: %+v", response)
	}
	if data, _ := os.ReadFile(filepath.Join(committed, "main.bean")); string(data) != testLedger {
		t.Fatal("the committed generation changed")
	}
	response = runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committed, "scratchRoot": committed,
		"provider": "faux", "model": "faux-1", "message": "改一下"})
	if response.OK || !strings.Contains(response.Error, "committed generation") {
		t.Fatalf("scratch equal to the committed generation was accepted: %+v", response)
	}
}

func TestBeanCheckReportsDiagnostics(t *testing.T) {
	SetChecker(&fakeChecker{})
	t.Cleanup(func() { SetChecker(nil) })
	dir := scratchCopy(t)
	if err := os.WriteFile(filepath.Join(dir, "main.bean"), []byte(testLedger+"  Expenses:Nope 1 CNY\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	files, err := openScratch(dir, "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	result, err := files.beanCheck(nil)
	if err != nil {
		t.Fatal(err)
	}
	if out, _ := json.Marshal(result); !strings.Contains(string(out), "unknown account") {
		t.Fatalf("diagnostics = %s", out)
	}
	SetChecker(nil)
	if _, err := files.beanCheck(nil); err == nil {
		t.Fatal("bean_check ran without a checker")
	}
}
