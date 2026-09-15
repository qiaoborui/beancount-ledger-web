package app

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func canonicalTestConfig(t *testing.T, source string) Config {
	t.Helper()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "main.bean"), []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	return Config{localTransport: true, localEntrypoint: "main.bean", LedgerRoot: root,
		RuntimeDir: t.TempDir(), LedgerStorage: "filesystem"}
}

// Runs the same bundled Python source used by BRValidate. Developers building
// the mobile runtime have this pinned interpreter; CI can provide its own via
// LOCAL_BEANCOUNT_PYTHON. Pure Go conversion coverage below always runs.
func canonicalPythonModel(t *testing.T, cfg Config) *LocalCanonicalModel {
	t.Helper()
	python := os.Getenv("LOCAL_BEANCOUNT_PYTHON")
	if python == "" {
		python = "../../.build/beancount-ios/test-venv/bin/python"
		if _, err := os.Stat(python); err != nil {
			t.Skip("canonical integration requires LOCAL_BEANCOUNT_PYTHON or the pinned mobile test-venv")
		}
	}
	cmd := exec.Command(python, "-c", `import sys; sys.path.insert(0, '../../../App/LedgerMobile/Runtime'); from ledger_validator import validate_json; print(validate_json(sys.argv[1]))`, cfg.LedgerRoot)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("canonical load: %v: %s", err, output)
	}
	var result struct {
		Errors    []struct{ Message string } `json:"errors"`
		Canonical *LocalCanonicalModel       `json:"canonical"`
	}
	if err := json.Unmarshal(output, &result); err != nil || len(result.Errors) > 0 || result.Canonical == nil {
		t.Fatalf("canonical result: %v: %s", err, output)
	}
	return result.Canonical
}

func TestLocalCanonicalReadModelKeepsTransformedEntries(t *testing.T) {
	cfg := canonicalTestConfig(t, `plugin "beancount.plugins.auto_accounts"
plugin "beancount.plugins.implicit_prices"
2026-01-01 * "Buy"
  Assets:Stock 2 HOOL {10 USD}
  Assets:Cash -20 USD
`)
	// This JSON is the canonical loader projection for the synthetic source.
	// Its generated opens and price have no corresponding raw directives.
	var model LocalCanonicalModel
	if err := json.Unmarshal([]byte(`{"version":1,"entries":[
{"Kind":"open","Date":"2026-01-01","Account":"Assets:Stock"},
{"Kind":"open","Date":"2026-01-01","Account":"Assets:Cash"},
{"Kind":"transaction","Date":"2026-01-01","File":"main.bean","Line":3,"Flag":"*","Narration":"Buy","Postings":[
{"account":"Assets:Stock","Quantity":{"Number":"2","Currency":"HOOL"},"Cost":{"Number":"10","Currency":"USD"}},
{"account":"Assets:Cash","Quantity":{"Number":"-20","Currency":"USD"}}]},
{"Kind":"price","Date":"2026-01-01","Currency":"HOOL","AmountValue":{"Number":"10","Currency":"USD"},"QuoteCurrency":"USD"}
],"options":{"operating_currency":"USD"}}`), &model); err != nil {
		t.Fatal(err)
	}
	cfg.localCanonical = &model
	snapshot, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Accounts) != 2 || len(snapshot.Prices) != 1 || len(snapshot.BeanErrors) > 0 {
		t.Fatalf("canonical directives missing: accounts=%+v prices=%+v errors=%+v", snapshot.Accounts, snapshot.Prices, snapshot.BeanErrors)
	}
	bootstrap := BuildLedgerBootstrap(snapshot, "2026-01-01", "2026-02-01", true, "USD", "2026-01-15")
	if bootstrap.ValuationCurrency != "USD" {
		t.Fatalf("valid implicit currency was rejected: %s", bootstrap.ValuationCurrency)
	}
	for _, row := range bootstrap.AccountBalances {
		if row.Account == "Assets:Stock" && (row.Valuation != 2000 || row.ValuationMissing) {
			t.Fatalf("canonical stock valuation: %+v", row)
		}
	}
	history := NetWorthHistoryInCurrency(snapshot.Transactions, snapshot.Prices, "USD")
	encoded, _ := json.Marshal(history)
	if len(history) != 1 || history[0].NetWorth != 0 {
		t.Fatalf("canonical valuation missing: %s", encoded)
	}
	if snapshot.RawBalances["Assets:Stock"]["HOOL"] != 200 || snapshot.RawBalances["Assets:Cash"]["USD"] != -2000 {
		t.Fatalf("booked quantities changed: %+v", snapshot.RawBalances)
	}
	txn := snapshot.Transactions[0]
	if txn.Source.Line != 3 || txn.Entry == nil || len(txn.Entry.Postings) != 2 {
		t.Fatalf("raw editor source missing: %+v", txn)
	}
	if _, _, _, err := transactionBlock(string(mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean"))), txn.Source); err != nil {
		t.Fatalf("canonical source hash cannot edit raw entry: %v", err)
	}
}

const canonicalBookingFixture = `2000-01-01 open Assets:Cash USD
2000-01-01 open Assets:Stock HOOL "FIFO"
2000-01-01 open Equity:Opening USD
2000-01-02 pad Assets:Cash Equity:Opening
2000-01-03 balance Assets:Cash 100 USD
2026-01-01 * "Buy first"
  Assets:Stock 2 HOOL {10 USD}
  Assets:Cash -20 USD
2026-01-02 * "Buy second"
  Assets:Stock 2 HOOL {12 USD}
  Assets:Cash -24 USD
2026-01-03 * "Sell split"
  Assets:Stock -3 HOOL {}
  Assets:Cash
`

func TestLocalCanonicalPythonBookingAndGeneratedSource(t *testing.T) {
	cfg := canonicalTestConfig(t, canonicalBookingFixture)
	cfg.localCanonical = canonicalPythonModel(t, cfg)
	cache := NewLedgerCache(cfg)
	snapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Transactions) != 4 || snapshot.RawBalances["Assets:Cash"]["USD"] != 8800 || snapshot.RawBalances["Assets:Stock"]["HOOL"] != 100 {
		t.Fatalf("canonical padding/booking lost: transactions=%+v balances=%+v", snapshot.Transactions, snapshot.RawBalances)
	}
	sell := snapshot.Transactions[3]
	if len(sell.Postings) != 3 || sell.Postings[2].Amount != 3200 || sell.Entry == nil || len(sell.Entry.Postings) != 2 || sell.Entry.Postings[1].Amount != "" {
		t.Fatalf("read postings and editor draft must retain their separate semantics: %+v", sell)
	}
	generated := snapshot.Transactions[0]
	if generated.Entry != nil || generated.Source.Line != 0 || !strings.HasPrefix(generated.Source.Hash, "generated:") {
		t.Fatalf("generated transaction acquired an editable source: %+v", generated)
	}
	writer := NewLedgerWriter(cfg, cache)
	writer.stagingValidation = func() error { return nil }
	service := NewTransactionService(cache, writer)
	before := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean")))
	if err := service.Delete(generated.Source, "test"); err == nil {
		t.Fatal("generated transaction delete accepted")
	}
	if err := service.Update(generated.Source, *sell.Entry); err == nil {
		t.Fatal("generated transaction update accepted")
	}
	if err := service.AddTags([]TransactionSource{generated.Source}, []string{"test"}); err == nil {
		t.Fatal("generated transaction tag accepted")
	}
	if _, err := service.Reverse(ReverseTransactionRequest{Source: generated.Source, Date: "2026-01-04"}); err == nil {
		t.Fatal("generated transaction reversal accepted")
	}
	if after := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean"))); before != after {
		t.Fatal("generated source request modified raw ledger")
	}
}

func TestLocalCanonicalReversalUsesCommentedRawDraft(t *testing.T) {
	cfg := canonicalTestConfig(t, `2000-01-01 open Assets:Cash USD
2000-01-01 open Expenses:Food USD
2026-01-01 * "Lunch" ; keep original
  Expenses:Food 12 USD
  Assets:Cash
`)
	cfg.localCanonical = canonicalPythonModel(t, cfg)
	cache := NewLedgerCache(cfg)
	snapshot, err := cache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	txn := snapshot.Transactions[0]
	if txn.Entry != nil {
		t.Fatal("commented source should use raw reversal recovery")
	}
	writer := NewLedgerWriter(cfg, cache)
	writer.stagingValidation = func() error { return nil }
	entry, err := NewTransactionService(cache, writer).Reverse(ReverseTransactionRequest{Source: txn.Source, Date: "2026-01-02"})
	if err != nil {
		t.Fatal(err)
	}
	if entry.Postings[0].Amount != "-12" || entry.Postings[1].Amount != "" {
		t.Fatalf("reversal replaced inferred raw posting with transformed amount: %+v", entry.Postings)
	}
}

func TestLocalCanonicalBookedLotsRespectLIFOAndExplicitCost(t *testing.T) {
	for _, sale := range []string{"-1 HOOL {}", "-1 HOOL {12 USD, 2026-01-02, \"second\"}"} {
		t.Run(sale, func(t *testing.T) {
			source := `2000-01-01 open Assets:Cash USD
2000-01-01 open Assets:Stock HOOL "LIFO"
2026-01-01 * "First"
  Assets:Stock 2 HOOL {10 USD, "first"}
  Assets:Cash -20 USD
2026-01-02 * "Second"
  Assets:Stock 2 HOOL {12 USD, "second"}
  Assets:Cash -24 USD
2026-01-03 * "Sell selected lot"
  Assets:Stock ` + sale + ` @ 15 USD
  Assets:Cash 15 USD
  Income:Gains
2000-01-01 open Income:Gains USD
`
			cfg := canonicalTestConfig(t, source)
			cfg.localCanonical = canonicalPythonModel(t, cfg)
			snapshot, err := NewLedgerCache(cfg).Snapshot()
			if err != nil {
				t.Fatal(err)
			}
			activity := investmentActivityFromEntries(snapshot.BeanEntries, map[string]bool{"HOOL": true}, nil, nil, investmentPriceIndex{})
			key := "Assets:Stock\x00HOOL"
			lots, trades := activity.Lots[key], activity.Realized[key]
			quantities := map[string]float64{}
			for _, lot := range lots {
				quantities[lot.Date] = lot.Quantity
			}
			if len(lots) != 2 || len(trades) != 1 || quantities["2026-01-01"] != 2 || quantities["2026-01-02"] != 1 || trades[0].CostValue == nil || *trades[0].CostValue != 12 {
				t.Fatalf("canonical booked lot was replaced by FIFO: lots=%+v trades=%+v", lots, trades)
			}
			if trades[0].RealizedPnL == nil || *trades[0].RealizedPnL != 3 {
				t.Fatalf("realized gain: %+v", trades[0])
			}
		})
	}
}

func TestLocalCanonicalEqualPriceLotsKeepBookedIdentity(t *testing.T) {
	// Two equal-price lots were acquired on the same date with distinct labels.
	// A booked reduction of the second lot must retain the first lot in full.
	cfg := canonicalTestConfig(t, "")
	posting := func(quantity, label string) parsedPosting {
		return parsedPosting{Posting: Posting{Account: "Assets:Stock"},
			Quantity: BeanAmount{Number: quantity, Currency: "HOOL"},
			Cost:     BeanAmount{Number: "10.00", Currency: "USD"}, CostDate: "2026-01-01", CostLabel: label}
	}
	cfg.localCanonical = &LocalCanonicalModel{Version: 1, Entries: []BeanEntry{
		{Kind: "transaction", Date: "2026-01-01", Postings: []parsedPosting{posting("2", "first")}},
		{Kind: "transaction", Date: "2026-01-02", Postings: []parsedPosting{posting("3", "second")}},
		{Kind: "transaction", Date: "2026-01-03", Postings: []parsedPosting{posting("-1", "second")}},
	}}
	entries, err := localCanonicalEntries(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	activity := investmentActivityFromEntries(entries, map[string]bool{"HOOL": true}, nil, nil, investmentPriceIndex{})
	quantities := map[string]float64{}
	for _, lot := range activity.Lots["Assets:Stock\x00HOOL"] {
		quantities[lot.Date] = lot.Quantity
	}
	if quantities["2026-01-01"] != 2 || quantities["2026-01-02"] != 2 {
		t.Fatalf("booked label lost: %+v", quantities)
	}
}

func TestLocalCanonicalInventoryRetainsSignedLots(t *testing.T) {
	cfg := canonicalTestConfig(t, "")
	entry := func(date, quantity string) BeanEntry {
		return BeanEntry{Kind: "transaction", Date: date, Postings: []parsedPosting{{
			Posting: Posting{Account: "Assets:Stock"}, Quantity: BeanAmount{Number: quantity, Currency: "HOOL"},
			Cost: BeanAmount{Number: "10", Currency: "USD"}, CostDate: date,
		}}}
	}
	cfg.localCanonical = &LocalCanonicalModel{Version: 1, Entries: []BeanEntry{entry("2026-01-01", "2"), entry("2026-01-02", "-1")}}
	entries, err := localCanonicalEntries(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	activity := investmentActivityFromEntries(entries, map[string]bool{"HOOL": true}, nil, nil, investmentPriceIndex{})
	lots := activity.Lots["Assets:Stock\x00HOOL"]
	quantity, cost := 0.0, 0.0
	for _, lot := range lots {
		quantity += lot.Quantity
		if lot.CostValue != nil {
			cost += *lot.CostValue
		}
	}
	if len(lots) != 2 || quantity != 1 || cost != 10 {
		t.Fatalf("signed canonical inventory lost: %+v quantity=%v cost=%v", lots, quantity, cost)
	}
	cfg.localCanonical.Entries = append(cfg.localCanonical.Entries, entry("2026-01-02", "1"))
	entries, err = localCanonicalEntries(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	activity = investmentActivityFromEntries(entries, map[string]bool{"HOOL": true}, nil, nil, investmentPriceIndex{})
	lots = activity.Lots["Assets:Stock\x00HOOL"]
	if len(lots) != 1 || lots[0].Quantity != 2 || lots[0].CostValue == nil || *lots[0].CostValue != 20 {
		t.Fatalf("matching cover failed to net negative lot: %+v", lots)
	}
}

func TestLocalCanonicalBudgetAndAmountMetadataKeepScalarContract(t *testing.T) {
	cfg := canonicalTestConfig(t, `2000-01-01 open Assets:Cash CNY
2000-01-01 open Expenses:Food CNY
2026-01-01 custom "budget" Expenses:Food "monthly" 100 CNY
2026-01-02 * "Lunch"
  limit: 100 CNY
  Assets:Cash -12.50 CNY
  Expenses:Food 12.50 CNY
`)
	cfg.localCanonical = canonicalPythonModel(t, cfg)
	snapshot, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	budgets := homeBudgetDirectives(snapshot.BeanEntries)
	if len(budgets) != 1 || budgets[0].Amount != 10000 || budgets[0].Currency != "CNY" {
		t.Errorf("canonical custom budget lost scalar amount: %+v", budgets)
	}
	if value := snapshot.Transactions[0].Metadata["limit"]; value != "100 CNY" {
		t.Errorf("canonical amount metadata changed API type: %#v", value)
	}
	if snapshot.Transactions[0].Postings[0].Amount != -1250 {
		t.Fatal("typed posting amount changed")
	}
}

func TestLocalCanonicalEntriesExposeRawControlsAndCanonicalSemantics(t *testing.T) {
	input := localTestRequest(t)
	if err := os.WriteFile(filepath.Join(input.WorkspaceRoot, "main.bean"), []byte(`option "operating_currency" "USD"
plugin "beancount.plugins.auto_accounts"
include "canonical-child.bean"
`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(input.WorkspaceRoot, "canonical-child.bean"), []byte(`pushtag #trip
2026-01-01 * "Lunch"
  Assets:Cash -10 USD
  Expenses:Food 10 USD
poptag #trip
`), 0600); err != nil {
		t.Fatal(err)
	}
	input.Canonical = canonicalPythonModel(t, Config{LedgerRoot: input.WorkspaceRoot})
	input.Path = "/api/ledger/entries"
	var result BeanLoadResult
	if err := json.Unmarshal(localTestDispatch(t, input), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Plugins) != 1 || result.Plugins[0].Module != "beancount.plugins.auto_accounts" {
		t.Errorf("raw plugin lost: %+v", result.Plugins)
	}
	if len(result.Includes) != 1 || result.Includes[0].Filename != "canonical-child.bean" {
		t.Errorf("raw include lost: %+v", result.Includes)
	}
	if len(result.Directives) != 2 {
		t.Errorf("raw scope controls lost: %+v", result.Directives)
	}
	if result.OptionsMap["operating_currency"] != "USD" {
		t.Errorf("canonical options lost: %+v", result.OptionsMap)
	}
	if len(result.Entries) != 3 {
		t.Fatalf("canonical semantic entries lost or duplicated: %+v", result.Entries)
	}
	var opens, transactions int
	for _, entry := range result.Entries {
		if entry.Type == "Open" {
			opens++
		}
		if entry.Type == "Transaction" {
			transactions++
			if len(entry.Tags) != 1 || entry.Tags[0] != "trip" || len(entry.Postings) != 2 {
				t.Errorf("canonical scoped transaction lost: %+v", entry)
			}
		}
	}
	if opens != 2 || transactions != 1 {
		t.Fatalf("canonical transformations lost: opens=%d transactions=%d", opens, transactions)
	}
}
