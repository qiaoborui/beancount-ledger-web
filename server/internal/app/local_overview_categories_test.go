package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func overviewPosting(account string, amount int) Posting {
	return Posting{Account: account, Amount: amount, Currency: "CNY"}
}

func overviewFixture(txns ...Transaction) (Config, *LedgerSnapshot) {
	cfg, snapshot := pageFixture(0)
	for i := range txns {
		if txns[i].Date == "" {
			txns[i].Date = "2026-09-01"
		}
		txns[i].Source = TransactionSource{File: filepath.Join(cfg.LedgerRoot, "main.bean"), Line: i + 1, Hash: fmt.Sprint(i)}
	}
	snapshot.Transactions = txns
	snapshot.transactionsAsc, snapshot.transactionsDesc = sortedTransactionIndices(txns)
	return cfg, snapshot
}

func readOverview(t *testing.T, cfg Config, snapshot *LedgerSnapshot, query map[string]string) localOverviewCategories {
	t.Helper()
	status, raw, err := localOverviewCategoriesResponse(cfg, snapshot, query)
	if status != http.StatusOK || err != nil || len(raw) > localTransactionPageBytes {
		t.Fatalf("status=%d bytes=%d error=%v", status, len(raw), err)
	}
	var result localOverviewCategories
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	if result.Categories == nil || !result.SensitiveUnlocked {
		t.Fatalf("invalid envelope: %+v", result)
	}
	return result
}

func TestLocalOverviewCategoriesSwiftSemantics(t *testing.T) {
	p := overviewPosting
	cfg, snapshot := overviewFixture(
		// Newest eligible row has zero net but two nonzero categories. Its
		// visual resolution must still see the ordered zero Food posting.
		Transaction{Date: "2026-09-30", Payee: "zero representative", Postings: []Posting{p("Expenses:Food", 0), p("Expenses:X", 30), p("Expenses:Y", -30)}},
		Transaction{Date: "2026-09-29", Payee: "refund representative", Postings: []Posting{p("Assets:Investment", 0), p("Expenses:Food", -40)}},
		Transaction{Postings: []Posting{p("Expenses:Food", 100), p("Assets:Cash", -100), p("Income:Salary", 0)}},
		Transaction{Postings: []Posting{p("Expenses:Food", 30), p("Expenses:Food", 20)}}, // duplicate account is not multi
		Transaction{Postings: []Posting{p("Expenses:X", 150), p("Expenses:Y", -10)}},
		Transaction{Postings: []Posting{p("Expenses:X", 10), p("Income:Salary", -10)}}, // income makes multi, not net income
		Transaction{Postings: []Posting{p("Expenses:Gone", 90)}},
		Transaction{Postings: []Posting{p("Expenses:Gone", -90)}},
		Transaction{Postings: []Posting{p("Expenses:Negative", -1000)}},
		Transaction{Postings: []Posting{p("Expenses:Ignored", 0), p("Income:Salary", -900)}},
		Transaction{Postings: []Posting{p("Assets:Cash", 42), p("Liabilities:Card", -42)}},
		Transaction{Postings: []Posting{p("expenses:WrongCase", 42)}},
		Transaction{Postings: []Posting{p("Expenses", 42)}},
	)
	result := readOverview(t, cfg, snapshot, nil)
	if result.PositiveTotalMinorUnits != 260 || len(result.Categories) != 2 {
		t.Fatalf("incorrect signed buckets: %+v", result)
	}
	want := []struct {
		label                        string
		total, count, representative int
	}{{"多分类", 150, 2, 0}, {"Food", 110, 2, 1}}
	for i, expected := range want {
		got := result.Categories[i]
		if got.Label != expected.label || got.TotalMinorUnits != expected.total || got.PositiveTransactionCount != expected.count {
			t.Fatalf("bucket %d: %+v", i, got)
		}
		var representative Transaction
		if err := json.Unmarshal(got.Representative, &representative); err != nil {
			t.Fatal(err)
		}
		original := snapshot.Transactions[expected.representative]
		if representative.Payee != original.Payee || !reflect.DeepEqual(representative.Postings, original.Postings) || representative.Source.File != "main.bean" {
			t.Fatalf("representative/order/zero postings changed: %+v", representative)
		}
	}
}

func TestLocalOverviewCategoriesLabels(t *testing.T) {
	alias := func(s string) *string { return &s }
	tests := []struct {
		account Account
		want    string
	}{
		{Account{Account: "Expenses:Food:Dining"}, "Food › Dining"},
		{Account{Account: "Expenses:Food", Label: "  餐饮 \n", Alias: alias("not preferred")}, "餐饮"},
		{Account{Account: "Expenses:Food", Label: "Expenses:Food", Alias: alias(" 美食/外卖 ")}, "美食/外卖"},
		{Account{Account: "Expenses:Food", Label: " \n", Alias: alias(" 美食 ")}, "美食"},
		{Account{Account: "Expenses:Food", Alias: alias("  \n ")}, "Food"},
		{Account{Account: "Expenses:Food", Alias: alias(" Expenses:Food ")}, "Food"},
		{Account{Account: "Expenses::Food:"}, "Food"},
		{Account{Account: "Expenses:"}, "Expenses:"},
		{Account{Account: "Expenses:Food", Label: "\u200b\u0085 餐饮\u2028"}, "餐饮"},
	}
	for _, tt := range tests {
		t.Run(tt.want, func(t *testing.T) {
			cfg, snapshot := overviewFixture(Transaction{Postings: []Posting{overviewPosting(tt.account.Account, 100)}})
			snapshot.Accounts = []Account{tt.account}
			snapshot.AccountMap = accountByName(snapshot.Accounts)
			got := readOverview(t, cfg, snapshot, nil)
			if got.Categories[0].Label != tt.want {
				t.Fatalf("got %q want %q", got.Categories[0].Label, tt.want)
			}
		})
	}
}

func TestLocalOverviewCategoriesLabelMergingAndDistinctAccounts(t *testing.T) {
	p := overviewPosting
	cfg, snapshot := overviewFixture(
		Transaction{Postings: []Posting{p("Expenses:A", 20)}},
		Transaction{Postings: []Posting{p("Expenses:B", 30)}},
		Transaction{Postings: []Posting{p("Expenses:A", 10), p("Expenses:B", 10)}},
		Transaction{Postings: []Posting{p("Expenses:Café", 5), p("Expenses:Cafe\u0301", 5)}},
	)
	snapshot.Accounts = []Account{{Account: "Expenses:A", Label: "Café"}, {Account: "Expenses:B", Label: "Cafe\u0301"}}
	snapshot.AccountMap = accountByName(snapshot.Accounts)
	got := readOverview(t, cfg, snapshot, nil)
	if got.PositiveTotalMinorUnits != 80 || len(got.Categories) != 2 || got.Categories[0].Label != "Café" || got.Categories[0].TotalMinorUnits != 60 || got.Categories[0].PositiveTransactionCount != 3 || got.Categories[1].Label != "多分类" {
		t.Fatalf("Swift label/account equivalence changed: %+v", got)
	}
}

func TestLocalOverviewCategoriesCanonicalAccountDefinitionsLastWins(t *testing.T) {
	for _, names := range [][2]string{{"Expenses:神", "Expenses:神"}, {"Expenses:神", "Expenses:神"}, {"Expenses:Café", "Expenses:Cafe\u0301"}} {
		for _, prepared := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/%s/prepared=%v", names[0], names[1], prepared), func(t *testing.T) {
				cfg, snapshot := overviewFixture(
					Transaction{Postings: []Posting{overviewPosting(names[0], 10)}},
					Transaction{Postings: []Posting{overviewPosting(names[1], 20)}},
				)
				snapshot.Accounts = []Account{{Account: names[0], Label: "A"}, {Account: names[1], Label: "B"}}
				snapshot.AccountMap = nil
				if prepared {
					snapshot.AccountMap = accountByName(snapshot.Accounts)
				}
				got := readOverview(t, cfg, snapshot, nil)
				if len(got.Categories) != 1 || got.Categories[0].Label != "B" || got.Categories[0].TotalMinorUnits != 30 || got.Categories[0].PositiveTransactionCount != 2 {
					t.Fatalf("canonical account definitions must both resolve to last label B: %+v", got)
				}
			})
		}
	}
}

func TestLocalOverviewCategoriesAccountIndexBudget(t *testing.T) {
	alias := " B "
	snapshot := &LedgerSnapshot{Accounts: []Account{
		{Account: "Expenses:神", Label: strings.Repeat("x", localOverviewCategoryWorkingBytes+1)},
		{Account: "Expenses:神", Alias: &alias},
	}}
	// Only the last canonical definition is retained; the overwritten label
	// cannot exhaust capacity. AccountMap is deliberately irrelevant.
	const key = "Expenses:神"
	wantBytes := 256 + len(key) + len(snapshot.Accounts[1].Account) + len(alias)
	index, used, ok := localOverviewAccountIndex(snapshot, wantBytes)
	if !ok || used != wantBytes || len(index) != 1 || index[key] != 1 {
		t.Fatalf("bounded last-wins index: index=%v used=%d ok=%v", index, used, ok)
	}
	if _, _, ok := localOverviewAccountIndex(snapshot, wantBytes-1); ok {
		t.Fatal("account index accepted one byte over budget")
	}
	for _, name := range []string{"Expenses:神", "Expenses:神"} {
		if label, ok := localOverviewAccountLabel(snapshot, index, name); !ok || label != "B" {
			t.Fatalf("last canonical alias for %q: label=%q ok=%v", name, label, ok)
		}
	}
	t.Run("many definitions exhaust bounded index", func(t *testing.T) {
		cfg, snapshot := overviewFixture(Transaction{Postings: []Posting{overviewPosting("Expenses:A", 1)}})
		for i := 0; i <= localOverviewCategoryWorkingBytes/256; i++ {
			snapshot.Accounts = append(snapshot.Accounts, Account{Account: fmt.Sprintf("Expenses:Account%d", i)})
		}
		assertOverviewCapacity(t, cfg, snapshot)
	})
	for _, field := range []string{"account", "label", "alias"} {
		t.Run(field, func(t *testing.T) {
			cfg, snapshot := overviewFixture(Transaction{Postings: []Posting{overviewPosting("Expenses:A", 1)}})
			large := strings.Repeat("x", localOverviewCategoryWorkingBytes+1)
			acct := Account{Account: "Expenses:A"}
			switch field {
			case "account":
				acct.Account = large
			case "label":
				acct.Label = large
			case "alias":
				acct.Alias = &large
			}
			snapshot.Accounts = []Account{acct}
			assertOverviewCapacity(t, cfg, snapshot)
		})
	}
}

func TestLocalOverviewCategoriesTopFourDenominatorAndStableTies(t *testing.T) {
	var txns []Transaction
	for _, label := range []string{"F", "E", "D", "C", "B", "A"} {
		txns = append(txns, Transaction{Postings: []Posting{overviewPosting("Expenses:"+label, 100)}})
	}
	cfg, snapshot := overviewFixture(txns...)
	for n := 0; n < 10; n++ {
		got := readOverview(t, cfg, snapshot, nil)
		if got.PositiveTotalMinorUnits != 600 || len(got.Categories) != 4 {
			t.Fatalf("top4 used as denominator: %+v", got)
		}
		for i, category := range got.Categories {
			if category.Label != string(rune('A'+i)) {
				t.Fatalf("unstable tie order: %+v", got.Categories)
			}
		}
	}
}

func TestLocalOverviewCategoriesRangeRevisionAndValidation(t *testing.T) {
	var txns []Transaction
	for _, date := range []string{"2026-08-31", "2026-09-01", "2026-09-30", "2026-10-01"} {
		txns = append(txns, Transaction{Date: date, Postings: []Posting{overviewPosting("Expenses:Food", 100)}})
	}
	cfg, snapshot := overviewFixture(txns...)
	q := map[string]string{"start": "2026-09-01", "end": "2026-10-01"}
	got := readOverview(t, cfg, snapshot, q)
	if got.Start != q["start"] || got.End != q["end"] || got.PositiveTotalMinorUnits != 200 || got.Categories[0].PositiveTransactionCount != 2 {
		t.Fatalf("range: %+v", got)
	}
	_, raw, err := localTransactionPageResponse(cfg, snapshot, q)
	if err != nil {
		t.Fatal(err)
	}
	var page localTransactionPage
	if err := json.Unmarshal(raw, &page); err != nil || got.Revision != page.Revision {
		t.Fatal("revision differs from pages", err)
	}
	snapshot.localReadModelID++
	if readOverview(t, cfg, snapshot, q).Revision == got.Revision {
		t.Fatal("revision omits model identity")
	}
	empty := readOverview(t, cfg, snapshot, map[string]string{"start": "2025-01-01", "end": "2025-02-01"})
	if empty.PositiveTotalMinorUnits != 0 || len(empty.Categories) != 0 {
		t.Fatal("empty range", empty)
	}
	defaults := readOverview(t, cfg, snapshot, nil)
	if defaults.Start != "0001-01-01" || defaults.End != "9999-12-31" {
		t.Fatal("defaults differ from pages")
	}
	for _, invalid := range []map[string]string{
		{"start": "bad"}, {"end": "2026-02-30"}, {"start": "2026-9-01"},
		{"start": "2026-10-01", "end": "2026-09-01"}, {"start": "2026-09-01", "end": "2026-09-01"},
		{"limit": "4"}, {"cursor": "opaque"}, {"account": "Expenses:Food"}, {"q": "food"},
	} {
		status, raw, err := localOverviewCategoriesResponse(cfg, snapshot, invalid)
		if status != 400 || raw != nil || err == nil {
			t.Fatalf("invalid accepted: %v status=%d error=%v", invalid, status, err)
		}
	}
}

func TestLocalOverviewCategoriesRepresentativeMatchesPageProjection(t *testing.T) {
	cfg, snapshot := overviewFixture(Transaction{
		Payee: "Store", Narration: "Lunch", Tags: []string{"food"}, Links: []string{"receipt"},
		Metadata: map[string]MetadataValue{"secret": strings.Repeat("s", 9<<20)},
		Entry:    &LedgerEntry{},
		Postings: []Posting{overviewPosting("Assets:Investment", 0), overviewPosting("Expenses:Food", 100), overviewPosting("Assets:Cash", -100)},
	})
	snapshot.Transactions[0].Postings[0].Flag = "!"
	snapshot.Transactions[0].Source.GitSHA = "abc"
	before, _ := json.Marshal(snapshot.Transactions[0])
	got := readOverview(t, cfg, snapshot, nil)
	_, raw, err := localTransactionPageResponse(cfg, snapshot, map[string]string{"limit": "1"})
	if err != nil {
		t.Fatal(err)
	}
	var page struct {
		Transactions []json.RawMessage `json:"transactions"`
	}
	if err := json.Unmarshal(raw, &page); err != nil {
		t.Fatal(err)
	}
	if string(page.Transactions[0]) != string(got.Categories[0].Representative) {
		t.Fatal("representative differs from page projection")
	}
	after, _ := json.Marshal(snapshot.Transactions[0])
	if string(before) != string(after) {
		t.Fatal("snapshot mutated")
	}
	snapshot.Transactions[0].Source.File = filepath.Join(filepath.Dir(cfg.LedgerRoot), "outside.bean")
	status, raw, err := localOverviewCategoriesResponse(cfg, snapshot, nil)
	if status != 500 || raw != nil || err == nil {
		t.Fatal("outside source accepted", status, err)
	}
}

func assertOverviewCapacity(t *testing.T, cfg Config, snapshot *LedgerSnapshot) {
	t.Helper()
	status, raw, err := localOverviewCategoriesResponse(cfg, snapshot, nil)
	if status != http.StatusRequestEntityTooLarge || raw != nil || !errors.Is(err, errLocalOverviewCategoryCapacity) {
		t.Fatalf("capacity must return 413 without partial totals: status=%d bytes=%d error=%v", status, len(raw), err)
	}
}

func TestLocalOverviewCategoriesGroupLimitIncludesNonpositive(t *testing.T) {
	txns := make([]Transaction, localOverviewCategoryGroups+1)
	for i := range txns {
		txns[i] = Transaction{Postings: []Posting{overviewPosting(fmt.Sprintf("Expenses:G%04d", i), -1)}}
	}
	cfg, snapshot := overviewFixture(txns[:localOverviewCategoryGroups]...)
	got := readOverview(t, cfg, snapshot, nil)
	if got.PositiveTotalMinorUnits != 0 || len(got.Categories) != 0 {
		t.Fatal("negative groups emitted")
	}
	cfg, snapshot = overviewFixture(txns...)
	assertOverviewCapacity(t, cfg, snapshot)
	// The exact group limit also works for positive groups.
	for i := range txns {
		txns[i].Postings[0].Amount = 1
	}
	cfg, snapshot = overviewFixture(txns[:localOverviewCategoryGroups]...)
	if got := readOverview(t, cfg, snapshot, nil); got.PositiveTotalMinorUnits != localOverviewCategoryGroups {
		t.Fatal("group-boundary partial totals", got.PositiveTotalMinorUnits)
	}
}

func TestLocalOverviewCategoriesWorkingAndResponseLimits(t *testing.T) {
	t.Run("retained representatives including negative buckets", func(t *testing.T) {
		var txns []Transaction
		for i := 0; i < 18; i++ {
			txns = append(txns, Transaction{Narration: strings.Repeat("x", 500000), Postings: []Posting{overviewPosting(fmt.Sprintf("Expenses:G%d", i), -1)}})
		}
		cfg, snapshot := overviewFixture(txns...)
		assertOverviewCapacity(t, cfg, snapshot)
	})
	t.Run("large label before projection", func(t *testing.T) {
		cfg, snapshot := overviewFixture(Transaction{Postings: []Posting{overviewPosting("Expenses:A", 1)}})
		snapshot.Accounts = []Account{{Account: "Expenses:A", Label: strings.Repeat("x", localOverviewCategoryWorkingBytes+1)}}
		snapshot.AccountMap = accountByName(snapshot.Accounts)
		assertOverviewCapacity(t, cfg, snapshot)
	})
	t.Run("large summary before marshal", func(t *testing.T) {
		cfg, snapshot := overviewFixture(Transaction{Narration: strings.Repeat("x", localOverviewCategoryWorkingBytes+1), Postings: []Posting{overviewPosting("Expenses:A", 1)}})
		assertOverviewCapacity(t, cfg, snapshot)
	})
	t.Run("all summary fields accounted", func(t *testing.T) {
		for _, field := range []string{"flag", "tags", "links", "hash", "gitSHA"} {
			t.Run(field, func(t *testing.T) {
				txn := Transaction{Postings: []Posting{overviewPosting("Expenses:A", 1)}}
				large := strings.Repeat("x", localOverviewCategoryWorkingBytes+1)
				switch field {
				case "flag":
					txn.Postings[0].Flag = large
				case "tags":
					txn.Tags = []string{large}
				case "links":
					txn.Links = []string{large}
				}
				cfg, snapshot := overviewFixture(txn)
				if field == "hash" {
					snapshot.Transactions[0].Source.Hash = large
				}
				if field == "gitSHA" {
					snapshot.Transactions[0].Source.GitSHA = large
				}
				assertOverviewCapacity(t, cfg, snapshot)
			})
		}
	})
	t.Run("single summary over response budget", func(t *testing.T) {
		cfg, snapshot := overviewFixture(Transaction{Narration: strings.Repeat("x", localTransactionPageBytes), Postings: []Posting{overviewPosting("Expenses:A", 1)}})
		assertOverviewCapacity(t, cfg, snapshot)
	})
	t.Run("JSON escape expansion", func(t *testing.T) {
		cfg, snapshot := overviewFixture(Transaction{Narration: strings.Repeat("\x01", 200000), Postings: []Posting{overviewPosting("Expenses:A", 1)}})
		assertOverviewCapacity(t, cfg, snapshot)
	})
	t.Run("combined summaries exceed response budget", func(t *testing.T) {
		var txns []Transaction
		for i := 0; i < 4; i++ {
			txns = append(txns, Transaction{Narration: strings.Repeat("x", 280000), Postings: []Posting{overviewPosting(fmt.Sprintf("Expenses:G%d", i), 1)}})
		}
		cfg, snapshot := overviewFixture(txns...)
		assertOverviewCapacity(t, cfg, snapshot)
		for i := range snapshot.Transactions {
			snapshot.Transactions[i].Narration = strings.Repeat("x", 240000)
		}
		if got := readOverview(t, cfg, snapshot, nil); got.PositiveTotalMinorUnits != 4 {
			t.Fatal("near-limit totals")
		}
	})
	t.Run("dropped non-top representative not serialized", func(t *testing.T) {
		var txns []Transaction
		for i := 0; i < 5; i++ {
			txns = append(txns, Transaction{Postings: []Posting{overviewPosting(fmt.Sprintf("Expenses:G%d", i), 10-i)}})
		}
		txns[4].Narration = strings.Repeat("x", 2<<20)
		cfg, snapshot := overviewFixture(txns...)
		if got := readOverview(t, cfg, snapshot, nil); got.PositiveTotalMinorUnits != 40 || len(got.Categories) != 4 {
			t.Fatal(got)
		}
	})
}

func TestLocalOverviewCategoriesOverflowNeverWraps(t *testing.T) {
	p := overviewPosting
	for _, txns := range [][]Transaction{
		{{Postings: []Posting{p("Expenses:A", math.MaxInt), p("Expenses:A", 1)}}},
		{{Postings: []Posting{p("Expenses:A", math.MinInt), p("Expenses:A", -1)}}},
		{{Postings: []Posting{p("Expenses:A", math.MaxInt)}}, {Postings: []Posting{p("Expenses:A", 1)}}},
		{{Postings: []Posting{p("Expenses:A", math.MaxInt)}}, {Postings: []Posting{p("Expenses:B", 1)}}},
	} {
		cfg, snapshot := overviewFixture(txns...)
		assertOverviewCapacity(t, cfg, snapshot)
	}
}

func TestLocalOverviewCategories100kExactFullScan(t *testing.T) {
	const rows = 100000
	txns := make([]Transaction, rows)
	for i := range txns {
		amount := 123
		if i%10 == 0 {
			amount = -23
		}
		txns[i] = Transaction{Date: "2026-09-01", Payee: fmt.Sprint(i), Postings: []Posting{overviewPosting("Expenses:Food", amount), overviewPosting("Assets:Cash", -amount)}}
	}
	cfg, snapshot := overviewFixture(txns...)
	// Thousands of definitions must be indexed once, not scanned for every
	// one of the 100k rows (including snapshots without a prepared AccountMap).
	snapshot.Accounts = []Account{{Account: "Expenses:Food", Label: "Food"}}
	for i := 0; i < 2048; i++ {
		snapshot.Accounts = append(snapshot.Accounts, Account{Account: fmt.Sprintf("Expenses:Unused%d", i)})
	}
	snapshot.AccountMap = nil
	got := readOverview(t, cfg, snapshot, nil)
	const total = 90000*123 - 10000*23
	if got.PositiveTotalMinorUnits != total || len(got.Categories) != 1 || got.Categories[0].TotalMinorUnits != total || got.Categories[0].PositiveTransactionCount != 90000 {
		t.Fatalf("100k partial totals: %+v", got)
	}
	var representative Transaction
	if err := json.Unmarshal(got.Categories[0].Representative, &representative); err != nil || representative.Payee != "0" || representative.Postings[0].Amount != -23 {
		t.Fatal("same-day descending source order / first refund changed", err)
	}
	// Constant retained state on a prepared model: do not accidentally call an
	// all-history projection before reducing. Fixture allocation is excluded.
	allocs := testing.AllocsPerRun(1, func() {
		if status, _, err := localOverviewCategoriesResponse(cfg, snapshot, nil); status != 200 || err != nil {
			panic(err)
		}
	})
	if allocs > 1000 {
		t.Fatalf("per-row projection/allocation regression: %.0f allocations", allocs)
	}
}

func TestLocalOverviewCategoriesIgnoresIneligibleAndOutOfRangePayload(t *testing.T) {
	p := overviewPosting
	cfg, snapshot := overviewFixture(
		Transaction{Postings: []Posting{p("Expenses:Food", 10)}},
		Transaction{Postings: []Posting{p("Income:"+strings.Repeat("x", localOverviewCategoryWorkingBytes+1), -100)}},
		Transaction{Date: "2026-08-31", Narration: strings.Repeat("x", localOverviewCategoryWorkingBytes+1), Postings: []Posting{p("Expenses:Outside", 900)}},
	)
	got := readOverview(t, cfg, snapshot, map[string]string{"start": "2026-09-01", "end": "2026-10-01"})
	if got.PositiveTotalMinorUnits != 10 || len(got.Categories) != 1 {
		t.Fatal("ineligible/range rows affected aggregate", got)
	}
}

func TestLocalOverviewCategoriesRawMinorUnitsAndUnpreparedSnapshot(t *testing.T) {
	cfg, snapshot := overviewFixture(Transaction{Postings: []Posting{
		{Account: "Expenses:Food", Amount: 10, Currency: "CNY"},
		{Account: "Expenses:Food", Amount: 20, Currency: "USD"},
	}})
	snapshot.Accounts = []Account{{Account: "Expenses:Food", Label: "earlier"}, {Account: "Expenses:Food", Label: "later"}}
	snapshot.AccountMap = nil
	snapshot.transactionsAsc, snapshot.transactionsDesc = nil, nil
	got := readOverview(t, cfg, snapshot, nil)
	if got.Categories[0].Label != "later" || got.PositiveTotalMinorUnits != 30 || got.Categories[0].PositiveTransactionCount != 1 {
		t.Fatal("raw minor units / Swift last account wins", got)
	}
	status, raw, err := localOverviewCategoriesResponse(cfg, nil, nil)
	if status != 500 || raw != nil || err == nil {
		t.Fatal("nil snapshot accepted")
	}
}

func TestLocalOverviewCategoriesWorkingBudgetBoundary(t *testing.T) {
	// Three negative buckets stay below the serialized-response surface. Size
	// exactly fills the accounted state; one additional byte must reject.
	txns := make([]Transaction, 3)
	for i := range txns {
		txns[i] = Transaction{Postings: []Posting{overviewPosting(fmt.Sprintf("Expenses:G%d", i), -1)}}
	}
	cfg, snapshot := overviewFixture(txns...)
	// Account lookup state and retained groups share one 8MiB budget.
	snapshot.Accounts = []Account{{Account: "Expenses:G0", Label: "G0"}}
	base := 256 + 2*len("Expenses:G0") + len("G0")
	for _, txn := range snapshot.Transactions {
		base += localOverviewSummaryBytes(txn) + 256 + len("G0")*2
	}
	remaining := localOverviewCategoryWorkingBytes - base
	for i := range snapshot.Transactions {
		n := remaining / (len(snapshot.Transactions) - i)
		snapshot.Transactions[i].Narration = strings.Repeat("x", n)
		remaining -= n
	}
	if got := readOverview(t, cfg, snapshot, nil); got.PositiveTotalMinorUnits != 0 {
		t.Fatal(got)
	}
	snapshot.Transactions[2].Narration += "x"
	assertOverviewCapacity(t, cfg, snapshot)
}

func TestLocalOverviewCategoriesSerializedResponseExactBoundary(t *testing.T) {
	txns := make([]Transaction, 4)
	for i := range txns {
		txns[i] = Transaction{Postings: []Posting{overviewPosting(fmt.Sprintf("Expenses:G%d", i), 1)}}
	}
	cfg, snapshot := overviewFixture(txns...)
	status, raw, err := localOverviewCategoriesResponse(cfg, snapshot, nil)
	if status != 200 || err != nil {
		t.Fatal(status, err)
	}
	remaining := localTransactionPageBytes - len(raw)
	for i := range snapshot.Transactions {
		n := remaining / (len(snapshot.Transactions) - i)
		snapshot.Transactions[i].Narration = strings.Repeat("x", n)
		remaining -= n
	}
	status, raw, err = localOverviewCategoriesResponse(cfg, snapshot, nil)
	if status != 200 || err != nil || len(raw) != localTransactionPageBytes {
		t.Fatal("exact serialized budget rejected", status, len(raw), err)
	}
	snapshot.Transactions[3].Narration += "x"
	assertOverviewCapacity(t, cfg, snapshot)
}

func TestLocalOverviewCategoriesNativeRoute(t *testing.T) {
	input := localTestRequest(t)
	input.Method = "GET"
	input.Path = "/api/ledger/overview/categories"
	input.Query = map[string]string{"start": "0001-01-01", "end": "9999-12-31"}
	status, raw, err := DispatchLocalRequest(input)
	if err != nil || status != 200 || len(raw) > localTransactionPageBytes {
		t.Fatal(status, err)
	}
	var response localOverviewCategories
	if err := json.Unmarshal(raw, &response); err != nil || response.Revision == "" || !response.SensitiveUnlocked || response.Categories == nil {
		t.Fatal("invalid response", err)
	}
	input.Staging = true
	if status, raw, err := DispatchLocalRequest(input); status != 400 || raw != nil || err == nil {
		t.Fatal("staged aggregate accepted", status, err)
	}
	input.Staging = false
	input.ImportFile = &LocalImportFile{Name: "invalid"}
	if status, raw, err := DispatchLocalRequest(input); status != 400 || raw != nil || err == nil {
		t.Fatal("import aggregate accepted", status, err)
	}
}
