package mobileagent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MichaelKinsy/PiG/ai"
)

// savedArtifact writes one record the way the shell saves it:
// runtime/agent-artifacts/<id>.json, each version holding the block as text.
func savedArtifact(t *testing.T, root, id, title, updated string, specs ...string) {
	t.Helper()
	directory := filepath.Join(root, savedArtifactDir)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	versions := []map[string]any{}
	for index, spec := range specs {
		versions = append(versions, map[string]any{"number": index + 1, "savedAt": updated, "spec": spec,
			"conversationId": "11111111-1111-1111-1111-111111111111", "messageId": "22222222-2222-2222-2222-222222222222"})
	}
	encoded, err := json.Marshal(map[string]any{"formatVersion": 1, "id": id, "title": title, "summary": title + "的说明",
		"createdAt": updated, "updatedAt": updated, "versions": versions})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, id+".json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
}

func runArtifactTool(t *testing.T, name string, shelf *artifactShelf, arguments string) (map[string]any, error) {
	t.Helper()
	for _, tool := range shelf.tools() {
		if tool.Name() != name {
			continue
		}
		result, err := tool.Execute(context.Background(), "", json.RawMessage(arguments), nil)
		if err != nil {
			return nil, err
		}
		text, ok := result.Content[0].(ai.TextContent)
		if !ok {
			t.Fatalf("tool output is not text: %T", result.Content[0])
		}
		var decoded map[string]any
		if err := json.Unmarshal([]byte(text.Text), &decoded); err != nil {
			t.Fatalf("tool output is not JSON: %v", err)
		}
		return decoded, nil
	}
	t.Fatalf("no tool %s", name)
	return nil, nil
}

func TestArtifactListSortsNewestFirstAndFilters(t *testing.T) {
	root := t.TempDir()
	savedArtifact(t, root, "food-2026", "2026 餐饮", "2026-11-01T09:00:00Z", `{"id":"food-2026","blocks":[]}`)
	savedArtifact(t, root, "net-worth", "净资产面板", "2026-11-10T09:00:00Z", `{"id":"net-worth","blocks":[]}`, `{"id":"net-worth","blocks":[{"type":"note","text":"v2"}]}`)
	// Not an artifact: a bad name and a stray file are skipped.
	if err := os.WriteFile(filepath.Join(root, savedArtifactDir, "Bad Name.json"), []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}

	shelf := openArtifacts(root)
	listed, err := runArtifactTool(t, "list_artifacts", shelf, `{}`)
	if err != nil {
		t.Fatal(err)
	}
	rows := listed["artifacts"].([]any)
	if len(rows) != 2 {
		t.Fatalf("listed %d artifacts, want 2: %v", len(rows), rows)
	}
	first := rows[0].(map[string]any)
	if first["id"] != "net-worth" || first["versions"].(float64) != 2 {
		t.Fatalf("newest first, with its version count: %v", first)
	}

	filtered, err := runArtifactTool(t, "list_artifacts", shelf, `{"query":"餐饮"}`)
	if err != nil {
		t.Fatal(err)
	}
	if rows := filtered["artifacts"].([]any); len(rows) != 1 || rows[0].(map[string]any)["id"] != "food-2026" {
		t.Fatalf("query should keep only food-2026: %v", rows)
	}
}

func TestArtifactListWithoutFolderIsEmpty(t *testing.T) {
	listed, err := runArtifactTool(t, "list_artifacts", openArtifacts(t.TempDir()), `{}`)
	if err != nil {
		t.Fatal(err)
	}
	if rows := listed["artifacts"].([]any); len(rows) != 0 {
		t.Fatalf("want no artifacts, got %v", rows)
	}
}

func TestArtifactReadReturnsLatestOrNamedVersionAsJSON(t *testing.T) {
	root := t.TempDir()
	savedArtifact(t, root, "net-worth", "净资产面板", "2026-11-10T09:00:00Z",
		`{"id":"net-worth","title":"v1","blocks":[]}`, `{"id":"net-worth","title":"v2","blocks":[]}`)
	shelf := openArtifacts(root)

	latest, err := runArtifactTool(t, "read_artifact", shelf, `{"id":"net-worth"}`)
	if err != nil {
		t.Fatal(err)
	}
	if latest["version"].(float64) != 2 || latest["artifact"].(map[string]any)["title"] != "v2" {
		t.Fatalf("latest version should be 2 as JSON: %v", latest)
	}
	first, err := runArtifactTool(t, "read_artifact", shelf, `{"id":"net-worth","version":1}`)
	if err != nil {
		t.Fatal(err)
	}
	if first["artifact"].(map[string]any)["title"] != "v1" {
		t.Fatalf("version 1 should read back: %v", first)
	}
	if _, err := runArtifactTool(t, "read_artifact", shelf, `{"id":"net-worth","version":3}`); err == nil {
		t.Fatal("a missing version should fail")
	}
	if _, err := runArtifactTool(t, "read_artifact", shelf, `{"id":"missing"}`); err == nil || !strings.Contains(err.Error(), "list_artifacts") {
		t.Fatalf("a missing artifact should point at list_artifacts: %v", err)
	}
	if _, err := runArtifactTool(t, "read_artifact", shelf, `{"id":"../agent-memory"}`); err == nil {
		t.Fatal("an id outside the folder must be refused")
	}
}

func TestArtifactPromptShowsTheFence(t *testing.T) {
	if !strings.Contains(artifactPrompt, "```artifact\n{\"id\":") {
		t.Fatal("artifact prompt lost its fence example")
	}
	if openArtifacts("relative/path") != nil || openArtifacts("") != nil {
		t.Fatal("only an absolute runtime root has artifacts")
	}
}
