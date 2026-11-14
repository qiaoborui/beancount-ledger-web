package mobileagent

import (
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

// everyToolSchema collects the parameter schemas of every tool this package
// exposes to the model. A schema that serializes a null field breaks the call
// before the tool runs (list_saved_conversations shipped "required": null and
// was rejected with "at '/required': got null, want array"), so the whole set
// is checked here instead of one tool at a time.
func everyToolSchema(t *testing.T) map[string]ai.ToolSchema {
	t.Helper()
	schemas := map[string]ai.ToolSchema{}
	add := func(tools []agent.AgentTool) {
		for _, tool := range tools {
			schemas[tool.Name()] = tool.Schema()
		}
	}

	scratch, err := openScratch(t.TempDir(), "main.bean")
	if err != nil {
		t.Fatalf("open scratch: %v", err)
	}
	t.Cleanup(scratch.close)
	add(scratch.tools())

	add((&historyIndex{dir: t.TempDir()}).tools())

	memory, err := openMemory(filepath.Join(t.TempDir(), "memory.md"))
	if err != nil {
		t.Fatalf("open memory: %v", err)
	}
	add(memory.tools())

	drafting, err := newOnboardingSession(nil, time.Date(2026, 10, 5, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("open onboarding: %v", err)
	}
	add(drafting.tools())

	// The image item makes view_attachment_image part of the set.
	attached := &attachments{images: true, items: []attachmentV1{{ID: "a1", ImagePath: "/tmp/a1.png"}}}
	add(attached.tools(nil))
	add([]agent.AgentTool{attached.saveTool(scratch), attached.archiveTool(scratch)})

	add([]agent.AgentTool{&askTool{}})
	add((&appSettingsSession{}).tools())

	for _, spec := range app.LocalAgentToolSpecs() {
		add([]agent.AgentTool{ledgerTool{spec: spec}})
	}
	if len(schemas) < 20 {
		t.Fatalf("only %d tool schemas collected; the list lost a tool set", len(schemas))
	}
	return schemas
}

// checkSchemaJSON walks a decoded schema and fails on any null value, because
// the model side rejects null where a keyword expects a typed value. It also
// pins the shapes this bug was about.
func checkSchemaJSON(t *testing.T, tool, path string, value any) {
	t.Helper()
	switch node := value.(type) {
	case nil:
		t.Errorf("%s: %s is null", tool, path)
	case map[string]any:
		for key, child := range node {
			checkSchemaJSON(t, tool, path+"."+key, child)
		}
		if raw, ok := node["required"]; ok {
			if _, isArray := raw.([]any); !isArray {
				t.Errorf("%s: %s.required is %T, want array", tool, path, raw)
			}
		}
		if raw, ok := node["enum"]; ok {
			if _, isArray := raw.([]any); !isArray {
				t.Errorf("%s: %s.enum is %T, want array", tool, path, raw)
			}
		}
		if raw, ok := node["properties"]; ok {
			if _, isObject := raw.(map[string]any); !isObject {
				t.Errorf("%s: %s.properties is %T, want object", tool, path, raw)
			}
		}
		if raw, ok := node["items"]; ok {
			if _, isObject := raw.(map[string]any); !isObject {
				t.Errorf("%s: %s.items is %T, want object", tool, path, raw)
			}
		}
	case []any:
		for _, child := range node {
			checkSchemaJSON(t, tool, path+"[]", child)
		}
	}
}

func TestToolSchemasSerializeNoNulls(t *testing.T) {
	for name, schema := range everyToolSchema(t) {
		if len(schema.Parameters) == 0 {
			t.Errorf("%s has no parameter schema", name)
			continue
		}
		encoded, err := json.Marshal(schema.Parameters)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		var decoded any
		if err := json.Unmarshal(encoded, &decoded); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		checkSchemaJSON(t, name, "parameters", decoded)
	}
}

// TestObjectParametersOmitsEmptyRequired pins the shared helper: a tool with no
// mandatory parameters must not emit "required" at all, because the nil
// []string it used to emit encoded as null.
func TestObjectParametersOmitsEmptyRequired(t *testing.T) {
	none := objectParameters(map[string]any{"limit": map[string]any{"type": "integer"}})
	encoded, err := json.Marshal(none)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if _, ok := decoded["required"]; ok {
		t.Fatalf("empty required was written: %s", encoded)
	}
	if decoded["additionalProperties"] != false {
		t.Fatalf("additionalProperties changed: %s", encoded)
	}

	with := objectParameters(map[string]any{"conversation": map[string]any{"type": "string"}}, "conversation")
	required, ok := with["required"].([]string)
	if !ok || len(required) != 1 || required[0] != "conversation" {
		t.Fatalf("required names were not kept: %#v", with["required"])
	}
}
