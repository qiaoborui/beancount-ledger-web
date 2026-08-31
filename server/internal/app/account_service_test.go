package app

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAccountServiceDetail(t *testing.T) {
	service := NewAccountService(NewLedgerCache(testLedger(t)), nil)

	if _, err := service.Detail("", "", "", ""); !errors.Is(err, ErrAccountRequired) {
		t.Fatalf("empty account error = %v, want ErrAccountRequired", err)
	}
	if _, err := service.Detail("Assets:Missing", "", "", ""); !errors.Is(err, ErrAccountNotFound) {
		t.Fatalf("missing account error = %v, want ErrAccountNotFound", err)
	}

	detail, err := service.Detail("Assets:Cash", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if detail.Account != "Assets:Cash" || detail.Label != "现金" || detail.Alias == nil || *detail.Alias != "现金" {
		t.Fatalf("unexpected account detail metadata: %#v", detail)
	}
	if detail.CurrentBalance != 98800 || len(detail.Rows) != 2 {
		t.Fatalf("unexpected account detail balance/rows: %#v", detail)
	}
}

func TestAccountServiceDetailScopesRowsAndBalancesToRange(t *testing.T) {
	service := NewAccountService(NewLedgerCache(testLedger(t)), nil)

	detail, err := service.Detail("Assets:Cash", "CNY", "2026-05-02", "2026-06-01")
	if err != nil {
		t.Fatal(err)
	}
	if len(detail.Rows) != 1 || detail.Rows[0].Date != "2026-05-31" {
		t.Fatalf("period rows = %#v, want only May 31", detail.Rows)
	}
	if detail.OpeningBalance != -1200 || detail.ClosingBalance != 98800 || detail.PeriodChange != 100000 {
		t.Fatalf("period balances = %#v", detail)
	}
	if detail.CurrentBalance != 98800 {
		t.Fatalf("current balance = %d, want 98800", detail.CurrentBalance)
	}

	if _, err := service.Detail("Assets:Cash", "CNY", "2026-06-01", "2026-05-01"); !errors.Is(err, ErrAccountRange) {
		t.Fatalf("invalid range error = %v, want ErrAccountRange", err)
	}
}

func TestAccountServiceDetailKeepsCurrenciesSeparate(t *testing.T) {
	snapshot := &LedgerSnapshot{
		Accounts: []Account{{Account: "Assets:Broker", Currency: "USD", Label: "Broker", Active: true}},
		Transactions: []Transaction{
			{
				Date: "2026-04-01",
				Postings: []Posting{
					{Account: "Assets:Broker", Amount: 10000, Currency: "USD"},
					{Account: "Equity:Opening", Amount: -10000, Currency: "USD"},
					{Account: "Assets:Broker", Amount: 20000, Currency: "HKD"},
					{Account: "Equity:Opening", Amount: -20000, Currency: "HKD"},
				},
			},
		},
	}
	service := NewAccountServiceWithSnapshot(nil, nil, func() (*LedgerSnapshot, error) { return snapshot, nil })

	usd, err := service.Detail("Assets:Broker", "USD", "2026-04-01", "2026-05-01")
	if err != nil {
		t.Fatal(err)
	}
	if usd.Currency != "USD" || usd.ClosingBalance != 10000 || len(usd.Rows) != 1 || usd.Rows[0].Change != 10000 {
		t.Fatalf("USD detail = %#v", usd)
	}

	hkd, err := service.Detail("Assets:Broker", "HKD", "2026-04-01", "2026-05-01")
	if err != nil {
		t.Fatal(err)
	}
	if hkd.Currency != "HKD" || hkd.ClosingBalance != 20000 || len(hkd.Rows) != 1 || hkd.Rows[0].Change != 20000 {
		t.Fatalf("HKD detail = %#v", hkd)
	}

	if _, err := service.Detail("Assets:Broker", "EUR", "2026-04-01", "2026-05-01"); !errors.Is(err, ErrAccountCurrency) {
		t.Fatalf("unsupported currency error = %v, want ErrAccountCurrency", err)
	}
}

func TestAccountDetailFromSortedAggregatesRepeatedAccountPostings(t *testing.T) {
	rows := AccountDetailFromSorted("Assets:Cash", []Transaction{
		{
			Date: "2026-01-01",
			Postings: []Posting{
				{Account: "Assets:Cash", Amount: 10_000, Currency: "CNY"},
				{Account: "Expenses:Food", Amount: -15_000, Currency: "CNY"},
				{Account: "Assets:Cash", Amount: 5_000, Currency: "CNY"},
			},
		},
		{
			Date: "2026-01-02",
			Postings: []Posting{
				{Account: "Assets:Cash", Amount: -2_000, Currency: "CNY"},
				{Account: "Expenses:Food", Amount: 2_000, Currency: "CNY"},
			},
		},
	})

	if len(rows) != 2 {
		t.Fatalf("rows = %#v, want 2", rows)
	}
	if rows[0].Change != 15_000 || rows[0].Balance != 15_000 {
		t.Fatalf("first row = %#v, want aggregated change and balance 15000", rows[0])
	}
	if rows[1].Change != -2_000 || rows[1].Balance != 13_000 {
		t.Fatalf("second row = %#v, want closing balance 13000", rows[1])
	}
}

func TestAccountServiceAppendDefaultsCurrency(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	cache := NewLedgerCache(cfg)
	service := NewAccountService(cache, NewLedgerWriter(cfg, cache))
	input, err := service.Append(AccountInput{Date: "2026-01-01", Account: "Assets:Wallet", Alias: "钱包"})
	if err != nil {
		t.Fatal(err)
	}
	if input.Currency != "CNY" {
		t.Fatalf("default currency = %q, want CNY", input.Currency)
	}
	text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "accounts.bean")))
	if !strings.Contains(text, "open Assets:Wallet CNY") || !strings.Contains(text, `alias: "钱包"`) {
		t.Fatalf("account was not appended:\n%s", text)
	}
}

func TestAccountServiceStatuses(t *testing.T) {
	service := NewAccountService(NewLedgerCache(testLedger(t)), nil)

	statuses, err := service.Statuses()
	if err != nil {
		t.Fatal(err)
	}
	if len(statuses) == 0 || statuses[0].Account == "" {
		t.Fatalf("expected account statuses, got %#v", statuses)
	}
}
