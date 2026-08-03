package app

import (
	"errors"
	"net/http"
	"strings"
	"testing"
)

func starterOnboardingRequest() LedgerOnboardingRequest {
	return LedgerOnboardingRequest{
		Title:     " 我的生活账本 ",
		Currency:  " cny ",
		StartDate: " 2026-08-03 ",
		Assets: []LedgerOnboardingAsset{
			{Account: " Assets:Cash ", OpeningBalance: "500.00"},
			{Account: "Liabilities:Card", OpeningBalance: "1200"},
		},
		Categories: []string{" Expenses:Food ", "Income:Salary"},
	}
}

func TestStarterLedgerFilesCreatesBalancedGitLedger(t *testing.T) {
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
	if got := files["accounts.bean"]; !strings.Contains(got, "2026-08-03 open Assets:Cash CNY") || !strings.Contains(got, "2026-08-03 open Liabilities:Card CNY") || !strings.Contains(got, "2026-08-03 open Equity:Opening-Balances") {
		t.Fatalf("accounts.bean=%q", got)
	}
	opening := files["transactions/2026.bean"]
	if !strings.Contains(opening, "Assets:Cash 500.00 CNY") || !strings.Contains(opening, "Liabilities:Card -1200 CNY") || strings.Count(opening, "Equity:Opening-Balances") != 2 {
		t.Fatalf("opening balances=%q", opening)
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
	if status.Code != http.StatusOK || !strings.Contains(status.Body.String(), `"state":"uninitialized"`) {
		t.Fatalf("onboarding status=%d body=%s", status.Code, status.Body.String())
	}

	created := requestWithCookies(router, http.MethodPost, "/api/onboarding/initialize", `{"title":"我的生活账本","currency":"CNY","startDate":"2026-08-03","assets":[{"account":"Assets:Cash","currency":"CNY","openingBalance":"500"}],"categories":["Expenses:Food","Income:Salary"]}`, cookies)
	if created.Code != http.StatusAccepted || !strings.Contains(created.Body.String(), `"gitSHA":"new-commit-1"`) {
		t.Fatalf("onboarding initialize=%d body=%s", created.Code, created.Body.String())
	}
	if got := fake.files["main.bean"]; !strings.Contains(got, "我的生活账本") {
		t.Fatalf("main.bean=%q", got)
	}

	again := requestWithCookies(router, http.MethodPost, "/api/onboarding/initialize", `{"title":"second","currency":"CNY","startDate":"2026-08-03","assets":[{"account":"Assets:Cash"}]}`, cookies)
	if again.Code != http.StatusBadRequest || !strings.Contains(again.Body.String(), "不会覆盖") {
		t.Fatalf("second onboarding initialize=%d body=%s", again.Code, again.Body.String())
	}
}

func TestOnboardingValidationRejectsUnsafeAccounts(t *testing.T) {
	for _, input := range []LedgerOnboardingRequest{
		{Title: "ledger", Currency: "CNY", StartDate: "2026-08-03"},
		{Title: "ledger", Currency: "CNY", StartDate: "2026-08-03", Assets: []LedgerOnboardingAsset{{Account: "Assets:Cash"}}, Categories: []string{"Assets:Side"}},
		{Title: "ledger", Currency: "CNY", StartDate: "2026-08-03", Assets: []LedgerOnboardingAsset{{Account: "Assets:Cash"}}, Categories: []string{"Expenses:Food", "Expenses:Food"}},
		{Title: "ledger", Currency: "CNY", StartDate: "2026-08-03", Assets: []LedgerOnboardingAsset{{Account: "Assets:Cash"}, {Account: "Assets:Cash"}}},
	} {
		if err := input.Validate(); err == nil {
			t.Fatalf("expected invalid onboarding input to fail: %#v", input)
		}
	}
}
