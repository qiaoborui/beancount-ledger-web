package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

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
	logDuration("ai.parse", start, map[string]any{"entries": len(entries)})
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
	input.SessionID = normalizeAgentSessionID(input.SessionID)
	input.Context.SensitiveUnlocked = isSensitiveUnlocked(c)
	if err := s.appendAgentTimelineItem(c.Request.Context(), input.SessionID, agentTimelineMessage("user", input.Message)); err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	prepareSSE(c)
	start := time.Now()
	err := s.runAgentTurn(c.Request.Context(), input, func(event string, payload any) error {
		return writeSSEEvent(c, event, payload)
	})
	logDuration("ai.agent.turn", start, nil)
	if err != nil {
		_ = writeSSEEvent(c, "error", gin.H{"error": err.Error()})
	}
}

func (s *Server) aiAgentApproval(c *gin.Context) {
	if !s.limiter.Check(c, "ai.agent_approval", 30, 5*time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input AgentApprovalRequest
	if !bindJSON(c, &input) {
		return
	}
	prepareSSE(c)
	pageContext := AgentPageContext{SensitiveUnlocked: isSensitiveUnlocked(c)}
	start := time.Now()
	err := s.resolveAgentApproval(c.Request.Context(), input, pageContext, func(event string, payload any) error {
		return writeSSEEvent(c, event, payload)
	})
	logDuration("ai.agent.approval", start, nil)
	if err != nil {
		_ = writeSSEEvent(c, "error", gin.H{"error": err.Error()})
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
	page, err := s.agentTimelinePage(c.Request.Context(), sessionID, before, agentTimelinePageLimit)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, page)
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
