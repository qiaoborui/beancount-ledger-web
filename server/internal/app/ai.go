package app

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
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

type ImportCategorySuggestion struct {
	EntryID         string  `json:"entryId"`
	CategoryAccount string  `json:"categoryAccount"`
	Alias           string  `json:"alias,omitempty"`
	Reason          string  `json:"reason,omitempty"`
	Confidence      float64 `json:"confidence,omitempty"`
	IsNew           bool    `json:"isNew"`
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

func (s *Server) resolveTransactionCategory(entry ImportEntry, instruction string) (ImportCategorySuggestion, []ImportNewAccount, error) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return ImportCategorySuggestion{}, nil, err
	}
	existingCategories := importCategoryAccounts(snapshot.Accounts)
	payload := ginH{
		"instruction": strings.TrimSpace(instruction),
		"entry": ginH{
			"id":              entry.ID,
			"date":            entry.Date,
			"payee":           entry.Payee,
			"narration":       entry.Narration,
			"amount":          entry.Amount,
			"method":          entry.Method,
			"txType":          entry.TxType,
			"type":            entry.Type,
			"currentCategory": entry.CategoryAccount,
			"metadata":        entry.Metadata,
		},
	}
	content, err := runAI(transactionCategoryPrompt(categoryAccountLines(snapshot.Accounts)), mustJSON(payload), false)
	if err != nil {
		return ImportCategorySuggestion{}, nil, err
	}
	var parsed struct {
		Suggestion  ImportCategorySuggestion   `json:"suggestion"`
		Suggestions []ImportCategorySuggestion `json:"suggestions,omitempty"`
	}
	if err := json.Unmarshal([]byte(extractJSON(content)), &parsed); err != nil {
		return ImportCategorySuggestion{}, nil, err
	}
	suggestion := parsed.Suggestion
	if suggestion.EntryID == "" && len(parsed.Suggestions) > 0 {
		suggestion = parsed.Suggestions[0]
	}
	if suggestion.EntryID == "" {
		suggestion.EntryID = entry.ID
	}
	suggestions, newAccounts, err := validateImportCategorySuggestions([]ImportCategorySuggestion{suggestion}, map[string]bool{entry.ID: true}, existingCategories)
	if err != nil {
		return ImportCategorySuggestion{}, nil, err
	}
	if len(suggestions) == 0 {
		return ImportCategorySuggestion{}, nil, errors.New("AI 没有返回分类建议")
	}
	return suggestions[0], newAccounts, nil
}

func parserPrompt(today string, accounts []string) string {
	return "你是一个 Beancount 记账解析器。只输出 JSON，不要 Markdown。今天日期：" + today + `。
币种固定 CNY。只能使用这些账户：
- ` + strings.Join(accounts, "\n- ") + `

输出 {"entries":[{"kind":"transaction","date":"YYYY-MM-DD","payee":"商户/对方","narration":"说明","metadata":{},"tags":[],"postings":[{"account":"账户","amount":"12.00","currency":"CNY"},{"account":"账户","amount":"-12.00","currency":"CNY"}],"confidence":0.9,"needsReview":false,"questions":[]}]}。
每条交易 postings 金额合计必须为 0；不确定分类用 Expenses:Unknown 并 needsReview=true；没有日期用今天。`
}

func transactionCategoryPrompt(existingCategories []string) string {
	return `你是 Beancount 流水分类纠正助手。只输出 JSON，不要 Markdown。
用户正在编辑一笔已经存在的流水，并会用 instruction 告诉你“这笔应该是哪一类”。

已有分类如下，格式为 账户名 | 显示名：
- ` + strings.Join(existingCategories, "\n- ") + `

规则：
- 不要根据商户或金额自行猜分类；instruction 是主要依据。
- 先在已有分类中按账户名、显示名、中文含义、英文含义做匹配。能匹配到就必须复用已有分类。
- 只有已有分类都表达不了用户指定类别时，才可以创建新分类。
- 只允许 Expenses:* 或 Income:*。
- 账户名必须是英文/数字/下划线/连字符组成的 Beancount 账户，例如 Expenses:Pets:Food 或 Income:Bonus。
- 新分类必须给出简短中文 alias。
- 如果用户说的是模糊的上级概念，优先使用已有最接近的上级或子分类；实在不确定才用 Expenses:Unknown。

输出 {"suggestion":{"entryId":"输入流水 id","categoryAccount":"Expenses:Food","alias":"新分类中文名，可选","reason":"简短原因","confidence":0.85,"isNew":false}}。`
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

func importCategoryAccounts(accounts []Account) []string {
	out := []string{}
	for _, account := range accounts {
		if account.Active && (strings.HasPrefix(account.Account, "Expenses:") || strings.HasPrefix(account.Account, "Income:")) {
			out = append(out, account.Account)
		}
	}
	return out
}

func categoryAccountLines(accounts []Account) []string {
	out := []string{}
	for _, account := range accounts {
		if account.Active && (strings.HasPrefix(account.Account, "Expenses:") || strings.HasPrefix(account.Account, "Income:")) {
			out = append(out, account.Account+" | "+account.Label)
		}
	}
	return out
}

func validateImportCategorySuggestions(suggestions []ImportCategorySuggestion, entryIDs map[string]bool, existingCategories []string) ([]ImportCategorySuggestion, []ImportNewAccount, error) {
	existingSet := map[string]bool{}
	for _, account := range existingCategories {
		existingSet[account] = true
	}
	seenEntries := map[string]bool{}
	newAccountsByName := map[string]ImportNewAccount{}
	out := []ImportCategorySuggestion{}
	for _, suggestion := range suggestions {
		suggestion.EntryID = strings.TrimSpace(suggestion.EntryID)
		suggestion.CategoryAccount = strings.TrimSpace(suggestion.CategoryAccount)
		suggestion.Alias = strings.TrimSpace(suggestion.Alias)
		suggestion.Reason = strings.TrimSpace(suggestion.Reason)
		if !entryIDs[suggestion.EntryID] || seenEntries[suggestion.EntryID] {
			continue
		}
		if err := validateAccount("categoryAccount", suggestion.CategoryAccount); err != nil {
			return nil, nil, err
		}
		isExisting := existingSet[suggestion.CategoryAccount]
		if !isExisting {
			if !strings.HasPrefix(suggestion.CategoryAccount, "Expenses:") && !strings.HasPrefix(suggestion.CategoryAccount, "Income:") {
				return nil, nil, fmt.Errorf("AI 建议了非法分类账户：%s", suggestion.CategoryAccount)
			}
			if suggestion.Alias == "" {
				suggestion.Alias = importAccountAlias(suggestion.CategoryAccount)
			}
			suggestion.IsNew = true
			if _, ok := newAccountsByName[suggestion.CategoryAccount]; !ok {
				newAccountsByName[suggestion.CategoryAccount] = ImportNewAccount{Account: suggestion.CategoryAccount, Alias: suggestion.Alias}
			}
		} else {
			suggestion.IsNew = false
			suggestion.Alias = ""
		}
		seenEntries[suggestion.EntryID] = true
		out = append(out, suggestion)
	}
	newAccounts := make([]ImportNewAccount, 0, len(newAccountsByName))
	for _, account := range newAccountsByName {
		newAccounts = append(newAccounts, account)
	}
	sort.Slice(newAccounts, func(i, j int) bool { return newAccounts[i].Account < newAccounts[j].Account })
	return out, newAccounts, nil
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
