package mobileagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/MichaelKinsy/PiG/ai"
)

// listRequestV1 asks a provider which models a key can call.
type listRequestV1 struct {
	Version  int               `json:"version"`
	Provider string            `json:"provider"`
	APIKey   string            `json:"apiKey"`
	Custom   *customEndpointV1 `json:"custom,omitempty"`
}

type listedModelV1 struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	// ThinkingLevels are those of the built-in catalog when Known; otherwise
	// the levels a turn may ask for, which the provider is trusted to honor.
	ThinkingLevels []ai.ModelThinkingLevel `json:"thinkingLevels"`
	// Known is whether the built-in catalog describes the model.
	Known bool `json:"known"`
}

type listResponseV1 struct {
	Version int             `json:"version"`
	OK      bool            `json:"ok"`
	Models  []listedModelV1 `json:"models"`
	Error   string          `json:"error,omitempty"`
}

// assumedThinkingLevels are offered for a model the catalog does not know,
// as for a custom endpoint: whether it reasons is up to the provider.
var assumedThinkingLevels = []ai.ModelThinkingLevel{ai.ThinkingOff, ai.ThinkingMinimal, ai.ThinkingLow,
	ai.ThinkingMedium, ai.ThinkingHigh}

// listClient is replaced by tests with a client for a local server.
var listClient = &http.Client{Timeout: 20 * time.Second}

// listBaseURLs overrides where a provider's list is fetched; tests point it
// at a local server.
var listBaseURLs = map[string]string{}

const maxListBytes = 8 << 20

// ListModelsJSON asks the provider for the models the key can call, newest
// listing order kept. It blocks on the network; the shell runs it off the
// main thread.
func ListModelsJSON(requestJSON string) string {
	done := make(chan string, 1)
	go func() {
		defer func() {
			if recovered := recover(); recovered != nil {
				done <- encode(listResponseV1{Version: 1, Models: []listedModelV1{}, Error: fmt.Sprint(recovered)})
			}
		}()
		models, err := listModels(context.Background(), requestJSON)
		if err != nil {
			done <- encode(listResponseV1{Version: 1, Models: []listedModelV1{}, Error: err.Error()})
			return
		}
		done <- encode(listResponseV1{Version: 1, OK: true, Models: models})
	}()
	return <-done
}

func listModels(ctx context.Context, requestJSON string) ([]listedModelV1, error) {
	decoder := json.NewDecoder(strings.NewReader(requestJSON))
	decoder.DisallowUnknownFields()
	var request listRequestV1
	if err := decoder.Decode(&request); err != nil {
		return nil, fmt.Errorf("invalid model list request: %w", err)
	}
	if request.Version != 1 {
		return nil, errors.New("supported model list request version is 1")
	}
	key := strings.TrimSpace(request.APIKey)
	if key == "" {
		return nil, errors.New("an API key is required")
	}
	endpoint, err := listEndpoint(request.Provider, request.Custom)
	if err != nil {
		return nil, err
	}
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.url, nil)
	if err != nil {
		return nil, err
	}
	httpRequest.Header.Set("Accept", "application/json")
	switch endpoint.auth {
	case authAnthropic:
		httpRequest.Header.Set("x-api-key", key)
		httpRequest.Header.Set("anthropic-version", "2023-06-01")
	case authGoogle:
		httpRequest.Header.Set("x-goog-api-key", key)
	default:
		httpRequest.Header.Set("Authorization", "Bearer "+key)
	}
	response, err := listClient.Do(httpRequest)
	if err != nil {
		return nil, fmt.Errorf("could not reach %s: %w", httpRequest.URL.Host, err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, maxListBytes))
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("model list returned HTTP %d: %s", response.StatusCode, errorText(body))
	}
	return parseModelList(request.Provider, body)
}

type listAuth int

const (
	authBearer listAuth = iota
	authAnthropic
	authGoogle
)

type modelListEndpoint struct {
	url  string
	auth listAuth
}

// listEndpoint is each provider's model list, which every offered provider
// serves beside its chat API.
func listEndpoint(provider string, custom *customEndpointV1) (modelListEndpoint, error) {
	if provider == customProvider {
		model, err := customModel("list", custom)
		if err != nil {
			return modelListEndpoint{}, err
		}
		if model.ProviderMeta.API == ai.API("anthropic-messages") {
			return modelListEndpoint{model.ProviderMeta.BaseURL + "/v1/models?limit=1000", authAnthropic}, nil
		}
		return modelListEndpoint{model.ProviderMeta.BaseURL + "/models", authBearer}, nil
	}
	if !slices.ContainsFunc(catalogProviders, func(entry struct{ ID, Title string }) bool { return entry.ID == provider }) {
		return modelListEndpoint{}, fmt.Errorf("unknown provider %s", provider)
	}
	base := listBaseURLs[provider]
	if base == "" {
		models := ai.GetBuiltinModels(provider)
		if len(models) == 0 {
			return modelListEndpoint{}, fmt.Errorf("no endpoint known for %s", provider)
		}
		base = strings.TrimRight(models[0].ProviderMeta.BaseURL, "/")
	}
	switch provider {
	case "anthropic":
		return modelListEndpoint{base + "/v1/models?limit=1000", authAnthropic}, nil
	case "google":
		return modelListEndpoint{base + "/models?pageSize=1000", authGoogle}, nil
	case "openrouter":
		// The chat models speak Anthropic Messages under /api; the list is
		// OpenRouter's own, under /api/v1.
		return modelListEndpoint{strings.TrimSuffix(base, "/v1") + "/v1/models", authBearer}, nil
	default:
		return modelListEndpoint{base + "/models", authBearer}, nil
	}
}

// parseModelList reads the OpenAI shape (data[].id), Anthropic's
// (data[].display_name), OpenRouter's (data[].name, supported_parameters)
// and Gemini's (models[].name "models/…").
func parseModelList(provider string, body []byte) ([]listedModelV1, error) {
	var payload struct {
		Data []struct {
			ID                  string   `json:"id"`
			DisplayName         string   `json:"display_name"`
			Name                string   `json:"name"`
			SupportedParameters []string `json:"supported_parameters"`
		} `json:"data"`
		Models []struct {
			Name                       string   `json:"name"`
			DisplayName                string   `json:"displayName"`
			SupportedGenerationMethods []string `json:"supportedGenerationMethods"`
		} `json:"models"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, fmt.Errorf("model list is not JSON: %w", err)
	}
	models := []listedModelV1{}
	seen := map[string]bool{}
	add := func(id, title string) {
		id = strings.TrimSpace(id)
		if id == "" || seen[id] || !looksLikeChat(id) {
			return
		}
		seen[id] = true
		models = append(models, describeListed(provider, id, strings.TrimSpace(title)))
	}
	for _, entry := range payload.Data {
		// OpenRouter says which models call tools; the Agent needs them.
		if entry.SupportedParameters != nil && !slices.Contains(entry.SupportedParameters, "tools") {
			continue
		}
		title := entry.DisplayName
		if title == "" {
			title = entry.Name
		}
		add(entry.ID, title)
	}
	for _, entry := range payload.Models {
		if entry.SupportedGenerationMethods != nil && !slices.Contains(entry.SupportedGenerationMethods, "generateContent") {
			continue
		}
		add(strings.TrimPrefix(entry.Name, "models/"), entry.DisplayName)
	}
	return models, nil
}

func describeListed(provider, id, title string) listedModelV1 {
	if provider != customProvider {
		if known := ai.GetBuiltinModel(provider, id); known != nil {
			if title == "" {
				title = known.DisplayName
			}
			return listedModelV1{ID: id, Title: title, ThinkingLevels: ai.GetSupportedThinkingLevels(known), Known: true}
		}
	}
	if title == "" {
		title = id
	}
	return listedModelV1{ID: id, Title: title, ThinkingLevels: assumedThinkingLevels}
}

// nonChatMarkers name model families a list carries that cannot chat with
// tools: embeddings, speech, images, video, moderation.
var nonChatMarkers = []string{"embed", "whisper", "tts", "dall-e", "davinci", "babbage", "moderation",
	"transcribe", "audio", "realtime", "image", "imagen", "aqa", "rerank", "speech", "sora", "veo", "lyria"}

func looksLikeChat(id string) bool {
	lower := strings.ToLower(id)
	return !slices.ContainsFunc(nonChatMarkers, func(marker string) bool { return strings.Contains(lower, marker) })
}

func errorText(body []byte) string {
	var payload struct {
		Error any `json:"error"`
	}
	if json.Unmarshal(body, &payload) == nil && payload.Error != nil {
		switch value := payload.Error.(type) {
		case string:
			return value
		case map[string]any:
			if message, ok := value["message"].(string); ok {
				return message
			}
		}
	}
	text := strings.TrimSpace(string(body))
	if len(text) > 200 {
		text = text[:200]
	}
	return text
}

// listedModel builds a model the catalog does not know but the provider
// listed, from the catalog entry of that provider whose id shares the
// longest prefix, so it keeps the provider's protocol, base URL and quirks.
// It does not reason unless a turn asks for a level.
func listedModel(provider, id string) *ai.Model {
	id = strings.TrimSpace(id)
	if id == "" || len(id) > 200 || strings.ContainsAny(id, " \t\r\n") {
		return nil
	}
	var template *ai.Model
	best := -1
	for _, candidate := range ai.GetBuiltinModels(provider) {
		if candidate.Type != "" && candidate.Type != ai.ModelTypeChat {
			continue
		}
		if shared := commonPrefix(candidate.ID, id); shared > best {
			template, best = candidate, shared
		}
	}
	if template == nil {
		return nil
	}
	meta := template.ProviderMeta
	meta.Reasoning = false
	if meta.Compat != nil {
		compat := *meta.Compat
		compat.AllowedFallbackModels = nil
		meta.Compat = &compat
	}
	capabilities := template.Capabilities
	capabilities.MaxThinking = ""
	return &ai.Model{ID: id, DisplayName: id, Provider: template.Provider, ProviderMeta: meta,
		Capabilities: capabilities, Input: slices.Clone(template.Input)}
}

func commonPrefix(a, b string) int {
	n := 0
	for n < len(a) && n < len(b) && a[n] == b[n] {
		n++
	}
	return n
}
