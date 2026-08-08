package app

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"google.golang.org/api/idtoken"
)

const (
	agentServiceRequestTimeout = 14 * time.Minute
)

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
		SessionID: input.SessionID, ClusterID: ledgerClusterID(s.cfg), Context: input.Context,
		SensitiveUnlocked: input.Context.SensitiveUnlocked, AllowedTools: s.agentToolNames(false),
		Subject: "web", ExpiresAt: time.Now().Add(agentCapabilityLifetime).Unix(),
	})
	if err != nil {
		return err
	}
	payload := map[string]any{
		"sessionId": input.SessionID, "message": strings.TrimSpace(input.Message), "context": input.Context,
		"capabilityToken": capabilityToken,
		"systemPrompt":    agentSystemPrompt(input.Context, memories),
		"mcpSystemPrompt": s.agentMCPSystemPrompt(input.Context, memories, false),
	}
	return s.proxyAgentSSE(c, "/v1/channels/web/messages", payload)
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

func (s *Server) requireAgentService(c *gin.Context) bool {
	want := strings.TrimSpace(s.cfg.AgentServiceToken)
	got := strings.TrimSpace(c.GetHeader("X-Agent-Service-Token"))
	if got == "" {
		got, _ = bearerToken(c.GetHeader("Authorization"))
	}
	if want == "" || len(got) != len(want) || subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid Agent service token"})
		return false
	}
	return true
}

func (s *Server) internalAgentModelProxy(c *gin.Context) {
	if !s.requireAgentService(c) {
		return
	}
	s.proxyAgentModelRequest(c)
}

func (s *Server) proxyAgentModelRequest(c *gin.Context) {
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
