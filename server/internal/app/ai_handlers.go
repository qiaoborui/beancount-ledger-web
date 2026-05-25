package app

import (
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
	start := time.Now()
	result, err := s.chatBookkeeping(input.Message, input.Messages, input.DraftEntries, time.Now().Format("2006-01-02"))
	elapsed := time.Since(start).Milliseconds()
	logDuration("ai.chat", start, map[string]any{"entries": len(result.Entries)})
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error(), "meta": gin.H{"elapsedMs": elapsed}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": result.Message, "entries": result.Entries, "meta": gin.H{"elapsedMs": elapsed}})
}

func (s *Server) aiTransactionCategory(c *gin.Context) {
	if !s.limiter.Check(c, "ai.transaction-category", 20, 5*time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input AITransactionCategoryRequest
	if !bindJSON(c, &input) {
		return
	}
	start := time.Now()
	suggestion, newAccounts, err := s.resolveTransactionCategory(input.Entry, input.Instruction)
	elapsed := time.Since(start).Milliseconds()
	logDuration("ai.transaction-category", start, map[string]any{"newAccounts": len(newAccounts)})
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error(), "meta": gin.H{"elapsedMs": elapsed}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"suggestion": suggestion, "newAccounts": newAccounts, "meta": gin.H{"elapsedMs": elapsed}})
}
