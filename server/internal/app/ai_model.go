package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type agentModelMessage struct {
	Role       string               `json:"role"`
	Content    string               `json:"content,omitempty"`
	ToolCalls  []agentModelToolCall `json:"tool_calls,omitempty"`
	ToolCallID string               `json:"tool_call_id,omitempty"`
}

type agentModelToolCall struct {
	ID       string                 `json:"id"`
	Type     string                 `json:"type"`
	Function agentModelFunctionCall `json:"function"`
}

type agentModelFunctionCall struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

type agentModelResult struct {
	Content   string
	ToolCalls []agentModelToolCall
}

type AgentModelClient interface {
	Complete(context.Context, string, []agentModelMessage, []agentToolSpec) (agentModelResult, error)
}

type openAICompatibleAgentClient struct {
	resolve func(context.Context) (aiProviderConfig, error)
}

func (client openAICompatibleAgentClient) Complete(ctx context.Context, system string, messages []agentModelMessage, tools []agentToolSpec) (agentModelResult, error) {
	resolve := client.resolve
	if resolve == nil {
		resolve = func(context.Context) (aiProviderConfig, error) { return resolveAIProviderConfig() }
	}
	provider, err := resolve(ctx)
	if err != nil {
		return agentModelResult{}, err
	}
	wireMessages := append([]agentModelMessage{{Role: "system", Content: system}}, messages...)
	wireTools := make([]map[string]any, 0, len(tools))
	for _, tool := range tools {
		wireTools = append(wireTools, map[string]any{"type": "function", "function": map[string]any{
			"name": tool.Name, "description": tool.Description, "parameters": tool.Parameters,
		}})
	}
	body := map[string]any{"model": provider.model, "messages": wireMessages, "temperature": 0}
	if len(wireTools) > 0 {
		body["tools"] = wireTools
		body["tool_choice"] = "auto"
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return agentModelResult{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(provider.baseURL, "/")+"/chat/completions", bytes.NewReader(raw))
	if err != nil {
		return agentModelResult{}, err
	}
	request.Header.Set("Authorization", "Bearer "+provider.apiKey)
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 90 * time.Second}).Do(request)
	if err != nil {
		return agentModelResult{}, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		content, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		return agentModelResult{}, fmt.Errorf("AI request failed: %s", strings.TrimSpace(string(content)))
	}
	var payload struct {
		Choices []struct {
			Message agentModelMessage `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		return agentModelResult{}, err
	}
	if len(payload.Choices) == 0 {
		return agentModelResult{}, errors.New("AI returned no choices")
	}
	message := payload.Choices[0].Message
	if strings.TrimSpace(message.Content) == "" && len(message.ToolCalls) == 0 {
		return agentModelResult{}, errors.New("AI returned empty content")
	}
	return agentModelResult{Content: message.Content, ToolCalls: message.ToolCalls}, nil
}

func (s *Server) modelClient() AgentModelClient {
	if s.agentModel != nil {
		return s.agentModel
	}
	return openAICompatibleAgentClient{resolve: s.resolveAIProviderConfig}
}
