package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// parseNaturalLanguage remains as the quick-entry parser. Conversational AI
// uses the unified Agent runtime in agent.go.
func (s *Server) parseNaturalLanguage(input, today string) ([]LedgerEntry, error) {
	snapshot, err := s.ledgerSnapshot(context.Background())
	if err != nil {
		return nil, err
	}
	accounts := activeAccounts(snapshot.Accounts)
	content, err := s.runStructuredAI(context.Background(), parserPrompt(today, accounts), input)
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

func parserPrompt(today string, accounts []string) string {
	return "你是一个 Beancount 记账解析器。只输出 JSON，不要 Markdown。今天日期：" + today + `。
只能使用这些账户；posting currency 使用对应账户在账本中定义的 commodity，常见为 CNY：
- ` + strings.Join(accounts, "\n- ") + `

输出 {"entries":[{"kind":"transaction","date":"YYYY-MM-DD","payee":"商户/对方","narration":"说明","metadata":{},"tags":[],"postings":[{"account":"账户","amount":"12.00","currency":"CNY"},{"account":"账户","amount":"-12.00","currency":"CNY"}],"confidence":0.9,"needsReview":false,"questions":[]}]}。
每条交易每个 currency 下的 postings 金额合计必须为 0；不确定分类用 Expenses:Unknown 并 needsReview=true；没有日期用今天。`
}

func (s *Server) runStructuredAI(ctx context.Context, system, input string) (string, error) {
	provider, err := s.resolveAIProviderConfig(ctx)
	if err != nil {
		return "", err
	}
	body := map[string]any{
		"model": provider.model,
		"messages": []map[string]string{
			{"role": "system", "content": system},
			{"role": "user", "content": input},
		},
		"temperature":     0,
		"response_format": map[string]string{"type": "json_object"},
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(provider.baseURL, "/")+"/chat/completions", bytes.NewReader(raw))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+provider.apiKey)
	req.Header.Set("Content-Type", "application/json")
	res, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		content, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
		return "", fmt.Errorf("AI request failed: %s", strings.TrimSpace(string(content)))
	}
	var parsed struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(res.Body).Decode(&parsed); err != nil {
		return "", err
	}
	if len(parsed.Choices) == 0 || strings.TrimSpace(parsed.Choices[0].Message.Content) == "" {
		return "", errors.New("AI returned empty content")
	}
	return parsed.Choices[0].Message.Content, nil
}

func (s *Server) resolveAIProviderConfig(ctx context.Context) (aiProviderConfig, error) {
	if s != nil && s.runtimeConfig != nil {
		return s.runtimeConfig.AIProviderConfig(ctx)
	}
	return resolveAIProviderConfig()
}

type aiProviderConfig struct {
	apiKey  string
	baseURL string
	model   string
}

func resolveAIProviderConfig() (aiProviderConfig, error) {
	provider := strings.ToLower(strings.TrimSpace(os.Getenv("LEDGER_AI_PROVIDER")))
	if provider == "" {
		switch {
		case strings.TrimSpace(os.Getenv("DEEPSEEK_API_KEY")) != "":
			provider = "deepseek"
		case strings.TrimSpace(os.Getenv("OPENAI_API_KEY")) != "":
			provider = "openai"
		default:
			return aiProviderConfig{}, errors.New("AI provider is not configured: set DEEPSEEK_API_KEY or OPENAI_API_KEY")
		}
	}
	if provider == "deepseek" {
		apiKey := os.Getenv("DEEPSEEK_API_KEY")
		if strings.TrimSpace(apiKey) == "" {
			return aiProviderConfig{}, errors.New("DEEPSEEK_API_KEY is not configured")
		}
		return aiProviderConfig{
			apiKey:  apiKey,
			baseURL: env("DEEPSEEK_BASE_URL", "https://api.deepseek.com"),
			model:   env("DEEPSEEK_MODEL", "deepseek-chat"),
		}, nil
	}
	apiKey := os.Getenv("OPENAI_API_KEY")
	if strings.TrimSpace(apiKey) == "" {
		return aiProviderConfig{}, errors.New("OPENAI_API_KEY is not configured")
	}
	return aiProviderConfig{
		apiKey:  apiKey,
		baseURL: env("OPENAI_BASE_URL", "https://api.openai.com/v1"),
		model:   env("OPENAI_MODEL", "gpt-4.1-mini"),
	}, nil
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
		totals := map[string]int{}
		for _, posting := range entry.Postings {
			if !accountSet[posting.Account] {
				return nil, fmt.Errorf("第 %d 条 AI 使用了不存在的账户：%s", index+1, posting.Account)
			}
			currency := posting.Currency
			if currency == "" {
				currency = "CNY"
			}
			totals[currency] += cents(posting.Amount)
		}
		for currency, total := range totals {
			if total != 0 {
				return nil, fmt.Errorf("第 %d 条 AI 生成的分录不平衡，差额 %s %s", index+1, fromCents(total), currency)
			}
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
