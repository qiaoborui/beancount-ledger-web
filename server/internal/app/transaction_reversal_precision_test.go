package app

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestReversalPreservesExactQuantityAndAnnotations(t *testing.T) {
	raw := []string{
		`2026-05-01 ! "Exchange" "Move" #investment ^order-1`,
		`  note: "original"`,
		`  ! Assets:Wallet 0.00010001 BTC`,
		`  Assets:Exchange -0.00010001 BTC`,
	}
	lines := make([]BeanLine, len(raw))
	for i, text := range raw {
		lines[i] = BeanLine{File: "sample.bean", Line: i + 1, Text: text}
	}
	original := ParseTransactions(lines)[0]
	entry, err := ReverseTransactionEntry(original, "2026-05-02")
	if err != nil {
		t.Fatal(err)
	}
	if entry.Postings[0].Amount != "-0.00010001" || entry.Postings[1].Amount != "0.00010001" {
		t.Fatalf("reversal lost exact quantities: %#v", entry.Postings)
	}
	if entry.Flag != "!" || entry.Postings[0].Flag != "!" || len(entry.Links) != 1 || entry.Metadata["note"] != "original" {
		t.Fatalf("reversal lost annotations: %#v", entry)
	}
	if original.Entry.Postings[0].Amount != "0.00010001" || original.Entry.Metadata["reversal"] != nil {
		t.Fatal("reversal mutated the original entry")
	}
}

func TestReversalBalancesExactUnitsCostsAndPrices(t *testing.T) {
	useRealGitHubBeanCheck(t)
	for name, annotation := range map[string]string{"units": "", "unit_cost": "{50000 USD, 2026-05-01}", "total_cost": "{{5 USD, 2026-05-01}}", "total_price": "@@ 5 USD"} {
		t.Run(name, func(t *testing.T) {
			currency, amount := "BTC", "-0.0001"
			if annotation != "" {
				currency, amount = "USD", "-5"
			}
			raw := []string{`2026-05-01 * "Exchange" "Buy"`, "  Assets:Wallet 0.0001 BTC " + annotation, "  Assets:Cash " + amount + " " + currency}
			lines := make([]BeanLine, len(raw))
			for i, text := range raw {
				lines[i] = BeanLine{File: "main.bean", Line: i + 1, Text: text}
			}
			original := ParseTransactions(lines)[0]
			entry, err := ReverseTransactionEntry(original, "2026-05-02")
			if err != nil {
				t.Fatal(err)
			}
			cfg := Config{LedgerRoot: t.TempDir()}
			content := "2026-01-01 open Assets:Wallet BTC\n2026-01-01 open Assets:Cash\n" + strings.Join(raw, "\n") + "\n" + TransactionToBean(entry) + "\n2026-05-03 balance Assets:Wallet 0 BTC\n2026-05-03 balance Assets:Cash 0 " + currency + "\n"
			mustWrite(t, filepath.Join(cfg.LedgerRoot, "main.bean"), content)
			if err := runBeanCheck(cfg); err != nil {
				t.Fatalf("original + reversal must return both accounts to zero: %v\n%s", err, content)
			}
		})
	}
}

func TestReversalPreservesLotAndPrice(t *testing.T) {
	raw := []string{
		`2026-05-01 * "Broker" "Buy"`,
		`  Assets:Broker 1.23456789 VT {{ 123.456789 USD, 2026-05-01, "lot-a" }} @@ 160.1234567 USD`,
		`  Assets:Cash -123.456789 USD`,
	}
	lines := make([]BeanLine, len(raw))
	for i, text := range raw {
		lines[i] = BeanLine{File: "sample.bean", Line: i + 1, Text: text}
	}
	original := ParseTransactions(lines)[0]
	entry, err := ReverseTransactionEntry(original, "2026-05-02")
	if err != nil {
		t.Fatal(err)
	}
	posting := entry.Postings[0]
	if posting.Amount != "-1.23456789" || posting.CostSpec != original.Entry.Postings[0].CostSpec || posting.PriceKind != "total" || posting.PriceAmount != "160.1234567" {
		t.Fatalf("reversal lost lot or price: %#v", posting)
	}
	if !strings.Contains(TransactionToBean(entry), `@@ 160.1234567 USD`) {
		t.Fatal("total price was lost")
	}
}

func TestReversalRejectsLossySummary(t *testing.T) {
	_, err := ReverseTransactionEntry(Transaction{Postings: []Posting{{Account: "Assets:Wallet", Amount: 0, Currency: "BTC"}}}, "2026-05-02")
	if err == nil {
		t.Fatal("summary-only transaction must require manual reversal")
	}
}

func TestReversalPreservesInferredBalancingLeg(t *testing.T) {
	original := Transaction{Entry: &LedgerEntry{Postings: []EntryPosting{
		{Account: "Expenses:Food", Amount: "12.00", Currency: "CNY"}, {Account: "Assets:Cash"},
	}}}
	entry, err := ReverseTransactionEntry(original, "2026-05-02")
	if err != nil {
		t.Fatal(err)
	}
	if entry.Postings[0].Amount != "-12.00" || entry.Postings[1].Amount != "" || entry.Postings[1].Currency != "" {
		t.Fatalf("inferred balancing leg changed: %#v", entry.Postings)
	}
}
