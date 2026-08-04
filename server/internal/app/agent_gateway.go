package app

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"google.golang.org/api/idtoken"
)

const (
	agentServiceRequestTimeout = 14 * time.Minute
	// The Bub interaction timeout is bounded below the hosted request timeout.
	// Capability and preview
	// confirmation tokens must remain valid for that entire human pause.
	agentCapabilityLifetime = 15 * time.Minute
)

type agentCapabilityClaims struct {
	SessionID         string           `json:"sessionId"`
	ClusterID         string           `json:"clusterId"`
	Context           AgentPageContext `json:"context"`
	SensitiveUnlocked bool             `json:"sensitiveUnlocked"`
	ExpiresAt         int64            `json:"expiresAt"`
}

type agentCapabilityRequest struct {
	Arguments         json.RawMessage `json:"arguments"`
	ConfirmationToken string          `json:"confirmationToken,omitempty"`
}

type agentConfirmationClaims struct {
	SessionID     string `json:"sessionId"`
	ClusterID     string `json:"clusterId"`
	ToolName      string `json:"toolName"`
	ArgumentsHash string `json:"argumentsHash"`
	ExpiresAt     int64  `json:"expiresAt"`
}

var newAgentServiceHTTPClient = func(ctx context.Context, audience string) (*http.Client, error) {
	if strings.TrimSpace(audience) == "" {
		return &http.Client{}, nil
	}
	return idtoken.NewClient(ctx, audience)
}

func (s *Server) proxyLedgerAgentTurn(c *gin.Context, input AgentTurnRequest) error {
	input.SessionID = normalizeAgentSessionID(input.SessionID)
	input.Context.SensitiveUnlocked = isSensitiveUnlocked(c)
	memories := []AgentMemoryRecord{}
	if input.Context.SensitiveUnlocked {
		var err error
		memories, err = s.listAgentMemories(c.Request.Context())
		if err != nil {
			return err
		}
	}
	capabilityToken, err := s.mintAgentCapabilityToken(agentCapabilityClaims{
		SessionID:         input.SessionID,
		ClusterID:         ledgerClusterID(s.cfg),
		Context:           input.Context,
		SensitiveUnlocked: input.Context.SensitiveUnlocked,
		ExpiresAt:         time.Now().Add(agentCapabilityLifetime).Unix(),
	})
	if err != nil {
		return err
	}
	payload := map[string]any{
		"sessionId":       input.SessionID,
		"message":         strings.TrimSpace(input.Message),
		"context":         input.Context,
		"approvalPolicy":  normalizeAgentApprovalPolicy(input.ApprovalPolicy),
		"capabilityToken": capabilityToken,
		"systemPrompt":    agentSystemPrompt(input.Context, memories),
	}
	return s.proxyAgentSSE(c, "/v1/turn", payload)
}

func (s *Server) proxyAgentSSE(c *gin.Context, path string, payload any) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(c.Request.Context()), agentServiceRequestTimeout)
	defer cancel()
	response, err := s.agentServiceRequest(ctx, http.MethodPost, path, payload)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return agentServiceResponseError(response)
	}
	prepareSSE(c)
	buffer := make([]byte, 32*1024)
	connected := true
	for {
		count, readErr := response.Body.Read(buffer)
		if count > 0 && connected {
			if _, writeErr := c.Writer.Write(buffer[:count]); writeErr != nil {
				connected = false
			} else {
				c.Writer.Flush()
			}
		}
		if errors.Is(readErr, io.EOF) {
			return nil
		}
		if readErr != nil {
			return readErr
		}
	}
}

func (s *Server) agentServiceRequest(ctx context.Context, method, path string, payload any) (*http.Response, error) {
	serviceURL := strings.TrimRight(strings.TrimSpace(s.cfg.AgentServiceURL), "/")
	serviceToken := strings.TrimSpace(s.cfg.AgentServiceToken)
	if serviceURL == "" || serviceToken == "" {
		return nil, errors.New("Agent service is not configured")
	}
	var body io.Reader
	if payload != nil {
		raw, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(raw)
	}
	request, err := http.NewRequestWithContext(ctx, method, serviceURL+path, body)
	if err != nil {
		return nil, err
	}
	request.Header.Set("X-Agent-Service-Token", serviceToken)
	if payload != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	client, err := newAgentServiceHTTPClient(ctx, s.cfg.AgentServiceAudience)
	if err != nil {
		return nil, fmt.Errorf("create Agent service identity client: %w", err)
	}
	return client.Do(request)
}

func agentServiceResponseError(response *http.Response) error {
	raw, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	var payload struct {
		Detail any `json:"detail"`
		Error  any `json:"error"`
	}
	if json.Unmarshal(raw, &payload) == nil {
		if payload.Error != nil {
			return fmt.Errorf("Agent service: %v", payload.Error)
		}
		if payload.Detail != nil {
			return fmt.Errorf("Agent service: %v", payload.Detail)
		}
	}
	message := strings.TrimSpace(string(raw))
	if message == "" {
		message = response.Status
	}
	return errors.New(message)
}

func (s *Server) mintAgentCapabilityToken(claims agentCapabilityClaims) (string, error) {
	raw, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	payload := base64.RawURLEncoding.EncodeToString(raw)
	signature := agentCapabilitySignature(payload, s.cfg.AgentServiceToken)
	return payload + "." + signature, nil
}

func (s *Server) parseAgentCapabilityToken(token string) (agentCapabilityClaims, error) {
	payload, signature, found := strings.Cut(strings.TrimSpace(token), ".")
	if !found || payload == "" || signature == "" {
		return agentCapabilityClaims{}, errors.New("invalid Agent capability token")
	}
	want := agentCapabilitySignature(payload, s.cfg.AgentServiceToken)
	if subtle.ConstantTimeCompare([]byte(signature), []byte(want)) != 1 {
		return agentCapabilityClaims{}, errors.New("invalid Agent capability signature")
	}
	raw, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return agentCapabilityClaims{}, errors.New("invalid Agent capability payload")
	}
	var claims agentCapabilityClaims
	if err := json.Unmarshal(raw, &claims); err != nil {
		return agentCapabilityClaims{}, errors.New("invalid Agent capability payload")
	}
	if claims.ExpiresAt < time.Now().Unix() {
		return agentCapabilityClaims{}, errors.New("Agent capability token has expired")
	}
	if claims.ClusterID != ledgerClusterID(s.cfg) || normalizeAgentSessionID(claims.SessionID) != claims.SessionID {
		return agentCapabilityClaims{}, errors.New("Agent capability token is not valid for this ledger")
	}
	claims.Context.SensitiveUnlocked = claims.SensitiveUnlocked
	return claims, nil
}

func agentCapabilitySignature(payload, secret string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(payload))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (s *Server) mintAgentConfirmationToken(claims agentConfirmationClaims) (string, error) {
	raw, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	payload := base64.RawURLEncoding.EncodeToString(raw)
	return payload + "." + agentConfirmationSignature(payload, s.cfg.AgentServiceToken), nil
}

func (s *Server) parseAgentConfirmationToken(token string) (agentConfirmationClaims, error) {
	payload, signature, found := strings.Cut(strings.TrimSpace(token), ".")
	if !found || payload == "" || signature == "" {
		return agentConfirmationClaims{}, errors.New("write confirmation token is required")
	}
	want := agentConfirmationSignature(payload, s.cfg.AgentServiceToken)
	if subtle.ConstantTimeCompare([]byte(signature), []byte(want)) != 1 {
		return agentConfirmationClaims{}, errors.New("invalid write confirmation token")
	}
	raw, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return agentConfirmationClaims{}, errors.New("invalid write confirmation token")
	}
	var claims agentConfirmationClaims
	if json.Unmarshal(raw, &claims) != nil || claims.ExpiresAt < time.Now().Unix() {
		return agentConfirmationClaims{}, errors.New("write confirmation token has expired or is invalid")
	}
	return claims, nil
}

func agentConfirmationSignature(payload, secret string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte("agent-write-confirmation." + payload))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func canonicalAgentArgumentsHash(raw json.RawMessage) (string, error) {
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", err
	}
	canonical, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canonical)
	return base64.RawURLEncoding.EncodeToString(sum[:]), nil
}

func (s *Server) requireAgentService(c *gin.Context) bool {
	want := strings.TrimSpace(s.cfg.AgentServiceToken)
	got := strings.TrimSpace(c.GetHeader("X-Agent-Service-Token"))
	if got == "" {
		got = strings.TrimSpace(strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer "))
	}
	if want == "" || len(got) != len(want) || subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid Agent service token"})
		return false
	}
	return true
}

func (s *Server) internalAgentTools(c *gin.Context) {
	if !s.requireAgentService(c) {
		return
	}
	tools := s.agentTools()
	names := make([]string, 0, len(tools))
	for name := range tools {
		names = append(names, name)
	}
	sort.Strings(names)
	result := make([]map[string]any, 0, len(names))
	for _, name := range names {
		tool := tools[name]
		result = append(result, map[string]any{
			"name": tool.Name, "description": tool.Description, "parameters": tool.Parameters,
			"title": tool.Title, "requiresApproval": tool.RequiresApproval, "approvalMessage": tool.ApprovalMessage,
			"executionStatus": tool.ExecutionStatus, "readOnly": tool.ReadOnly,
		})
	}
	c.JSON(http.StatusOK, gin.H{"tools": result})
}

func (s *Server) internalAgentToolPreview(c *gin.Context) {
	claims, request, ok := s.authorizeAgentCapabilityCall(c)
	if !ok {
		return
	}
	toolName := c.Param("toolName")
	tool, exists := s.agentTools()[toolName]
	if !exists || !tool.RequiresApproval {
		errorJSON(c, http.StatusNotFound, errors.New("Agent tool preview is not available"))
		return
	}
	if _, _, _, err := validateAgentToolCall(s.agentTools(), agentModelToolCall{ID: "capability-preview", Type: "function", Function: agentModelFunctionCall{Name: toolName, Arguments: string(request.Arguments)}}, map[string]struct{}{}); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	execution, err := s.previewAgentWrite(c.Request.Context(), toolName, request.Arguments, claims.Context)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	argumentsHash, err := canonicalAgentArgumentsHash(request.Arguments)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	confirmationToken, err := s.mintAgentConfirmationToken(agentConfirmationClaims{
		SessionID: claims.SessionID, ClusterID: claims.ClusterID, ToolName: toolName,
		ArgumentsHash: argumentsHash, ExpiresAt: time.Now().Add(agentCapabilityLifetime).Unix(),
	})
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	response := agentCapabilityExecutionResponse(execution)
	response["confirmationToken"] = confirmationToken
	c.JSON(http.StatusOK, response)
}

func (s *Server) internalAgentToolExecute(c *gin.Context) {
	claims, request, ok := s.authorizeAgentCapabilityCall(c)
	if !ok {
		return
	}
	toolName := c.Param("toolName")
	tools := s.agentTools()
	tool, arguments, _, err := validateAgentToolCall(tools, agentModelToolCall{ID: "capability-execute", Type: "function", Function: agentModelFunctionCall{Name: toolName, Arguments: string(request.Arguments)}}, map[string]struct{}{})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if tool.RequiresApproval {
		confirmation, confirmationErr := s.parseAgentConfirmationToken(request.ConfirmationToken)
		argumentsHash, hashErr := canonicalAgentArgumentsHash(arguments)
		if confirmationErr != nil || hashErr != nil || confirmation.SessionID != claims.SessionID || confirmation.ClusterID != claims.ClusterID || confirmation.ToolName != toolName || confirmation.ArgumentsHash != argumentsHash {
			if confirmationErr == nil {
				confirmationErr = errors.New("write confirmation token does not match this tool call")
			}
			errorJSON(c, http.StatusForbidden, confirmationErr)
			return
		}
	}
	execution, err := tool.Execute(c.Request.Context(), arguments, claims.Context)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, agentCapabilityExecutionResponse(execution))
}

func (s *Server) authorizeAgentCapabilityCall(c *gin.Context) (agentCapabilityClaims, agentCapabilityRequest, bool) {
	token := strings.TrimSpace(strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer "))
	claims, err := s.parseAgentCapabilityToken(token)
	if err != nil {
		errorJSON(c, http.StatusUnauthorized, err)
		return agentCapabilityClaims{}, agentCapabilityRequest{}, false
	}
	var request agentCapabilityRequest
	if !bindJSON(c, &request) {
		return agentCapabilityClaims{}, agentCapabilityRequest{}, false
	}
	if len(request.Arguments) == 0 || !json.Valid(request.Arguments) {
		errorJSON(c, http.StatusBadRequest, errors.New("arguments must be valid JSON"))
		return agentCapabilityClaims{}, agentCapabilityRequest{}, false
	}
	return claims, request, true
}

func agentCapabilityExecutionResponse(execution agentToolExecution) gin.H {
	modelOutput := execution.ModelOutput
	if modelOutput == nil {
		modelOutput = execution.ClientOutput
	}
	return gin.H{
		"modelOutput": modelOutput, "clientOutput": execution.ClientOutput,
		"artifacts": execution.Artifacts, "refreshLedger": execution.RefreshLedger,
	}
}

func (s *Server) internalAgentModelProxy(c *gin.Context) {
	if !s.requireAgentService(c) {
		return
	}
	raw, err := io.ReadAll(io.LimitReader(c.Request.Body, 8<<20))
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		errorJSON(c, http.StatusBadRequest, errors.New("invalid model request"))
		return
	}
	provider, err := s.resolveAIProviderConfig(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	body["model"] = provider.model
	raw, err = json.Marshal(body)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	target, err := url.JoinPath(strings.TrimRight(provider.baseURL, "/"), "chat/completions")
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	request, err := http.NewRequestWithContext(c.Request.Context(), http.MethodPost, target, bytes.NewReader(raw))
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	request.Header.Set("Authorization", "Bearer "+provider.apiKey)
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{}).Do(request)
	if err != nil {
		errorJSON(c, http.StatusBadGateway, err)
		return
	}
	defer response.Body.Close()
	if contentType := response.Header.Get("Content-Type"); contentType != "" {
		c.Header("Content-Type", contentType)
	}
	c.Status(response.StatusCode)
	_, _ = io.Copy(c.Writer, response.Body)
}
