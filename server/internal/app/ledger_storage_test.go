package app

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLedgerParserAndCache(t *testing.T) {
	cfg := testLedger(t)
	cache := NewLedgerCache(cfg)
	snapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Transactions) != 2 {
		t.Fatalf("transactions = %d, want 2", len(snapshot.Transactions))
	}
	if len(snapshot.BeanEntries) == 0 {
		t.Fatal("snapshot should keep compiled AST entries")
	}
	if len(snapshot.BeanErrors) != 0 {
		t.Fatalf("snapshot compile errors: %#v", snapshot.BeanErrors)
	}
	if snapshot.OptionsMap["title"] != "Test Ledger" {
		t.Fatalf("snapshot options map not derived from AST: %#v", snapshot.OptionsMap)
	}
	if snapshot.Balances["Assets:Cash"] != 98800 {
		t.Fatalf("cash balance = %d, want 98800", snapshot.Balances["Assets:Cash"])
	}
	if snapshot.Accounts[0].Account != "Assets:Cash" || snapshot.Accounts[0].Label != "现金" {
		t.Fatalf("account alias not parsed: %#v", snapshot.Accounts[0])
	}
	second, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if second != snapshot {
		t.Fatal("snapshot was not reused")
	}
}

func TestParseTransactionsInfersSingleBlankPostingWithCost(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "commodities.bean"), strings.Join([]string{
		"2026-01-01 commodity CNY",
		"2026-01-01 commodity USD",
		"2026-01-01 commodity NVDA",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), strings.Join([]string{
		"2026-01-01 open Assets:Broker:USD USD",
		"2026-01-01 open Assets:Broker:Investments:NVDA NVDA",
		"2026-01-01 open Expenses:Investment:Fee USD",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean"), strings.Join([]string{
		`2026-05-31 * "Broker" "Buy NVDA"`,
		"  Assets:Broker:Investments:NVDA 3 NVDA {209.50 USD}",
		"  Expenses:Investment:Fee 0.99 USD",
		"  Assets:Broker:USD",
		"",
	}, "\n"))

	snapshot, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	raw := snapshot.RawBalances
	if raw["Assets:Broker:Investments:NVDA"]["NVDA"] != 300 {
		t.Fatalf("NVDA balance = %#v, want 3 NVDA", raw["Assets:Broker:Investments:NVDA"])
	}
	if raw["Assets:Broker:USD"]["USD"] != -62949 {
		t.Fatalf("USD balance = %#v, want -629.49 USD", raw["Assets:Broker:USD"])
	}
	detail := AccountDetail("Assets:Broker:USD", snapshot.Transactions)
	if len(detail) != 1 || detail[0].Change != -62949 || detail[0].Txn.Postings[2].Currency != "USD" {
		t.Fatalf("USD detail did not include inferred posting: %#v", detail)
	}
}

func TestParseTransactionsIncludesPaddingFromPadBalance(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "commodities.bean"), strings.Join([]string{
		"2026-01-01 commodity CNY",
		"2026-01-01 commodity USD",
		"2026-01-01 commodity NVDA",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"), strings.Join([]string{
		"2026-01-01 open Assets:Broker:USD USD",
		"2026-01-01 open Assets:Broker:Investments:NVDA NVDA",
		"2026-01-01 open Expenses:Investment:Fee USD",
		"2026-01-01 open Income:Investment:Gain USD",
		"2026-01-01 open Equity:Opening-Balances USD",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean"), strings.Join([]string{
		`2026-05-15 * "Broker" "Opening transfer"`,
		"  Assets:Broker:USD 802.35 USD",
		"  Equity:Opening-Balances -802.35 USD",
		"",
		"2026-05-15 pad Assets:Broker:USD Income:Investment:Gain",
		"2026-05-16 balance Assets:Broker:USD 802.95 USD",
		"",
		`2026-05-16 * "Broker" "Buy NVDA"`,
		"  Assets:Broker:Investments:NVDA 3 NVDA {209.50 USD}",
		"  Expenses:Investment:Fee 0.99 USD",
		"  Assets:Broker:USD",
		"",
	}, "\n"))

	snapshot, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.RawBalances["Assets:Broker:USD"]["USD"] != 17346 {
		t.Fatalf("USD balance = %#v, want 173.46 USD", snapshot.RawBalances["Assets:Broker:USD"])
	}
	detail := AccountDetail("Assets:Broker:USD", snapshot.Transactions)
	if len(detail) != 3 || detail[1].Change != 60 || detail[1].Txn.Narration == "" {
		t.Fatalf("padding transaction missing from account detail: %#v", detail)
	}
}

func TestBeanParserAcceptsPythonBeancountTransactionForms(t *testing.T) {
	lines := []BeanLine{
		{File: "main.bean", Line: 1, Text: `2026/5/1 txn "Dinner only narration" #food ^receipt-1`},
		{File: "main.bean", Line: 2, Text: `  date-meta: 2026/5/2`},
		{File: "main.bean", Line: 3, Text: `  empty-meta:`},
		{File: "main.bean", Line: 4, Text: `  nil-meta: NULL`},
		{File: "main.bean", Line: 5, Text: `  * Expenses:Food 12.00 USD @ 7.10 CNY`},
		{File: "main.bean", Line: 6, Text: `  Assets:Cash`},
		{File: "main.bean", Line: 7, Text: ``},
		{File: "main.bean", Line: 8, Text: `2026-05-02 ! "Broker" "Buy option" #invest`},
		{File: "main.bean", Line: 9, Text: `  Assets:Broker 1 /NQH21_QNEG21C13100 {100.00 USD}`},
		{File: "main.bean", Line: 10, Text: `  Assets:Cash`},
	}

	result := ParseBeanLines(lines)
	if len(result.Errors) != 0 {
		t.Fatalf("parse errors: %#v", result.Errors)
	}
	txns := ParseTransactions(lines)
	if len(txns) != 2 {
		t.Fatalf("transactions = %#v, want 2", txns)
	}
	first := txns[0]
	if first.Date != "2026-05-01" || first.Payee != "" || first.Narration != "Dinner only narration" {
		t.Fatalf("unexpected txn head: %#v", first)
	}
	if len(first.Tags) != 1 || first.Tags[0] != "food" || len(first.Links) != 1 || first.Links[0] != "receipt-1" {
		t.Fatalf("tags/links not parsed: %#v", first)
	}
	if first.Metadata["date-meta"] != "2026-05-02" {
		t.Fatalf("date metadata not normalized: %#v", first.Metadata)
	}
	if _, ok := first.Metadata["empty-meta"]; !ok {
		t.Fatalf("empty metadata key missing: %#v", first.Metadata)
	}
	if first.Postings[0].Flag != "*" || first.Postings[1].Amount != -8520 || first.Postings[1].Currency != "CNY" {
		t.Fatalf("posting flag or @ inference wrong: %#v", first.Postings)
	}
	second := txns[1]
	if second.Postings[0].Currency != "/NQH21_QNEG21C13100" || second.Postings[1].Amount != -10000 || second.Postings[1].Currency != "USD" {
		t.Fatalf("slash commodity or cost inference wrong: %#v", second.Postings)
	}
}

func TestBeanParserDirectiveCoverage(t *testing.T) {
	lines := []BeanLine{
		{File: "main.bean", Line: 1, Text: `option "title" "Parser Test"`},
		{File: "main.bean", Line: 2, Text: `include "accounts.bean"`},
		{File: "main.bean", Line: 3, Text: `plugin "beancount.plugins.auto_accounts"`},
		{File: "main.bean", Line: 1, Text: `2026/1/1 commodity TLT_040921C144`},
		{File: "main.bean", Line: 2, Text: `2026/1/1 price TLT_040921C144 (1 + 2) USD`},
		{File: "main.bean", Line: 3, Text: `2026/1/2 balance Assets:Broker 3.00 ~ 0.01 USD`},
	}

	if got := ParseCommodities(lines); len(got) != 1 || got[0] != "TLT_040921C144" {
		t.Fatalf("commodities = %#v", got)
	}
	prices := ParsePrices(lines)
	if len(prices) != 1 || prices[0].Amount != 300 || prices[0].QuoteCurrency != "USD" {
		t.Fatalf("prices = %#v", prices)
	}
	balances := ParseBalances(lines)
	if len(balances) != 1 || balances[0].Date != "2026-01-02" || balances[0].Amount != 300 {
		t.Fatalf("balances = %#v", balances)
	}
	parsed := ParseBeanLines(lines)
	if parsed.Entries[0].Kind != "option" || parsed.Entries[0].Name != "title" || parsed.Entries[0].Value != "Parser Test" {
		t.Fatalf("option entry not parsed: %#v", parsed.Entries[0])
	}
	if parsed.Entries[1].Kind != "include" || parsed.Entries[1].Filename != "accounts.bean" {
		t.Fatalf("include entry not parsed: %#v", parsed.Entries[1])
	}
	if parsed.Entries[2].Kind != "plugin" || parsed.Entries[2].Name != "beancount.plugins.auto_accounts" {
		t.Fatalf("plugin entry not parsed: %#v", parsed.Entries[2])
	}
}

func TestBeanParserAppliesPushTagAndPushMetaScopes(t *testing.T) {
	lines := []BeanLine{
		{File: "main.bean", Line: 1, Text: `pushtag #trip`},
		{File: "main.bean", Line: 2, Text: `pushmeta trip: "tokyo"`},
		{File: "main.bean", Line: 3, Text: `2026-02-01 * "Cafe" "Breakfast"`},
		{File: "main.bean", Line: 4, Text: `  Expenses:Food 10.00 USD`},
		{File: "main.bean", Line: 5, Text: `  Assets:Cash`},
		{File: "main.bean", Line: 6, Text: `2026-02-02 note Assets:Cash "ATM receipt" #cash`},
		{File: "main.bean", Line: 7, Text: `  trip: "override"`},
		{File: "main.bean", Line: 8, Text: `poptag #trip`},
		{File: "main.bean", Line: 9, Text: `popmeta trip:`},
		{File: "main.bean", Line: 10, Text: `2026-02-03 * "Store" "Water"`},
		{File: "main.bean", Line: 11, Text: `  Expenses:Food 1.00 USD`},
		{File: "main.bean", Line: 12, Text: `  Assets:Cash`},
	}

	parsed := ParseBeanLines(lines)
	if len(parsed.Errors) != 0 {
		t.Fatalf("parse errors: %#v", parsed.Errors)
	}
	if parsed.Entries[2].Kind != "transaction" || len(parsed.Entries[2].Tags) != 1 || parsed.Entries[2].Tags[0] != "trip" || parsed.Entries[2].Metadata["trip"] != "tokyo" {
		t.Fatalf("transaction did not inherit scopes: %#v", parsed.Entries[2])
	}
	if parsed.Entries[3].Kind != "note" || !containsString(parsed.Entries[3].Tags, "trip") || !containsString(parsed.Entries[3].Tags, "cash") || parsed.Entries[3].Metadata["trip"] != "override" {
		t.Fatalf("note scopes or override wrong: %#v", parsed.Entries[3])
	}
	txns := ParseTransactions(lines)
	if len(txns) != 2 {
		t.Fatalf("transactions = %#v, want 2", txns)
	}
	if len(txns[1].Tags) != 0 {
		t.Fatalf("poptag did not clear active tag: %#v", txns[1])
	}
	if _, ok := txns[1].Metadata["trip"]; ok {
		t.Fatalf("popmeta did not clear active metadata: %#v", txns[1].Metadata)
	}
}

func TestBeanParserPreservesExactAmountTextInAST(t *testing.T) {
	lines := []BeanLine{
		{File: "main.bean", Line: 1, Text: `2026-03-01 * "Broker" "Fractional"`},
		{File: "main.bean", Line: 2, Text: `  Assets:Broker 0.333333333333 QQQ {1 / 3 USD}`},
		{File: "main.bean", Line: 3, Text: `  Assets:Cash`},
		{File: "main.bean", Line: 4, Text: `2026-03-02 price QQQ (1 / 8) USD`},
	}

	parsed := ParseBeanLines(lines)
	if len(parsed.Entries) != 2 {
		t.Fatalf("entries = %#v, want 2", parsed.Entries)
	}
	posting := parsed.Entries[0].Postings[0]
	if posting.Quantity.Number != "0.333333333333" || posting.Quantity.Currency != "QQQ" {
		t.Fatalf("quantity lost exact text: %#v", posting.Quantity)
	}
	if posting.Cost.Number != "0.333333333333333333" || posting.Cost.Currency != "USD" {
		t.Fatalf("cost expression not preserved exactly enough: %#v", posting.Cost)
	}
	price := parsed.Entries[1]
	if price.AmountValue.Number != "0.125" || price.Amount != 13 {
		t.Fatalf("price exact amount/projection wrong: %#v", price)
	}
}

func TestBeanCompilerValidation(t *testing.T) {
	valid := CompileBeanLines([]BeanLine{
		{File: "main.bean", Line: 1, Text: `pushtag #ok`},
		{File: "main.bean", Line: 2, Text: `pushmeta source: "test"`},
		{File: "main.bean", Line: 3, Text: `2026-04-01 * "Broker" "Buy"`},
		{File: "main.bean", Line: 4, Text: `  Assets:Broker 1 QQQ {100.00 USD}`},
		{File: "main.bean", Line: 5, Text: `  Assets:Cash -100.00 USD`},
		{File: "main.bean", Line: 6, Text: `popmeta source:`},
		{File: "main.bean", Line: 7, Text: `poptag #ok`},
	})
	if len(valid.Errors) != 0 {
		t.Fatalf("valid compile errors: %#v", valid.Errors)
	}

	invalid := CompileBeanLines([]BeanLine{
		{File: "main.bean", Line: 1, Text: `poptag #missing`},
		{File: "main.bean", Line: 2, Text: `popmeta missing:`},
		{File: "main.bean", Line: 3, Text: `2026-04-01 * "Cafe" "Lunch"`},
		{File: "main.bean", Line: 4, Text: `  Expenses:Food 10.00 USD`},
		{File: "main.bean", Line: 5, Text: `  Assets:Cash -9.00 USD`},
	})
	if len(invalid.Errors) != 3 {
		t.Fatalf("invalid compile errors = %#v, want 3", invalid.Errors)
	}
}

func TestReadLedgerLinesPreservesIncludeEntriesForParser(t *testing.T) {
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, "main.bean"), strings.Join([]string{
		`include "accounts.bean"`,
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(dir, "accounts.bean"), "2026-01-01 open Assets:Cash USD\n")

	lines, err := ReadLedgerLines(filepath.Join(dir, "main.bean"), map[string]bool{})
	if err != nil {
		t.Fatal(err)
	}
	parsed := ParseBeanLines(lines)
	if len(parsed.Entries) != 2 || parsed.Entries[0].Kind != "include" || parsed.Entries[0].Filename != "accounts.bean" || parsed.Entries[1].Kind != "open" {
		t.Fatalf("include was not preserved before expanded entries: %#v", parsed.Entries)
	}
}

func TestLoadBeanLinesReturnsSDKLikeResult(t *testing.T) {
	lines := []BeanLine{
		{File: "main.bean", Line: 1, Text: `option "title" "SDK Test"`},
		{File: "main.bean", Line: 2, Text: `include "accounts.bean"`},
		{File: "main.bean", Line: 3, Text: `plugin "beancount.plugins.auto_accounts" "config"`},
		{File: "main.bean", Line: 4, Text: `pushtag #trip`},
		{File: "main.bean", Line: 5, Text: `2026-05-01 * "Broker" "Buy"`},
		{File: "main.bean", Line: 6, Text: `  Assets:Broker 1.5 QQQ {100.00 USD} @ 101.00 USD`},
		{File: "main.bean", Line: 7, Text: `  Assets:Cash -150.00 USD`},
		{File: "main.bean", Line: 8, Text: `2026-05-02 balance Assets:Cash 850.00 ~ 0.01 USD`},
	}

	result := LoadBeanLines(lines)
	if len(result.Errors) != 0 {
		t.Fatalf("unexpected loader errors: %#v", result.Errors)
	}
	if result.OptionsMap["title"] != "SDK Test" || len(result.Includes) != 1 || result.Includes[0].Filename != "accounts.bean" || len(result.Plugins) != 1 || result.Plugins[0].Config != "config" {
		t.Fatalf("loader controls not captured: %#v", result)
	}
	if len(result.Directives) != 1 || result.Directives[0].Type != "PushTag" || result.Directives[0].Tags[0] != "trip" {
		t.Fatalf("scope directive not captured: %#v", result.Directives)
	}
	if len(result.Entries) != 2 {
		t.Fatalf("entries = %#v, want transaction and balance", result.Entries)
	}
	txn := result.Entries[0]
	if txn.Type != "Transaction" || txn.Meta.Filename != "main.bean" || txn.Meta.Lineno != 5 || txn.Date != "2026-05-01" || txn.Flag != "*" || txn.Payee != "Broker" || txn.Narration != "Buy" || !containsString(txn.Tags, "trip") {
		t.Fatalf("unexpected transaction entry: %#v", txn)
	}
	if len(txn.Postings) != 2 || txn.Postings[0].Units == nil || txn.Postings[0].Units.Number != "1.5" || txn.Postings[0].Units.Currency != "QQQ" || txn.Postings[0].Cost == nil || txn.Postings[0].Cost.Number != "100.00" || txn.Postings[0].Price == nil || txn.Postings[0].Price.Number != "101.00" {
		t.Fatalf("unexpected sdk postings: %#v", txn.Postings)
	}
	balance := result.Entries[1]
	if balance.Type != "Balance" || balance.Account != "Assets:Cash" || balance.Amount == nil || balance.Amount.Number != "850.00" || balance.Amount.Currency != "USD" || balance.Tolerance != "0.01" {
		t.Fatalf("unexpected balance entry: %#v", balance)
	}
	payload, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(payload), `"type":"Transaction"`) || !strings.Contains(string(payload), `"optionsMap":{"title":"SDK Test"}`) {
		t.Fatalf("sdk result JSON shape changed: %s", payload)
	}
}

func TestWriterRollsBackOnBeanCheckFailure(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 1\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	cache := NewLedgerCache(cfg)
	writer := NewLedgerWriter(cfg, cache)
	mainBefore, err := os.ReadFile(mainBeanPath(cfg))
	if err != nil {
		t.Fatal(err)
	}
	err = writer.AppendBeanText("2026-06-01", `2026-06-01 * "Shop" "Snack"`+"\n  Expenses:Food 8.00 CNY\n  Assets:Cash -8.00 CNY\n")
	if err == nil {
		t.Fatal("expected bean-check failure")
	}
	mainAfter, err := os.ReadFile(mainBeanPath(cfg))
	if err != nil {
		t.Fatal(err)
	}
	if string(mainAfter) != string(mainBefore) {
		t.Fatal("main.bean was not rolled back")
	}
	if _, err := os.Stat(filepath.Join(cfg.LedgerRoot, "transactions", "2026", "06.bean")); !os.IsNotExist(err) {
		t.Fatalf("new monthly file should have been removed, err=%v", err)
	}
}

func TestLedgerWriteTransactionRollsBackExistingAndNewFiles(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 1\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	cache := NewLedgerCache(cfg)
	writer := NewLedgerWriter(cfg, cache)
	accountsFile := accountsBeanPath(cfg)
	accountsBefore := string(mustRead(t, accountsFile))
	newFile := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "imports", "rollback.bean")

	err := writer.RunTransaction(func(tx *LedgerWriteTransaction) error {
		if err := tx.WriteFile(accountsFile, []byte(accountsBefore+"\n2026-01-02 open Expenses:Travel CNY\n"), 0o644); err != nil {
			return err
		}
		return tx.WriteFile(newFile, []byte("; should roll back\n"), 0o644)
	})
	if err == nil {
		t.Fatal("expected bean-check failure")
	}
	if got := string(mustRead(t, accountsFile)); got != accountsBefore {
		t.Fatalf("existing file was not restored:\n%s", got)
	}
	if _, err := os.Stat(newFile); !os.IsNotExist(err) {
		t.Fatalf("new file should have been removed, err=%v", err)
	}
}

func TestLedgerWriteTransactionClearsCacheAfterSuccessfulWrite(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	cache := NewLedgerCache(cfg)
	beforeSnapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	writer := NewLedgerWriter(cfg, cache)
	accountsFile := accountsBeanPath(cfg)
	accountsBefore := string(mustRead(t, accountsFile))

	err = writer.RunTransaction(func(tx *LedgerWriteTransaction) error {
		next := appendText(accountsBefore, `2026-01-02 open Expenses:Travel CNY
  alias: "差旅"`)
		return tx.WriteFile(accountsFile, []byte(next), 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	afterSnapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if afterSnapshot == beforeSnapshot {
		t.Fatal("snapshot cache was not cleared after successful transaction")
	}
	found := false
	for _, account := range afterSnapshot.Accounts {
		if account.Account == "Expenses:Travel" && account.Alias != nil && strings.Contains(*account.Alias, "差旅") {
			found = true
		}
	}
	if !found {
		t.Fatalf("new account was not visible after cache reload: %#v", afterSnapshot.Accounts)
	}
}

func TestLedgerWriteTransactionAppendsAccount(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	writer := NewLedgerWriter(cfg, NewLedgerCache(cfg))
	err := writer.AppendAccount(AccountInput{Date: "2026-01-02", Account: "Expenses:Travel", Alias: "差旅", Currency: "CNY"})
	if err != nil {
		t.Fatal(err)
	}
	text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "accounts.bean")))
	if !strings.Contains(text, "open Expenses:Travel CNY") {
		t.Fatalf("account was not appended:\n%s", text)
	}
}
