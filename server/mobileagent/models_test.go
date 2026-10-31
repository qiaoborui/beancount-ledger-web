package mobileagent

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/MichaelKinsy/PiG/ai"
)

func listFor(t *testing.T, request map[string]any) listResponseV1 {
	t.Helper()
	body, _ := json.Marshal(request)
	var response listResponseV1
	if err := json.Unmarshal([]byte(ListModelsJSON(string(body))), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

// serveList answers every request with body and records the last one.
func serveList(t *testing.T, provider, body string) *http.Request {
	t.Helper()
	seen := &http.Request{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*seen = *r.Clone(r.Context())
		if r.Header.Get("x-api-key") == "bad" || r.Header.Get("Authorization") == "Bearer bad" {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":{"message":"invalid x-api-key"}}`))
			return
		}
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	previous, had := listBaseURLs[provider]
	listBaseURLs[provider] = server.URL
	t.Cleanup(func() {
		if had {
			listBaseURLs[provider] = previous
		} else {
			delete(listBaseURLs, provider)
		}
	})
	return seen
}

func TestListModelsReadsAnthropic(t *testing.T) {
	seen := serveList(t, "anthropic", `{"data":[{"id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5"},{"id":"claude-next-9","display_name":"Claude Next"}],"has_more":false}`)
	response := listFor(t, map[string]any{"version": 1, "provider": "anthropic", "apiKey": "k"})
	if !response.OK || len(response.Models) != 2 {
		t.Fatalf("response = %+v", response)
	}
	if seen.URL.Path != "/v1/models" || seen.Header.Get("x-api-key") != "k" || seen.Header.Get("anthropic-version") == "" {
		t.Fatalf("request = %s %v", seen.URL, seen.Header)
	}
	known, unknown := response.Models[0], response.Models[1]
	if !known.Known || len(known.ThinkingLevels) != 5 {
		t.Fatalf("known = %+v", known)
	}
	if unknown.Known || unknown.Title != "Claude Next" || len(unknown.ThinkingLevels) != len(assumedThinkingLevels) {
		t.Fatalf("unknown = %+v", unknown)
	}
}

func TestListModelsDropsModelsThatCannotChat(t *testing.T) {
	serveList(t, "openai", `{"object":"list","data":[{"id":"gpt-4o"},{"id":"text-embedding-3-large"},{"id":"whisper-1"},{"id":"gpt-image-1"},{"id":"gpt-4o"}]}`)
	response := listFor(t, map[string]any{"version": 1, "provider": "openai", "apiKey": "k"})
	if !response.OK || len(response.Models) != 1 || response.Models[0].ID != "gpt-4o" {
		t.Fatalf("response = %+v", response)
	}
}

func TestListModelsKeepsOpenRouterToolModels(t *testing.T) {
	seen := serveList(t, "openrouter", `{"data":[{"id":"a/tools","name":"A: Tools","supported_parameters":["tools","reasoning"]},{"id":"b/plain","name":"B","supported_parameters":["temperature"]}]}`)
	response := listFor(t, map[string]any{"version": 1, "provider": "openrouter", "apiKey": "k"})
	if !response.OK || len(response.Models) != 1 || response.Models[0].Title != "A: Tools" {
		t.Fatalf("response = %+v", response)
	}
	if seen.URL.Path != "/v1/models" {
		t.Fatalf("path = %s", seen.URL.Path)
	}
}

func TestListModelsReadsGemini(t *testing.T) {
	seen := serveList(t, "google", `{"models":[{"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","supportedGenerationMethods":["generateContent"]},{"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}]}`)
	response := listFor(t, map[string]any{"version": 1, "provider": "google", "apiKey": "k"})
	if !response.OK || len(response.Models) != 1 || response.Models[0].ID != "gemini-2.5-flash" {
		t.Fatalf("response = %+v", response)
	}
	if seen.Header.Get("x-goog-api-key") != "k" || seen.URL.Query().Get("key") != "" {
		t.Fatalf("key must travel in a header: %s %v", seen.URL, seen.Header)
	}
}

func TestListModelsReportsTheProviderError(t *testing.T) {
	serveList(t, "anthropic", `{}`)
	response := listFor(t, map[string]any{"version": 1, "provider": "anthropic", "apiKey": "bad"})
	if response.OK || response.Error != "model list returned HTTP 401: invalid x-api-key" {
		t.Fatalf("response = %+v", response)
	}
	if response := listFor(t, map[string]any{"version": 1, "provider": "nope", "apiKey": "k"}); response.OK {
		t.Fatalf("unknown provider listed: %+v", response)
	}
	if response := listFor(t, map[string]any{"version": 1, "provider": "anthropic", "apiKey": " "}); response.OK {
		t.Fatalf("empty key listed: %+v", response)
	}
}

func TestListModelsAsksACustomEndpoint(t *testing.T) {
	var path, auth string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path, auth = r.URL.Path, r.Header.Get("Authorization")
		_, _ = w.Write([]byte(`{"data":[{"id":"qwen3:32b"}]}`))
	}))
	defer server.Close()
	response := listFor(t, map[string]any{"version": 1, "provider": "custom", "apiKey": "k",
		"custom": map[string]string{"api": "openai-completions", "baseURL": server.URL + "/v1"}})
	if !response.OK || len(response.Models) != 1 || response.Models[0].Known || path != "/v1/models" || auth != "Bearer k" {
		t.Fatalf("response = %+v path=%s auth=%s", response, path, auth)
	}
}

func TestListedModelBorrowsTheNearestCatalogEntry(t *testing.T) {
	model := listedModel("anthropic", "claude-sonnet-4-5-20990101")
	if model == nil || model.ID != "claude-sonnet-4-5-20990101" || model.ProviderMeta.API != ai.API("anthropic-messages") ||
		model.ProviderMeta.BaseURL != "https://api.anthropic.com" || model.ProviderMeta.Reasoning {
		t.Fatalf("model = %+v", model)
	}
	if got, _ := thinkingLevel(model, "high", true); got != ai.ThinkingHigh || !model.ProviderMeta.Reasoning {
		t.Fatalf("assumed high = %q reasoning=%v", got, model.ProviderMeta.Reasoning)
	}
	if listedModel("anthropic", "bad id") != nil || listedModel("custom", "x") != nil {
		t.Fatal("invalid listed model built")
	}
}
