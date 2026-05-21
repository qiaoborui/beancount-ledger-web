package app

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

type ChatMessage struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

type ChatResult struct {
	Message string        `json:"message"`
	Entries []LedgerEntry `json:"entries"`
}

func (s *Server) parseNaturalLanguage(input, today string) ([]LedgerEntry, error) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return nil, err
	}
	accounts := activeAccounts(snapshot.Accounts)
	content, err := runAI(parserPrompt(today, accounts), input, false)
	if err != nil {
		return nil, err
	}
	var parsed struct {
		Entries []LedgerEntry `json:"entries"`
	}
	if err := json.Unmarshal([]byte(extractJSON(content)), &parsed); err != nil {
		return nil, err
	}
	if len(parsed.Entries) == 0 {
		return nil, errors.New("AI 没有返回交易")
	}
	return validateAIEntries(parsed.Entries, accounts)
}

func (s *Server) chatBookkeeping(message string, messages []ChatMessage, draft []LedgerEntry, today string) (ChatResult, error) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return ChatResult{}, err
	}
	accounts := activeAccounts(snapshot.Accounts)
	if _, err := validateAIEntries(draft, accounts); err != nil {
		return ChatResult{}, err
	}
	conversation := []string{}
	for _, item := range messages {
		role := "用户"
		if item.Role == "assistant" {
			role = "助理"
		}
		conversation = append(conversation, role+"："+item.Text)
	}
	payload := fmt.Sprintf("当前草稿 entries:\n%s\n\n最近对话:\n%s\n\n用户最新消息:\n%s", mustJSON(draft), strings.Join(conversation, "\n"), message)
	content, err := runAI(parserPrompt(today, accounts)+`\n\n你是聊天式 AI 记账助理。只输出 {"message":"中文回复","entries":[...完整草稿...]}。如果用户只是问能力且没有流水，entries 返回当前草稿或空数组。`, payload, true)
	if err != nil {
		return ChatResult{}, err
	}
	var parsed ChatResult
	if err := json.Unmarshal([]byte(extractJSON(content)), &parsed); err != nil {
		return ChatResult{}, err
	}
	entries, err := validateAIEntries(parsed.Entries, accounts)
	if err != nil {
		return ChatResult{}, err
	}
	if strings.TrimSpace(parsed.Message) == "" {
		parsed.Message = fmt.Sprintf("已更新 %d 条预览。", len(entries))
	}
	parsed.Entries = entries
	return parsed, nil
}

func parserPrompt(today string, accounts []string) string {
	return "你是一个 Beancount 记账解析器。只输出 JSON，不要 Markdown。今天日期：" + today + `。
币种固定 CNY。只能使用这些账户：
- ` + strings.Join(accounts, "\n- ") + `

输出 {"entries":[{"kind":"transaction","date":"YYYY-MM-DD","payee":"商户/对方","narration":"说明","metadata":{},"tags":[],"postings":[{"account":"账户","amount":"12.00","currency":"CNY"},{"account":"账户","amount":"-12.00","currency":"CNY"}],"confidence":0.9,"needsReview":false,"questions":[]}]}。
每条交易 postings 金额合计必须为 0；不确定分类用 Expenses:Unknown 并 needsReview=true；没有日期用今天。`
}

func runAI(system, input string, chat bool) (string, error) {
	provider := strings.ToLower(env("LEDGER_AI_PROVIDER", "deepseek"))
	apiKey, baseURL, model := os.Getenv("DEEPSEEK_API_KEY"), env("DEEPSEEK_BASE_URL", "https://api.deepseek.com"), env("DEEPSEEK_MODEL", "deepseek-chat")
	if provider != "deepseek" {
		apiKey, baseURL, model = os.Getenv("OPENAI_API_KEY"), env("OPENAI_BASE_URL", "https://api.openai.com/v1"), env("OPENAI_MODEL", "gpt-4.1-mini")
	}
	if apiKey == "" {
		if provider == "deepseek" {
			return "", errors.New("DEEPSEEK_API_KEY is not configured")
		}
		return "", errors.New("OPENAI_API_KEY is not configured")
	}
	body := map[string]any{
		"model": model,
		"messages": []map[string]string{
			{"role": "system", "content": system},
			{"role": "user", "content": input},
		},
		"temperature":     0,
		"response_format": map[string]string{"type": "json_object"},
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(baseURL, "/")+"/chat/completions", bytes.NewReader(raw))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 60 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	content, _ := io.ReadAll(res.Body)
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return "", fmt.Errorf("AI request failed: %s", strings.TrimSpace(string(content)))
	}
	var parsed struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(content, &parsed); err != nil {
		return "", err
	}
	if len(parsed.Choices) == 0 || strings.TrimSpace(parsed.Choices[0].Message.Content) == "" {
		return "", errors.New("AI returned empty content")
	}
	return parsed.Choices[0].Message.Content, nil
}

func activeAccounts(accounts []Account) []string {
	out := []string{}
	for _, account := range accounts {
		if account.Active {
			out = append(out, account.Account)
		}
	}
	return out
}

func validateAIEntries(entries []LedgerEntry, accounts []string) ([]LedgerEntry, error) {
	accountSet := map[string]bool{}
	for _, account := range accounts {
		accountSet[account] = true
	}
	for index, entry := range entries {
		if entry.Kind == "" {
			entry.Kind = "transaction"
			entries[index].Kind = "transaction"
		}
		var total int
		for _, posting := range entry.Postings {
			if !accountSet[posting.Account] {
				return nil, fmt.Errorf("第 %d 条 AI 使用了不存在的账户：%s", index+1, posting.Account)
			}
			total += cents(posting.Amount)
		}
		if total != 0 {
			return nil, fmt.Errorf("第 %d 条 AI 生成的分录不平衡，差额 %s CNY", index+1, fromCents(total))
		}
	}
	return entries, nil
}

func extractJSON(content string) string {
	trimmed := strings.TrimSpace(content)
	if strings.HasPrefix(trimmed, "{") && strings.HasSuffix(trimmed, "}") {
		return trimmed
	}
	if start := strings.Index(trimmed, "{"); start >= 0 {
		if end := strings.LastIndex(trimmed, "}"); end > start {
			return trimmed[start : end+1]
		}
	}
	return trimmed
}

func mustJSON(value any) string {
	raw, _ := json.MarshalIndent(value, "", "  ")
	return string(raw)
}
