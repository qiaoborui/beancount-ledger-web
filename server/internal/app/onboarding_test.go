package app

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func starterOnboardingRequest() LedgerOnboardingRequest {
	return LedgerOnboardingRequest{
		Title:     " 我的生活账本 ",
		Currency:  " cny ",
		StartDate: " 2026-08-03 ",
		FundingSpaces: []LedgerOnboardingFundingSpace{
			{Kind: "cash", Name: " 钱包 ", Account: "Assets:Cash:Wallet", OpeningBalance: "500.00"},
			{Kind: "bank_card", Name: "招商银行", Account: "Assets:Bank:ChinaMerchants", OpeningBalance: "12800"},
		},
		Liabilities: []LedgerOnboardingLiability{{Kind: "credit_card", Name: "信用卡", Account: "Liabilities:CreditCard:Primary", OpeningBalance: "1200"}},
		IncomeCategories: []LedgerOnboardingCategory{
			{TemplateKey: "salary", Account: "Income:Work:Salary"},
			{CustomName: "稿费", Account: "Income:Writing"},
		},
		ExpenseCategories: []LedgerOnboardingCategory{
			{TemplateKey: "coffee", Account: "Expenses:Food:Coffee"},
			{TemplateKey: "rent", Account: "Expenses:Home:Rent"},
			{CustomName: "宠物用品", Account: "Expenses:Family:Pet"},
		},
	}
}

func TestStarterLedgerFilesCreatesBalancedSemanticGitLedger(t *testing.T) {
	input := starterOnboardingRequest()
	input.Normalize()
	if err := input.Validate(); err != nil {
		t.Fatal(err)
	}

	files, err := starterLedgerFiles(input)
	if err != nil {
		t.Fatal(err)
	}
	if got := files["main.bean"]; !strings.Contains(got, `option "title" "我的生活账本"`) || !strings.Contains(got, `include "transactions/2026.bean"`) {
		t.Fatalf("main.bean=%q", got)
	}
	accounts := files["accounts.bean"]
	for _, want := range []string{
		"open Assets:Cash:Wallet CNY",
		`alias: "钱包"`,
		"open Assets:Bank:ChinaMerchants CNY",
		"open Liabilities:CreditCard:Primary CNY",
		"open Income:Work:Salary CNY",
		`alias: "工资"`,
		"open Income:Writing CNY",
		"open Expenses:Food:Coffee CNY",
		"open Expenses:Home:Rent CNY",
		"open Expenses:Family:Pet CNY",
		"open Equity:Opening-Balances CNY",
	} {
		if !strings.Contains(accounts, want) {
			t.Fatalf("accounts.bean missing %q:\n%s", want, accounts)
		}
	}
	opening := files["transactions/2026.bean"]
	if !strings.Contains(opening, "Assets:Cash:Wallet 500.00 CNY") || !strings.Contains(opening, "Liabilities:CreditCard:Primary -1200 CNY") || strings.Count(opening, "Equity:Opening-Balances") != 3 {
		t.Fatalf("opening balances=%q", opening)
	}
}

func TestOnboardingAccountPathsAreAgentSuppliedAndRootBound(t *testing.T) {
	input := starterOnboardingRequest()
	input.FundingSpaces[0].Account = "Assets:Bank:Wallet"
	if err := input.Validate(); err == nil || !strings.Contains(err.Error(), "Assets:Cash") {
		t.Fatalf("expected invalid funding account root error, got %v", err)
	}
}

func TestDefaultOnboardingDraftUsesEmptyCollections(t *testing.T) {
	draft := defaultOnboardingDraft()
	if draft.FundingSpaces == nil || draft.Liabilities == nil || draft.IncomeCategories == nil || draft.ExpenseCategories == nil {
		t.Fatalf("first Agent response must encode collections as [] rather than null: %#v", draft)
	}
}

func TestOnboardingAgentUsesToolsAndOnlyPresentsAValidDraft(t *testing.T) {
	server := &Server{agentModel: &queuedAgentModel{results: []agentModelResult{
		{ToolCalls: []agentModelToolCall{{ID: "wallet", Type: "function", Function: agentModelFunctionCall{Name: "upsert_funding_space", Arguments: `{"kind":"digital_wallet","name":"微信","account":"Assets:Wallet:WeChat"}`}}}},
		{ToolCalls: []agentModelToolCall{{ID: "income", Type: "function", Function: agentModelFunctionCall{Name: "upsert_income_category", Arguments: `{"templateKey":"salary","account":"Income:Work:Salary"}`}}, {ID: "expense", Type: "function", Function: agentModelFunctionCall{Name: "upsert_expense_category", Arguments: `{"templateKey":"groceries","account":"Expenses:Food:Groceries"}`}}}},
		{ToolCalls: []agentModelToolCall{{ID: "present", Type: "function", Function: agentModelFunctionCall{Name: "present_onboarding_plan", Arguments: `{}`}}}},
		{Content: "我已经整理好了。你可以查看财务地图并确认创建。"},
	}}}

	result, err := server.runOnboardingAgent(context.Background(), LedgerOnboardingAgentRequest{Start: true})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Ready || len(result.Draft.FundingSpaces) != 1 || result.Draft.FundingSpaces[0].Account != "Assets:Wallet:WeChat" {
		t.Fatalf("unexpected onboarding agent result: %#v", result)
	}
	if err := result.Draft.Validate(); err != nil {
		t.Fatalf("agent returned an invalid ready draft: %v", err)
	}
}

func TestOnboardingAgentStreamsTheSharedToolAndDraftEvents(t *testing.T) {
	server := &Server{agentModel: &queuedAgentModel{results: []agentModelResult{
		{ToolCalls: []agentModelToolCall{{ID: "wallet", Type: "function", Function: agentModelFunctionCall{Name: "upsert_funding_space", Arguments: `{"kind":"digital_wallet","name":"微信","account":"Assets:Wallet:WeChat"}`}}}},
		{Content: "**已记录微信**。接下来告诉我你的收入分类。"},
	}}}
	var events []string
	_, err := server.runOnboardingAgentWithEvents(context.Background(), LedgerOnboardingAgentRequest{Start: true}, func(event string, _ any) error {
		events = append(events, event)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"status", "tool_call", "tool_result", "onboarding_draft", "message_delta", "final"} {
		found := false
		for _, event := range events {
			if event == want {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("shared Agent stream missing %q: %#v", want, events)
		}
	}
}

func TestOnboardingAgentNeverMarksAnIncompleteDraftReady(t *testing.T) {
	server := &Server{agentModel: &queuedAgentModel{results: []agentModelResult{
		{ToolCalls: []agentModelToolCall{{ID: "present", Type: "function", Function: agentModelFunctionCall{Name: "present_onboarding_plan", Arguments: `{}`}}}},
		{Content: "先告诉我你平时把钱放在哪里。"},
	}}}
	result, err := server.runOnboardingAgent(context.Background(), LedgerOnboardingAgentRequest{Start: true})
	if err != nil {
		t.Fatal(err)
	}
	if result.Ready || len(result.Draft.FundingSpaces) != 0 {
		t.Fatalf("incomplete draft must not be ready: %#v", result)
	}
}

func TestOnboardingAgentCannotPresentWithoutIncomeAndExpenseCategories(t *testing.T) {
	draft := defaultOnboardingDraft()
	draft.FundingSpaces = append(draft.FundingSpaces, LedgerOnboardingFundingSpace{
		Kind: "digital_wallet", Name: "微信", Account: "Assets:Wallet:WeChat",
	})
	ready := false
	tool := onboardingAgentTools(&draft, &ready)["present_onboarding_plan"]
	if _, err := tool.Execute(context.Background(), nil, AgentPageContext{}); err == nil {
		t.Fatal("present_onboarding_plan must reject a draft whose category map is still empty")
	}
	if ready {
		t.Fatal("incomplete category map must not become ready")
	}
}

func TestOnboardingAgentBulkCategoryToolsKeepDraftAndReadyInSync(t *testing.T) {
	draft := defaultOnboardingDraft()
	draft.FundingSpaces = append(draft.FundingSpaces, LedgerOnboardingFundingSpace{
		Kind: "digital_wallet", Name: "微信", Account: "Assets:Wallet:WeChat",
	})
	ready := true
	tools := onboardingAgentTools(&draft, &ready)
	if _, err := tools["replace_income_categories"].Execute(context.Background(), json.RawMessage(`{"categories":[{"templateKey":"salary","account":"Income:Work:Salary"},{"customName":"红包","account":"Income:Gift"}]}`), AgentPageContext{}); err != nil {
		t.Fatal(err)
	}
	if ready || len(draft.IncomeCategories) != 2 {
		t.Fatalf("income replacement must update the draft and reset ready: ready=%v draft=%#v", ready, draft)
	}
	if _, err := tools["replace_expense_categories"].Execute(context.Background(), json.RawMessage(`{"categories":[{"templateKey":"dining","account":"Expenses:Food:Dining"},{"customName":"通讯","account":"Expenses:Communication"}]}`), AgentPageContext{}); err != nil {
		t.Fatal(err)
	}
	if ready || len(draft.ExpenseCategories) != 2 {
		t.Fatalf("expense replacement must update the draft and keep ready false: ready=%v draft=%#v", ready, draft)
	}
	if _, err := tools["present_onboarding_plan"].Execute(context.Background(), nil, AgentPageContext{}); err != nil {
		t.Fatal(err)
	}
	if !ready {
		t.Fatal("a complete category draft should become ready only after present_onboarding_plan")
	}
}

func TestOnboardingAgentAllowsAnAuthenticatedButLockedSession(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	t.Setenv("LEDGER_AI_PROVIDER", "openai")
	t.Setenv("OPENAI_API_KEY", "")
	router := testRouter(t, cfg)
	lockedCookies := []*http.Cookie{}
	for _, cookie := range loginCookies(t, router) {
		if cookie.Name == sessionCookieName {
			lockedCookies = append(lockedCookies, cookie)
		}
	}
	response := requestWithCookies(router, http.MethodPost, "/api/onboarding/agent", `{"start":true}`, lockedCookies)
	if response.Code == http.StatusLocked {
		t.Fatalf("onboarding Agent must not require sensitive unlock: %s", response.Body.String())
	}
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "event: error") || !strings.Contains(response.Body.String(), "OPENAI_API_KEY is not configured") {
		t.Fatalf("expected the shared Agent stream to report the deliberately unconfigured provider after auth, got %d: %s", response.Code, response.Body.String())
	}
}

func TestOnboardingCustomNamesUseStableSafeSegmentsAndResolveCollisions(t *testing.T) {
	input := LedgerOnboardingRequest{
		Title:     "账本",
		Currency:  "CNY",
		StartDate: "2026-08-03",
		FundingSpaces: []LedgerOnboardingFundingSpace{
			{Kind: "bank_card", Name: "My Card", Account: "Assets:Bank:MyCard"},
			{Kind: "bank_card", Name: "my card", Account: "Assets:Bank:MyCard2"},
		},
		IncomeCategories: []LedgerOnboardingCategory{{CustomName: "A", Account: "Income:Custom:A"}, {CustomName: "a", Account: "Income:Custom:A2"}},
	}
	if err := input.Validate(); err != nil {
		t.Fatal(err)
	}
	first, err := starterLedgerAccounts(input)
	if err != nil {
		t.Fatal(err)
	}
	second, err := starterLedgerAccounts(input)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("account mapping was not stable: %#v != %#v", first, second)
	}
	accounts := make([]string, 0, len(first))
	for _, account := range first {
		accounts = append(accounts, account.Account)
		if err := validateAccount("generated account", account.Account); err != nil {
			t.Fatal(err)
		}
	}
	joined := strings.Join(accounts, "\n")
	for _, want := range []string{"Assets:Bank:MyCard", "Assets:Bank:MyCard2", "Income:Custom:A", "Income:Custom:A2"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("generated accounts missing %q:\n%s", want, joined)
		}
	}
}

func TestStarterLedgerFilesPassBeanCheckWhenAvailable(t *testing.T) {
	binary, err := exec.LookPath("bean-check")
	if err != nil {
		t.Skip("bean-check is not installed in this Go test environment")
	}
	input := starterOnboardingRequest()
	input.Normalize()
	files, err := starterLedgerFiles(input)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	for path, content := range files {
		fullPath := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(fullPath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(fullPath, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	command := exec.Command(binary, "main.bean")
	command.Dir = root
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("bean-check failed: %v\n%s", err, output)
	}
}

func TestOnboardingInitializationCommitsOnlyToGitHub(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{"README.md": "private ledger\n"})
	defer fake.server.Close()
	input := starterOnboardingRequest()
	input.Normalize()
	files, err := starterLedgerFiles(input)
	if err != nil {
		t.Fatal(err)
	}

	writer := NewLedgerWriter(githubAPITestConfig(t, fake), nil)
	gitSHA, err := writer.RunTransactionWithSourceResult("onboarding-initialize", func(tx *LedgerWriteTransaction) error {
		if exists, err := tx.Exists("main.bean"); err != nil {
			return err
		} else if exists {
			return errors.New("账本已初始化，不会覆盖现有 main.bean")
		}
		for _, path := range sortedStringKeys(files) {
			if err := tx.WriteFile(path, []byte(files[path]), 0o644); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if gitSHA != "new-commit-1" || fake.updatedRef != "refs/heads/main" {
		t.Fatalf("gitSHA=%q ref=%q", gitSHA, fake.updatedRef)
	}
	if got := fake.files["main.bean"]; !strings.Contains(got, "我的生活账本") {
		t.Fatalf("main.bean was not committed through GitHub: %q", got)
	}

	_, err = writer.RunTransactionWithSourceResult("onboarding-initialize", func(tx *LedgerWriteTransaction) error {
		if exists, err := tx.Exists("main.bean"); err != nil {
			return err
		} else if exists {
			return errors.New("账本已初始化，不会覆盖现有 main.bean")
		}
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "已初始化") {
		t.Fatalf("existing main.bean error=%v", err)
	}
}

func TestOnboardingRoutesInitializeAnEmptyGitHubLedger(t *testing.T) {
	t.Setenv("AUTH_SECRET", "test-auth-secret-with-enough-entropy")
	t.Setenv("APP_PASSWORD", "secret")
	fake := newFakeGitHubLedgerAPI(t, map[string]string{"README.md": "private ledger\n"})
	defer fake.server.Close()
	cfg := githubAPITestConfig(t, fake)
	router := newRouter(cfg, &Server{cfg: cfg, writer: NewLedgerWriter(cfg, nil), limiter: NewRateLimiter()})
	cookies := loginCookies(t, router)

	status := requestWithCookies(router, http.MethodGet, "/api/onboarding", "", cookies)
	if status.Code != http.StatusOK || !strings.Contains(status.Body.String(), `"state":"uninitialized"`) || !strings.Contains(status.Body.String(), `"salary"`) {
		t.Fatalf("onboarding status=%d body=%s", status.Code, status.Body.String())
	}

	created := requestWithCookies(router, http.MethodPost, "/api/onboarding/initialize", `{"title":"我的生活账本","currency":"CNY","startDate":"2026-08-03","fundingSpaces":[{"kind":"cash","name":"钱包","account":"Assets:Cash:Wallet","currency":"CNY","openingBalance":"500"}],"liabilities":[],"incomeCategories":[{"templateKey":"salary","account":"Income:Work:Salary"}],"expenseCategories":[{"templateKey":"coffee","account":"Expenses:Food:Coffee"}]}`, cookies)
	if created.Code != http.StatusAccepted || !strings.Contains(created.Body.String(), `"gitSHA":"new-commit-1"`) {
		t.Fatalf("onboarding initialize=%d body=%s", created.Code, created.Body.String())
	}
	if got := fake.files["main.bean"]; !strings.Contains(got, "我的生活账本") {
		t.Fatalf("main.bean=%q", got)
	}

	again := requestWithCookies(router, http.MethodPost, "/api/onboarding/initialize", `{"title":"second","currency":"CNY","startDate":"2026-08-03","fundingSpaces":[{"kind":"cash","name":"备用金","account":"Assets:Cash:Reserve"}],"incomeCategories":[],"expenseCategories":[]}`, cookies)
	if again.Code != http.StatusBadRequest || !strings.Contains(again.Body.String(), "不会覆盖") {
		t.Fatalf("second onboarding initialize=%d body=%s", again.Code, again.Body.String())
	}
}

func TestOnboardingValidationRejectsUnsafeSemanticInput(t *testing.T) {
	for _, input := range []LedgerOnboardingRequest{
		{Title: "ledger", Currency: "CNY", StartDate: "2026-08-03"},
		{Title: "ledger", Currency: "CNY", StartDate: "2026-08-03", FundingSpaces: []LedgerOnboardingFundingSpace{{Kind: "filesystem", Name: "账本"}}},
		{Title: "ledger", Currency: "CNY", StartDate: "2026-08-03", FundingSpaces: []LedgerOnboardingFundingSpace{{Kind: "cash", Name: "钱包", OpeningBalance: "-1"}}},
		{Title: "ledger", Currency: "CNY", StartDate: "2026-08-03", FundingSpaces: []LedgerOnboardingFundingSpace{{Kind: "cash", Name: "钱包"}}, ExpenseCategories: []LedgerOnboardingCategory{{TemplateKey: "unknown"}}},
		{Title: "ledger", Currency: "CNY", StartDate: "2026-08-03", FundingSpaces: []LedgerOnboardingFundingSpace{{Kind: "cash", Name: "钱包"}}, IncomeCategories: []LedgerOnboardingCategory{{TemplateKey: "salary", CustomName: "工资"}}},
	} {
		if err := input.Validate(); err == nil {
			t.Fatalf("expected invalid onboarding input to fail: %#v", input)
		}
	}
}
