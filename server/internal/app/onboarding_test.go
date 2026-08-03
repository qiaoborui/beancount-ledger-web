package app

import (
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
			{Kind: "cash", Name: " 钱包 ", OpeningBalance: "500.00"},
			{Kind: "bank_card", Name: "招商银行", OpeningBalance: "12800"},
		},
		Liabilities: []LedgerOnboardingLiability{{Kind: "credit_card", Name: "信用卡", OpeningBalance: "1200"}},
		IncomeCategories: []LedgerOnboardingCategory{
			{TemplateKey: "salary"},
			{CustomName: "稿费"},
		},
		ExpenseCategories: []LedgerOnboardingCategory{
			{TemplateKey: "coffee"},
			{TemplateKey: "rent"},
			{CustomName: "宠物用品"},
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
		"open Assets:Cash:U94b1u5305 CNY",
		`alias: "钱包"`,
		"open Assets:Bank:U62dbu5546u94f6u884c CNY",
		"open Liabilities:CreditCard:U4fe1u7528u5361 CNY",
		"open Income:Salary CNY",
		`alias: "工资"`,
		"open Income:Custom:U7a3fu8d39 CNY",
		"open Expenses:Food:Coffee CNY",
		"open Expenses:Home:Rent CNY",
		"open Expenses:Custom:U5ba0u7269u7528u54c1 CNY",
		"open Equity:Opening-Balances CNY",
	} {
		if !strings.Contains(accounts, want) {
			t.Fatalf("accounts.bean missing %q:\n%s", want, accounts)
		}
	}
	opening := files["transactions/2026.bean"]
	if !strings.Contains(opening, "Assets:Cash:U94b1u5305 500.00 CNY") || !strings.Contains(opening, "Liabilities:CreditCard:U4fe1u7528u5361 -1200 CNY") || strings.Count(opening, "Equity:Opening-Balances") != 3 {
		t.Fatalf("opening balances=%q", opening)
	}
}

func TestOnboardingCustomNamesUseStableSafeSegmentsAndResolveCollisions(t *testing.T) {
	input := LedgerOnboardingRequest{
		Title:     "账本",
		Currency:  "CNY",
		StartDate: "2026-08-03",
		FundingSpaces: []LedgerOnboardingFundingSpace{
			{Kind: "bank_card", Name: "My Card"},
			{Kind: "bank_card", Name: "my card"},
		},
		IncomeCategories: []LedgerOnboardingCategory{{CustomName: "A"}, {CustomName: "a"}},
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
	for _, want := range []string{"Assets:Bank:My-card", "Assets:Bank:My-card-2", "Income:Custom:A", "Income:Custom:A-2"} {
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

	created := requestWithCookies(router, http.MethodPost, "/api/onboarding/initialize", `{"title":"我的生活账本","currency":"CNY","startDate":"2026-08-03","fundingSpaces":[{"kind":"cash","name":"钱包","currency":"CNY","openingBalance":"500"}],"liabilities":[],"incomeCategories":[{"templateKey":"salary"}],"expenseCategories":[{"templateKey":"coffee"}]}`, cookies)
	if created.Code != http.StatusAccepted || !strings.Contains(created.Body.String(), `"gitSHA":"new-commit-1"`) {
		t.Fatalf("onboarding initialize=%d body=%s", created.Code, created.Body.String())
	}
	if got := fake.files["main.bean"]; !strings.Contains(got, "我的生活账本") {
		t.Fatalf("main.bean=%q", got)
	}

	again := requestWithCookies(router, http.MethodPost, "/api/onboarding/initialize", `{"title":"second","currency":"CNY","startDate":"2026-08-03","fundingSpaces":[{"kind":"cash","name":"备用金"}],"incomeCategories":[],"expenseCategories":[]}`, cookies)
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
