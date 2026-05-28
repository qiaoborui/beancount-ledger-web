package app

import (
	"bufio"
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

type ChatPlan struct {
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Steps       []string `json:"steps"`
}

type ChatSource struct {
	Title       string `json:"title"`
	Description string `json:"description,omitempty"`
	Kind        string `json:"kind,omitempty"`
	Reference   string `json:"reference,omitempty"`
}

type ChatResult struct {
	Message string        `json:"message"`
	Plan    *ChatPlan     `json:"plan,omitempty"`
	Sources []ChatSource  `json:"sources,omitempty"`
	Entries []LedgerEntry `json:"entries"`
}

type AccountChatResult struct {
	Message    string             `json:"message"`
	Plan       *ChatPlan          `json:"plan,omitempty"`
	Sources    []ChatSource       `json:"sources,omitempty"`
	Operations []AccountOperation `json:"operations"`
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
	system, payload, accounts, err := s.bookkeepingChatPrompt(message, messages, draft, today)
	if err != nil {
		return ChatResult{}, err
	}
	content, err := runAI(system, payload, true)
	if err != nil {
		return ChatResult{}, err
	}
	return parseBookkeepingChatResult(content, accounts, len(draft))
}

func (s *Server) streamChatBookkeeping(message string, messages []ChatMessage, draft []LedgerEntry, today string, onMessage func(string) error, onStatus func(string) error) (ChatResult, error) {
	system, payload, accounts, err := s.bookkeepingChatPrompt(message, messages, draft, today)
	if err != nil {
		return ChatResult{}, err
	}
	if onStatus != nil {
		if err := onStatus("生成回复和处理计划"); err != nil {
			return ChatResult{}, err
		}
	}
	var buffer strings.Builder
	lastMessage := ""
	content, err := runAIStream(system, payload, func(delta string) error {
		buffer.WriteString(delta)
		message := partialJSONStringField(buffer.String(), "message")
		if message != "" && message != lastMessage {
			lastMessage = message
			if err := onMessage(message); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return ChatResult{}, err
	}
	if onStatus != nil {
		if err := onStatus("解析并校验分录草稿"); err != nil {
			return ChatResult{}, err
		}
	}
	result, err := parseBookkeepingChatResult(content, accounts, len(draft))
	if err != nil {
		return ChatResult{}, err
	}
	if onStatus != nil {
		if err := onStatus("预览已准备好"); err != nil {
			return ChatResult{}, err
		}
	}
	return result, nil
}

func (s *Server) bookkeepingChatPrompt(message string, messages []ChatMessage, draft []LedgerEntry, today string) (string, string, []string, error) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return "", "", nil, err
	}
	accounts := activeAccounts(snapshot.Accounts)
	if _, err := validateAIEntries(draft, accounts); err != nil {
		return "", "", nil, err
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
	system := parserPrompt(today, accounts) + `\n\n你是聊天式 AI 记账助理。只输出 {"message":"中文回复","plan":{"title":"计划标题","description":"一句话说明","steps":["步骤1","步骤2"]},"entries":[...完整草稿...]}。plan 是给用户确认前看的执行计划：有新增/调整草稿时用 2-4 个简短步骤说明你会如何分类、平衡和标记待确认问题；如果只是回答问题且没有草稿变化，plan 返回 null。entries 必须是本轮对话后的完整草稿；如果用户只是问能力且没有流水，entries 返回当前草稿或空数组。`
	return system, payload, accounts, nil
}

func parseBookkeepingChatResult(content string, accounts []string, draftCount int) (ChatResult, error) {
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
	parsed.Plan = normalizeChatPlan(parsed.Plan)
	parsed.Entries = entries
	parsed.Sources = bookkeepingChatSources(entries, accounts, draftCount)
	return parsed, nil
}

func (s *Server) chatAccounts(message string, messages []ChatMessage, draft []AccountOperation, today string) (AccountChatResult, error) {
	system, payload, accounts, err := s.accountsChatPrompt(message, messages, draft, today)
	if err != nil {
		return AccountChatResult{}, err
	}
	content, err := runAI(system, payload, true)
	if err != nil {
		return AccountChatResult{}, err
	}
	return parseAccountChatResult(content, accounts, len(draft))
}

func (s *Server) streamChatAccounts(message string, messages []ChatMessage, draft []AccountOperation, today string, onMessage func(string) error, onStatus func(string) error) (AccountChatResult, error) {
	system, payload, accounts, err := s.accountsChatPrompt(message, messages, draft, today)
	if err != nil {
		return AccountChatResult{}, err
	}
	if onStatus != nil {
		if err := onStatus("生成账户处理计划"); err != nil {
			return AccountChatResult{}, err
		}
	}
	var buffer strings.Builder
	lastMessage := ""
	content, err := runAIStream(system, payload, func(delta string) error {
		buffer.WriteString(delta)
		message := partialJSONStringField(buffer.String(), "message")
		if message != "" && message != lastMessage {
			lastMessage = message
			if err := onMessage(message); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return AccountChatResult{}, err
	}
	if onStatus != nil {
		if err := onStatus("解析并校验账户操作"); err != nil {
			return AccountChatResult{}, err
		}
	}
	result, err := parseAccountChatResult(content, accounts, len(draft))
	if err != nil {
		return AccountChatResult{}, err
	}
	if onStatus != nil {
		if err := onStatus("账户草稿已准备好"); err != nil {
			return AccountChatResult{}, err
		}
	}
	return result, nil
}

func (s *Server) accountsChatPrompt(message string, messages []ChatMessage, draft []AccountOperation, today string) (string, string, []Account, error) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return "", "", nil, err
	}
	if err := validateAccountOperations(draft, snapshot.Accounts); err != nil {
		return "", "", nil, err
	}
	conversation := []string{}
	for _, item := range messages {
		role := "用户"
		if item.Role == "assistant" {
			role = "助理"
		}
		conversation = append(conversation, role+"："+item.Text)
	}
	payload := fmt.Sprintf("当前账户操作草稿 operations:\n%s\n\n最近对话:\n%s\n\n用户最新消息:\n%s", mustJSON(draft), strings.Join(conversation, "\n"), message)
	return accountAgentPrompt(today, snapshot.Accounts), payload, snapshot.Accounts, nil
}

func parseAccountChatResult(content string, accounts []Account, draftCount int) (AccountChatResult, error) {
	var parsed AccountChatResult
	if err := json.Unmarshal([]byte(extractJSON(content)), &parsed); err != nil {
		return AccountChatResult{}, err
	}
	if err := validateAccountOperations(parsed.Operations, accounts); err != nil {
		return AccountChatResult{}, err
	}
	if strings.TrimSpace(parsed.Message) == "" {
		parsed.Message = fmt.Sprintf("已更新 %d 个账户操作草稿。", len(parsed.Operations))
	}
	parsed.Plan = normalizeChatPlan(parsed.Plan)
	parsed.Sources = accountChatSources(parsed.Operations, accounts, draftCount)
	return parsed, nil
}

func bookkeepingChatSources(entries []LedgerEntry, accounts []string, draftCount int) []ChatSource {
	sources := []ChatSource{{
		Title:       "当前账户表",
		Description: fmt.Sprintf("%d 个可用账户用于分类和平衡检查", len(accounts)),
		Kind:        "accounts",
		Reference:   "active accounts",
	}}
	if draftCount > 0 {
		sources = append(sources, ChatSource{
			Title:       "当前记账草稿",
			Description: fmt.Sprintf("沿用并更新了 %d 条待确认预览", draftCount),
			Kind:        "draft",
			Reference:   "draftEntries",
		})
	}
	seen := map[string]bool{}
	for _, entry := range entries {
		for _, posting := range entry.Postings {
			if posting.Account == "" || seen[posting.Account] {
				continue
			}
			seen[posting.Account] = true
			sources = append(sources, ChatSource{
				Title:       posting.Account,
				Description: "本次草稿使用的账户",
				Kind:        "account",
				Reference:   posting.Account,
			})
			if len(sources) >= 8 {
				return sources
			}
		}
	}
	for _, entry := range entries {
		if entry.NeedsReview {
			sources = append(sources, ChatSource{
				Title:       "待确认问题",
				Description: "AI 标记了需要人工复核的分类或字段",
				Kind:        "review",
				Reference:   "needsReview",
			})
			break
		}
	}
	return sources
}

func accountChatSources(operations []AccountOperation, accounts []Account, draftCount int) []ChatSource {
	sources := []ChatSource{{
		Title:       "accounts.bean 账户表",
		Description: fmt.Sprintf("%d 个现有账户用于冲突检查", len(accounts)),
		Kind:        "accounts",
		Reference:   "accounts",
	}}
	if draftCount > 0 {
		sources = append(sources, ChatSource{
			Title:       "当前账户操作草稿",
			Description: fmt.Sprintf("沿用并更新了 %d 个待确认操作", draftCount),
			Kind:        "draft",
			Reference:   "draftOperations",
		})
	}
	accountByName := map[string]Account{}
	for _, account := range accounts {
		accountByName[account.Account] = account
	}
	seen := map[string]bool{}
	for _, operation := range operations {
		if operation.Account == "" || seen[operation.Account] {
			continue
		}
		seen[operation.Account] = true
		description := "拟新增账户路径"
		if account, ok := accountByName[operation.Account]; ok {
			description = fmt.Sprintf("现有账户，分组 %s", account.Group)
			if !account.Active {
				description += "，当前已关闭"
			}
		}
		sources = append(sources, ChatSource{
			Title:       operation.Account,
			Description: description,
			Kind:        "account",
			Reference:   operation.Kind,
		})
		if len(sources) >= 8 {
			return sources
		}
	}
	return sources
}

func parserPrompt(today string, accounts []string) string {
	return "你是一个 Beancount 记账解析器。只输出 JSON，不要 Markdown。今天日期：" + today + `。
币种固定 CNY。只能使用这些账户：
- ` + strings.Join(accounts, "\n- ") + `

输出 {"entries":[{"kind":"transaction","date":"YYYY-MM-DD","payee":"商户/对方","narration":"说明","metadata":{},"tags":[],"postings":[{"account":"账户","amount":"12.00","currency":"CNY"},{"account":"账户","amount":"-12.00","currency":"CNY"}],"confidence":0.9,"needsReview":false,"questions":[]}]}。
每条交易 postings 金额合计必须为 0；不确定分类用 Expenses:Unknown 并 needsReview=true；没有日期用今天。`
}

func accountAgentPrompt(today string, accounts []Account) string {
	rows := make([]string, 0, len(accounts))
	for _, account := range accounts {
		active := "active"
		if !account.Active {
			active = "closed"
		}
		alias := ""
		if account.Alias != nil && strings.TrimSpace(*account.Alias) != "" {
			alias = " alias=" + *account.Alias
		}
		rows = append(rows, fmt.Sprintf("%s [%s] group=%s%s", account.Account, active, account.Group, alias))
	}
	return "你是一个 Beancount 账户管理助理。只输出 JSON，不要 Markdown。今天日期：" + today + `。
你可以帮助用户生成账户操作草稿，但不能直接写入。支持的操作：
- create: 创建账户，字段 kind,date,account,alias,currency,group。currency 固定 CNY，group 可用 cash/wealth/credit/receivable/expense/income/equity/other。
- update: 更新账户显示名或分组，字段 kind,date,account,alias,group。不要改 account 路径；如果用户想改路径，建议新建账户并关闭旧账户。
- disable: 禁用账户，即追加 close，字段 kind,date,account。

已有账户：
- ` + strings.Join(rows, "\n- ") + `

只输出 {"message":"中文回复","plan":{"title":"计划标题","description":"一句话说明","steps":["步骤1","步骤2"]},"operations":[...完整草稿...]}。
plan 是给用户确认前看的执行计划：有新增/调整账户操作草稿时用 2-4 个简短步骤说明你会创建、更新或关闭哪些账户以及原因；如果只是回答问题或需要追问且没有草稿变化，plan 返回 null。
operations 必须是本轮对话后的完整草稿；用户只是问问题时返回当前草稿或空数组。不要为已经存在的账户生成 create；不要为已关闭账户生成 disable；不确定时先追问并保持草稿不变。`
}

func normalizeChatPlan(plan *ChatPlan) *ChatPlan {
	if plan == nil {
		return nil
	}
	plan.Title = strings.TrimSpace(plan.Title)
	plan.Description = strings.TrimSpace(plan.Description)
	steps := make([]string, 0, len(plan.Steps))
	for _, step := range plan.Steps {
		step = strings.TrimSpace(step)
		if step != "" {
			steps = append(steps, step)
		}
		if len(steps) >= 4 {
			break
		}
	}
	plan.Steps = steps
	if plan.Title == "" && plan.Description == "" && len(plan.Steps) == 0 {
		return nil
	}
	if plan.Title == "" {
		plan.Title = "处理计划"
	}
	return plan
}

func runAI(system, input string, chat bool) (string, error) {
	content, err := runAIRequest(system, input, false, nil)
	if err != nil {
		return "", err
	}
	return content, nil
}

func runAIStream(system, input string, onDelta func(string) error) (string, error) {
	return runAIRequest(system, input, true, onDelta)
}

func runAIRequest(system, input string, stream bool, onDelta func(string) error) (string, error) {
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
	if stream {
		body["stream"] = true
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
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		content, _ := io.ReadAll(res.Body)
		return "", fmt.Errorf("AI request failed: %s", strings.TrimSpace(string(content)))
	}
	if stream {
		return readAIStream(res.Body, onDelta)
	}
	content, _ := io.ReadAll(res.Body)
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

func readAIStream(reader io.Reader, onDelta func(string) error) (string, error) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	var out strings.Builder
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "" || data == "[DONE]" {
			continue
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			return "", err
		}
		for _, choice := range chunk.Choices {
			delta := choice.Delta.Content
			if delta == "" {
				delta = choice.Message.Content
			}
			if delta == "" {
				continue
			}
			out.WriteString(delta)
			if onDelta != nil {
				if err := onDelta(delta); err != nil {
					return "", err
				}
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	if strings.TrimSpace(out.String()) == "" {
		return "", errors.New("AI returned empty streamed content")
	}
	return out.String(), nil
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

func partialJSONStringField(content, field string) string {
	index := strings.Index(content, `"`+field+`"`)
	if index < 0 {
		return ""
	}
	rest := content[index+len(field)+2:]
	colon := strings.Index(rest, ":")
	if colon < 0 {
		return ""
	}
	rest = strings.TrimLeft(rest[colon+1:], " \n\r\t")
	if !strings.HasPrefix(rest, `"`) {
		return ""
	}
	var out strings.Builder
	escaped := false
	for i := 1; i < len(rest); i++ {
		ch := rest[i]
		if escaped {
			switch ch {
			case '"', '\\', '/':
				out.WriteByte(ch)
			case 'n':
				out.WriteByte('\n')
			case 'r':
				out.WriteByte('\r')
			case 't':
				out.WriteByte('\t')
			default:
				out.WriteByte(ch)
			}
			escaped = false
			continue
		}
		if ch == '\\' {
			escaped = true
			continue
		}
		if ch == '"' {
			return out.String()
		}
		out.WriteByte(ch)
	}
	return out.String()
}

func mustJSON(value any) string {
	raw, _ := json.MarshalIndent(value, "", "  ")
	return string(raw)
}
