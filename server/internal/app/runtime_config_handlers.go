package app

import (
	"context"
	"crypto/subtle"
	"errors"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

func (s *Server) setupStatus(c *gin.Context) {
	if s.runtimeConfig == nil {
		c.JSON(http.StatusOK, gin.H{"setupRequired": false, "setupComplete": true, "configSource": "environment"})
		return
	}
	status, err := s.runtimeConfig.Status(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusServiceUnavailable, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"setupRequired": status.SetupRequired,
		"setupComplete": status.SetupComplete,
		"configSource":  status.ConfigSource,
	})
}

func (s *Server) indexerRuntimeConfig(c *gin.Context) {
	if s.runtimeConfig == nil {
		errorJSON(c, http.StatusNotFound, errors.New("database runtime configuration is unavailable"))
		return
	}
	expected := strings.TrimSpace(os.Getenv("INDEXER_IDENTITY_TOKEN"))
	provided := strings.TrimSpace(strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer "))
	if expected == "" || len(provided) != len(expected) || subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) != 1 {
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "Unauthorized"})
		return
	}
	config, err := s.runtimeConfig.IndexerConfig(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusServiceUnavailable, err)
		return
	}
	identityID := valueOr(strings.TrimSpace(os.Getenv("INDEXER_IDENTITY_ID")), "compose-indexer")
	if err := s.runtimeConfig.RecordIndexerIdentity(c.Request.Context(), identityID, expected); err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, config)
}

func (s *Server) setupInstall(c *gin.Context) {
	if s.runtimeConfig == nil {
		errorJSON(c, http.StatusBadRequest, errors.New("database runtime configuration is unavailable"))
		return
	}
	if !s.limiter.Check(c, "setup.install", 10, 10*time.Minute) {
		return
	}
	var input RuntimeConfigInstallInput
	if !bindJSON(c, &input) {
		return
	}
	s.cfgMu.Lock()
	defer s.cfgMu.Unlock()
	if err := s.runtimeConfig.Install(c.Request.Context(), input); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	effective, err := s.runtimeConfig.EffectiveConfig(c.Request.Context(), s.cfg)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	s.applyConfigLocked(effective)
	status, err := s.runtimeConfig.Status(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusCreated, status)
}

func (s *Server) setupTest(c *gin.Context) {
	if s.runtimeConfig == nil {
		errorJSON(c, http.StatusBadRequest, errors.New("database runtime configuration is unavailable"))
		return
	}
	if !s.limiter.Check(c, "setup.test", 12, 10*time.Minute) {
		return
	}
	var input RuntimeConfigInstallInput
	if !bindJSON(c, &input) {
		return
	}
	input.normalize()
	if err := input.validate(); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	valid, err := s.runtimeConfig.VerifyInstallCode(c.Request.Context(), input.InstallCode)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	if !valid {
		errorJSON(c, http.StatusUnauthorized, errors.New("invalid install code"))
		return
	}
	for _, credential := range []struct {
		name  string
		token string
	}{
		{name: "write token", token: input.GitHubWriteToken},
		{name: "indexer read token", token: input.GitHubIndexToken},
	} {
		githubConfig := s.cfg
		githubConfig.LedgerGitHubOwner = input.GitHubOwner
		githubConfig.LedgerGitHubRepo = input.GitHubRepo
		githubConfig.LedgerGitBranch = input.GitHubBranch
		githubConfig.LedgerGitHubAPIURL = input.GitHubAPIURL
		githubConfig.LedgerGitHubToken = credential.token
		client, err := newGitHubLedgerClient(githubConfig)
		if err != nil {
			errorJSON(c, http.StatusBadRequest, err)
			return
		}
		if _, _, err := client.client.Repositories.Get(c.Request.Context(), client.owner, client.repo); err != nil {
			errorJSON(c, http.StatusBadRequest, errors.New("GitHub "+credential.name+" verification failed: "+err.Error()))
			return
		}
	}
	model := openAICompatibleAgentClient{resolve: func(context.Context) (aiProviderConfig, error) {
		return aiProviderConfig{apiKey: input.AIAPIKey, baseURL: input.AIBaseURL, model: input.AIModel}, nil
	}}
	result, err := model.Complete(c.Request.Context(), "Call the configuration_ok tool exactly once.", []agentModelMessage{{Role: "user", Content: "Verify tool calling."}}, []agentToolSpec{{
		Name: "configuration_ok", Description: "Confirm that tool calling works.", Parameters: map[string]any{"type": "object", "properties": map[string]any{}, "additionalProperties": false},
	}})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, errors.New("AI tool-call verification failed: "+err.Error()))
		return
	}
	if len(result.ToolCalls) != 1 || result.ToolCalls[0].Function.Name != "configuration_ok" {
		errorJSON(c, http.StatusBadRequest, errors.New("AI provider responded but did not execute the verification tool"))
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "github": true, "aiToolCalling": true})
}

func (s *Server) runtimeConfigStatus(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	if s.runtimeConfig == nil {
		c.JSON(http.StatusOK, gin.H{"setupComplete": true, "configSource": "environment"})
		return
	}
	status, err := s.runtimeConfig.Status(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusServiceUnavailable, err)
		return
	}
	c.JSON(http.StatusOK, status)
}

func (s *Server) runtimeConfigUpdate(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	if s.runtimeConfig == nil {
		errorJSON(c, http.StatusBadRequest, errors.New("database runtime configuration is unavailable"))
		return
	}
	var input RuntimeConfigUpdateInput
	if !bindJSON(c, &input) {
		return
	}
	s.cfgMu.Lock()
	defer s.cfgMu.Unlock()
	if err := s.runtimeConfig.Update(c.Request.Context(), input); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	effective, err := s.runtimeConfig.EffectiveConfig(c.Request.Context(), s.cfg)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	s.applyConfigLocked(effective)
	status, err := s.runtimeConfig.Status(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, status)
}
