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

// listedWindows lists provider (a custom endpoint when custom is set) from
// body and returns each model's context window.
func listedWindows(t *testing.T, provider, body string, custom map[string]string) map[string]int {
	t.Helper()
	request := map[string]any{"version": 1, "provider": provider, "apiKey": "k"}
	if custom != nil {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(body)) }))
		t.Cleanup(server.Close)
		custom["baseURL"] = server.URL + "/v1"
		request["custom"] = custom
	} else {
		serveList(t, provider, body)
	}
	response := listFor(t, request)
	if !response.OK {
		t.Fatalf("%s: %+v", provider, response)
	}
	windows := map[string]int{}
	for _, model := range response.Models {
		windows[model.ID] = model.ContextWindow
	}
	return windows
}

func TestListModelsReadsEachProvidersContextWindow(t *testing.T) {
	if got := listedWindows(t, "anthropic", `{"data":[{"id":"claude-next-9","max_input_tokens":1000000,"max_tokens":128000}]}`, nil); got["claude-next-9"] != 1_000_000 {
		t.Fatalf("anthropic = %v", got)
	}
	if got := listedWindows(t, "openrouter", `{"data":[{"id":"a/x","supported_parameters":["tools"],"context_length":262144},`+
		`{"id":"b/y","supported_parameters":["tools"],"context_length":null,"top_provider":{"context_length":65536}}]}`, nil); got["a/x"] != 262144 || got["b/y"] != 65536 {
		t.Fatalf("openrouter = %v", got)
	}
	if got := listedWindows(t, "google", `{"models":[{"name":"models/gemini-next","supportedGenerationMethods":["generateContent"],"inputTokenLimit":1048576}]}`, nil); got["gemini-next"] != 1048576 {
		t.Fatalf("gemini = %v", got)
	}
	got := listedWindows(t, "custom", `{"data":[{"id":"vllm","max_model_len":32768},{"id":"lm","context_window":131072.0},`+
		`{"id":"other","max_context_length":40960},{"id":"odd","context_length":"big"},{"id":"none","context_length":-1}]}`,
		map[string]string{"api": "openai-completions"})
	if got["vllm"] != 32768 || got["lm"] != 131072 || got["other"] != 40960 || got["odd"] != 0 || got["none"] != 0 || len(got) != 5 {
		t.Fatalf("custom = %v", got)
	}
}

func TestListedCatalogModelFallsBackToTheCatalogWindow(t *testing.T) {
	models := ai.GetBuiltinModels("anthropic")
	if len(models) == 0 || models[0].Capabilities.ContextWindow <= 0 {
		t.Skip("no built-in Anthropic model with a window")
	}
	builtin := models[0]
	serveList(t, "anthropic", `{"data":[{"id":"`+builtin.ID+`"}]}`)
	response := listFor(t, map[string]any{"version": 1, "provider": "anthropic", "apiKey": "k"})
	if !response.OK || len(response.Models) != 1 || response.Models[0].ContextWindow != builtin.Capabilities.ContextWindow {
		t.Fatalf("response = %+v, catalog window %d", response, builtin.Capabilities.ContextWindow)
	}
}

// gatewayModelList is the shape of an OpenAI-compatible gateway that names
// its models provider/model and says each one's limits (issue #663).
const gatewayModelList = `{"object":"list","data":[` +
	`{"id":"antigravity/gemini-3.8-flash-tiered","object":"model","owned_by":"antigravity","context_length":1048576,` +
	`"context_window":1048576,"max_input_tokens":1048576,"max_output_tokens":65536,"reasoning_levels":["low","medium","high"],` +
	`"supported_parameters":["tools","tool_choice","reasoning"]},` +
	`{"id":"auto/deepseek-flash","object":"model"}]}`

func TestListModelsReadsAGatewaysLimits(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(gatewayModelList)) }))
	defer server.Close()
	response := listFor(t, map[string]any{"version": 1, "provider": "custom", "apiKey": "k",
		"custom": map[string]string{"api": "openai-completions", "baseURL": server.URL + "/v1"}})
	if !response.OK || len(response.Models) != 2 {
		t.Fatalf("response = %+v", response)
	}
	gemini, auto := response.Models[0], response.Models[1]
	if gemini.ID != "antigravity/gemini-3.8-flash-tiered" || gemini.ContextWindow != 1_048_576 || gemini.MaxOutputTokens != 65_536 || gemini.Known {
		t.Fatalf("gemini = %+v", gemini)
	}
	if auto.ID != "auto/deepseek-flash" || auto.ContextWindow != 0 || auto.MaxOutputTokens != 0 {
		t.Fatalf("a model without limits = %+v", auto)
	}
	raw, _ := json.Marshal(gemini)
	var wire map[string]any
	if json.Unmarshal(raw, &wire) != nil || wire["contextWindow"] != float64(1_048_576) || wire["maxOutputTokens"] != float64(65_536) {
		t.Fatalf("wire = %s", raw)
	}
}

func TestListModelsReadsEachProvidersReplyLimit(t *testing.T) {
	outputs := func(provider, body string, custom map[string]string) map[string]int {
		request := map[string]any{"version": 1, "provider": provider, "apiKey": "k"}
		if custom != nil {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(body)) }))
			t.Cleanup(server.Close)
			custom["baseURL"] = server.URL + "/v1"
			request["custom"] = custom
		} else {
			serveList(t, provider, body)
		}
		response := listFor(t, request)
		if !response.OK {
			t.Fatalf("%s: %+v", provider, response)
		}
		got := map[string]int{}
		for _, model := range response.Models {
			got[model.ID] = model.MaxOutputTokens
		}
		return got
	}
	if got := outputs("openrouter", `{"data":[{"id":"a/x","supported_parameters":["tools"],"top_provider":{"context_length":262144,"max_completion_tokens":32768}}]}`, nil); got["a/x"] != 32768 {
		t.Fatalf("openrouter = %v", got)
	}
	if got := outputs("google", `{"models":[{"name":"models/gemini-next","supportedGenerationMethods":["generateContent"],"inputTokenLimit":1048576,"outputTokenLimit":65536}]}`, nil); got["gemini-next"] != 65536 {
		t.Fatalf("gemini = %v", got)
	}
	if got := outputs("custom", `{"data":[{"id":"c","max_completion_tokens":16384},{"id":"d","max_output_tokens":"lots"}]}`,
		map[string]string{"api": "openai-completions"}); got["c"] != 16384 || got["d"] != 0 || len(got) != 2 {
		t.Fatalf("custom = %v", got)
	}
}

// One entry a gateway shapes oddly is skipped; the rest of the list, and
// their windows, still arrive.
func TestListModelsSkipsAnEntryItCannotRead(t *testing.T) {
	got := listedWindows(t, "custom", `{"data":[{"id":"bad","top_provider":"none"},{"id":7},"text",`+
		`{"id":"good/model","context_length":1048576},{"id":"named","name":{"en":"x"}}]}`,
		map[string]string{"api": "openai-completions"})
	if len(got) != 1 || got["good/model"] != 1_048_576 {
		t.Fatalf("custom = %v", got)
	}
	got = listedWindows(t, "google", `{"models":[{"name":3},{"name":"models/gemini-next","inputTokenLimit":1048576}]}`, nil)
	if len(got) != 1 || got["gemini-next"] != 1_048_576 {
		t.Fatalf("gemini = %v", got)
	}
}
