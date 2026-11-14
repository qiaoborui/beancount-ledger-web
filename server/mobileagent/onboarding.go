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
	onboardingSegment = regexp.MustCompile(`^[A-Z0-9][A-Za-z0-9-]*$`)
	// Beancount currencies end in a letter or digit.
	onboardingCurrency = regexp.MustCompile(`^[A-Z]([A-Z0-9._-]{0,22}[A-Z0-9])?$`)
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

// hasFunds reports an account the user's money actually sits in; a credit
// card or a loan alone is not somewhere money can come from.
func (draft onboardingDraftV1) hasFunds() bool {
	for _, item := range draft.Accounts {
		if strings.HasPrefix(item.Account, "Assets:") {
			return true
		}
	}
	return false
}

// isReady is the least a ledger needs: somewhere money is, somewhere it
// comes from and somewhere it goes.
func (draft onboardingDraftV1) isReady() bool {
	return draft.hasFunds() && len(draft.IncomeCategories) > 0 && len(draft.ExpenseCategories) > 0
}

// missingItems names what the ledger still needs, in the words the user
// hears, so the model reads the next question off the draft instead of
// working through a fixed list. Amounts owed and the profile have defaults,
// so they never hold the draft back.
func (draft onboardingDraftV1) missingItems() []string {
	missing := []string{}
	if !draft.hasFunds() {
		missing = append(missing, "资金账户")
	}
	if len(draft.IncomeCategories) == 0 {
		missing = append(missing, "收入分类")
	}
	if len(draft.ExpenseCategories) == 0 {
		missing = append(missing, "支出分类")
	}
	return missing
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

// validateOnboardingDate compares calendar dates. The ledger opens its
// accounts on 1970-01-01, so opening balances cannot come earlier.
func validateOnboardingDate(value string, today time.Time) error {
	if _, err := time.Parse(time.DateOnly, value); err != nil {
		return fmt.Errorf("startDate %q must be YYYY-MM-DD", value)
	}
	if value > today.Format(time.DateOnly) {
		return fmt.Errorf("startDate %s is in the future", value)
	}
	if value < "1970-01-01" {
		return fmt.Errorf("startDate %s is before 1970-01-01", value)
	}
	return nil
}

// onboardingDay is the user's calendar day: the date the shell sends, since
// Go on iOS keeps time in UTC, or else the local date here.
func onboardingDay(local string) time.Time {
	if day, err := time.Parse(time.DateOnly, local); err == nil {
		return day
	}
	now := time.Now()
	return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
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
	plan := "未就绪"
	if state.Ready {
		plan = "已就绪，等待用户确认"
	} else if missing := state.Draft.missingItems(); len(missing) > 0 {
		plan += "，还缺" + strings.Join(missing, "、")
	}
	return fmt.Sprintf("（当前草案，方案%s：%s）\n\n", plan, encoded)
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
	category := objectParameters(map[string]any{
		"name":    map[string]any{"type": "string", "description": "给用户看的中文名称，如 餐饮"},
		"account": map[string]any{"type": "string", "description": "英文路径，收入以 Income: 开头，支出以 Expenses: 开头，如 Expenses:Food"},
	}, "name", "account")
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
				"currency":       map[string]any{"type": "string", "description": "账户币种；与账本本位币相同时可以不传"},
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
				if input.Kind != "income" && input.Kind != "expense" {
					return "", errors.New("kind must be income or expense")
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
	return ai.ToolSchema{Name: t.name, Description: t.description, Parameters: objectParameters(t.properties, t.required...)}
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
// no draft, so it stays one cacheable prefix for the day. It states what a
// ledger needs and what counts as done, never an order to walk: the user's
// own account of their money decides what gets asked and in which order.
func onboardingSystemPrompt(today time.Time) string {
	return `你是“账本”App 里的建账助手。用户刚开始使用，还没有账本；你要陪一个完全不懂 Beancount 的人聊几句，按他真实在用的账户和习惯，把第一本账搭好。用户不该面对空白的聊天框，也不该被按步骤盘问。

你只能通过工具修改一份建账草案。工具不会写任何文件；草案就绪后用户在 App 里点「确认创建」，App 才会在本机生成账本并校验。每条用户消息前附有“当前草案”JSON，那是唯一可信的已知信息。

## 要收集到什么（是目标，不是顺序）
- 这本账叫什么、用什么货币记、期初余额算哪一天。三者都有默认值（我的账本、人民币、创建当天），用户不提就不用问。
- 资金账户：钱平时放在哪里，各自现在有多少。
- 待还款项：信用卡、花呗、白条、消费贷、房贷、车贷、欠别人的钱，各自现在欠多少。没有就不用记。
- 收入分类和支出分类：按他的生活来，不是照抄一份通用清单。

## 完成标准
草案里有一个资金账户、一个收入分类、一个支出分类，并且你调用过 present_onboarding_plan。其余项目能合理推断的按默认填好并在回复里说明，推断不了的留空并说明还缺什么。余额和欠款永远不臆造。

## 开场
第一轮用一句话说明你会帮他搭好账本、确认之前不会写入任何文件，然后开放式地问一句他现在的情况和想怎么记账：平时用哪些卡和钱包、钱主要花在哪、有没有在用别的记账方式。不要一上来就抛出选项清单，也不要宣布会分几步走。

## 每一轮怎么做
1. 先从用户最新的话里尽量多地提取信息，一次把能记的都写进草案：一句话里提到三张卡和工资，就三张卡和工资一起记下。再用一两句话复述记下了什么。绝不能没调工具就说“已记下了”。
2. 再看草案还缺什么（消息前的草案会写明还缺哪几项），只追问缺的、且影响建账的内容。自己判断下一个最有价值的问题，一次问一到两件事，不要按固定顺序，也不要重问已经答过的。
3. 能从他说的、从常识或从已有账户合理推断的，直接写进草案并说明“先按…来，可以改”；只有确实需要他决定的事才问。
4. 有明确选项的问题（用哪些钱包、要不要记欠款、推荐哪组分类）用 ask_user 展示选项卡，最多 6 个选项，可多选时设 multiple；金额、名称、日期这类开放问题直接用文字问。整套对话里选项卡别超过两三次，其余用文字聊。
5. 用户说“你看着办”“都行”“按推荐来”时，不要再问：直接补齐一份完整方案（常见账户形态、常见收支分类、余额留空），调用 present_onboarding_plan，再用简短文字说明你替他定了什么、哪里可以改。
6. 用户中途改主意（换币种、删账户、改分类、改期初日期），先按他说的改草案再复述；改完必须重新调用 present_onboarding_plan。

## 按他的情况主动延伸
一次最多带一个延伸问题，并且先把它记进草案再问：
- 提到外币、港卡、境外账户、常在境外花钱 → 问清是哪种货币；该账户的 currency 要和本位币分开记。
- 提到房贷、车贷、分期、欠朋友钱 → 作为待还款项记下，并问现在还欠多少。
- 自由职业、做买卖、有副业 → 收入分类多半是项目款、稿费、经营收入，而不是工资。
- 学生、刚工作 → 精简分类，别给一堆用不上的。
- 提到基金、股票、理财 → 记为投资账户；说不清用途的账户先问一句再记。

## 规矩
7. 对用户只说“资金账户、待还款项、收入分类、支出分类、期初余额”这类直接概念，绝不展示 Assets、Liabilities、Income、Expenses、复式记账或账户路径。
8. 只把用户明确说出或确认的信息写进草案，不臆造银行、余额或欠款。用户没给余额就留空，问过一次即可，不要反复追问。
9. 用户说出一组分类时用 replace_categories 一次写入整组；之后单项改动用 upsert_category、remove_category。用户说“按推荐来”时写入你推荐的那组。
10. account 由你来定：清晰、分层的英文 Beancount 路径，每段以大写字母或数字开头，只含字母、数字和连字符，不用拼音或中文。资金账户和待还款项必须在工具规定的根路径下，如 Assets:Bank:CMB、Assets:Wallet:Alipay、Liabilities:CreditCard:CMB；收入在 Income: 下，支出在 Expenses: 下。
11. 期初余额是“这个账户现在有多少钱”；待还款项填“现在欠多少”，都是不带符号的正数。
12. 满足完成标准后调用 present_onboarding_plan，再用简短文字总结（记了什么、哪些是默认值），请用户点「查看结构」检查，没问题就点「确认创建」。之后用户再改动，改完要再次调用 present_onboarding_plan。
13. 工具报错时按错误信息改正参数再调用，不要把错误原文转述给用户。
14. 回复简短口语化，每次不超过三句，不用表格和代码块。

今天是 ` + today.Format(time.DateOnly) + "。"
}
