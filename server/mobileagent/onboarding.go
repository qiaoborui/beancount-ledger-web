package mobileagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// Onboarding is the ledger-less mode of a turn: the model builds the plan of
// a first ledger through draft tools, and the shell creates the ledger only
// after the user confirms. The shell owns the draft and sends it with every
// turn; nothing here touches a file.

const (
	maxOnboardingAccounts   = 60
	maxOnboardingCategories = 80
	maxOnboardingNameRunes  = 40
	maxOnboardingTitleRunes = 60
	maxOnboardingPathBytes  = 120
)

// onboardingStateV1 is the draft and whether the model presented it as
// ready; it travels in the request and comes back in the response.
type onboardingStateV1 struct {
	Draft onboardingDraftV1 `json:"draft"`
	Ready bool              `json:"ready"`
}

type onboardingDraftV1 struct {
	Title    string `json:"title"`
	Currency string `json:"currency"`
	// StartDate dates the opening balances; empty means the day the ledger
	// is created.
	StartDate         string                 `json:"startDate"`
	Accounts          []onboardingAccountV1  `json:"accounts"`
	IncomeCategories  []onboardingCategoryV1 `json:"incomeCategories"`
	ExpenseCategories []onboardingCategoryV1 `json:"expenseCategories"`
}

type onboardingAccountV1 struct {
	Kind    string `json:"kind"`
	Name    string `json:"name"`
	Account string `json:"account"`
	// Currency is empty for the ledger's currency.
	Currency string `json:"currency"`
	// OpeningBalance is a plain non-negative decimal, or empty; for a
	// liability it is the amount owed.
	OpeningBalance string `json:"openingBalance"`
}

type onboardingCategoryV1 struct {
	Name    string `json:"name"`
	Account string `json:"account"`
}

// onboardingKinds maps each account kind to the root its path must sit under.
var onboardingKinds = map[string]string{
	"cash":           "Assets:Cash",
	"bank_card":      "Assets:Bank",
	"digital_wallet": "Assets:Wallet",
	"savings":        "Assets:Savings",
	"investment":     "Assets:Investment",
	"credit_card":    "Liabilities:CreditCard",
	"consumer_loan":  "Liabilities:Loan",
	"other_debt":     "Liabilities:Other",
}

var onboardingKindOrder = []string{"cash", "bank_card", "digital_wallet", "savings", "investment", "credit_card", "consumer_loan", "other_debt"}

var (
	onboardingSegment  = regexp.MustCompile(`^[A-Z0-9][A-Za-z0-9-]*$`)
	onboardingCurrency = regexp.MustCompile(`^[A-Z][A-Z0-9._-]{0,23}$`)
	onboardingAmount   = regexp.MustCompile(`^[0-9]{1,13}(\.[0-9]{1,2})?$`)
)

func defaultOnboardingDraft() onboardingDraftV1 {
	return onboardingDraftV1{Title: "我的账本", Currency: "CNY", Accounts: []onboardingAccountV1{},
		IncomeCategories: []onboardingCategoryV1{}, ExpenseCategories: []onboardingCategoryV1{}}
}

// normalized fills the lists a client may have left out, so the draft always
// encodes them as arrays.
func (draft onboardingDraftV1) normalized() onboardingDraftV1 {
	if draft.Accounts == nil {
		draft.Accounts = []onboardingAccountV1{}
	}
	if draft.IncomeCategories == nil {
		draft.IncomeCategories = []onboardingCategoryV1{}
	}
	if draft.ExpenseCategories == nil {
		draft.ExpenseCategories = []onboardingCategoryV1{}
	}
	return draft
}

// validate checks a whole draft, as a request carries it.
func (draft onboardingDraftV1) validate(today time.Time) error {
	if err := validateOnboardingTitle(draft.Title); err != nil {
		return err
	}
	if !onboardingCurrency.MatchString(draft.Currency) {
		return fmt.Errorf("currency %q is not a commodity code such as CNY", draft.Currency)
	}
	if draft.StartDate != "" {
		if err := validateOnboardingDate(draft.StartDate, today); err != nil {
			return err
		}
	}
	if len(draft.Accounts) > maxOnboardingAccounts || len(draft.IncomeCategories) > maxOnboardingCategories ||
		len(draft.ExpenseCategories) > maxOnboardingCategories {
		return errors.New("draft has too many accounts or categories")
	}
	paths := map[string]bool{}
	names := map[string]bool{}
	for _, item := range draft.Accounts {
		if err := item.validate(); err != nil {
			return err
		}
		if names[item.Name] || paths[item.Account] {
			return fmt.Errorf("account %s is listed twice", item.Name)
		}
		names[item.Name], paths[item.Account] = true, true
	}
	for _, group := range []struct {
		root  string
		items []onboardingCategoryV1
	}{{"Income", draft.IncomeCategories}, {"Expenses", draft.ExpenseCategories}} {
		names := map[string]bool{}
		for _, item := range group.items {
			if err := item.validate(group.root); err != nil {
				return err
			}
			if names[item.Name] || paths[item.Account] {
				return fmt.Errorf("category %s is listed twice", item.Name)
			}
			names[item.Name], paths[item.Account] = true, true
		}
	}
	return nil
}

// isReady is the least a ledger needs: somewhere money is, somewhere it
// comes from and somewhere it goes.
func (draft onboardingDraftV1) isReady() bool {
	hasAsset := false
	for _, item := range draft.Accounts {
		if strings.HasPrefix(item.Account, "Assets:") {
			hasAsset = true
		}
	}
	return hasAsset && len(draft.IncomeCategories) > 0 && len(draft.ExpenseCategories) > 0
}

func (item onboardingAccountV1) validate() error {
	root, ok := onboardingKinds[item.Kind]
	if !ok {
		return fmt.Errorf("unknown account kind %q", item.Kind)
	}
	if err := validateOnboardingName(item.Name); err != nil {
		return err
	}
	if err := validateOnboardingPath(item.Account, root); err != nil {
		return err
	}
	if item.Currency != "" && !onboardingCurrency.MatchString(item.Currency) {
		return fmt.Errorf("currency %q is not a commodity code such as CNY", item.Currency)
	}
	if item.OpeningBalance != "" && !onboardingAmount.MatchString(item.OpeningBalance) {
		return fmt.Errorf("openingBalance %q must be a non-negative amount with at most two decimals", item.OpeningBalance)
	}
	return nil
}

func (item onboardingCategoryV1) validate(root string) error {
	if err := validateOnboardingName(item.Name); err != nil {
		return err
	}
	return validateOnboardingPath(item.Account, root)
}

func validateOnboardingTitle(title string) error {
	if title != strings.TrimSpace(title) || title == "" || utf8.RuneCountInString(title) > maxOnboardingTitleRunes || hasUnsafeRune(title) {
		return fmt.Errorf("title must be 1 to %d characters without quotes or line breaks", maxOnboardingTitleRunes)
	}
	return nil
}

func validateOnboardingName(name string) error {
	if name != strings.TrimSpace(name) || name == "" || utf8.RuneCountInString(name) > maxOnboardingNameRunes || hasUnsafeRune(name) {
		return fmt.Errorf("name %q must be 1 to %d characters without quotes or line breaks", name, maxOnboardingNameRunes)
	}
	return nil
}

func hasUnsafeRune(text string) bool {
	return strings.ContainsFunc(text, func(r rune) bool { return r == '"' || r == '\\' || unicode.IsControl(r) })
}

// validateOnboardingPath requires an English path below root, at least one
// level deep, in Beancount's account syntax.
func validateOnboardingPath(path, root string) error {
	segments := strings.Split(path, ":")
	if len(path) > maxOnboardingPathBytes || !strings.HasPrefix(path, root+":") || len(segments) < 2 {
		return fmt.Errorf("account %q must be an English Beancount path below %s:", path, root)
	}
	for _, segment := range segments[strings.Count(root, ":")+1:] {
		if !onboardingSegment.MatchString(segment) {
			return fmt.Errorf("account %q: each part starts with a capital letter or digit and holds only letters, digits and -", path)
		}
	}
	return nil
}

func validateOnboardingDate(value string, today time.Time) error {
	date, err := time.Parse(time.DateOnly, value)
	if err != nil {
		return fmt.Errorf("startDate %q must be YYYY-MM-DD", value)
	}
	if date.After(today) {
		return fmt.Errorf("startDate %s is in the future", value)
	}
	return nil
}

// cleanAmount accepts what a model is likely to send for an amount: a
// string with separators or currency signs, or a bare number.
func cleanAmount(raw json.RawMessage) (string, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return "", nil
	}
	var text string
	if err := json.Unmarshal(raw, &text); err != nil {
		var number json.Number
		if err := json.Unmarshal(raw, &number); err != nil {
			return "", errors.New("openingBalance must be an amount")
		}
		text = number.String()
	}
	text = strings.Map(func(r rune) rune {
		if r == ',' || r == '，' || r == '¥' || r == '￥' || r == '$' || unicode.IsSpace(r) {
			return -1
		}
		return r
	}, text)
	if text == "" {
		return "", nil
	}
	if !onboardingAmount.MatchString(text) {
		return "", fmt.Errorf("openingBalance %q must be a non-negative amount with at most two decimals", text)
	}
	return text, nil
}

// onboardingSession is the draft one turn edits. Every change takes the
// plan back out of ready until the model presents it again.
type onboardingSession struct {
	mu    sync.Mutex
	state onboardingStateV1
	today time.Time
}

func newOnboardingSession(state *onboardingStateV1, today time.Time) (*onboardingSession, error) {
	session := &onboardingSession{today: today}
	if state == nil {
		session.state.Draft = defaultOnboardingDraft()
		return session, nil
	}
	session.state = onboardingStateV1{Draft: state.Draft.normalized(), Ready: state.Ready}
	if err := session.state.Draft.validate(today); err != nil {
		return nil, fmt.Errorf("invalid onboarding draft: %w", err)
	}
	session.state.Ready = session.state.Ready && session.state.Draft.isReady()
	return session, nil
}

func (s *onboardingSession) snapshot() *onboardingStateV1 {
	s.mu.Lock()
	defer s.mu.Unlock()
	state := s.state
	state.Draft.Accounts = append([]onboardingAccountV1{}, state.Draft.Accounts...)
	state.Draft.IncomeCategories = append([]onboardingCategoryV1{}, state.Draft.IncomeCategories...)
	state.Draft.ExpenseCategories = append([]onboardingCategoryV1{}, state.Draft.ExpenseCategories...)
	return &state
}

// draftNote is the draft as the model reads it in front of the user's
// message, so a compacted transcript never leaves it guessing.
func (s *onboardingSession) draftNote() string {
	state := s.snapshot()
	encoded, _ := json.Marshal(state.Draft)
	ready := "未就绪"
	if state.Ready {
		ready = "已就绪，等待用户确认"
	}
	return fmt.Sprintf("（当前草案，方案%s：%s）\n\n", ready, encoded)
}

// change applies edit to a copy of the draft and keeps it only when the
// whole draft still validates.
func (s *onboardingSession) change(edit func(*onboardingDraftV1) error) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	draft := s.state.Draft
	draft.Accounts = append([]onboardingAccountV1{}, draft.Accounts...)
	draft.IncomeCategories = append([]onboardingCategoryV1{}, draft.IncomeCategories...)
	draft.ExpenseCategories = append([]onboardingCategoryV1{}, draft.ExpenseCategories...)
	if err := edit(&draft); err != nil {
		return "", err
	}
	if err := draft.validate(s.today); err != nil {
		return "", err
	}
	s.state = onboardingStateV1{Draft: draft}
	encoded, _ := json.Marshal(draft)
	return "草案已更新（方案需要重新确认）：" + string(encoded), nil
}

func (s *onboardingSession) present() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.state.Draft.isReady() {
		return "", errors.New("草案还不完整：至少需要一个资金账户、一个收入分类和一个支出分类")
	}
	s.state.Ready = true
	return "方案已展示给用户，「确认创建」按钮已可用。用简短文字总结方案，请用户检查后确认。", nil
}

// tools are the draft tools of the session.
func (s *onboardingSession) tools() []agent.AgentTool {
	kinds := append([]string{}, onboardingKindOrder...)
	categoryKind := map[string]any{"type": "string", "enum": []string{"income", "expense"}, "description": "income 是收入分类，expense 是支出分类"}
	category := map[string]any{"type": "object", "additionalProperties": false, "required": []string{"name", "account"},
		"properties": map[string]any{
			"name":    map[string]any{"type": "string", "description": "给用户看的中文名称，如 餐饮"},
			"account": map[string]any{"type": "string", "description": "英文路径，收入以 Income: 开头，支出以 Expenses: 开头，如 Expenses:Food"},
		}}
	categories := func(kind string, draft *onboardingDraftV1) *[]onboardingCategoryV1 {
		if kind == "income" {
			return &draft.IncomeCategories
		}
		return &draft.ExpenseCategories
	}
	return []agent.AgentTool{
		onboardingTool{name: "set_ledger_profile", label: "设置账本",
			description: "设置账本名称、记账本位币和期初日期。只传要改的字段。",
			properties: map[string]any{
				"title":     map[string]any{"type": "string", "description": "账本名称，如 我的生活账本"},
				"currency":  map[string]any{"type": "string", "description": "记账本位币代码，如 CNY、USD"},
				"startDate": map[string]any{"type": "string", "description": "期初余额的日期 YYYY-MM-DD；不传则为创建当天"},
			},
			run: func(params json.RawMessage) (string, error) {
				var input struct{ Title, Currency, StartDate *string }
				if err := json.Unmarshal(params, &input); err != nil {
					return "", err
				}
				return s.change(func(draft *onboardingDraftV1) error {
					if input.Title != nil {
						draft.Title = strings.TrimSpace(*input.Title)
					}
					if input.Currency != nil {
						draft.Currency = strings.ToUpper(strings.TrimSpace(*input.Currency))
					}
					if input.StartDate != nil {
						draft.StartDate = strings.TrimSpace(*input.StartDate)
					}
					return nil
				})
			}},
		onboardingTool{name: "upsert_account", label: "记下账户",
			description: "新增或按名称更新一个资金账户或待还款项。kind 决定路径根：cash→Assets:Cash，bank_card→Assets:Bank，digital_wallet→Assets:Wallet，savings→Assets:Savings，investment→Assets:Investment，credit_card→Liabilities:CreditCard，consumer_loan→Liabilities:Loan，other_debt→Liabilities:Other。",
			required:    []string{"kind", "name", "account"},
			properties: map[string]any{
				"kind":           map[string]any{"type": "string", "enum": kinds},
				"name":           map[string]any{"type": "string", "description": "给用户看的中文名称，如 招商银行卡、支付宝余额；同名即更新"},
				"account":        map[string]any{"type": "string", "description": "kind 对应根路径下的英文路径，如 Assets:Bank:CMB、Liabilities:CreditCard:CMB"},
				"currency":       map[string]any{"type": "string", "description": "账户币种；与账本本位币相同时不传"},
				"openingBalance": map[string]any{"type": "string", "description": "现在的余额（待还款项填现在欠多少），不带符号的数字；用户没说就不传"},
			},
			run: func(params json.RawMessage) (string, error) {
				var input struct {
					Kind, Name, Account, Currency string
					OpeningBalance                json.RawMessage
				}
				if err := json.Unmarshal(params, &input); err != nil {
					return "", err
				}
				balance, err := cleanAmount(input.OpeningBalance)
				if err != nil {
					return "", err
				}
				item := onboardingAccountV1{Kind: input.Kind, Name: strings.TrimSpace(input.Name), Account: strings.TrimSpace(input.Account),
					Currency: strings.ToUpper(strings.TrimSpace(input.Currency)), OpeningBalance: balance}
				return s.change(func(draft *onboardingDraftV1) error {
					if item.Currency == draft.Currency {
						item.Currency = ""
					}
					for index, current := range draft.Accounts {
						if current.Name == item.Name {
							draft.Accounts[index] = item
							return nil
						}
					}
					draft.Accounts = append(draft.Accounts, item)
					return nil
				})
			}},
		onboardingTool{name: "remove_account", label: "移除账户", description: "按名称移除一个资金账户或待还款项。",
			required: []string{"name"}, properties: map[string]any{"name": map[string]any{"type": "string"}},
			run: func(params json.RawMessage) (string, error) {
				var input struct{ Name string }
				if err := json.Unmarshal(params, &input); err != nil {
					return "", err
				}
				return s.change(func(draft *onboardingDraftV1) error {
					before := len(draft.Accounts)
					draft.Accounts = removeWhere(draft.Accounts, func(item onboardingAccountV1) bool { return item.Name == strings.TrimSpace(input.Name) })
					if len(draft.Accounts) == before {
						return fmt.Errorf("草案里没有叫 %s 的账户", input.Name)
					}
					return nil
				})
			}},
		onboardingTool{name: "replace_categories", label: "写入分类", description: "用一整组分类替换某一类（收入或支出）现有的全部分类。用户一次说了多个分类时用它。",
			required: []string{"kind", "categories"},
			properties: map[string]any{"kind": categoryKind,
				"categories": map[string]any{"type": "array", "minItems": 1, "maxItems": maxOnboardingCategories, "items": category}},
			run: func(params json.RawMessage) (string, error) {
				var input struct {
					Kind       string
					Categories []onboardingCategoryV1
				}
				if err := json.Unmarshal(params, &input); err != nil {
					return "", err
				}
				if input.Kind != "income" && input.Kind != "expense" {
					return "", errors.New("kind must be income or expense")
				}
				return s.change(func(draft *onboardingDraftV1) error {
					items := make([]onboardingCategoryV1, 0, len(input.Categories))
					for _, item := range input.Categories {
						items = append(items, onboardingCategoryV1{Name: strings.TrimSpace(item.Name), Account: strings.TrimSpace(item.Account)})
					}
					*categories(input.Kind, draft) = items
					return nil
				})
			}},
		onboardingTool{name: "upsert_category", label: "记下分类", description: "新增或按名称更新一个收入或支出分类。",
			required: []string{"kind", "name", "account"},
			properties: map[string]any{"kind": categoryKind,
				"name": category["properties"].(map[string]any)["name"], "account": category["properties"].(map[string]any)["account"]},
			run: func(params json.RawMessage) (string, error) {
				var input struct{ Kind, Name, Account string }
				if err := json.Unmarshal(params, &input); err != nil {
					return "", err
				}
				if input.Kind != "income" && input.Kind != "expense" {
					return "", errors.New("kind must be income or expense")
				}
				item := onboardingCategoryV1{Name: strings.TrimSpace(input.Name), Account: strings.TrimSpace(input.Account)}
				return s.change(func(draft *onboardingDraftV1) error {
					list := categories(input.Kind, draft)
					for index, current := range *list {
						if current.Name == item.Name {
							(*list)[index] = item
							return nil
						}
					}
					*list = append(*list, item)
					return nil
				})
			}},
		onboardingTool{name: "remove_category", label: "移除分类", description: "按名称移除一个收入或支出分类。",
			required: []string{"kind", "name"}, properties: map[string]any{"kind": categoryKind, "name": map[string]any{"type": "string"}},
			run: func(params json.RawMessage) (string, error) {
				var input struct{ Kind, Name string }
				if err := json.Unmarshal(params, &input); err != nil {
					return "", err
				}
				return s.change(func(draft *onboardingDraftV1) error {
					list := categories(input.Kind, draft)
					before := len(*list)
					*list = removeWhere(*list, func(item onboardingCategoryV1) bool { return item.Name == strings.TrimSpace(input.Name) })
					if len(*list) == before {
						return fmt.Errorf("草案里没有叫 %s 的分类", input.Name)
					}
					return nil
				})
			}},
		onboardingTool{name: "present_onboarding_plan", label: "展示方案",
			description: "草案至少有一个资金账户、一个收入分类和一个支出分类后调用，让用户可以点「确认创建」。之后草案再有改动，需要再次调用。",
			properties:  map[string]any{},
			run:         func(json.RawMessage) (string, error) { return s.present() }},
	}
}

func removeWhere[T any](items []T, match func(T) bool) []T {
	kept := items[:0]
	for _, item := range items {
		if !match(item) {
			kept = append(kept, item)
		}
	}
	return kept
}

// onboardingTool is one draft tool; its errors go back to the model, which
// corrects the call.
type onboardingTool struct {
	name, label, description string
	properties               map[string]any
	required                 []string
	run                      func(json.RawMessage) (string, error)
}

func (t onboardingTool) Name() string  { return t.name }
func (t onboardingTool) Label() string { return t.label }
func (t onboardingTool) Schema() ai.ToolSchema {
	parameters := map[string]any{"type": "object", "properties": t.properties, "additionalProperties": false}
	if len(t.required) > 0 {
		parameters["required"] = t.required
	}
	return ai.ToolSchema{Name: t.name, Description: t.description, Parameters: parameters}
}
func (onboardingTool) ExecutionMode() agent.ToolExecutionMode { return agent.ToolModeSequential }

func (t onboardingTool) Execute(_ context.Context, _ string, params json.RawMessage, _ agent.ToolUpdateCallback) (agent.AgentToolResult, error) {
	if len(params) == 0 {
		params = json.RawMessage("{}")
	}
	text, err := t.run(params)
	if err != nil {
		return agent.AgentToolResult{}, err
	}
	return agent.AgentToolResult{Content: []ai.ToolResultMessageContent{ai.TextContent{Text: text}}, Details: map[string]any{}}, nil
}

// onboardingSystemPrompt is the whole prompt of an onboarding turn; it holds
// no draft, so it stays one cacheable prefix for the day.
func onboardingSystemPrompt(today time.Time) string {
	return `你是“账本”App 里的建账助手。用户刚开始使用，还没有账本；你要用对话主动引导一个完全不懂 Beancount 的人，几分钟内搭好第一本账。用户不应面对空白的聊天框，也不需要懂会计术语。

你只能通过工具修改一份建账草案。工具不会写任何文件；草案就绪后用户在 App 里点「确认创建」，App 才会在本机生成账本并校验。每条用户消息前附有“当前草案”JSON，那是唯一可信的已知信息。

行为准则：
1. 第一轮先用一两句话介绍自己和接下来要做的事，再问第一个问题，通常从“平时钱放在哪里”开始。每轮只问一个问题。
2. 有明确选项的问题用 ask_user 展示选项卡，例如常用的支付方式、有没有信用卡或花呗、想细分哪些支出；可多选时设 multiple。金额、名称这类开放问题直接用文字问。
3. 对用户只说“资金账户、待还款项、收入分类、支出分类、期初余额”这些直接概念，绝不展示 Assets、Liabilities、Income、Expenses、复式记账或账户路径。
4. 只把用户明确说出或确认的信息写进草案，不要臆造银行、余额或欠款。用户没给余额就留空，问一次即可，不要反复追问。
5. 收到信息先调用工具更新草案，再用一两句话复述记下了什么，接着问下一个问题。绝不能没调工具就说“已记录”。
6. 用户一次说了多个分类时，用 replace_categories 一次写入整组；之后单项改动用 upsert_category 或 remove_category。用户没想好时，可以推荐一组常用分类（支出如餐饮、日用、交通、居住、娱乐、医疗；收入如工资、其他收入），用户同意后再写入。
7. account 由你来定：清晰、分层的英文 Beancount 路径，每段以大写字母或数字开头，只含字母、数字和连字符，不用拼音或中文。资金账户和待还款项必须在工具规定的根路径下，如 Assets:Bank:CMB、Assets:Wallet:Alipay、Liabilities:CreditCard:CMB；收入在 Income: 下，支出在 Expenses: 下。
8. 期初余额是“这个账户现在有多少钱”；待还款项填“现在欠多少”，都是不带符号的正数。
9. 草案至少有一个资金账户、一个收入分类和一个支出分类后，调用 present_onboarding_plan，再用简短文字总结方案，请用户检查页面上的账本结构并点「确认创建」。之后用户再改动，改完要再次调用 present_onboarding_plan。
10. 工具报错时按错误信息改正参数再调用，不要把错误原文转述给用户。
11. 回复简短口语化，不用表格和代码块。

今天是 ` + today.Format(time.DateOnly) + "。"
}
