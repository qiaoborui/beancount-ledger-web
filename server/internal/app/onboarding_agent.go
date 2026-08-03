package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// LedgerOnboardingAgentRequest is deliberately stateless. The browser owns the
// conversation and the draft; this endpoint only lets the model update the
// draft through the small set of tools below. Nothing here can write a ledger.
type LedgerOnboardingAgentRequest struct {
	Start    bool                     `json:"start,omitempty"`
	Message  string                   `json:"message,omitempty"`
	Messages []AgentMessage           `json:"messages,omitempty"`
	Draft    *LedgerOnboardingRequest `json:"draft,omitempty"`
	Ready    bool                     `json:"ready,omitempty"`
}

func (r LedgerOnboardingAgentRequest) Validate() error {
	r.Message = strings.TrimSpace(r.Message)
	if !r.Start && r.Message == "" {
		return errors.New("message is required unless start is true")
	}
	if len(r.Message) > 4000 || len(r.Messages) > 32 {
		return errors.New("onboarding conversation is too long")
	}
	for _, message := range r.Messages {
		role := strings.ToLower(strings.TrimSpace(message.Role))
		if role != "user" && role != "assistant" {
			return errors.New("onboarding messages must be user or assistant")
		}
		if len(message.Content) > 4000 {
			return errors.New("onboarding message is too long")
		}
	}
	return nil
}

type LedgerOnboardingAgentResponse struct {
	Reply string                  `json:"reply"`
	Draft LedgerOnboardingRequest `json:"draft"`
	Ready bool                    `json:"ready"`
}

func defaultOnboardingDraft() LedgerOnboardingRequest {
	return LedgerOnboardingRequest{
		Title:     "我的生活账本",
		Currency:  "CNY",
		StartDate: time.Now().Format("2006-01-02"),
	}
}

func normalizeOnboardingDraft(draft *LedgerOnboardingRequest) error {
	if draft == nil {
		return errors.New("onboarding draft is required")
	}
	draft.Normalize()
	if draft.Title == "" {
		draft.Title = "我的生活账本"
	}
	if draft.Currency == "" {
		draft.Currency = "CNY"
	}
	if draft.StartDate == "" {
		draft.StartDate = time.Now().Format("2006-01-02")
	}
	if len(draft.FundingSpaces) > 32 || len(draft.Liabilities) > 24 || len(draft.IncomeCategories) > 48 || len(draft.ExpenseCategories) > 96 {
		return errors.New("onboarding draft contains too many items")
	}
	if len(draft.Title) > 120 || !currencyPattern.MatchString(draft.Currency) {
		return errors.New("onboarding draft profile is invalid")
	}
	if err := validateDate("startDate", draft.StartDate); err != nil {
		return err
	}
	for i, space := range draft.FundingSpaces {
		if err := validateOnboardingFundingSpace(i, space); err != nil {
			return err
		}
	}
	for i, liability := range draft.Liabilities {
		if err := validateOnboardingLiability(i, liability); err != nil {
			return err
		}
	}
	if err := validateOnboardingCategories("incomeCategories", draft.IncomeCategories, onboardingIncomeTemplates, "Income"); err != nil {
		return err
	}
	if err := validateOnboardingCategories("expenseCategories", draft.ExpenseCategories, onboardingExpenseTemplates, "Expenses"); err != nil {
		return err
	}
	return nil
}

func validateOnboardingFundingSpace(index int, space LedgerOnboardingFundingSpace) error {
	if _, ok := fundingSpacePrefixes[space.Kind]; !ok {
		return fmt.Errorf("fundingSpaces[%d].kind 无效", index)
	}
	if err := validateOnboardingName(fmt.Sprintf("fundingSpaces[%d].name", index), space.Name); err != nil {
		return err
	}
	if err := validateOnboardingAccount(fmt.Sprintf("fundingSpaces[%d].account", index), space.Account, fundingSpacePrefixes[space.Kind]); err != nil {
		return err
	}
	return validateOnboardingAmount(fmt.Sprintf("fundingSpaces[%d]", index), space.Currency, space.OpeningBalance)
}

func validateOnboardingLiability(index int, liability LedgerOnboardingLiability) error {
	if _, ok := liabilityPrefixes[liability.Kind]; !ok {
		return fmt.Errorf("liabilities[%d].kind 无效", index)
	}
	if err := validateOnboardingName(fmt.Sprintf("liabilities[%d].name", index), liability.Name); err != nil {
		return err
	}
	if err := validateOnboardingAccount(fmt.Sprintf("liabilities[%d].account", index), liability.Account, liabilityPrefixes[liability.Kind]); err != nil {
		return err
	}
	return validateOnboardingAmount(fmt.Sprintf("liabilities[%d]", index), liability.Currency, liability.OpeningBalance)
}

func (s *Server) runOnboardingAgent(ctx context.Context, request LedgerOnboardingAgentRequest) (LedgerOnboardingAgentResponse, error) {
	if err := request.Validate(); err != nil {
		return LedgerOnboardingAgentResponse{}, err
	}
	draft := defaultOnboardingDraft()
	if request.Draft != nil {
		draft = *request.Draft
	}
	if err := normalizeOnboardingDraft(&draft); err != nil {
		return LedgerOnboardingAgentResponse{}, err
	}
	ready := request.Ready && draft.Validate() == nil
	messages := agentMessagesFromRequest(request.Messages)
	if request.Start && strings.TrimSpace(request.Message) == "" {
		messages = append(messages, agentModelMessage{Role: "user", Content: "请主动开始这次建账引导。"})
	} else {
		messages = append(messages, agentModelMessage{Role: "user", Content: strings.TrimSpace(request.Message)})
	}

	tools := onboardingAgentTools(&draft, &ready)
	specs := sortedAgentToolSpecs(tools)
	for modelCalls := 0; modelCalls < 12; modelCalls++ {
		result, err := s.modelClient().Complete(ctx, onboardingAgentPrompt(draft), messages, specs)
		if err != nil {
			return LedgerOnboardingAgentResponse{}, err
		}
		messages = append(messages, agentModelMessage{Role: "assistant", Content: result.Content, ToolCalls: result.ToolCalls})
		if len(result.ToolCalls) == 0 {
			reply := strings.TrimSpace(result.Content)
			if reply == "" {
				reply = "我已经更新了这份财务地图。接下来想先确认哪一部分？"
			}
			return LedgerOnboardingAgentResponse{Reply: reply, Draft: draft, Ready: ready && draft.Validate() == nil}, nil
		}
		seenIDs := make(map[string]struct{}, len(result.ToolCalls))
		for _, call := range result.ToolCalls {
			tool, args, _, err := validateAgentToolCall(tools, call, seenIDs)
			if err != nil {
				messages = append(messages, agentToolResultMessage(call.ID, map[string]any{"error": err.Error()}))
				continue
			}
			execution, err := tool.Execute(ctx, args, AgentPageContext{})
			if err != nil {
				messages = append(messages, agentToolResultMessage(call.ID, map[string]any{"error": err.Error()}))
				continue
			}
			output := execution.ModelOutput
			if output == nil {
				output = execution.ClientOutput
			}
			messages = append(messages, agentToolResultMessage(call.ID, output))
		}
	}
	return LedgerOnboardingAgentResponse{}, errors.New("建账 Agent 的工具调用次数过多，请换一种说法再试")
}

func onboardingAgentTools(draft *LedgerOnboardingRequest, ready *bool) map[string]agentTool {
	result := func() agentToolExecution {
		return agentToolExecution{ModelOutput: map[string]any{"draft": draft, "ready": *ready}}
	}
	mutated := func() agentToolExecution {
		*ready = false
		return result()
	}
	return map[string]agentTool{
		"set_ledger_profile": {
			agentToolSpec: agentToolSpec{Name: "set_ledger_profile", Description: "更新账本名称、基础货币或开始日期。仅在用户明确说出或确认时使用。", Parameters: objectSchema(map[string]any{"title": stringSchema("账本名称"), "currency": stringSchema("三位基础货币，例如 CNY"), "startDate": stringSchema("YYYY-MM-DD")}, nil)},
			Title:         "更新账本资料",
			Execute: func(_ context.Context, raw json.RawMessage, _ AgentPageContext) (agentToolExecution, error) {
				var input struct{ Title, Currency, StartDate string }
				if err := decodeAgentArgs(raw, &input); err != nil {
					return agentToolExecution{}, err
				}
				if strings.TrimSpace(input.Title) != "" {
					draft.Title = input.Title
				}
				if strings.TrimSpace(input.Currency) != "" {
					draft.Currency = input.Currency
				}
				if strings.TrimSpace(input.StartDate) != "" {
					draft.StartDate = input.StartDate
				}
				if err := normalizeOnboardingDraft(draft); err != nil {
					return agentToolExecution{}, err
				}
				return mutated(), nil
			},
		},
		"upsert_funding_space":    onboardingFundingTool(draft, mutated),
		"remove_funding_space":    onboardingRemoveFundingTool(draft, mutated),
		"upsert_liability":        onboardingLiabilityTool(draft, mutated),
		"remove_liability":        onboardingRemoveLiabilityTool(draft, mutated),
		"upsert_income_category":  onboardingCategoryTool(draft, mutated, true),
		"remove_income_category":  onboardingRemoveCategoryTool(draft, mutated, true),
		"upsert_expense_category": onboardingCategoryTool(draft, mutated, false),
		"remove_expense_category": onboardingRemoveCategoryTool(draft, mutated, false),
		"present_onboarding_plan": {
			agentToolSpec: agentToolSpec{Name: "present_onboarding_plan", Description: "仅当草案已包含至少一个钱在哪里的账户，且足以开始记账时调用。它不会写入账本，只会让用户看到确认创建按钮。", Parameters: objectSchema(nil, nil)},
			Title:         "展示建账方案",
			Execute: func(_ context.Context, _ json.RawMessage, _ AgentPageContext) (agentToolExecution, error) {
				if err := draft.Validate(); err != nil {
					return agentToolExecution{}, fmt.Errorf("草案尚不能确认：%w", err)
				}
				*ready = true
				return result(), nil
			},
		},
	}
}

func onboardingFundingTool(draft *LedgerOnboardingRequest, done func() agentToolExecution) agentTool {
	return agentTool{agentToolSpec: agentToolSpec{Name: "upsert_funding_space", Description: "新增或更新一个“钱在哪里”的位置，如现金、微信、支付宝、银行卡、储蓄或投资。account 必须由你设计为分层英文 Beancount 路径。", Parameters: objectSchema(map[string]any{"kind": enumSchema("cash", "bank_card", "digital_wallet", "savings", "investment"), "name": stringSchema("用户看见的中文名称"), "account": stringSchema("英文 Beancount 路径"), "currency": stringSchema("可选货币"), "openingBalance": stringSchema("可选、非负的期初余额")}, []string{"kind", "name", "account"})}, Title: "整理资金位置", Execute: func(_ context.Context, raw json.RawMessage, _ AgentPageContext) (agentToolExecution, error) {
		var input LedgerOnboardingFundingSpace
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		input.Kind, input.Name, input.Account = strings.TrimSpace(input.Kind), strings.TrimSpace(input.Name), strings.TrimSpace(input.Account)
		input.Currency, input.OpeningBalance = strings.ToUpper(strings.TrimSpace(input.Currency)), strings.TrimSpace(input.OpeningBalance)
		if err := validateOnboardingFundingSpace(len(draft.FundingSpaces), input); err != nil {
			return agentToolExecution{}, err
		}
		for i := range draft.FundingSpaces {
			if draft.FundingSpaces[i].Name == input.Name {
				draft.FundingSpaces[i] = input
				return done(), nil
			}
		}
		draft.FundingSpaces = append(draft.FundingSpaces, input)
		if err := normalizeOnboardingDraft(draft); err != nil {
			return agentToolExecution{}, err
		}
		return done(), nil
	}}
}

func onboardingRemoveFundingTool(draft *LedgerOnboardingRequest, done func() agentToolExecution) agentTool {
	return agentTool{agentToolSpec: agentToolSpec{Name: "remove_funding_space", Description: "删除用户明确不要的一个资金位置。", Parameters: objectSchema(map[string]any{"name": stringSchema("要删除的中文名称")}, []string{"name"})}, Title: "移除资金位置", Execute: func(_ context.Context, raw json.RawMessage, _ AgentPageContext) (agentToolExecution, error) {
		var input struct {
			Name string `json:"name"`
		}
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		for i, item := range draft.FundingSpaces {
			if item.Name == strings.TrimSpace(input.Name) {
				draft.FundingSpaces = append(draft.FundingSpaces[:i], draft.FundingSpaces[i+1:]...)
				return done(), nil
			}
		}
		return agentToolExecution{}, errors.New("没有找到这个资金位置")
	}}
}

func onboardingLiabilityTool(draft *LedgerOnboardingRequest, done func() agentToolExecution) agentTool {
	return agentTool{agentToolSpec: agentToolSpec{Name: "upsert_liability", Description: "新增或更新一个需要偿还的项目，例如信用卡、消费贷、借款。只在用户提及时使用。account 必须是分层英文 Beancount 路径。", Parameters: objectSchema(map[string]any{"kind": enumSchema("credit_card", "consumer_loan", "other_debt"), "name": stringSchema("中文名称"), "account": stringSchema("英文 Beancount 路径"), "currency": stringSchema("可选货币"), "openingBalance": stringSchema("可选、非负的待还金额")}, []string{"kind", "name", "account"})}, Title: "整理待还款项", Execute: func(_ context.Context, raw json.RawMessage, _ AgentPageContext) (agentToolExecution, error) {
		var input LedgerOnboardingLiability
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		input.Kind, input.Name, input.Account = strings.TrimSpace(input.Kind), strings.TrimSpace(input.Name), strings.TrimSpace(input.Account)
		input.Currency, input.OpeningBalance = strings.ToUpper(strings.TrimSpace(input.Currency)), strings.TrimSpace(input.OpeningBalance)
		if err := validateOnboardingLiability(len(draft.Liabilities), input); err != nil {
			return agentToolExecution{}, err
		}
		for i := range draft.Liabilities {
			if draft.Liabilities[i].Name == input.Name {
				draft.Liabilities[i] = input
				return done(), nil
			}
		}
		draft.Liabilities = append(draft.Liabilities, input)
		if err := normalizeOnboardingDraft(draft); err != nil {
			return agentToolExecution{}, err
		}
		return done(), nil
	}}
}

func onboardingRemoveLiabilityTool(draft *LedgerOnboardingRequest, done func() agentToolExecution) agentTool {
	return agentTool{agentToolSpec: agentToolSpec{Name: "remove_liability", Description: "删除用户明确不存在或不想记录的待还款项。", Parameters: objectSchema(map[string]any{"name": stringSchema("中文名称")}, []string{"name"})}, Title: "移除待还款项", Execute: func(_ context.Context, raw json.RawMessage, _ AgentPageContext) (agentToolExecution, error) {
		var input struct {
			Name string `json:"name"`
		}
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		for i, item := range draft.Liabilities {
			if item.Name == strings.TrimSpace(input.Name) {
				draft.Liabilities = append(draft.Liabilities[:i], draft.Liabilities[i+1:]...)
				return done(), nil
			}
		}
		return agentToolExecution{}, errors.New("没有找到这个待还款项")
	}}
}

func onboardingCategoryTool(draft *LedgerOnboardingRequest, done func() agentToolExecution, income bool) agentTool {
	name, root, title := "upsert_expense_category", "Expenses", "整理消费分类"
	templates := onboardingExpenseTemplates
	if income {
		name, root, title, templates = "upsert_income_category", "Income", "整理收入来源", onboardingIncomeTemplates
	}
	return agentTool{agentToolSpec: agentToolSpec{Name: name, Description: "新增或更新一个" + map[bool]string{true: "收入来源", false: "消费分类"}[income] + "。templateKey 仅在适合预设分类时填写；否则用 customName。account 必须由你设计为分层英文 Beancount 路径。", Parameters: objectSchema(map[string]any{"templateKey": stringSchema("可选预设分类 key"), "customName": stringSchema("可选自定义中文名称"), "account": stringSchema("英文 Beancount 路径")}, []string{"account"})}, Title: title, Execute: func(_ context.Context, raw json.RawMessage, _ AgentPageContext) (agentToolExecution, error) {
		var input LedgerOnboardingCategory
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		input.TemplateKey, input.CustomName, input.Account = strings.TrimSpace(input.TemplateKey), strings.TrimSpace(input.CustomName), strings.TrimSpace(input.Account)
		if err := validateOnboardingCategories("category", []LedgerOnboardingCategory{input}, templates, root); err != nil {
			return agentToolExecution{}, err
		}
		categories := &draft.ExpenseCategories
		if income {
			categories = &draft.IncomeCategories
		}
		key := onboardingCategoryKey(input)
		for i, existing := range *categories {
			if onboardingCategoryKey(existing) == key {
				(*categories)[i] = input
				return done(), nil
			}
		}
		*categories = append(*categories, input)
		if err := normalizeOnboardingDraft(draft); err != nil {
			return agentToolExecution{}, err
		}
		return done(), nil
	}}
}

func onboardingRemoveCategoryTool(draft *LedgerOnboardingRequest, done func() agentToolExecution, income bool) agentTool {
	name, title := "remove_expense_category", "移除消费分类"
	if income {
		name, title = "remove_income_category", "移除收入来源"
	}
	return agentTool{agentToolSpec: agentToolSpec{Name: name, Description: "删除用户明确不要的分类。传 templateKey 或 customName，二者只能有一个。", Parameters: objectSchema(map[string]any{"templateKey": stringSchema("预设分类 key"), "customName": stringSchema("自定义中文名称")}, nil)}, Title: title, Execute: func(_ context.Context, raw json.RawMessage, _ AgentPageContext) (agentToolExecution, error) {
		var input LedgerOnboardingCategory
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		input.TemplateKey, input.CustomName = strings.TrimSpace(input.TemplateKey), strings.TrimSpace(input.CustomName)
		if (input.TemplateKey == "") == (input.CustomName == "") {
			return agentToolExecution{}, errors.New("请提供且只提供 templateKey 或 customName")
		}
		categories := &draft.ExpenseCategories
		if income {
			categories = &draft.IncomeCategories
		}
		key := onboardingCategoryKey(input)
		for i, category := range *categories {
			if onboardingCategoryKey(category) == key {
				*categories = append((*categories)[:i], (*categories)[i+1:]...)
				return done(), nil
			}
		}
		return agentToolExecution{}, errors.New("没有找到这个分类")
	}}
}

func onboardingCategoryKey(category LedgerOnboardingCategory) string {
	if category.TemplateKey != "" {
		return "template:" + category.TemplateKey
	}
	return "custom:" + category.CustomName
}

func onboardingAgentPrompt(draft LedgerOnboardingRequest) string {
	raw, _ := json.Marshal(draft)
	return `你是中文个人财务产品的“建账 Agent”。你必须主动引导完全不了解 Beancount 的用户，一步步完成第一本账；用户不应面对空白的聊天框，也不需要理解会计术语。

当前草案（唯一可信的已知信息）如下：` + string(raw) + `

你有工具可增删和修改这份内存草案。工具绝不会写 Git、文件、数据库或账本；只有用户稍后点击网页上的“确认并创建”才会走安全的 GitHub 写入、bean-check 和回滚保护。

行为准则：
- 首轮先自然地自我介绍，并主动问一个最有价值的问题；通常从“你平时把钱放在哪里”开始。每轮只问一个问题。
- 用“钱在哪里、钱从哪里来、钱去哪了、待还款项”的日常语言，绝不向用户展示 Assets、Expenses、Income、Liabilities、复式记账或 Beancount 路径。
- 仅把用户明确说明或确认的信息写入草案；不要臆造银行、余额、债务或生活偏好。可以给 2–4 个自然语言选项帮助回答。
- 收到信息后先用相应工具更新草案，再用简短中文说明你理解了什么并继续问一个最有价值的问题。
- account 是内部实现：每个账户都必须由你给出清晰、分层、英文的标准 Beancount 路径。不能把中文编码、拼音化，也不能让程序猜账户名。资金位置与待还款项严格使用工具规定的根路径；收入位于 Income:，消费位于 Expenses:。
- 当“钱在哪里”至少有一个账户，且收入来源和常见消费已足够让用户开始使用时，主动调用 present_onboarding_plan，再告知用户可以检查财务地图并确认创建。用户即使在方案就绪后继续修改，也必须再次调用该工具才能恢复确认状态。
- 只在确实要变更草案或展示方案时调用工具；正常对话直接回复。`
}
