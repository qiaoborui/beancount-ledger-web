package app

import (
	"encoding/json"
	"fmt"
	"net/http"
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

func (s *Server) aiChat(c *gin.Context) {
	if !s.limiter.Check(c, "ai.chat", 20, 5*time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input AIChatRequest
	if !bindJSON(c, &input) {
		return
	}
	if strings.TrimSpace(input.Message) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid chat request"})
		return
	}
	if input.Stream {
		s.aiChatStream(c, input)
		return
	}
	start := time.Now()
	result, err := s.chatBookkeeping(input.Message, input.Messages, input.DraftEntries, time.Now().Format("2006-01-02"))
	elapsed := time.Since(start).Milliseconds()
	logDuration("ai.chat", start, map[string]any{"entries": len(result.Entries)})
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error(), "meta": gin.H{"elapsedMs": elapsed}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": result.Message, "plan": result.Plan, "entries": result.Entries, "meta": gin.H{"elapsedMs": elapsed}})
}

func (s *Server) aiAccountsChat(c *gin.Context) {
	if !s.limiter.Check(c, "ai.accounts_chat", 20, 5*time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input AIAccountChatRequest
	if !bindJSON(c, &input) {
		return
	}
	if strings.TrimSpace(input.Message) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid account chat request"})
		return
	}
	if input.Stream {
		s.aiAccountsChatStream(c, input)
		return
	}
	start := time.Now()
	result, err := s.chatAccounts(input.Message, input.Messages, input.DraftOperations, time.Now().Format("2006-01-02"))
	elapsed := time.Since(start).Milliseconds()
	logDuration("ai.accounts_chat", start, map[string]any{"operations": len(result.Operations)})
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error(), "meta": gin.H{"elapsedMs": elapsed}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": result.Message, "plan": result.Plan, "operations": result.Operations, "meta": gin.H{"elapsedMs": elapsed}})
}

func (s *Server) aiChatStream(c *gin.Context, input AIChatRequest) {
	start := time.Now()
	prepareSSE(c)
	result, err := s.streamChatBookkeeping(input.Message, input.Messages, input.DraftEntries, time.Now().Format("2006-01-02"), func(message string) error {
		return writeSSEEvent(c, "message", gin.H{"text": message})
	})
	elapsed := time.Since(start).Milliseconds()
	logDuration("ai.chat.stream", start, map[string]any{"entries": len(result.Entries)})
	if err != nil {
		_ = writeSSEEvent(c, "error", gin.H{"error": err.Error(), "meta": gin.H{"elapsedMs": elapsed}})
		return
	}
	_ = writeSSEEvent(c, "final", gin.H{"message": result.Message, "plan": result.Plan, "entries": result.Entries, "meta": gin.H{"elapsedMs": elapsed}})
}

func (s *Server) aiAccountsChatStream(c *gin.Context, input AIAccountChatRequest) {
	start := time.Now()
	prepareSSE(c)
	result, err := s.streamChatAccounts(input.Message, input.Messages, input.DraftOperations, time.Now().Format("2006-01-02"), func(message string) error {
		return writeSSEEvent(c, "message", gin.H{"text": message})
	})
	elapsed := time.Since(start).Milliseconds()
	logDuration("ai.accounts_chat.stream", start, map[string]any{"operations": len(result.Operations)})
	if err != nil {
		_ = writeSSEEvent(c, "error", gin.H{"error": err.Error(), "meta": gin.H{"elapsedMs": elapsed}})
		return
	}
	_ = writeSSEEvent(c, "final", gin.H{"message": result.Message, "plan": result.Plan, "operations": result.Operations, "meta": gin.H{"elapsedMs": elapsed}})
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
