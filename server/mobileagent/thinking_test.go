package mobileagent

import (
	"encoding/json"
	"testing"

	"github.com/MichaelKinsy/PiG/ai"
)

func TestThinkingLevelClampsToTheModel(t *testing.T) {
	for _, tc := range []struct {
		provider, model, requested string
		want                       ai.ModelThinkingLevel
	}{
		{"anthropic", "claude-sonnet-4-5", "medium", ai.ThinkingMedium},
		{"anthropic", "claude-sonnet-4-5", "max", ai.ThinkingHigh},
		{"anthropic", "claude-sonnet-4-5", "", ai.ThinkingOff},
		{"openai", "gpt-4o", "high", ai.ThinkingOff},
	} {
		model := ai.GetBuiltinModel(tc.provider, tc.model)
		if model == nil {
			t.Fatalf("no builtin %s/%s", tc.provider, tc.model)
		}
		got, err := thinkingLevel(model, tc.requested, false)
		if err != nil || got != tc.want {
			t.Fatalf("%s/%s %q = %q, %v; want %q", tc.provider, tc.model, tc.requested, got, err, tc.want)
		}
	}
	custom, err := customModel("local", &customEndpointV1{API: "openai-completions", BaseURL: "https://example.com/v1"})
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := thinkingLevel(custom, "xhigh", true); got != ai.ThinkingHigh {
		t.Fatalf("custom xhigh = %q, want high", got)
	}
	if _, err := thinkingLevel(custom, "huge", true); err == nil {
		t.Fatal("unknown level accepted")
	}
}

func TestRunTurnAcceptsAThinkingLevel(t *testing.T) {
	useFaux(t, ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好")}}))
	if response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "hi", "thinking": "high"}); !response.OK {
		t.Fatalf("turn failed: %+v", response)
	}
	useFaux(t)
	if response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "hi", "thinking": "huge"}); response.OK {
		t.Fatalf("unknown level accepted: %+v", response)
	}
}

func TestModelCatalogListsThinkingLevels(t *testing.T) {
	var catalog struct {
		Providers []struct {
			ID     string `json:"id"`
			Models []struct {
				ID             string   `json:"id"`
				ThinkingLevels []string `json:"thinkingLevels"`
			} `json:"models"`
		} `json:"providers"`
	}
	if err := json.Unmarshal([]byte(ModelCatalogJSON()), &catalog); err != nil {
		t.Fatal(err)
	}
	for _, provider := range catalog.Providers {
		for _, model := range provider.Models {
			if provider.ID == "anthropic" && model.ID == "claude-sonnet-4-5" {
				if len(model.ThinkingLevels) != 5 || model.ThinkingLevels[0] != "off" || model.ThinkingLevels[4] != "high" {
					t.Fatalf("claude-sonnet-4-5 levels = %v", model.ThinkingLevels)
				}
				return
			}
		}
	}
	t.Fatal("claude-sonnet-4-5 not in catalog")
}
