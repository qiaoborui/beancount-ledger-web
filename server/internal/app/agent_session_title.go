package app

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
)

const (
	agentSessionTitleTimeout       = 15 * time.Second
	agentSessionTitleQuestionLimit = 4000
	agentSessionTitleAnswerLimit   = 12000
	agentSessionTitleMessageLimit  = 2000
	agentSessionTitleMinRunes      = 2
	agentSessionTitleMaxRunes      = 28
)

const agentSessionTitleSystemPrompt = "你负责为个人账本助手的对话生成简短标题。" +
	"只输出一个 4 到 24 个字符的标题，不要 Markdown、引号、序号或解释。" +
	"标题概括这次对话要办的事，用用户提问的语言，不要重复账本数据结构。"

// AgentSessionTitleRequest asks for a title for one agent conversation. The
// first question and the first answer are enough to name a session, so the
// client sends those instead of the whole timeline.
type AgentSessionTitleRequest struct {
	Question string `json:"question"`
	Answer   string `json:"answer"`
}

func (r AgentSessionTitleRequest) Validate() error {
	if strings.TrimSpace(r.Question) == "" {
		return errors.New("question is required")
	}
	if len(r.Question) > agentSessionTitleQuestionLimit {
		return errors.New("question is too long")
	}
	if len(r.Answer) > agentSessionTitleAnswerLimit {
		return errors.New("answer is too long")
	}
	return nil
}

func (s *Server) aiAgentSessionTitle(c *gin.Context) {
	if !s.limiter.Check(c, "ai.agent_title", 60, 5*time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input AgentSessionTitleRequest
	if !bindJSON(c, &input) {
		return
	}
	if err := input.Validate(); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	title, err := s.generateAgentSessionTitle(c.Request.Context(), input.Question, input.Answer)
	if err != nil {
		errorJSON(c, http.StatusServiceUnavailable, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"title": title})
}

// generateAgentSessionTitle names one conversation from its opening exchange.
// It is best effort: callers fall back to the first question when the model is
// unavailable, so a title failure must never block the turn.
func (s *Server) generateAgentSessionTitle(ctx context.Context, question, answer string) (string, error) {
	titleCtx, cancel := context.WithTimeout(ctx, agentSessionTitleTimeout)
	defer cancel()
	content := "用户提问：\n" + clipAgentTitleText(question, agentSessionTitleMessageLimit)
	if trimmed := strings.TrimSpace(answer); trimmed != "" {
		content += "\n\n助手回答：\n" + clipAgentTitleText(trimmed, agentSessionTitleMessageLimit)
	}
	result, err := s.modelClient().Complete(titleCtx, agentSessionTitleSystemPrompt, []agentModelMessage{{Role: "user", Content: content}}, nil)
	if err != nil {
		return "", err
	}
	if len(result.ToolCalls) > 0 {
		return "", errors.New("AI returned an unexpected tool call")
	}
	return normalizeAgentSessionTitle(result.Content)
}

func clipAgentTitleText(value string, limit int) string {
	trimmed := strings.TrimSpace(value)
	if utf8.RuneCountInString(trimmed) <= limit {
		return trimmed
	}
	runes := []rune(trimmed)
	return string(runes[:limit])
}

// normalizeAgentSessionTitle reduces a model reply to one short title. It peels
// one layer per pass so `**标题：修复流水**。` unwraps through the trailing
// punctuation, the bold markers, and the label instead of only the first layer.
func normalizeAgentSessionTitle(value string) (string, error) {
	lines := strings.FieldsFunc(value, func(r rune) bool { return r == '\n' || r == '\r' })
	if len(lines) == 0 {
		return "", errors.New("title is required")
	}
	title := strings.TrimSpace(lines[0])
	for {
		before := title
		title = strings.TrimSpace(title)
		title = strings.Trim(title, "`\\\"'*")
		title = strings.TrimRight(title, "。.!！?？,，、；;：:")
		for _, prefix := range []string{"标题", "会话标题", "Title", "title"} {
			if rest, found := strings.CutPrefix(title, prefix); found {
				title = strings.TrimSpace(strings.TrimLeft(rest, "：:"))
			}
		}
		title = strings.TrimSpace(title)
		if title == before {
			break
		}
	}
	if title == "" {
		return "", errors.New("title is required")
	}
	if utf8.RuneCountInString(title) < agentSessionTitleMinRunes {
		return "", errors.New("title is too short")
	}
	runes := []rune(title)
	if len(runes) > agentSessionTitleMaxRunes {
		title = strings.TrimSpace(string(runes[:agentSessionTitleMaxRunes]))
	}
	if title == "" {
		return "", errors.New("title is too long")
	}
	return title, nil
}
