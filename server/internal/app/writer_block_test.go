package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func stubBeanCheck(t *testing.T) {
	t.Helper()
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
}

// parsedTransactions returns the transactions exactly as the parser reports
// them, so their sources carry the hash the app would send back to the writer.
func parsedTransactions(t *testing.T, cfg Config) []Transaction {
	t.Helper()
	lines, err := ReadLedgerLines(mainBeanPath(cfg), map[string]bool{})
	if err != nil {
		t.Fatal(err)
	}
	return ParseTransactions(lines)
}

func parsedTransactionByNarration(t *testing.T, cfg Config, narration string) Transaction {
	t.Helper()
	for _, txn := range parsedTransactions(t, cfg) {
		if txn.Narration == narration {
			return txn
		}
	}
	t.Fatalf("transaction %q not found", narration)
	return Transaction{}
}

func blockTestEntry(narration string) LedgerEntry {
	return LedgerEntry{
		Kind:      "transaction",
		Date:      "2026-05-01",
		Flag:      "*",
		Payee:     "Hotel",
		Narration: narration,
		Postings: []EntryPosting{
			{Account: "Expenses:Food", Amount: "500.00", Currency: "CNY"},
			{Account: "Assets:Cash", Amount: "-500.00", Currency: "CNY"},
		},
	}
}

func TestTransactionWritersFindBlocksEndedByUndatedDirectives(t *testing.T) {
	for name, follower := range map[string]string{
		"poptag":           "poptag #trip",
		"option":           `option "operating_currency" "CNY"`,
		"org-mode heading": "* Later",
	} {
		t.Run(name, func(t *testing.T) {
			stubBeanCheck(t)
			cfg := testLedger(t)
			file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
			mustWrite(t, file, strings.Join([]string{
				"pushtag #trip",
				`2026-05-01 * "Hotel" "Stay"`,
				"  Expenses:Food 500.00 CNY",
				"  Assets:Cash -500.00 CNY",
				follower,
				`2026-05-02 * "Cafe" "Lunch"`,
				"  Expenses:Food 12.00 CNY",
				"  Assets:Cash -12.00 CNY",
				"",
			}, "\n"))
			if name != "poptag" {
				// Keep the pushtag balanced so the ledger stays valid.
				content := string(mustRead(t, file)) + "poptag #trip\n"
				mustWrite(t, file, content)
			}
			writer := NewLedgerWriter(cfg, nil)

			hotel := parsedTransactionByNarration(t, cfg, "Stay")
			if err := NewTransactionService(NewLedgerCache(cfg), writer).AddTags([]TransactionSource{hotel.Source}, []string{"extra"}); err != nil {
				t.Fatalf("add tags: %v", err)
			}
			hotel = parsedTransactionByNarration(t, cfg, "Stay")
			if err := writer.ReplaceTransactionBlock(hotel.Source, blockTestEntry("Edited stay")); err != nil {
				t.Fatalf("replace: %v", err)
			}
			after := string(mustRead(t, file))
			if !strings.Contains(after, `"Edited stay"`) || !strings.Contains(after, "-500.00 CNY\n"+follower+"\n") {
				t.Fatalf("edit did not keep the following directive in place:\n%s", after)
			}

			edited := parsedTransactionByNarration(t, cfg, "Edited stay")
			if err := writer.CommentTransactionBlock(edited.Source, ""); err != nil {
				t.Fatalf("delete: %v", err)
			}
			after = string(mustRead(t, file))
			if !strings.Contains(after, "\n"+follower+"\n") || strings.Contains(after, "; "+follower) {
				t.Fatalf("delete commented out the following directive:\n%s", after)
			}
		})
	}
}

func TestReplaceTransactionBlockKeepsBlankSeparator(t *testing.T) {
	stubBeanCheck(t)
	cfg := testLedger(t)
	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	lunch := parsedTransactionByNarration(t, cfg, "Lunch")
	if err := NewLedgerWriter(cfg, nil).ReplaceTransactionBlock(lunch.Source, blockTestEntry("Edited")); err != nil {
		t.Fatal(err)
	}
	after := string(mustRead(t, file))
	if !strings.Contains(after, "-500.00 CNY\n\n2026-05-31 * \"Employer\" \"Salary\"") {
		t.Fatalf("edit removed the blank line before the next entry:\n%s", after)
	}
}

func TestTransactionBeforeDeletedEntryStaysEditable(t *testing.T) {
	stubBeanCheck(t)
	cfg := testLedger(t)
	file := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	writer := NewLedgerWriter(cfg, nil)
	salary := parsedTransactionByNarration(t, cfg, "Salary")
	if err := writer.CommentTransactionBlock(salary.Source, "duplicate"); err != nil {
		t.Fatal(err)
	}
	deleted := string(mustRead(t, file))
	if !strings.Contains(deleted, "\n\n; deleted ") {
		t.Fatalf("delete should keep the blank separator:\n%s", deleted)
	}

	lunch := parsedTransactionByNarration(t, cfg, "Lunch")
	if lunch.Entry == nil {
		t.Fatal("trailing commented-out entry made the previous transaction uneditable")
	}
	if lunch.Entry.Narration != "Lunch" || len(lunch.Entry.Postings) != 2 {
		t.Fatalf("editable draft changed: %#v", lunch.Entry)
	}
	edit := *lunch.Entry
	edit.Narration = "Dinner"
	if err := writer.ReplaceTransactionBlock(lunch.Source, edit); err != nil {
		t.Fatalf("edit before deleted entry: %v", err)
	}
	after := string(mustRead(t, file))
	if !strings.Contains(after, `"Dinner"`) {
		t.Fatalf("edit was not written:\n%s", after)
	}
	if !strings.Contains(after, "\n\n; deleted ") || !strings.Contains(after, `; 2026-05-31 * "Employer" "Salary"`) {
		t.Fatalf("edit dropped the trailing comment lines:\n%s", after)
	}
}

func TestEditableTransactionEntryIgnoresOnlyTrailingWholeLineComments(t *testing.T) {
	trailing := ParseBeanLines([]BeanLine{
		{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Cafe" "Lunch"`},
		{File: "transactions/2026/05.bean", Line: 2, Text: `  Expenses:Food 12.00 CNY`},
		{File: "transactions/2026/05.bean", Line: 3, Text: `  Assets:Cash -12.00 CNY`},
		{File: "transactions/2026/05.bean", Line: 4, Text: ``},
		{File: "transactions/2026/05.bean", Line: 5, Text: `; import-fingerprint: abc`},
	})
	if editable := EditableLedgerEntryFromBeanTransaction(trailing.Entries[0]); editable == nil {
		t.Fatal("whole-line comments after the last posting should not block editing")
	}
	inner := ParseBeanLines([]BeanLine{
		{File: "transactions/2026/05.bean", Line: 1, Text: `2026-05-01 * "Cafe" "Lunch"`},
		{File: "transactions/2026/05.bean", Line: 2, Text: `  Expenses:Food 12.00 CNY`},
		{File: "transactions/2026/05.bean", Line: 3, Text: `  ; between postings`},
		{File: "transactions/2026/05.bean", Line: 4, Text: `  Assets:Cash -12.00 CNY`},
	})
	if editable := EditableLedgerEntryFromBeanTransaction(inner.Entries[0]); editable != nil {
		t.Fatal("a comment between postings would be lost and must keep blocking edits")
	}
}
