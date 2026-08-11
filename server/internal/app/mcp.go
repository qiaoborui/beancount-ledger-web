package app

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	agentMCPServerName      = "beancount-ledger-web"
	agentMCPServerVersion   = "0.1.0"
	agentMCPToolPrefix      = "ledger_"
	agentMCPContextToolName = "ledger_agent_context"
	agentMCPMetaPrefix      = "com.beancount-ledger/"
	agentMCPMaxRequestBytes = 4 << 20
)

type agentMCPPrincipal struct {
	Subject string
	Page    AgentPageContext
}

type agentMCPPrincipalContextKey struct{}

func (s *Server) mcpHandler() http.Handler {
	transport := mcp.NewStreamableHTTPHandler(func(request *http.Request) *mcp.Server {
		principal, ok := request.Context().Value(agentMCPPrincipalContextKey{}).(agentMCPPrincipal)
		if !ok {
			return nil
		}
		return s.newMCPServer(principal)
	}, &mcp.StreamableHTTPOptions{
		Stateless:                    true,
		JSONResponse:                 true,
		PropagateRequestCancellation: true,
		MaxRequestBodyBytes:          agentMCPMaxRequestBytes,
	})
	authenticated := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		principal, err := s.authenticateMCPRequest(request)
		if err != nil {
			writer.Header().Set("Content-Type", "application/json")
			writer.Header().Set("WWW-Authenticate", `Bearer realm="beancount-ledger-mcp"`)
			writer.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(writer).Encode(map[string]any{
				"jsonrpc": "2.0",
				"error":   map[string]any{"code": -32001, "message": err.Error()},
				"id":      nil,
			})
			return
		}
		transport.ServeHTTP(writer, request.WithContext(context.WithValue(
			request.Context(), agentMCPPrincipalContextKey{}, principal,
		)))
	})
	return http.NewCrossOriginProtection().Handler(authenticated)
}

func (s *Server) authenticateMCPRequest(request *http.Request) (agentMCPPrincipal, error) {
	raw, err := bearerToken(request.Header.Get("Authorization"))
	if err != nil {
		return agentMCPPrincipal{}, errors.New("missing MCP bearer token")
	}
	serviceToken := strings.TrimSpace(s.cfg.AgentServiceToken)
	if serviceToken != "" && len(raw) == len(serviceToken) && subtle.ConstantTimeCompare([]byte(raw), []byte(serviceToken)) == 1 {
		return agentMCPPrincipal{
			Subject: "service:agent",
			Page:    AgentPageContext{SensitiveUnlocked: true},
		}, nil
	}
	record, err := s.authenticateAgentAccessTokenValue(request.Context(), raw)
	if err != nil {
		if errors.Is(err, errInvalidAgentAccessToken) {
			return agentMCPPrincipal{}, errors.New("invalid or expired MCP bearer token")
		}
		return agentMCPPrincipal{}, err
	}
	return agentMCPPrincipal{
		Subject: "token:" + record.ID,
		Page:    AgentPageContext{SensitiveUnlocked: true},
	}, nil
}

func (s *Server) newMCPServer(principal agentMCPPrincipal) *mcp.Server {
	server := mcp.NewServer(
		&mcp.Implementation{Name: agentMCPServerName, Version: agentMCPServerVersion},
		&mcp.ServerOptions{
			Instructions: "Personal Beancount ledger tools. Read and validate before mutation. Before using a write tool, show the exact visible draft and wait for the user's confirmation in a later turn.",
			Capabilities: &mcp.ServerCapabilities{},
			PageSize:     100,
		},
	)
	tools := s.agentTools()
	names := make([]string, 0, len(tools))
	for name := range tools {
		if name == "open_page" {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		tool := tools[name]
		server.AddTool(s.mcpToolDefinition(tool, tools), s.mcpToolHandler(tool, tools, principal.Page))
	}
	server.AddTool(s.mcpContextToolDefinition(), s.mcpContextToolHandler(principal.Page))
	return server
}

func (s *Server) mcpToolDefinition(tool agentTool, tools map[string]agentTool) *mcp.Tool {
	openWorld := false
	destructive := agentMCPToolDestructive(tool.Name)
	return &mcp.Tool{
		Name:        agentMCPToolName(tool.Name),
		Title:       tool.Title,
		Description: agentMCPToolDescription(tool.Description, tools),
		InputSchema: tool.Parameters,
		Annotations: &mcp.ToolAnnotations{
			Title:           tool.Title,
			ReadOnlyHint:    tool.ReadOnly,
			DestructiveHint: &destructive,
			IdempotentHint:  tool.ReadOnly,
			OpenWorldHint:   &openWorld,
		},
		Meta: mcp.Meta{
			agentMCPMetaPrefix + "executionStatus": tool.ExecutionStatus,
			agentMCPMetaPrefix + "internalName":    tool.Name,
		},
	}
}

func (s *Server) mcpToolHandler(tool agentTool, tools map[string]agentTool, page AgentPageContext) mcp.ToolHandler {
	return func(ctx context.Context, request *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		arguments := request.Params.Arguments
		if len(arguments) == 0 {
			arguments = json.RawMessage(`{}`)
		}
		_, validated, _, err := validateAgentToolCall(tools, agentModelToolCall{
			ID:   "mcp-call",
			Type: "function",
			Function: agentModelFunctionCall{
				Name:      tool.Name,
				Arguments: string(arguments),
			},
		}, map[string]struct{}{})
		if err != nil {
			return agentMCPToolError(err), nil
		}
		execution, err := tool.Execute(ctx, validated, page)
		if err != nil {
			return agentMCPToolError(err), nil
		}
		return agentMCPToolResult(execution), nil
	}
}

func (s *Server) mcpContextToolDefinition() *mcp.Tool {
	openWorld := false
	destructive := false
	return &mcp.Tool{
		Name:        agentMCPContextToolName,
		Title:       "读取 Agent 指引",
		Description: "读取当前渠道的账本 Agent 系统指引。运行时应在模型调用前读取，并且不要把这个工具暴露给模型重复调用。",
		InputSchema: objectSchema(map[string]any{
			"channel":           enumSchema("web", "telegram", "cli", "external"),
			"page":              stringSchema("当前页面名称"),
			"path":              stringSchema("当前页面路径"),
			"start":             stringSchema("页面时间范围起始日期"),
			"end":               stringSchema("页面时间范围结束日期"),
			"valuationCurrency": stringSchema("折算币种"),
			"bqlQuery":          stringSchema("当前 BQL 编辑器内容"),
		}, []string{"channel"}),
		Annotations: &mcp.ToolAnnotations{
			Title:           "读取 Agent 指引",
			ReadOnlyHint:    true,
			DestructiveHint: &destructive,
			OpenWorldHint:   &openWorld,
		},
		Meta: mcp.Meta{agentMCPMetaPrefix + "runtimeOnly": true},
	}
}

func (s *Server) mcpContextToolHandler(basePage AgentPageContext) mcp.ToolHandler {
	return func(ctx context.Context, request *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var input struct {
			Channel           string `json:"channel"`
			Page              string `json:"page"`
			Path              string `json:"path"`
			Start             string `json:"start"`
			End               string `json:"end"`
			ValuationCurrency string `json:"valuationCurrency"`
			BQLQuery          string `json:"bqlQuery"`
		}
		if err := decodeAgentArgs(request.Params.Arguments, &input); err != nil {
			return agentMCPToolError(err), nil
		}
		page := basePage
		page.Page = input.Page
		page.Path = input.Path
		page.Start = input.Start
		page.End = input.End
		page.ValuationCurrency = input.ValuationCurrency
		page.BQLQuery = input.BQLQuery
		memories, err := s.listAgentMemories(ctx)
		if err != nil {
			return agentMCPToolError(err), nil
		}
		prompt := s.agentMCPSystemPrompt(page, memories, input.Channel == "telegram")
		return agentMCPToolResult(agentToolExecution{
			ModelOutput:  map[string]any{"systemPrompt": prompt},
			ClientOutput: map[string]any{"systemPrompt": prompt},
		}), nil
	}
}

func agentMCPToolResult(execution agentToolExecution) *mcp.CallToolResult {
	modelOutput := execution.ModelOutput
	if modelOutput == nil {
		modelOutput = execution.ClientOutput
	}
	artifacts := execution.Artifacts
	if artifacts == nil {
		artifacts = []AgentArtifact{}
	}
	envelope := map[string]any{
		"modelOutput":   modelOutput,
		"clientOutput":  execution.ClientOutput,
		"artifacts":     artifacts,
		"refreshLedger": execution.RefreshLedger,
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		return agentMCPToolError(err)
	}
	return &mcp.CallToolResult{
		Content:           []mcp.Content{&mcp.TextContent{Text: string(raw)}},
		StructuredContent: modelOutput,
		Meta: mcp.Meta{
			agentMCPMetaPrefix + "clientOutput":  execution.ClientOutput,
			agentMCPMetaPrefix + "artifacts":     artifacts,
			agentMCPMetaPrefix + "refreshLedger": execution.RefreshLedger,
		},
	}
}

func agentMCPToolError(err error) *mcp.CallToolResult {
	raw, marshalErr := json.Marshal(map[string]any{
		"kind":    "error",
		"message": err.Error(),
	})
	if marshalErr != nil {
		raw = []byte(`{"kind":"error","message":"MCP tool failed"}`)
	}
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: string(raw)}},
		IsError: true,
	}
}

func (s *Server) agentMCPSystemPrompt(page AgentPageContext, memories []AgentMemoryRecord, telegram bool) string {
	prompt := agentSystemPrompt(page, memories)
	if telegram {
		prompt = agentTelegramSystemPrompt(page, memories)
	}
	return agentMCPToolDescription(prompt, s.agentTools())
}

func agentMCPToolName(name string) string {
	return agentMCPToolPrefix + name
}

func agentMCPToolDescription(description string, tools map[string]agentTool) string {
	names := make([]string, 0, len(tools))
	for name := range tools {
		if name != "open_page" {
			names = append(names, name)
		}
	}
	sort.Slice(names, func(i, j int) bool { return len(names[i]) > len(names[j]) })
	for _, name := range names {
		description = strings.ReplaceAll(description, name, agentMCPToolName(name))
	}
	return description
}

func agentMCPToolDestructive(name string) bool {
	switch name {
	case "update_transaction", "delete_transaction", "reverse_transaction", "apply_account_operations", "upsert_memory":
		return true
	default:
		return false
	}
}

func agentMCPInternalToolName(exposed string) (string, error) {
	name := strings.TrimPrefix(strings.TrimSpace(exposed), agentMCPToolPrefix)
	if name == exposed || name == "" {
		return "", fmt.Errorf("invalid ledger MCP tool name: %s", exposed)
	}
	return name, nil
}
