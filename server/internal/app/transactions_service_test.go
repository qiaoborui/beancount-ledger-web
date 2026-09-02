package app

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReverseTransactionEntryMirrorsOriginalPostings(t *testing.T) {
	original := Transaction{
		Date:      "2026-05-01",
		Payee:     "Cafe",
		Narration: "Lunch",
		Tags:      []string{"work"},
		Postings: []Posting{
			{Account: "Expenses:Food", Amount: 1200, Currency: "CNY"},
			{Account: "Assets:Cash", Amount: -1200, Currency: "CNY"},
		},
	}
	entry := ReverseTransactionEntry(original, "2026-05-02")
	if entry.Date != "2026-05-02" || entry.Payee != "Cafe" || entry.Narration != "冲销：Lunch" {
		t.Fatalf("unexpected reversal entry header: %#v", entry)
	}
	if len(entry.Postings) != 2 || entry.Postings[0].Amount != "-12.00" || entry.Postings[1].Amount != "12.00" {
		t.Fatalf("reversal postings should invert original amounts: %#v", entry.Postings)
	}
	if entry.Metadata["reversal"] != true || len(entry.Tags) != 1 || entry.Tags[0] != "work" {
		t.Fatalf("reversal metadata/tags were not preserved: %#v", entry)
	}
}

func TestEditableTransactionEntryPreservesCompleteParsedSemantics(t *testing.T) {
	parsed := ParseBeanLines([]BeanLine{
		{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 ! "Broker" "Buy" #invest ^order-1`},
		{File: "transactions/2026/05.bean", Line: 2, Text: `  cleared: NULL`},
		{File: "transactions/2026/05.bean", Line: 3, Text: `  ! Assets:Broker 1.23456789 VT {{ 123.456789 USD, 2026-05-01, "lot-a" }} @@ 160.1234567 USD`},
		{File: "transactions/2026/05.bean", Line: 4, Text: `  ? Assets:Cash`},
	})
	if len(parsed.Entries) != 1 {
		t.Fatalf("parsed entries=%#v errors=%#v", parsed.Entries, parsed.Errors)
	}
	entry := LedgerEntryFromBeanTransaction(parsed.Entries[0])
	if entry.Flag != "!" || len(entry.Links) != 1 || entry.Links[0] != "order-1" || entry.Metadata["cleared"] != nil {
		t.Fatalf("transaction annotations were not preserved: %#v", entry)
	}
	if len(entry.Postings) != 2 {
		t.Fatalf("postings=%#v", entry.Postings)
	}
	first := entry.Postings[0]
	if first.Flag != "!" || first.Amount != "1.23456789" || first.CostKind != "total" || first.CostAmount != "123.456789" || first.CostSpec != `{{ 123.456789 USD , 2026-05-01 , "lot-a" }}` || first.PriceKind != "total" || first.PriceAmount != "160.1234567" {
		t.Fatalf("rich posting was not preserved: %#v", first)
	}
	if entry.Postings[1].Flag != "?" || entry.Postings[1].Amount != "" || entry.Postings[1].Currency != "" {
		t.Fatalf("blank posting was not preserved: %#v", entry.Postings[1])
	}
	rendered := TransactionToBean(entry)
	for _, fragment := range []string{
		`2026-05-01 ! "Broker" "Buy" #invest ^order-1`,
		`cleared: NULL`,
		`! Assets:Broker`,
		`1.23456789 VT {{ 123.456789 USD , 2026-05-01 , "lot-a" }} @@ 160.1234567 USD`,
		`? Assets:Cash`,
	} {
		if !strings.Contains(rendered, fragment) {
			t.Fatalf("rendered entry missing %q:\n%s", fragment, rendered)
		}
	}
}

func TestEditableTransactionEntryRejectsMetadataThatWouldChangeMeaning(t *testing.T) {
	tests := map[string][]BeanLine{
		"typed transaction metadata": {
			{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Broker" "Buy"`},
			{File: "transactions/2026/05.bean", Line: 2, Text: `  settlement: 2026-05-03`},
			{File: "transactions/2026/05.bean", Line: 3, Text: `  Assets:Broker 1 VT`},
			{File: "transactions/2026/05.bean", Line: 4, Text: `  Assets:Cash -1 USD`},
		},
		"posting metadata": {
			{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Broker" "Buy"`},
			{File: "transactions/2026/05.bean", Line: 2, Text: `  Assets:Broker 1 VT`},
			{File: "transactions/2026/05.bean", Line: 3, Text: `    lot_note: "retirement"`},
			{File: "transactions/2026/05.bean", Line: 4, Text: `  Assets:Cash -1 USD`},
		},
		"inherited metadata": {
			{File: "transactions/2026/05.bean", Line: 1, Text: `pushmeta source: "broker"`},
			{File: "transactions/2026/05.bean", Line: 2, Text: `2026-05-01 * "Broker" "Buy"`},
			{File: "transactions/2026/05.bean", Line: 3, Text: `  Assets:Broker 1 VT`},
			{File: "transactions/2026/05.bean", Line: 4, Text: `  Assets:Cash -1 USD`},
		},
		"header comment": {
			{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Broker" "Buy" ; keep this note`},
			{File: "transactions/2026/05.bean", Line: 2, Text: `  Assets:Broker 1 VT`},
			{File: "transactions/2026/05.bean", Line: 3, Text: `  Assets:Cash -1 USD`},
		},
		"posting comment": {
			{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Broker" "Buy"`},
			{File: "transactions/2026/05.bean", Line: 2, Text: `  Assets:Broker 1 VT ; tax lot note`},
			{File: "transactions/2026/05.bean", Line: 3, Text: `  Assets:Cash -1 USD`},
		},
		"comment line": {
			{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Broker" "Buy"`},
			{File: "transactions/2026/05.bean", Line: 2, Text: `  ; manual reconciliation note`},
			{File: "transactions/2026/05.bean", Line: 3, Text: `  Assets:Broker 1 VT`},
			{File: "transactions/2026/05.bean", Line: 4, Text: `  Assets:Cash -1 USD`},
		},
	}
	for name, lines := range tests {
		t.Run(name, func(t *testing.T) {
			parsed := ParseBeanLines(lines)
			entry := parsed.Entries[len(parsed.Entries)-1]
			if editable := EditableLedgerEntryFromBeanTransaction(entry); editable != nil {
				t.Fatalf("unsafe metadata should disable full-entry editing: %#v", editable)
			}
		})
	}
}

func TestEditableTransactionEntryAllowsSemicolonsInsideStrings(t *testing.T) {
	parsed := ParseBeanLines([]BeanLine{
		{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Broker; Desk" "Buy"`},
		{File: "transactions/2026/05.bean", Line: 2, Text: `  note: "keep; value"`},
		{File: "transactions/2026/05.bean", Line: 3, Text: `  Assets:Broker 1 VT { "lot;a" }`},
		{File: "transactions/2026/05.bean", Line: 4, Text: `  Assets:Cash -1 USD`},
	})
	if editable := EditableLedgerEntryFromBeanTransaction(parsed.Entries[0]); editable == nil {
		t.Fatal("semicolons inside quoted strings should remain editable")
	}
}

func TestEditableTransactionEntryPreservesSupportedStringEscapes(t *testing.T) {
	parsed := ParseBeanLines([]BeanLine{
		{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Broker\nDesk" "Buy\tshares\rnow"`},
		{File: "transactions/2026/05.bean", Line: 2, Text: `  note: "line\nbreak\fform\bback"`},
		{File: "transactions/2026/05.bean", Line: 3, Text: `  Assets:Broker +1. VT`},
		{File: "transactions/2026/05.bean", Line: 4, Text: `  Assets:Cash -1. USD`},
	})
	editable := EditableLedgerEntryFromBeanTransaction(parsed.Entries[0])
	if editable == nil {
		t.Fatal("supported escaped strings and direct number forms should remain editable")
	}
	rendered := TransactionToBean(*editable)
	for _, fragment := range []string{`"Broker\nDesk"`, `"Buy\tshares\rnow"`, `note: "line\nbreak\fform\bback"`, `+1. VT`} {
		if !strings.Contains(rendered, fragment) {
			t.Fatalf("rendered entry missing %q:\n%s", fragment, rendered)
		}
	}
}

func TestEditableTransactionEntryRejectsUnsupportedStringEscapes(t *testing.T) {
	parsed := ParseBeanLines([]BeanLine{
		{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Broker\u0020Desk" "Buy"`},
		{File: "transactions/2026/05.bean", Line: 2, Text: `  Assets:Broker 1 VT`},
		{File: "transactions/2026/05.bean", Line: 3, Text: `  Assets:Cash -1 USD`},
	})
	if editable := EditableLedgerEntryFromBeanTransaction(parsed.Entries[0]); editable != nil {
		t.Fatalf("unsupported string escape should disable full-entry editing: %#v", editable)
	}
}

func TestEditableTransactionEntryRejectsArithmeticThatWouldLosePrecision(t *testing.T) {
	tests := map[string]string{
		"quantity expression": `  Assets:Broker (1 / 3) VT`,
		"price expression":    `  Assets:Broker 1 VT @ (1 / 3) USD`,
	}
	for name, posting := range tests {
		t.Run(name, func(t *testing.T) {
			parsed := ParseBeanLines([]BeanLine{
				{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Broker" "Buy"`},
				{File: "transactions/2026/05.bean", Line: 2, Text: posting},
				{File: "transactions/2026/05.bean", Line: 3, Text: `  Assets:Cash -1 USD`},
			})
			if editable := EditableLedgerEntryFromBeanTransaction(parsed.Entries[0]); editable != nil {
				t.Fatalf("arithmetic expression should disable full-entry editing: %#v", editable)
			}
		})
	}
}

func TestEditableTransactionEntryPreservesCostSpecsWithoutAmounts(t *testing.T) {
	tests := map[string]string{
		"empty":      `{ }`,
		"currency":   `{ USD }`,
		"label":      `{ "lot-a" }`,
		"date":       `{ 2026-05-01 }`,
		"number":     `{ 1 / 3 }`,
		"total only": `{ # 10 USD }`,
	}
	for name, expected := range tests {
		t.Run(name, func(t *testing.T) {
			parsed := ParseBeanLines([]BeanLine{
				{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Broker" "Buy"`},
				{File: "transactions/2026/05.bean", Line: 2, Text: `  Assets:Broker 1 VT ` + expected},
				{File: "transactions/2026/05.bean", Line: 3, Text: `  Assets:Cash -1 USD`},
			})
			entry := LedgerEntryFromBeanTransaction(parsed.Entries[0])
			if entry.Postings[0].CostSpec != expected {
				t.Fatalf("cost spec=%q, want %q", entry.Postings[0].CostSpec, expected)
			}
			if rendered := TransactionToBean(entry); !strings.Contains(rendered, expected) {
				t.Fatalf("rendered entry lost %q:\n%s", expected, rendered)
			}
		})
	}
}

func TestAddTagsToTransactionHeaderEnforcesFinalLimit(t *testing.T) {
	tags := make([]string, 0, maxTransactionTags-1)
	for index := 0; index < maxTransactionTags-1; index++ {
		tags = append(tags, fmt.Sprintf("tag-%d", index))
	}
	header := `2026-05-01 * "Cafe" "Lunch" #` + strings.Join(tags, " #")
	if _, err := addTagsToTransactionHeader(header, []string{"extra-a", "extra-b"}); err == nil {
		t.Fatal("adding tags beyond the final transaction limit should fail")
	}
	updated, err := addTagsToTransactionHeader(header, []string{"extra-a", tags[0]})
	if err != nil || !strings.Contains(updated, "#extra-a") {
		t.Fatalf("deduplicated final tag set should fit the limit: %q, %v", updated, err)
	}
}

func TestFindTransactionPrefersHashOverStaleLine(t *testing.T) {
	txns := []Transaction{
		{Narration: "Replaced", Source: TransactionSource{File: "transactions/2026/05.bean", Line: 1, Hash: "new"}},
		{Narration: "Original", Source: TransactionSource{File: "transactions/2026/05.bean", Line: 2, Hash: "old"}},
	}
	found := FindTransaction(txns, TransactionSource{File: "transactions/2026/05.bean", Line: 1, Hash: "old"})
	if found == nil || found.Narration != "Original" {
		t.Fatalf("hash must identify the approved transaction, got %#v", found)
	}
}

func TestTransactionServiceAddTagsUpdatesBatchAndPreservesHeaderComment(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	before := string(mustRead(t, file))
	lines := strings.Split(strings.TrimRight(before, "\n"), "\n")
	first := transactionHash(lines[0:4])
	second := transactionHash(lines[5:8])
	lines[0] = `2026-05-01 * "Cafe; inside quote" "Lunch" #work ; keep this`
	mustWrite(t, file, strings.Join(lines, "\n")+"\n")
	updated := strings.Split(strings.TrimRight(string(mustRead(t, file)), "\n"), "\n")
	first = transactionHash(updated[0:4])

	service := NewTransactionService(NewLedgerCache(cfg), NewLedgerWriter(cfg, nil))
	err := service.AddTags([]TransactionSource{
		{File: "transactions/2026/05.bean", Line: 1, Hash: first},
		{File: "transactions/2026/05.bean", Line: 6, Hash: second},
	}, []string{"travel", "trip-2026-hokkaido", "travel"})
	if err != nil {
		t.Fatal(err)
	}
	after := string(mustRead(t, file))
	if !strings.Contains(after, `#work #travel #trip-2026-hokkaido ; keep this`) {
		t.Fatalf("first transaction tags/comment were not preserved:\n%s", after)
	}
	if strings.Count(after, "#travel") != 2 || strings.Count(after, "#trip-2026-hokkaido") != 2 {
		t.Fatalf("both transactions should receive deduplicated tags:\n%s", after)
	}
}

func TestTransactionServiceAddTagsKeepsLineDistinctSourcesWithSameHash(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	block := "2026-05-01 * \"Duplicate\" \"Same raw transaction\"\n  Expenses:Food  12.00 CNY\n  Assets:Cash  -12.00 CNY"
	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	mustWrite(t, file, block+"\n"+block)
	hash := transactionHash(strings.Split(block, "\n"))

	service := NewTransactionService(NewLedgerCache(cfg), NewLedgerWriter(cfg, nil))
	err := service.AddTags([]TransactionSource{
		{File: "transactions/2026/05.bean", Line: 1, Hash: hash},
		{File: "transactions/2026/05.bean", Line: 4, Hash: hash},
	}, []string{"travel"})
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(string(mustRead(t, file)), "#travel"); got != 2 {
		t.Fatalf("line-distinct sources with one hash received %d tags, want 2", got)
	}
}

func TestTransactionWritersSupportParsedFlagsAndDateForms(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	block := strings.Join([]string{
		`2026/5/1 ? "Cafe" "Lunch"`,
		"  Expenses:Food 12.00 CNY",
		"  Assets:Cash -12.00 CNY",
	}, "\n")
	mustWrite(t, file, block+"\n")
	writer := NewLedgerWriter(cfg, nil)
	source := TransactionSource{File: "transactions/2026/05.bean", Line: 1, Hash: transactionHash(strings.Split(block, "\n"))}
	if err := writer.AddTransactionTags([]TransactionSource{source}, []string{"travel"}); err != nil {
		t.Fatalf("add tags to parsed transaction flag/date: %v", err)
	}

	updatedLines := strings.Split(strings.TrimRight(string(mustRead(t, file)), "\n"), "\n")
	updatedSource := TransactionSource{File: source.File, Line: 1, Hash: transactionHash(updatedLines)}
	entry := LedgerEntry{
		Kind:      "transaction",
		Date:      "2026-05-01",
		Flag:      "?",
		Payee:     "Cafe",
		Narration: "Updated lunch",
		Tags:      []string{"travel"},
		Postings: []EntryPosting{
			{Account: "Expenses:Food", Amount: "12.00", Currency: "CNY"},
			{Account: "Assets:Cash", Amount: "-12.00", Currency: "CNY"},
		},
	}
	if err := writer.ReplaceTransactionBlock(updatedSource, entry); err != nil {
		t.Fatalf("replace parsed transaction flag/date: %v", err)
	}
	after := string(mustRead(t, file))
	if !strings.Contains(after, `2026-05-01 ? "Cafe" "Updated lunch" #travel`) {
		t.Fatalf("transaction writer lost flag or tags:\n%s", after)
	}
}

func TestTransactionServiceAddTagsEnforcesEffectiveTagLimit(t *testing.T) {
	tests := map[string]func(Config, []string){
		"body tags": func(cfg Config, tags []string) {
			file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
			lines := []string{`2026-05-01 * "Cafe" "Lunch"`}
			for _, tag := range tags {
				lines = append(lines, "  #"+tag)
			}
			lines = append(lines, "  Expenses:Food 12.00 CNY", "  Assets:Cash -12.00 CNY")
			mustWrite(t, file, strings.Join(lines, "\n")+"\n")
		},
		"pushtag scopes": func(cfg Config, tags []string) {
			main := []string{
				`option "title" "Test Ledger"`,
				`option "operating_currency" "CNY"`,
				`include "commodities.bean"`,
				`include "accounts.bean"`,
				`include "prices.bean"`,
			}
			for _, tag := range tags {
				main = append(main, "pushtag #"+tag)
			}
			main = append(main, `include "transactions/2026/05.bean"`)
			mustWrite(t, filepath.Join(cfg.LedgerRoot, "main.bean"), strings.Join(main, "\n")+"\n")
			mustWrite(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean"), strings.Join([]string{
				`2026-05-01 * "Cafe" "Lunch"`,
				"  Expenses:Food 12.00 CNY",
				"  Assets:Cash -12.00 CNY",
			}, "\n")+"\n")
		},
	}

	for name, configure := range tests {
		t.Run(name, func(t *testing.T) {
			cfg := testLedger(t)
			tags := make([]string, maxTransactionTags-1)
			for index := range tags {
				tags[index] = fmt.Sprintf("tag-%d", index)
			}
			configure(cfg, tags)
			file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
			before := string(mustRead(t, file))
			block := strings.Split(strings.TrimRight(before, "\n"), "\n")
			service := NewTransactionService(NewLedgerCache(cfg), NewLedgerWriter(cfg, nil))
			err := service.AddTags([]TransactionSource{{
				File: "transactions/2026/05.bean",
				Line: 1,
				Hash: transactionHash(block),
			}}, []string{"extra-a", "extra-b"})
			if err == nil || !strings.Contains(err.Error(), "最多 50 个") {
				t.Fatalf("expected effective tag limit error, got %v", err)
			}
			if after := string(mustRead(t, file)); after != before {
				t.Fatalf("failed batch changed ledger:\n%s", after)
			}
		})
	}
}

func TestTransactionServiceAddTagsIsAtomicWhenAnySourceIsStale(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	before := string(mustRead(t, file))
	lines := strings.Split(strings.TrimRight(before, "\n"), "\n")
	validHash := transactionHash(lines[0:4])

	service := NewTransactionService(NewLedgerCache(cfg), NewLedgerWriter(cfg, nil))
	err := service.AddTags([]TransactionSource{
		{File: "transactions/2026/05.bean", Line: 1, Hash: validHash},
		{File: "transactions/2026/05.bean", Line: 6, Hash: "stale"},
	}, []string{"travel"})
	if err == nil || !strings.Contains(err.Error(), "找不到原交易") {
		t.Fatalf("expected stale-source error, got %v", err)
	}
	if after := string(mustRead(t, file)); after != before {
		t.Fatalf("batch must be all-or-nothing; file changed:\n%s", after)
	}
}

func TestAddTransactionTagsRouteWritesOneValidatedBatch(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	lines := strings.Split(strings.TrimRight(string(mustRead(t, file)), "\n"), "\n")
	body, err := json.Marshal(AddTransactionTagsRequest{
		Sources: []TransactionSource{{File: "transactions/2026/05.bean", Line: 1, Hash: transactionHash(lines[0:4])}},
		Tags:    []string{"travel"},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := testRouter(t, cfg)
	response := requestWithCookies(router, http.MethodPost, "/api/ledger/transactions/tags", string(body), loginCookies(t, router))
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if after := string(mustRead(t, file)); !strings.Contains(after, `"Lunch" #work #travel`) {
		t.Fatalf("route did not add tag:\n%s", after)
	}
}

func TestTransactionServiceReverseWritesEntry(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)

	cache := NewLedgerCache(cfg)
	writer := NewLedgerWriter(cfg, cache)
	service := NewTransactionService(cache, writer)
	entry, err := service.Reverse(ReverseTransactionRequest{Source: TransactionSource{File: filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean"), Line: 1}, Date: "2026-05-02"})
	if err != nil {
		t.Fatal(err)
	}
	if entry.Narration != "冲销：Lunch" {
		t.Fatalf("unexpected reversal entry: %#v", entry)
	}
	text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")))
	if !strings.Contains(text, "冲销：Lunch") || !strings.Contains(text, "Assets:Cash") || !strings.Contains(text, "12.00 CNY") {
		t.Fatalf("reversal was not written:\n%s", text)
	}
}

func TestTransactionServiceReverseUsesInjectedSnapshotWithoutLocalLedger(t *testing.T) {
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"main.bean":                 "include \"commodities.bean\"\ninclude \"accounts.bean\"\ninclude \"transactions/2026/05.bean\"\n",
		"commodities.bean":          "2026-01-01 commodity CNY\n",
		"accounts.bean":             "2026-01-01 open Assets:Cash CNY\n2026-01-01 open Expenses:Food CNY\n",
		"transactions/2026/05.bean": "; 2026-05 transactions\n",
	})
	defer fake.server.Close()

	cfg := githubAPITestConfig(t, fake)
	snapshot := &LedgerSnapshot{Transactions: []Transaction{{
		Date:      "2026-05-01",
		Payee:     "Cafe",
		Narration: "Lunch",
		Postings: []Posting{
			{Account: "Expenses:Food", Amount: 1200, Currency: "CNY"},
			{Account: "Assets:Cash", Amount: -1200, Currency: "CNY"},
		},
		Source: TransactionSource{File: "transactions/2026/05.bean", Line: 1, Hash: "source-hash"},
	}}}
	service := NewTransactionServiceWithSnapshot(nil, NewLedgerWriter(cfg, nil), func() (*LedgerSnapshot, error) {
		return snapshot, nil
	})

	entry, err := service.Reverse(ReverseTransactionRequest{Source: snapshot.Transactions[0].Source, Date: "2026-05-02"})
	if err != nil {
		t.Fatal(err)
	}
	if entry.Narration != "冲销：Lunch" || fake.commitCount != 1 {
		t.Fatalf("entry=%#v commits=%d", entry, fake.commitCount)
	}
}
