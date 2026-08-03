package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// LedgerOnboardingPlanRequest carries only the short conversation needed to
// build a first ledger. It is deliberately separate from the general ledger
// agent: an empty repository has no accounts for that agent to inspect.
type LedgerOnboardingPlanRequest struct {
	Messages []AgentMessage `json:"messages"`
	Message  string         `json:"message"`
}

func (r LedgerOnboardingPlanRequest) Validate() error {
	if strings.TrimSpace(r.Message) == "" {
		return errors.New("message is required")
	}
	if len(r.Message) > 4000 || len(r.Messages) > 16 {
		return errors.New("onboarding conversation is too long")
	}
	return nil
}

type LedgerOnboardingPlanResponse struct {
	Reply    string                   `json:"reply"`
	Complete bool                     `json:"complete"`
	Plan     *LedgerOnboardingRequest `json:"plan,omitempty"`
}

func (s *Server) planOnboarding(request LedgerOnboardingPlanRequest) (LedgerOnboardingPlanResponse, error) {
	conversation := make([]string, 0, len(request.Messages)+1)
	for _, message := range request.Messages {
		role := strings.ToLower(strings.TrimSpace(message.Role))
		if role != "user" && role != "assistant" {
			continue
		}
		content := strings.TrimSpace(message.Content)
		if content != "" {
			conversation = append(conversation, role+"："+content)
		}
	}
	conversation = append(conversation, "user："+strings.TrimSpace(request.Message))
	content, err := runStructuredAI(onboardingPlannerPrompt(time.Now().Format("2006-01-02")), strings.Join(conversation, "\n"))
	if err != nil {
		return LedgerOnboardingPlanResponse{}, err
	}
	var response LedgerOnboardingPlanResponse
	if err := json.Unmarshal([]byte(extractJSON(content)), &response); err != nil {
		return LedgerOnboardingPlanResponse{}, fmt.Errorf("无法理解建账建议：%w", err)
	}
	response.Reply = strings.TrimSpace(response.Reply)
	if response.Reply == "" {
		return LedgerOnboardingPlanResponse{}, errors.New("建账 Agent 没有返回回复")
	}
	if response.Plan == nil {
		response.Complete = false
		return response, nil
	}
	response.Plan.Normalize()
	if err := response.Plan.Validate(); err != nil {
		return LedgerOnboardingPlanResponse{}, fmt.Errorf("建账 Agent 生成了无效方案：%w", err)
	}
	response.Complete = true
	return response, nil
}

func onboardingPlannerPrompt(today string) string {
	return `你是“建账 Agent”，帮助完全不了解 Beancount 的中文个人用户建立第一本账。
只输出 JSON，不要 Markdown，格式必须是：
{"reply":"给用户的简短中文回复","complete":false,"plan":null}
或者
{"reply":"说明你已生成方案并请用户检查","complete":true,"plan":{"title":"...","currency":"CNY","startDate":"` + today + `","fundingSpaces":[{"kind":"cash|bank_card|digital_wallet|savings|investment","name":"...","account":"Assets:...","currency":"CNY","openingBalance":""}],"liabilities":[],"incomeCategories":[{"templateKey":"...","account":"Income:..."}],"expenseCategories":[{"templateKey":"...","account":"Expenses:..."}]}}

你的目标不是教授会计术语。用“钱在哪里、钱从哪里来、钱去哪了”的语言。每轮最多追问一个最重要的问题。只要已有至少一个资金位置，就可以在 reply 中明确说“我先按常见生活方式给你一份可编辑方案”，并输出 plan；不要为了完美阻止用户开始。

常见的中国个人生活默认：资金位置优先为 现金、微信、支付宝、常用银行卡；收入优先 salary；消费优先 groceries、coffee、public_transport、rent、daily_goods、entertainment。根据用户明确说明增加或移除项。不要假定任何余额、负债、银行或投资信息；余额未知时 openingBalance 使用空字符串。

只能使用下列分类 templateKey：
收入：salary, bonus, freelance, interest, investment, other_income。
消费：groceries, dining, coffee, public_transport, taxi, rent, utilities, daily_goods, clothing, medical, fitness, entertainment, subscriptions, education, gifts。
资金 kind 只能使用 cash, bank_card, digital_wallet, savings, investment；负债 kind 只能使用 credit_card, consumer_loan, other_debt。
你必须为 plan 中的每一个资金位置、负债、收入和消费分类给出 account。account 是你主动设计的标准 Beancount 路径，绝不能把中文编码、拼音化或留给程序猜测。每个路径的各段仅使用英文大写字母开头，后续可含英文、数字和连字符。
资金位置必须分别位于：cash -> Assets:Cash:，digital_wallet -> Assets:Wallet:，bank_card -> Assets:Bank:，savings -> Assets:Savings:，investment -> Assets:Investment:。负债必须分别位于：credit_card -> Liabilities:CreditCard:，consumer_loan -> Liabilities:Loan:，other_debt -> Liabilities:Other:。收入必须位于 Income: 下，消费必须位于 Expenses: 下。
为常见账户选择简短且有语义的英文，例如 微信 -> Assets:Wallet:WeChat，支付宝 -> Assets:Wallet:Alipay，常用银行卡 -> Assets:Bank:Primary，招商银行 -> Assets:Bank:ChinaMerchants。中文 name 仍是用户看到的名字。
plan 必须包含 title、currency、startDate、至少一个 fundingSpaces 项。用户没说账本名称时用“我的生活账本”，没说货币时用 CNY，没说开始日期时用今天。`
}
