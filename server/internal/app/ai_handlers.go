package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

const agentTurnDetachedTimeout = 5 * time.Minute

func (s *Server) aiParse(c *gin.Context) {
	if !s.limiter.Check(c, "ai.parse", 20, 5*time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input AIParseRequest
	if !bindJSON(c, &input) {
		return
	}
	if strings.TrimSpace(input.Input) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "input is required"})
		return
	}
	start := time.Now()
	entries, err := s.parseNaturalLanguage(input.Input, time.Now().Format("2006-01-02"))
	s.logDuration("ai.parse", start, map[string]any{"entries": len(entries)})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	var first any
	if len(entries) > 0 {
		first = entries[0]
	}
	c.JSON(http.StatusOK, gin.H{"entries": entries, "entry": first})
}

func (s *Server) aiAgentTurn(c *gin.Context) {
	if !s.limiter.Check(c, "ai.agent_turn", 30, 5*time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input AgentTurnRequest
	if !bindJSON(c, &input) {
		return
	}
	start := time.Now()
	err := s.proxyLedgerAgentTurn(c, input)
	s.logDuration("ai.agent.turn", start, nil)
	if err != nil {
		if !c.Writer.Written() {
			errorJSON(c, http.StatusBadGateway, err)
		}
	}
}

func (s *Server) aiAgentTimeline(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	sessionID := normalizeAgentSessionID(c.Param("sessionID"))
	before := 0
	if raw := c.Query("before"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 1 {
			errorJSON(c, http.StatusBadRequest, errors.New("before must be a positive integer"))
			return
		}
		before = value
	}
	path := fmt.Sprintf("/v1/sessions/%s/timeline", url.PathEscape(sessionID))
	if before > 0 {
		path += "?before=" + strconv.Itoa(before)
	}
	response, err := s.agentServiceRequest(c.Request.Context(), http.MethodGet, path, nil)
	if err != nil {
		errorJSON(c, http.StatusBadGateway, err)
		return
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		errorJSON(c, response.StatusCode, agentServiceResponseError(response))
		return
	}
	c.Status(response.StatusCode)
	_, _ = io.Copy(c.Writer, response.Body)
}

func (s *Server) aiAgentSessionDelete(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	rawSessionID := c.Param("sessionID")
	sessionID := normalizeAgentSessionID(rawSessionID)
	if rawSessionID != sessionID {
		errorJSON(c, http.StatusBadRequest, errors.New("invalid session ID"))
		return
	}
	response, err := s.agentServiceRequest(c.Request.Context(), http.MethodDelete, "/v1/sessions/"+url.PathEscape(sessionID), nil)
	if err != nil {
		errorJSON(c, http.StatusBadGateway, err)
		return
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		errorJSON(c, response.StatusCode, agentServiceResponseError(response))
		return
	}
	c.Status(http.StatusNoContent)
}

func prepareSSE(c *gin.Context) {
	c.Header("Content-Type", "text/event-stream; charset=utf-8")
	c.Header("Cache-Control", "no-cache")
	c.Header("Connection", "keep-alive")
	c.Status(http.StatusOK)
	c.Writer.Flush()
}

func writeSSEEvent(c *gin.Context, event string, payload any) error {
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(c.Writer, "event: %s\ndata: %s\n\n", event, raw); err != nil {
		return err
	}
	c.Writer.Flush()
	return nil
}
