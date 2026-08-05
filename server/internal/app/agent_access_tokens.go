package app

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
)

const (
	agentAccessTokenScope    = "auth"
	agentAccessTokenStoreKey = "agent-access-tokens"
	agentAccessTokenLifetime = 90 * 24 * time.Hour
	agentAccessTokenPrefix   = "blw_agent_"
	agentAccessTokenIDBytes  = 9
	agentAccessTokenKeyBytes = 32
)

type agentAccessTokenRecord struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	SecretHash string     `json:"secretHash"`
	CreatedAt  time.Time  `json:"createdAt"`
	ExpiresAt  time.Time  `json:"expiresAt"`
	LastUsedAt *time.Time `json:"lastUsedAt,omitempty"`
	RevokedAt  *time.Time `json:"revokedAt,omitempty"`
}

type agentAccessTokenStore struct {
	Tokens []agentAccessTokenRecord `json:"tokens"`
}

type agentAccessTokenSummary struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	CreatedAt  time.Time  `json:"createdAt"`
	ExpiresAt  time.Time  `json:"expiresAt"`
	LastUsedAt *time.Time `json:"lastUsedAt,omitempty"`
	RevokedAt  *time.Time `json:"revokedAt,omitempty"`
}

func (s *Server) agentAccessTokens(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	store, err := s.readAgentAccessTokens(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	summaries := make([]agentAccessTokenSummary, 0, len(store.Tokens))
	for _, token := range store.Tokens {
		summaries = append(summaries, summarizeAgentAccessToken(token))
	}
	sort.Slice(summaries, func(i, j int) bool { return summaries[i].CreatedAt.After(summaries[j].CreatedAt) })
	c.JSON(http.StatusOK, gin.H{"tokens": summaries})
}

func (s *Server) createAgentAccessToken(c *gin.Context) {
	if !s.limiter.Check(c, "agent.access_token.create", 10, 5*time.Minute) || !requireSensitive(c) {
		return
	}
	var input struct {
		Name string `json:"name"`
	}
	if !bindJSON(c, &input) {
		return
	}
	name := strings.TrimSpace(input.Name)
	if name == "" || utf8.RuneCountInString(name) > 64 {
		errorJSON(c, http.StatusBadRequest, errors.New("令牌名称长度必须为 1 到 64 个字符"))
		return
	}
	id, secret, rawToken, err := newAgentAccessToken()
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	now := time.Now().UTC()
	record := agentAccessTokenRecord{
		ID: id, Name: name, SecretHash: agentAccessSecretHash(secret),
		CreatedAt: now, ExpiresAt: now.Add(agentAccessTokenLifetime),
	}
	err = s.runtime().WithLock(c.Request.Context(), "agent-access-tokens", func(lockCtx context.Context) error {
		store, readErr := s.readAgentAccessTokens(lockCtx)
		if readErr != nil {
			return readErr
		}
		store.Tokens = append(store.Tokens, record)
		return s.writeAgentAccessTokens(lockCtx, store)
	})
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusCreated, gin.H{"token": rawToken, "credential": summarizeAgentAccessToken(record)})
}

func (s *Server) revokeAgentAccessToken(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	id := strings.TrimSpace(c.Param("tokenID"))
	found := false
	err := s.runtime().WithLock(c.Request.Context(), "agent-access-tokens", func(lockCtx context.Context) error {
		store, readErr := s.readAgentAccessTokens(lockCtx)
		if readErr != nil {
			return readErr
		}
		now := time.Now().UTC()
		for index := range store.Tokens {
			if store.Tokens[index].ID != id {
				continue
			}
			store.Tokens[index].RevokedAt = &now
			found = true
			break
		}
		if !found {
			return nil
		}
		return s.writeAgentAccessTokens(lockCtx, store)
	})
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	if !found {
		errorJSON(c, http.StatusNotFound, errors.New("Agent 访问令牌不存在"))
		return
	}
	c.Status(http.StatusNoContent)
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
	channel := strings.TrimSpace(input.Channel)
	if channel == "" {
		channel = "external"
	}
	rawSessionID := strings.TrimSpace(input.SessionID)
	if rawSessionID == "" {
		rawSessionID = channel + ":default"
	}
	// Local write access is an instance setting stored in the database
	// runtime config. Without a configured resolver the safe default is
	// read-only: external tokens never receive write tools.
	writeEnabled := false
	if s.agentTokenWrite != nil {
		var err error
		writeEnabled, err = s.agentTokenWrite.AgentTokenWriteEnabled(c.Request.Context())
		if err != nil {
			errorJSON(c, http.StatusServiceUnavailable, err)
			return
		}
	}
	sessionID := agentCapabilitySessionID("token:"+record.ID, rawSessionID)
	input.Context.SensitiveUnlocked = true
	s.writeAgentBootstrap(c, sessionID, "token:"+record.ID, input.Context, s.agentToolNames(!writeEnabled), writeEnabled, false)
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
	channel := strings.TrimSpace(input.Channel)
	if channel == "" {
		channel = "gateway"
	}
	rawSessionID := strings.TrimSpace(input.SessionID)
	if rawSessionID == "" {
		rawSessionID = channel + ":default"
	}
	subject := "channel:" + channel
	input.Context.SensitiveUnlocked = true
	allowedTools := s.agentToolNames(false)
	telegram := channel == "telegram"
	if telegram {
		allowedTools = agentTelegramToolNames(allowedTools)
	}
	s.writeAgentBootstrap(
		c,
		agentCapabilitySessionID(subject, rawSessionID),
		subject,
		input.Context,
		allowedTools,
		false,
		telegram,
	)
}

func (s *Server) writeAgentBootstrap(
	c *gin.Context,
	sessionID string,
	subject string,
	page AgentPageContext,
	allowedTools []string,
	trusted bool,
	telegram bool,
) {
	memories, err := s.listAgentMemories(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	systemPrompt := agentSystemPromptMode(page, memories, trusted)
	if telegram {
		systemPrompt = agentTelegramSystemPrompt(page, memories)
	}
	expiresAt := time.Now().Add(agentCapabilityLifetime)
	capabilityToken, err := s.mintAgentCapabilityToken(agentCapabilityClaims{
		SessionID: sessionID, ClusterID: ledgerClusterID(s.cfg), Context: page,
		SensitiveUnlocked: true, AllowedTools: allowedTools, Subject: subject,
		Trusted: trusted, ExpiresAt: expiresAt.Unix(),
	})
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	tools := s.agentTools()
	result := make([]map[string]any, 0, len(allowedTools))
	for _, name := range allowedTools {
		tool := tools[name]
		// Trusted capabilities (local bub chat with write enabled) expose write
		// tools without the per-call approval handshake: the synchronous CLI
		// channel has no interactive approval surface. Confirmation happens in
		// the conversation instead, driven by the trusted system prompt. The Go
		// execute endpoint still enforces this via the Trusted claim, so the
		// registry's own RequiresApproval flag is left untouched.
		requiresApproval := tool.RequiresApproval
		if trusted && !tool.ReadOnly {
			requiresApproval = false
		}
		result = append(result, map[string]any{
			"name": tool.Name, "description": tool.Description, "parameters": tool.Parameters,
			"title": tool.Title, "requiresApproval": requiresApproval,
			"approvalMessage": tool.ApprovalMessage, "executionStatus": tool.ExecutionStatus,
			"readOnly": tool.ReadOnly,
		})
	}
	c.JSON(http.StatusOK, gin.H{
		"capabilityToken": capabilityToken,
		"systemPrompt":    systemPrompt,
		"tools":           result,
		"expiresAt":       expiresAt.UTC().Format(time.RFC3339),
	})
}

// agentTelegramToolNames removes web-only tools that are meaningless for the
// Telegram channel, such as frontend page navigation.
func agentTelegramToolNames(allowed []string) []string {
	filtered := make([]string, 0, len(allowed))
	for _, name := range allowed {
		if name != "open_page" {
			filtered = append(filtered, name)
		}
	}
	return filtered
}

func (s *Server) externalAgentModelProxy(c *gin.Context) {
	if !s.limiter.Check(c, "agent.model", 120, 5*time.Minute) {
		return
	}
	if _, ok := s.authenticateAgentAccessToken(c); !ok {
		return
	}
	s.proxyAgentModelRequest(c)
}

func (s *Server) authenticateAgentAccessToken(c *gin.Context) (agentAccessTokenRecord, bool) {
	raw := strings.TrimSpace(strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer "))
	id, secret, ok := parseAgentAccessToken(raw)
	if !ok {
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid Agent access token"})
		return agentAccessTokenRecord{}, false
	}
	var authenticated agentAccessTokenRecord
	err := s.runtime().WithLock(c.Request.Context(), "agent-access-tokens", func(lockCtx context.Context) error {
		store, readErr := s.readAgentAccessTokens(lockCtx)
		if readErr != nil {
			return readErr
		}
		now := time.Now().UTC()
		for index := range store.Tokens {
			record := &store.Tokens[index]
			if record.ID != id || record.RevokedAt != nil || !record.ExpiresAt.After(now) {
				continue
			}
			want := record.SecretHash
			got := agentAccessSecretHash(secret)
			if len(want) != len(got) || subtle.ConstantTimeCompare([]byte(want), []byte(got)) != 1 {
				continue
			}
			authenticated = *record
			if record.LastUsedAt == nil || now.Sub(*record.LastUsedAt) >= time.Hour {
				record.LastUsedAt = &now
				authenticated.LastUsedAt = &now
				return s.writeAgentAccessTokens(lockCtx, store)
			}
			return nil
		}
		return nil
	})
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return agentAccessTokenRecord{}, false
	}
	if authenticated.ID == "" {
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid or expired Agent access token"})
		return agentAccessTokenRecord{}, false
	}
	return authenticated, true
}

func (s *Server) readAgentAccessTokens(ctx context.Context) (agentAccessTokenStore, error) {
	var store agentAccessTokenStore
	ok, err := s.runtime().GetJSON(ctx, agentAccessTokenScope, agentAccessTokenStoreKey, &store)
	if err != nil || !ok {
		return store, err
	}
	return store, nil
}

func (s *Server) writeAgentAccessTokens(ctx context.Context, store agentAccessTokenStore) error {
	return s.runtime().PutJSON(ctx, agentAccessTokenScope, agentAccessTokenStoreKey, store)
}

func summarizeAgentAccessToken(record agentAccessTokenRecord) agentAccessTokenSummary {
	return agentAccessTokenSummary{
		ID: record.ID, Name: record.Name, CreatedAt: record.CreatedAt, ExpiresAt: record.ExpiresAt,
		LastUsedAt: record.LastUsedAt, RevokedAt: record.RevokedAt,
	}
}

func newAgentAccessToken() (string, string, string, error) {
	idRaw := make([]byte, agentAccessTokenIDBytes)
	secretRaw := make([]byte, agentAccessTokenKeyBytes)
	if _, err := rand.Read(idRaw); err != nil {
		return "", "", "", err
	}
	if _, err := rand.Read(secretRaw); err != nil {
		return "", "", "", err
	}
	id := base64.RawURLEncoding.EncodeToString(idRaw)
	secret := base64.RawURLEncoding.EncodeToString(secretRaw)
	return id, secret, agentAccessTokenPrefix + id + "_" + secret, nil
}

func parseAgentAccessToken(raw string) (string, string, bool) {
	value := strings.TrimSpace(raw)
	if !strings.HasPrefix(value, agentAccessTokenPrefix) {
		return "", "", false
	}
	value = strings.TrimPrefix(value, agentAccessTokenPrefix)
	idLength := base64.RawURLEncoding.EncodedLen(agentAccessTokenIDBytes)
	secretLength := base64.RawURLEncoding.EncodedLen(agentAccessTokenKeyBytes)
	if len(value) != idLength+1+secretLength || value[idLength] != '_' {
		return "", "", false
	}
	id, secret := value[:idLength], value[idLength+1:]
	idRaw, idErr := base64.RawURLEncoding.DecodeString(id)
	secretRaw, secretErr := base64.RawURLEncoding.DecodeString(secret)
	if idErr != nil || secretErr != nil || len(idRaw) != agentAccessTokenIDBytes || len(secretRaw) != agentAccessTokenKeyBytes {
		return "", "", false
	}
	return id, secret, true
}

func agentCapabilitySessionID(subject, rawSessionID string) string {
	sum := sha256.Sum256([]byte(subject + "\x00" + rawSessionID))
	return "session_" + base64.RawURLEncoding.EncodeToString(sum[:18])
}

func agentAccessSecretHash(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}
