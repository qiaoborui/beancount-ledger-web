package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// The post date backfill runs the import matcher over every archived HSBC HK
// statement, so entries booked before the import learned to carry post dates
// get them too. It is stateless: apply recomputes the match and writes only
// the fills the user selected, refusing when the ledger moved in between.
// It also reports card purchases that sit in the ledger twice, once from the
// bank and once from Alipay/WeChat; those are only listed, never removed.

const (
	postDateBackfillProvider          = "hsbchk-credit"
	ledgerWriteSourcePostDateBackfill = "post-date-backfill"
)

type PostDateBackfillApplyRequest struct {
	FillIDs []string `json:"fillIds"`
}

type postDateEntryRef struct {
	Date      string `json:"date"`
	Payee     string `json:"payee"`
	Narration string `json:"narration"`
	Amount    string `json:"amount"`
	Currency  string `json:"currency"`
	PostDate  string `json:"postDate,omitempty"`
	Source    string `json:"source,omitempty"`
	File      string `json:"file"`
	Line      int    `json:"line"`
}

// postDateBackfillReview is a statement row that probably belongs to an
// existing entry but was not paired automatically.
type postDateBackfillReview struct {
	BankDate  string              `json:"bankDate"`
	PostDate  string              `json:"postDate"`
	BankPayee string              `json:"bankPayee"`
	Amount    string              `json:"amount"`
	Currency  string              `json:"currency"`
	Hint      ImportDuplicateHint `json:"hint"`
}

type postDateDuplicatePair struct {
	Bank       postDateEntryRef `json:"bank"`
	Existing   postDateEntryRef `json:"existing"`
	AmountDiff string           `json:"amountDiff"`
}

type postDateBackfillResult struct {
	Documents          int                      `json:"documents"`
	BankRows           int                      `json:"bankRows"`
	MissingPostDate    int                      `json:"missingPostDate"`
	Fills              []importPostDateFill     `json:"fills"`
	Reviews            []postDateBackfillReview `json:"reviews"`
	PossibleDuplicates []postDateDuplicatePair  `json:"possibleDuplicates"`
	Warnings           []string                 `json:"warnings"`
}

func (s *Server) buildPostDateBackfill(ctx context.Context) (postDateBackfillResult, error) {
	result := postDateBackfillResult{Fills: []importPostDateFill{}, Reviews: []postDateBackfillReview{}, PossibleDuplicates: []postDateDuplicatePair{}, Warnings: []string{}}
	importer, err := s.ensureImportRequirements(postDateBackfillProvider)
	if err != nil {
		return result, err
	}
	documents, err := s.listImportDocuments(ctx)
	if err != nil {
		return result, err
	}
	statements := []ImportDocument{}
	for _, document := range documents {
		if document.Provider == postDateBackfillProvider && document.Ext == ".csv" {
			statements = append(statements, document)
		}
	}
	sort.Slice(statements, func(i, j int) bool { return statements[i].Path < statements[j].Path })

	perStatement := [][]postDateBankRow{}
	for _, document := range statements {
		rows, err := s.postDateRowsFromStatement(ctx, importer, document)
		if err != nil {
			result.Warnings = append(result.Warnings, fmt.Sprintf("跳过账单 %s：%v", document.Name, err))
			continue
		}
		result.Documents++
		perStatement = append(perStatement, rows)
	}
	rows := mergePostDateStatementRows(perStatement)
	result.BankRows = len(rows)

	snapshot, err := s.ledgerSnapshotLite(ctx)
	if err != nil {
		return result, err
	}
	existing := snapshot.Transactions
	duplicates, duplicated := findPostDateDuplicates(existing)
	result.PossibleDuplicates = append(result.PossibleDuplicates, duplicates...)
	result.MissingPostDate = len(postDateTargets(existing, rows))

	// An entry that already has a bank twin needs the user first; filling it
	// from another statement row would hide the duplicate.
	matchable := make([]Transaction, 0, len(existing))
	for _, txn := range existing {
		if !duplicated[postDateSourceKey(txn.Source)] {
			matchable = append(matchable, txn)
		}
	}
	fills, hints, _ := pairPostDateRows(matchable, unimportedPostDateRows(existing, rows))
	result.Fills = append(result.Fills, fills...)
	for _, hint := range hints {
		result.Reviews = append(result.Reviews, postDateBackfillReview{
			BankDate:  hint.bank.dateText,
			PostDate:  hint.bank.postDate,
			BankPayee: hint.bank.payee,
			Amount:    fromCents(hint.bank.amount),
			Currency:  hint.bank.currency,
			Hint:      hint.hint,
		})
	}
	return result, nil
}

// postDateRowsFromStatement generates the statement with the same importer
// and configuration a fresh import would use.
func (s *Server) postDateRowsFromStatement(ctx context.Context, importer billImporter, document ImportDocument) ([]postDateBankRow, error) {
	content, err := s.readImportDocument(ctx, document.Path)
	if err != nil {
		return nil, err
	}
	importID := "postdate-backfill-" + randomID()
	defer os.RemoveAll(importRuntimeDir(s.cfg, importID))
	input := previewPath(s.cfg, importID, "statement.csv")
	if err := os.MkdirAll(filepath.Dir(input), 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(input, content, 0o600); err != nil {
		return nil, err
	}
	prepared, err := importer.Prepare(s, importFileInput{InputFile: input, OriginalFilename: document.Name, ImportID: importID})
	if err != nil {
		return nil, err
	}
	output := previewPath(s.cfg, importID, importer.ProviderConfig().Output)
	if err := importer.Generate(ctx, s, prepared, output); err != nil {
		return nil, err
	}
	generated, err := os.ReadFile(output)
	if err != nil {
		return nil, err
	}
	parsed := ParseBeanLines(beanTextLines("<postdate-backfill>", transactionOnlyBeanText(string(generated))))
	if len(parsed.Errors) > 0 {
		return nil, parsed.Errors[0]
	}
	source := postDateStatementSource(sha256Hex(content))
	rows := []postDateBankRow{}
	for _, entry := range parsed.Entries {
		if entry.Kind != "transaction" {
			continue
		}
		if row, ok := postDateBankRowFromEntry(entry, 0); ok {
			row.source = source
			rows = append(rows, row)
		}
	}
	return rows, nil
}

func (s *Server) readImportDocument(ctx context.Context, rawPath string) ([]byte, error) {
	path, full, err := cleanImportDocumentPath(s.cfg, rawPath)
	if err != nil {
		return nil, err
	}
	if githubAPIEnabled(s.cfg) {
		client, err := newGitHubLedgerClient(s.cfg)
		if err != nil {
			return nil, err
		}
		return client.readLedgerFile(ctx, path)
	}
	return os.ReadFile(full)
}

// mergePostDateStatementRows unions rows across statements whose date ranges
// overlap: a row exported twice counts once, while repeated identical rows
// inside one statement (two 1.20 snacks) keep their multiplicity.
func mergePostDateStatementRows(perStatement [][]postDateBankRow) []postDateBankRow {
	best := map[string][]postDateBankRow{}
	for _, rows := range perStatement {
		byKey := map[string][]postDateBankRow{}
		for _, row := range rows {
			byKey[row.key] = append(byKey[row.key], row)
		}
		for key, group := range byKey {
			if len(group) > len(best[key]) {
				best[key] = group
			}
		}
	}
	merged := []postDateBankRow{}
	for _, group := range best {
		merged = append(merged, group...)
	}
	sort.SliceStable(merged, func(i, j int) bool {
		if merged[i].dateText != merged[j].dateText {
			return merged[i].dateText < merged[j].dateText
		}
		if merged[i].key != merged[j].key {
			return merged[i].key < merged[j].key
		}
		return merged[i].source < merged[j].source
	})
	for index := range merged {
		merged[index].index = index
	}
	return merged
}

// findPostDateDuplicates pairs bank-imported card entries with entries from
// other sources on the same card that look like the same purchase.
func findPostDateDuplicates(existing []Transaction) ([]postDateDuplicatePair, map[string]bool) {
	banks := []postDateBankRow{}
	bankTxns := []Transaction{}
	for _, txn := range existing {
		if metadataString(txn.Metadata["credit_or_debit"]) == "" {
			continue
		}
		status := metadataString(txn.Metadata["status"])
		if status != "" && !strings.EqualFold(status, "POSTED") {
			continue
		}
		row, ok := postDateBankRowFromTransaction(txn, len(banks))
		if !ok {
			continue
		}
		banks = append(banks, row)
		bankTxns = append(bankTxns, txn)
	}
	targets := postDateTargets(existing, banks)
	pairs := []postDatePair{}
	for b, bank := range banks {
		for t, target := range targets {
			if target.account != bank.account || target.currency != bank.currency || (target.amount > 0) != (bank.amount > 0) {
				continue
			}
			days := absInt(int(bank.date.Sub(target.date).Hours() / 24))
			diff := absInt(bank.amount - target.amount)
			if days <= postDateMatchWindowDays && diff <= postDateMatchToleranceCents {
				pairs = append(pairs, postDatePair{bank: b, target: t, amountDiff: diff, dayDiff: days})
			}
		}
	}
	duplicates := []postDateDuplicatePair{}
	duplicated := map[string]bool{}
	for _, pair := range assignPostDatePairs(pairs, make([]bool, len(banks)), make([]bool, len(targets))) {
		bank, target := banks[pair.bank], targets[pair.target]
		duplicated[postDateSourceKey(target.txn.Source)] = true
		duplicates = append(duplicates, postDateDuplicatePair{
			Bank:       postDateEntryRefOf(bankTxns[pair.bank], bank.amount, bank.currency),
			Existing:   postDateEntryRefOf(target.txn, target.amount, target.currency),
			AmountDiff: fromCents(pair.amountDiff),
		})
	}
	sort.SliceStable(duplicates, func(i, j int) bool { return duplicates[i].Bank.Date < duplicates[j].Bank.Date })
	return duplicates, duplicated
}

func postDateBankRowFromTransaction(txn Transaction, index int) (postDateBankRow, bool) {
	postDate := metadataString(txn.Metadata["post_date"])
	date, err := time.Parse("2006-01-02", txn.Date)
	if postDate == "" || err != nil {
		return postDateBankRow{}, false
	}
	for _, posting := range txn.Postings {
		if strings.HasPrefix(posting.Account, "Liabilities:") && posting.Amount != 0 {
			return postDateBankRow{
				index:    index,
				date:     date,
				dateText: txn.Date,
				postDate: postDate,
				account:  posting.Account,
				amount:   posting.Amount,
				currency: posting.Currency,
				payee:    valueOr(txn.Payee, txn.Narration),
				key:      postDateBankKey(txn.Date, postDate, posting.Account, posting.Amount, posting.Currency),
			}, true
		}
	}
	return postDateBankRow{}, false
}

func postDateEntryRefOf(txn Transaction, amount int, currency string) postDateEntryRef {
	return postDateEntryRef{
		Date:      txn.Date,
		Payee:     txn.Payee,
		Narration: txn.Narration,
		Amount:    fromCents(amount),
		Currency:  currency,
		PostDate:  metadataString(txn.Metadata["post_date"]),
		Source:    metadataString(txn.Metadata["source"]),
		File:      txn.Source.File,
		Line:      txn.Source.Line,
	}
}

func postDateSourceKey(source TransactionSource) string {
	return fmt.Sprintf("%s:%d", source.File, source.Line)
}

func (s *Server) applyPostDateBackfill(ctx context.Context, fillIDs []string) (ginH, error) {
	wanted := map[string]bool{}
	for _, id := range fillIDs {
		if strings.TrimSpace(id) != "" {
			wanted[id] = true
		}
	}
	if len(wanted) == 0 {
		return nil, errors.New("没有选择要补写的记账日")
	}
	current, err := s.buildPostDateBackfill(ctx)
	if err != nil {
		return nil, err
	}
	selected := []importPostDateFill{}
	for _, fill := range current.Fills {
		if wanted[fill.ID] {
			selected = append(selected, fill)
		}
	}
	if len(selected) != len(wanted) {
		return nil, errors.New("账本或账单在扫描后有变化，请重新扫描后再写入")
	}
	gitSHA, err := s.writer.RunTransactionWithSourceResult(ledgerWriteSourcePostDateBackfill, func(tx *LedgerWriteTransaction) error {
		return applyPostDateFills(tx, s.cfg, selected, "")
	})
	if err != nil {
		return nil, err
	}
	result := ginH{"ok": true, "count": len(selected), "readModelPending": ledgerReadModelEnabled(s.cfg)}
	if gitSHA != "" {
		result["indexGitSHA"] = gitSHA
	}
	return result, nil
}
