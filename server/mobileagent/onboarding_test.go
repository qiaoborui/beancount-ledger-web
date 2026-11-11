package mobileagent

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/MichaelKinsy/PiG/ai"
)

var onboardingToday = time.Date(2026, 11, 11, 0, 0, 0, 0, time.UTC)

func onboardingStep(content ...ai.FauxContentBlock) ai.FauxResponseStep {
	return ai.FauxFactoryStep(func(ai.TranscriptContext, ai.StreamOptions, *ai.FauxProviderState, *ai.Model) (ai.AssistantMessage, error) {
		stop := string(ai.StopReasonStop)
		for _, block := range content {
			if block.Type == ai.FauxContentToolCall {
				stop = string(ai.StopReasonToolUse)
			}
		}
		return ai.FauxResponse{StopReason: stop, Content: content}.AssistantMessage(), nil
	})
}

func TestOnboardingTurnBuildsTheDraftWithoutALedger(t *testing.T) {
	var question string
	useFaux(t,
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			question = lastUserText(request)
			return ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
				ai.FauxToolCall("upsert_account", map[string]any{"kind": "bank_card", "name": "招商银行卡", "account": "Assets:Bank:CMB", "openingBalance": "12,345.6"}, nil),
				ai.FauxToolCall("upsert_account", map[string]any{"kind": "credit_card", "name": "招行信用卡", "account": "Liabilities:CreditCard:CMB", "openingBalance": 800, "currency": "cny"}, nil),
				ai.FauxToolCall("replace_categories", map[string]any{"kind": "income", "categories": []any{map[string]any{"name": "工资", "account": "Income:Salary"}}}, nil),
				ai.FauxToolCall("replace_categories", map[string]any{"kind": "expense", "categories": []any{
					map[string]any{"name": "餐饮", "account": "Expenses:Food"}, map[string]any{"name": "交通", "account": "Expenses:Transport"}}}, nil),
				ai.FauxToolCall("present_onboarding_plan", map[string]any{}, nil),
			}}.AssistantMessage(), nil
		}),
		onboardingStep(ai.FauxText("方案好了，检查一下就可以创建。")),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "message": "我有招行卡和招行信用卡",
		"onboarding": map[string]any{"draft": defaultOnboardingDraft(), "ready": false}})
	if !response.OK || response.Reply != "方案好了，检查一下就可以创建。" {
		t.Fatalf("unexpected response: %+v", response)
	}
	if !strings.HasPrefix(question, "（当前草案，方案未就绪：") || !strings.HasSuffix(question, "我有招行卡和招行信用卡") {
		t.Fatalf("question does not carry the draft: %q", question)
	}
	if response.Onboarding == nil || !response.Onboarding.Ready {
		t.Fatalf("onboarding = %+v", response.Onboarding)
	}
	draft := response.Onboarding.Draft
	if len(draft.Accounts) != 2 || draft.Accounts[0].OpeningBalance != "12345.6" || draft.Accounts[1].OpeningBalance != "800" ||
		draft.Accounts[1].Currency != "CNY" || len(draft.IncomeCategories) != 1 || len(draft.ExpenseCategories) != 2 {
		t.Fatalf("draft = %+v", draft)
	}
	for _, call := range response.ToolCalls {
		if call.IsError {
			t.Fatalf("tool %s failed: %s", call.Name, call.ErrorText)
		}
	}
	if response.Transcript == "" {
		t.Fatal("onboarding turn returned no transcript")
	}
}

func TestOnboardingToolErrorsGoBackToTheModelAndChangesClearReady(t *testing.T) {
	var badResult string
	useFaux(t,
		onboardingStep(ai.FauxToolCall("upsert_account", map[string]any{"kind": "bank_card", "name": "工行", "account": "Assets:Bank:GongHang:储蓄"}, nil)),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			badResult = lastToolResultText(request)
			return ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
				ai.FauxToolCall("upsert_account", map[string]any{"kind": "bank_card", "name": "工行", "account": "Assets:Bank:ICBC"}, nil),
			}}.AssistantMessage(), nil
		}),
		onboardingStep(ai.FauxText("记下了工行卡。")),
	)
	ready := defaultOnboardingDraft()
	ready.Accounts = []onboardingAccountV1{{Kind: "cash", Name: "现金", Account: "Assets:Cash:Wallet"}}
	ready.IncomeCategories = []onboardingCategoryV1{{Name: "工资", Account: "Income:Salary"}}
	ready.ExpenseCategories = []onboardingCategoryV1{{Name: "餐饮", Account: "Expenses:Food"}}
	response := runTurnFor(t, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "message": "还有一张工行卡",
		"onboarding": map[string]any{"draft": ready, "ready": true}})
	if !response.OK || response.Onboarding == nil {
		t.Fatalf("unexpected response: %+v", response)
	}
	if !strings.Contains(badResult, "each part starts with a capital letter") {
		t.Fatalf("model did not see the path error: %q", badResult)
	}
	if response.Onboarding.Ready || len(response.Onboarding.Draft.Accounts) != 2 || response.Onboarding.Draft.Accounts[1].Account != "Assets:Bank:ICBC" {
		t.Fatalf("onboarding = %+v", response.Onboarding)
	}
}

func TestOnboardingTurnRefusesALedgerAndAnInvalidDraft(t *testing.T) {
	useFaux(t, onboardingStep(ai.FauxText("不该被调用")))
	withLedger := runTurnFor(t, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "message": "开始",
		"workspaceRoot": committedWorkspace(t), "onboarding": map[string]any{"draft": defaultOnboardingDraft()}})
	if withLedger.OK || !strings.Contains(withLedger.Error, "onboarding turns take no ledger") {
		t.Fatalf("ledger accepted: %+v", withLedger)
	}
	bad := defaultOnboardingDraft()
	bad.Accounts = []onboardingAccountV1{{Kind: "cash", Name: "现金", Account: "Expenses:Cash"}}
	invalid := runTurnFor(t, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "message": "开始",
		"onboarding": map[string]any{"draft": bad}})
	if invalid.OK || invalid.Onboarding != nil || !strings.Contains(invalid.Error, "invalid onboarding draft") {
		t.Fatalf("invalid draft accepted: %+v", invalid)
	}
}

func TestOnboardingDraftValidation(t *testing.T) {
	valid := defaultOnboardingDraft()
	valid.Accounts = []onboardingAccountV1{{Kind: "digital_wallet", Name: "支付宝", Account: "Assets:Wallet:Alipay", OpeningBalance: "0.5"}}
	if err := valid.validate(onboardingToday); err != nil {
		t.Fatal(err)
	}
	for name, edit := range map[string]func(*onboardingDraftV1){
		"wrong root":     func(d *onboardingDraftV1) { d.Accounts[0].Account = "Liabilities:Wallet:Alipay" },
		"root only":      func(d *onboardingDraftV1) { d.Accounts[0].Account = "Assets:Wallet" },
		"han segment":    func(d *onboardingDraftV1) { d.Accounts[0].Account = "Assets:Wallet:支付宝" },
		"lowercase":      func(d *onboardingDraftV1) { d.Accounts[0].Account = "Assets:Wallet:alipay" },
		"quote in name":  func(d *onboardingDraftV1) { d.Accounts[0].Name = `支付"宝` },
		"negative":       func(d *onboardingDraftV1) { d.Accounts[0].OpeningBalance = "-5" },
		"three decimals": func(d *onboardingDraftV1) { d.Accounts[0].OpeningBalance = "1.005" },
		"future start":   func(d *onboardingDraftV1) { d.StartDate = "2026-12-01" },
		"bad currency":   func(d *onboardingDraftV1) { d.Currency = "rmb" },
		"trailing dot":   func(d *onboardingDraftV1) { d.Currency = "RMB." },
		"before 1970":    func(d *onboardingDraftV1) { d.StartDate = "1969-12-31" },
		"duplicate path": func(d *onboardingDraftV1) {
			d.Accounts = append(d.Accounts, onboardingAccountV1{Kind: "digital_wallet", Name: "余额宝", Account: "Assets:Wallet:Alipay"})
		},
		"unknown kind": func(d *onboardingDraftV1) { d.Accounts[0].Kind = "crypto" },
		"income as asset": func(d *onboardingDraftV1) {
			d.IncomeCategories = []onboardingCategoryV1{{Name: "工资", Account: "Assets:Salary"}}
		},
	} {
		draft := valid
		draft.Accounts = append([]onboardingAccountV1{}, valid.Accounts...)
		edit(&draft)
		if err := draft.validate(onboardingToday); err == nil {
			t.Errorf("%s: accepted %+v", name, draft)
		}
	}
	if valid.isReady() {
		t.Fatal("a draft without categories is ready")
	}
	debtOnly := valid
	debtOnly.Accounts = []onboardingAccountV1{{Kind: "credit_card", Name: "信用卡", Account: "Liabilities:CreditCard:CMB"}}
	debtOnly.IncomeCategories = []onboardingCategoryV1{{Name: "工资", Account: "Income:Salary"}}
	debtOnly.ExpenseCategories = []onboardingCategoryV1{{Name: "餐饮", Account: "Expenses:Food"}}
	if debtOnly.isReady() {
		t.Fatal("a draft with only a credit card is ready")
	}
}

func TestOnboardingDayComesFromTheShell(t *testing.T) {
	// Go on iOS runs in UTC, so the device's own date decides what is future.
	today := onboardingDay("2026-11-12")
	draft := defaultOnboardingDraft()
	draft.StartDate = "2026-11-12"
	if err := draft.validate(today); err != nil {
		t.Fatalf("the device's today was refused: %v", err)
	}
	if err := draft.validate(onboardingToday); err == nil {
		t.Fatal("a date after today was accepted")
	}
	if fallback := onboardingDay("not a date"); fallback.Format(time.DateOnly) != time.Now().Format(time.DateOnly) {
		t.Fatalf("fallback day = %s", fallback)
	}
}

func onboardingRun(t *testing.T, session *onboardingSession, name string, params map[string]any) error {
	t.Helper()
	encoded, _ := json.Marshal(params)
	for _, tool := range session.tools() {
		if tool, ok := tool.(onboardingTool); ok && tool.name == name {
			_, err := tool.run(encoded)
			return err
		}
	}
	t.Fatalf("no tool %s", name)
	return nil
}

func TestOnboardingToolsKeepExplicitCurrencyAndCheckCategoryKind(t *testing.T) {
	session, err := newOnboardingSession(nil, onboardingToday)
	if err != nil {
		t.Fatal(err)
	}
	if err := onboardingRun(t, session, "upsert_account", map[string]any{"kind": "bank_card", "name": "招行卡", "account": "Assets:Bank:CMB", "currency": "cny"}); err != nil {
		t.Fatal(err)
	}
	// The card stays in CNY after the ledger moves to HKD.
	if err := onboardingRun(t, session, "set_ledger_profile", map[string]any{"currency": "HKD"}); err != nil {
		t.Fatal(err)
	}
	if got := session.snapshot().Draft.Accounts[0].Currency; got != "CNY" {
		t.Fatalf("explicit currency became %q", got)
	}
	if err := onboardingRun(t, session, "upsert_category", map[string]any{"kind": "expense", "name": "餐饮", "account": "Expenses:Food"}); err != nil {
		t.Fatal(err)
	}
	if err := onboardingRun(t, session, "remove_category", map[string]any{"kind": "spending", "name": "餐饮"}); err == nil ||
		!strings.Contains(err.Error(), "income or expense") {
		t.Fatalf("a bad kind was accepted: %v", err)
	}
	if len(session.snapshot().Draft.ExpenseCategories) != 1 {
		t.Fatal("a refused removal changed the draft")
	}
}

func TestOnboardingAmountsAcceptWhatModelsSend(t *testing.T) {
	for raw, want := range map[string]string{`"1,234.50"`: "1234.50", `"¥ 88"`: "88", `1200`: "1200", `12.5`: "12.5", `""`: "", `null`: ""} {
		got, err := cleanAmount(json.RawMessage(raw))
		if err != nil || got != want {
			t.Errorf("%s: got %q, %v; want %q", raw, got, err, want)
		}
	}
	for _, raw := range []string{`"-3"`, `"一百"`, `true`} {
		if _, err := cleanAmount(json.RawMessage(raw)); err == nil {
			t.Errorf("%s accepted", raw)
		}
	}
}
