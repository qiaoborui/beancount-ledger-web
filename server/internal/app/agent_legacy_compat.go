package app

// This file keeps the pre-MCP Agent tool protocol available only as a rolling
// deployment bridge. Current agents use the stateless /mcp endpoint directly.

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

const agentCapabilityLifetime = 15 * time.Minute

type agentCapabilityClaims struct {
	SessionID         string           `json:"sessionId"`
	ClusterID         string           `json:"clusterId"`
	Context           AgentPageContext `json:"context"`
	SensitiveUnlocked bool             `json:"sensitiveUnlocked"`
	AllowedTools      []string         `json:"allowedTools"`
	Subject           string           `json:"subject,omitempty"`
	ExpiresAt         int64            `json:"expiresAt"`
}

type agentCapabilityRequest struct {
	Arguments json.RawMessage `json:"arguments"`
}

func (s *Server) mintAgentCapabilityToken(claims agentCapabilityClaims) (string, error) {
	raw, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	payload := base64.RawURLEncoding.EncodeToString(raw)
	return payload + "." + agentCapabilitySignature(payload, s.cfg.AgentServiceToken), nil
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
	if json.Unmarshal(raw, &claims) != nil {
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
		result = append(result, legacyAgentToolSpec(tool))
	}
	c.JSON(http.StatusOK, gin.H{"tools": result, "deprecated": true})
}

func (s *Server) internalAgentToolExecute(c *gin.Context) {
	claims, request, ok := s.authorizeAgentCapabilityCall(c)
	if !ok {
		return
	}
	toolName := c.Param("toolName")
	if !agentCapabilityAllowsTool(claims, toolName) {
		errorJSON(c, http.StatusForbidden, errors.New("Agent capability does not allow this tool"))
		return
	}
	tools := s.agentTools()
	tool, arguments, _, err := validateAgentToolCall(tools, agentModelToolCall{ID: "capability-execute", Type: "function", Function: agentModelFunctionCall{Name: toolName, Arguments: string(request.Arguments)}}, map[string]struct{}{})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	execution, err := tool.Execute(c.Request.Context(), arguments, claims.Context)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, agentCapabilityExecutionResponse(execution))
}

func (s *Server) authorizeAgentCapabilityCall(c *gin.Context) (agentCapabilityClaims, agentCapabilityRequest, bool) {
	token, err := bearerToken(c.GetHeader("Authorization"))
	if err != nil {
		errorJSON(c, http.StatusUnauthorized, errors.New("invalid Agent capability token"))
		return agentCapabilityClaims{}, agentCapabilityRequest{}, false
	}
	claims, err := s.parseAgentCapabilityToken(token)
	if err != nil {
		errorJSON(c, http.StatusUnauthorized, err)
		return agentCapabilityClaims{}, agentCapabilityRequest{}, false
	}
	active, err := s.agentCapabilitySubjectActive(c.Request.Context(), claims.Subject)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return agentCapabilityClaims{}, agentCapabilityRequest{}, false
	}
	if !active {
		errorJSON(c, http.StatusUnauthorized, errors.New("Agent access token has been revoked or expired"))
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
	artifacts := execution.Artifacts
	if artifacts == nil {
		artifacts = []AgentArtifact{}
	}
	return gin.H{"modelOutput": modelOutput, "clientOutput": execution.ClientOutput, "artifacts": artifacts, "refreshLedger": execution.RefreshLedger}
}

func (s *Server) externalAgentBootstrap(c *gin.Context) {
	if !s.limiter.Check(c, "agent.bootstrap", 60, 5*time.Minute) {
		return
	}
	record, ok := s.authenticateAgentAccessToken(c)
	if !ok {
		return
	}
	var input struct {
		SessionID string           `json:"sessionId"`
		Channel   string           `json:"channel"`
		Context   AgentPageContext `json:"context"`
	}
	if !bindJSON(c, &input) {
		return
	}
	channel := firstNonEmpty(strings.TrimSpace(input.Channel), "external")
	rawSessionID := firstNonEmpty(strings.TrimSpace(input.SessionID), channel+":default")
	input.Context.SensitiveUnlocked = true
	s.writeAgentBootstrap(c, agentCapabilitySessionID("token:"+record.ID, rawSessionID), "token:"+record.ID, input.Context, s.agentToolNames(false), channel == "telegram")
}

func (s *Server) internalAgentBootstrap(c *gin.Context) {
	if !s.requireAgentService(c) {
		return
	}
	var input struct {
		SessionID string           `json:"sessionId"`
		Channel   string           `json:"channel"`
		Context   AgentPageContext `json:"context"`
	}
	if !bindJSON(c, &input) {
		return
	}
	channel := firstNonEmpty(strings.TrimSpace(input.Channel), "gateway")
	rawSessionID := firstNonEmpty(strings.TrimSpace(input.SessionID), channel+":default")
	input.Context.SensitiveUnlocked = true
	s.writeAgentBootstrap(c, agentCapabilitySessionID("channel:"+channel, rawSessionID), "channel:"+channel, input.Context, s.agentToolNames(false), channel == "telegram")
}

func (s *Server) writeAgentBootstrap(c *gin.Context, sessionID, subject string, page AgentPageContext, allowedTools []string, telegram bool) {
	memories, err := s.listAgentMemories(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	prompt := agentSystemPrompt(page, memories)
	if telegram {
		prompt = agentTelegramSystemPrompt(page, memories)
		allowedTools = agentTelegramToolNames(allowedTools)
	}
	expiresAt := time.Now().Add(agentCapabilityLifetime)
	token, err := s.mintAgentCapabilityToken(agentCapabilityClaims{SessionID: sessionID, ClusterID: ledgerClusterID(s.cfg), Context: page, SensitiveUnlocked: true, AllowedTools: allowedTools, Subject: subject, ExpiresAt: expiresAt.Unix()})
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	tools := s.agentTools()
	result := make([]map[string]any, 0, len(allowedTools))
	for _, name := range allowedTools {
		result = append(result, legacyAgentToolSpec(tools[name]))
	}
	c.JSON(http.StatusOK, gin.H{"capabilityToken": token, "systemPrompt": prompt, "tools": result, "expiresAt": expiresAt.UTC().Format(time.RFC3339), "deprecated": true})
}

func legacyAgentToolSpec(tool agentTool) map[string]any {
	return map[string]any{"name": tool.Name, "description": tool.Description, "parameters": tool.Parameters, "title": tool.Title, "executionStatus": tool.ExecutionStatus, "readOnly": tool.ReadOnly}
}

func (s *Server) agentToolNames(readOnly bool) []string {
	tools := s.agentTools()
	names := make([]string, 0, len(tools))
	for name, tool := range tools {
		if !readOnly || tool.ReadOnly {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}

func agentTelegramToolNames(allowed []string) []string {
	filtered := make([]string, 0, len(allowed))
	for _, name := range allowed {
		if name != "open_page" {
			filtered = append(filtered, name)
		}
	}
	return filtered
}

func agentCapabilityAllowsTool(claims agentCapabilityClaims, toolName string) bool {
	for _, allowed := range claims.AllowedTools {
		if allowed == toolName {
			return true
		}
	}
	return false
}

func (s *Server) agentCapabilitySubjectActive(ctx context.Context, subject string) (bool, error) {
	if !strings.HasPrefix(subject, "token:") {
		return true, nil
	}
	id := strings.TrimSpace(strings.TrimPrefix(subject, "token:"))
	if id == "" {
		return false, nil
	}
	store, err := s.readAgentAccessTokens(ctx)
	if err != nil {
		return false, err
	}
	now := time.Now().UTC()
	for _, record := range store.Tokens {
		if record.ID == id && record.RevokedAt == nil && record.ExpiresAt.After(now) {
			return true, nil
		}
	}
	return false, nil
}

func agentCapabilitySessionID(subject, rawSessionID string) string {
	sum := sha256.Sum256([]byte(subject + "\x00" + rawSessionID))
	return "session_" + base64.RawURLEncoding.EncodeToString(sum[:18])
}
