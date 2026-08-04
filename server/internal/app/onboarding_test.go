package app

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
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
func TestOnboardingAgentAllowsAnAuthenticatedButLockedSession(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	agent := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/onboarding/turn" || r.Header.Get("X-Agent-Service-Token") != "agent-secret" {
			t.Fatalf("unexpected onboarding Agent request: %s token=%q", r.URL.Path, r.Header.Get("X-Agent-Service-Token"))
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("event: final\ndata: {\"ready\":false}\n\n"))
	}))
	defer agent.Close()
	cfg.AgentServiceURL = agent.URL
	cfg.AgentServiceToken = "agent-secret"
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
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "event: final") {
		t.Fatalf("expected the Bub Agent stream after auth, got %d: %s", response.Code, response.Body.String())
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
	t.Setenv("BEAN_CHECK_BIN", binary)
	input := starterOnboardingRequest()
	input.Normalize()
	files, err := starterLedgerFiles(input)
	if err != nil {
		t.Fatal(err)
	}
	if err := validateStarterLedgerFiles(context.Background(), files); err != nil {
		t.Fatal(err)
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
	cookies := []*http.Cookie{}
	for _, cookie := range loginCookies(t, router) {
		if cookie.Name == sessionCookieName {
			cookies = append(cookies, cookie)
		}
	}

	status := requestWithCookies(router, http.MethodGet, "/api/onboarding", "", cookies)
	if status.Code != http.StatusOK || !strings.Contains(status.Body.String(), `"state":"uninitialized"`) || !strings.Contains(status.Body.String(), `"salary"`) {
		t.Fatalf("onboarding status=%d body=%s", status.Code, status.Body.String())
	}

	initializeBody := `{"title":"我的生活账本","currency":"CNY","startDate":"2026-08-03","fundingSpaces":[{"kind":"cash","name":"钱包","account":"Assets:Cash:Wallet","currency":"CNY","openingBalance":"500"}],"liabilities":[],"incomeCategories":[{"templateKey":"salary","account":"Income:Work:Salary"}],"expenseCategories":[{"templateKey":"coffee","account":"Expenses:Food:Coffee"}]}`
	unauthenticated := requestWithCookies(router, http.MethodPost, "/api/onboarding/initialize", initializeBody, nil)
	if unauthenticated.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated onboarding initialize=%d body=%s", unauthenticated.Code, unauthenticated.Body.String())
	}

	created := requestWithCookies(router, http.MethodPost, "/api/onboarding/initialize", initializeBody, cookies)
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
		{Title: "ledger", Currency: "CNY", StartDate: "2026-08-03", FundingSpaces: []LedgerOnboardingFundingSpace{{Kind: "cash", Name: "钱包", Account: "Assets:Cash:Wallet"}, {Kind: "cash", Name: "备用金", Account: "Assets:Cash:Wallet"}}},
	} {
		if err := input.Validate(); err == nil {
			t.Fatalf("expected invalid onboarding input to fail: %#v", input)
		}
	}
	oversized := starterOnboardingRequest()
	oversized.FundingSpaces = make([]LedgerOnboardingFundingSpace, maxOnboardingFundingSpaces+1)
	if err := oversized.Validate(); err == nil || !strings.Contains(err.Error(), "最多") {
		t.Fatalf("expected oversized onboarding input to fail with a limit error: %v", err)
	}
}

func TestOnboardingInitializationDoesNotOverwritePartialLedger(t *testing.T) {
	t.Setenv("AUTH_SECRET", "test-auth-secret-with-enough-entropy")
	t.Setenv("APP_PASSWORD", "secret")
	fake := newFakeGitHubLedgerAPI(t, map[string]string{"README.md": "private ledger\n", "accounts.bean": "sentinel\n"})
	defer fake.server.Close()
	cfg := githubAPITestConfig(t, fake)
	router := newRouter(cfg, &Server{cfg: cfg, writer: NewLedgerWriter(cfg, nil), limiter: NewRateLimiter()})
	cookies := loginCookies(t, router)

	response := requestWithCookies(router, http.MethodPost, "/api/onboarding/initialize", `{"title":"我的生活账本","currency":"CNY","startDate":"2026-08-03","fundingSpaces":[{"kind":"cash","name":"钱包","account":"Assets:Cash:Wallet"}],"liabilities":[],"incomeCategories":[],"expenseCategories":[]}`, cookies)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "不会覆盖") {
		t.Fatalf("partial ledger initialize=%d body=%s", response.Code, response.Body.String())
	}
	if got := fake.files["accounts.bean"]; got != "sentinel\n" {
		t.Fatalf("partial ledger file was overwritten: %q", got)
	}
}

func TestOnboardingInitializationRunsBeanCheckBeforeCommit(t *testing.T) {
	t.Setenv("AUTH_SECRET", "test-auth-secret-with-enough-entropy")
	t.Setenv("APP_PASSWORD", "secret")
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	if err := os.WriteFile(beanCheck, []byte("#!/bin/sh\necho invalid generated ledger >&2\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	fake := newFakeGitHubLedgerAPI(t, map[string]string{"README.md": "private ledger\n"})
	defer fake.server.Close()
	cfg := githubAPITestConfig(t, fake)
	router := newRouter(cfg, &Server{cfg: cfg, writer: NewLedgerWriter(cfg, nil), limiter: NewRateLimiter()})
	cookies := loginCookies(t, router)

	response := requestWithCookies(router, http.MethodPost, "/api/onboarding/initialize", `{"title":"我的生活账本","currency":"CNY","startDate":"2026-08-03","fundingSpaces":[{"kind":"cash","name":"钱包","account":"Assets:Cash:Wallet"}],"liabilities":[],"incomeCategories":[],"expenseCategories":[]}`, cookies)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "bean-check") {
		t.Fatalf("bean-check rejection=%d body=%s", response.Code, response.Body.String())
	}
	if fake.updatedRef != "" || fake.files["main.bean"] != "" {
		t.Fatalf("invalid ledger was committed: ref=%q main=%q", fake.updatedRef, fake.files["main.bean"])
	}
}
