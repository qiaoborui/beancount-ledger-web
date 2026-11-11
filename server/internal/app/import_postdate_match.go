package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// HSBC HK statement rows carry the bank post date but an unreadable merchant;
// Alipay and WeChat exports describe the purchase but have no post date. When a
// statement row is the same purchase as an existing Alipay/WeChat (or manual)
// entry on the card, the import writes the row's post date onto that entry
// instead of appending a second copy of the purchase. Rows that only nearly
// match (a discount, an ambiguous pairing) stay in the preview with a hint so
// the user decides; nothing is merged or dropped on a guess.

const (
	postDateMatchWindowDays     = 5
	postDateMatchToleranceCents = 50
	postDateMatchFileName       = "postdate-match"
)

const (
	duplicateHintAmountDiffers = "amount-differs"
	duplicateHintAmbiguous     = "ambiguous"
)

type importPostDateFill struct {
	ID        string            `json:"id"`
	Target    TransactionSource `json:"target"`
	Date      string            `json:"date"`
	Payee     string            `json:"payee"`
	Narration string            `json:"narration"`
	Account   string            `json:"account"`
	Amount    string            `json:"amount"`
	Currency  string            `json:"currency"`
	PostDate  string            `json:"postDate"`
	BankDate  string            `json:"bankDate"`
	BankPayee string            `json:"bankPayee"`
	// Source is the post_date_source written with the fill; empty means the
	// statement being imported.
	Source string `json:"source,omitempty"`
}

// ImportDuplicateHint marks a preview entry that is probably the same purchase
// as an existing ledger entry. It is preview-only and never rendered to Beancount.
type ImportDuplicateHint struct {
	Reason    string `json:"reason"`
	Date      string `json:"date"`
	Payee     string `json:"payee"`
	Narration string `json:"narration"`
	Amount    string `json:"amount"`
	Currency  string `json:"currency"`
	Source    string `json:"source,omitempty"`
}

type postDateMatchResult struct {
	Fills []importPostDateFill           `json:"fills"`
	Hints map[string]ImportDuplicateHint `json:"hints,omitempty"`
	Kept  []string                       `json:"-"`
}

type postDateBankRow struct {
	index    int
	date     time.Time
	dateText string
	postDate string
	account  string
	amount   int
	currency string
	payee    string
	key      string
	source   string
}

type postDateTarget struct {
	txn      Transaction
	date     time.Time
	account  string
	amount   int
	currency string
}

type postDatePair struct {
	bank, target int
	amountDiff   int
	dayDiff      int
}

// matchImportPostDates pairs the statement rows in beanText with existing
// ledger entries that lack a post date. Exact amount pairs become fills and
// leave the import; near pairs and ambiguous pairs become hints. Kept holds
// the transaction blocks that continue through normal deduplication.
func matchImportPostDates(existing []Transaction, beanText string) (postDateMatchResult, error) {
	result := postDateMatchResult{Hints: map[string]ImportDuplicateHint{}}
	parsed := ParseBeanLines(beanTextLines("<import-postdate>", beanText))
	if len(parsed.Errors) > 0 {
		return result, parsed.Errors[0]
	}
	blocks := []string{}
	rows := []postDateBankRow{}
	for _, entry := range parsed.Entries {
		if entry.Kind != "transaction" || len(entry.RawLines) == 0 {
			continue
		}
		index := len(blocks)
		blocks = append(blocks, strings.TrimRight(strings.Join(entry.RawLines, "\n"), "\n"))
		if row, ok := postDateBankRowFromEntry(entry, index); ok {
			rows = append(rows, row)
		}
	}
	fills, hints, matched := pairPostDateRows(existing, unimportedPostDateRows(existing, rows))
	result.Fills = fills
	for _, hint := range hints {
		result.Hints[hint.bank.key] = hint.hint
	}
	for index, block := range blocks {
		if !matched[index] {
			result.Kept = append(result.Kept, block)
		}
	}
	return result, nil
}

// unimportedPostDateRows drops statement rows already in the ledger as their
// own bank entry. Those are left to normal deduplication; matching them would
// hide an existing duplicate.
func unimportedPostDateRows(existing []Transaction, rows []postDateBankRow) []postDateBankRow {
	alreadyImported := map[string]int{}
	for _, txn := range existing {
		postDate := metadataString(txn.Metadata["post_date"])
		if postDate == "" {
			continue
		}
		for _, posting := range txn.Postings {
			if strings.HasPrefix(posting.Account, "Liabilities:") && posting.Amount != 0 {
				alreadyImported[postDateBankKey(txn.Date, postDate, posting.Account, posting.Amount, posting.Currency)]++
			}
		}
	}
	kept := make([]postDateBankRow, 0, len(rows))
	for _, row := range rows {
		if alreadyImported[row.key] > 0 {
			alreadyImported[row.key]--
			continue
		}
		kept = append(kept, row)
	}
	return kept
}

type postDateRowHint struct {
	bank postDateBankRow
	hint ImportDuplicateHint
}

// pairPostDateRows pairs bank rows with existing entries that lack a post
// date. Exact unique pairs become fills; ambiguous exact pairs and pairs
// within the tolerance become hints. matched holds the fills' row indexes.
func pairPostDateRows(existing []Transaction, banks []postDateBankRow) ([]importPostDateFill, []postDateRowHint, map[int]bool) {
	targets := postDateTargets(existing, banks)
	exact, near := []postDatePair{}, []postDatePair{}
	for b, bank := range banks {
		for t, target := range targets {
			if target.account != bank.account || target.currency != bank.currency || (target.amount > 0) != (bank.amount > 0) {
				continue
			}
			days := absInt(int(bank.date.Sub(target.date).Hours() / 24))
			if days > postDateMatchWindowDays {
				continue
			}
			diff := absInt(bank.amount - target.amount)
			pair := postDatePair{bank: b, target: t, amountDiff: diff, dayDiff: days}
			if diff == 0 {
				exact = append(exact, pair)
			} else if diff <= postDateMatchToleranceCents {
				near = append(near, pair)
			}
		}
	}

	fills := []importPostDateFill{}
	hints := []postDateRowHint{}
	matched := map[int]bool{}
	bankTaken := make([]bool, len(banks))
	targetTaken := make([]bool, len(targets))
	for _, pair := range assignPostDatePairs(exact, bankTaken, targetTaken) {
		bank, target := banks[pair.bank], targets[pair.target]
		if postDatePairAmbiguous(pair, exact, banks, targets, bankTaken, targetTaken) {
			hints = append(hints, postDateRowHint{bank: bank, hint: postDateHint(duplicateHintAmbiguous, target)})
			continue
		}
		matched[bank.index] = true
		fills = append(fills, importPostDateFill{
			ID:        fmt.Sprintf("%s|%s:%d", bank.key, target.txn.Source.File, target.txn.Source.Line),
			Target:    target.txn.Source,
			Date:      target.txn.Date,
			Payee:     target.txn.Payee,
			Narration: target.txn.Narration,
			Account:   target.account,
			Amount:    fromCents(target.amount),
			Currency:  target.currency,
			PostDate:  bank.postDate,
			BankDate:  bank.dateText,
			BankPayee: bank.payee,
			Source:    bank.source,
		})
	}
	// Near pairs only ever pair leftovers on both sides, so a row with an exact
	// counterpart is never reported against a different entry.
	for _, pair := range assignPostDatePairs(near, bankTaken, targetTaken) {
		hints = append(hints, postDateRowHint{bank: banks[pair.bank], hint: postDateHint(duplicateHintAmountDiffers, targets[pair.target])})
	}
	return fills, hints, matched
}

func postDateBankRowFromEntry(entry BeanEntry, index int) (postDateBankRow, bool) {
	postDate := metadataString(entry.Metadata["post_date"])
	if postDate == "" || !strings.EqualFold(metadataString(entry.Metadata["status"]), "POSTED") {
		return postDateBankRow{}, false
	}
	date, err := time.Parse("2006-01-02", entry.Date)
	if err != nil {
		return postDateBankRow{}, false
	}
	for _, posting := range entry.Postings {
		if !strings.HasPrefix(posting.Account, "Liabilities:") || posting.Amount == 0 {
			continue
		}
		return postDateBankRow{
			index:    index,
			date:     date,
			dateText: entry.Date,
			postDate: postDate,
			account:  posting.Account,
			amount:   posting.Amount,
			currency: posting.Currency,
			payee:    valueOr(entry.Payee, entry.Narration),
			key:      postDateBankKey(entry.Date, postDate, posting.Account, posting.Amount, posting.Currency),
		}, true
	}
	return postDateBankRow{}, false
}

// postDateTargets lists card postings that a statement row could belong to:
// entries without a post date that the bank importer did not write itself.
func postDateTargets(existing []Transaction, banks []postDateBankRow) []postDateTarget {
	accounts := map[string]bool{}
	for _, bank := range banks {
		accounts[bank.account] = true
	}
	targets := []postDateTarget{}
	if len(accounts) == 0 {
		return targets
	}
	for _, txn := range existing {
		if metadataString(txn.Metadata["post_date"]) != "" || metadataString(txn.Metadata["credit_or_debit"]) != "" {
			continue
		}
		date, err := time.Parse("2006-01-02", txn.Date)
		if err != nil {
			continue
		}
		for _, posting := range txn.Postings {
			if accounts[posting.Account] && posting.Amount != 0 {
				targets = append(targets, postDateTarget{txn: txn, date: date, account: posting.Account, amount: posting.Amount, currency: posting.Currency})
				break
			}
		}
	}
	sort.SliceStable(targets, func(i, j int) bool {
		a, b := targets[i].txn, targets[j].txn
		if a.Date != b.Date {
			return a.Date < b.Date
		}
		if a.Source.File != b.Source.File {
			return a.Source.File < b.Source.File
		}
		return a.Source.Line < b.Source.Line
	})
	return targets
}

// assignPostDatePairs is a deterministic one-to-one greedy assignment: the
// closest amount wins, then the closest date, then statement and ledger order.
func assignPostDatePairs(pairs []postDatePair, bankTaken, targetTaken []bool) []postDatePair {
	sort.SliceStable(pairs, func(i, j int) bool {
		a, b := pairs[i], pairs[j]
		if a.amountDiff != b.amountDiff {
			return a.amountDiff < b.amountDiff
		}
		if a.dayDiff != b.dayDiff {
			return a.dayDiff < b.dayDiff
		}
		if a.bank != b.bank {
			return a.bank < b.bank
		}
		return a.target < b.target
	})
	chosen := []postDatePair{}
	for _, pair := range pairs {
		if bankTaken[pair.bank] || targetTaken[pair.target] {
			continue
		}
		bankTaken[pair.bank] = true
		targetTaken[pair.target] = true
		chosen = append(chosen, pair)
	}
	return chosen
}

// postDatePairAmbiguous reports whether an equally good pairing was left
// unmatched and would have produced a different result. Interchangeable
// candidates (same date on the ledger side, same post date on the bank side)
// are not ambiguous: either one yields the same ledger.
func postDatePairAmbiguous(pair postDatePair, pairs []postDatePair, banks []postDateBankRow, targets []postDateTarget, bankTaken, targetTaken []bool) bool {
	for _, other := range pairs {
		if other.amountDiff != pair.amountDiff || other.dayDiff != pair.dayDiff {
			continue
		}
		if other.target == pair.target && other.bank != pair.bank && !bankTaken[other.bank] && banks[other.bank].postDate != banks[pair.bank].postDate {
			return true
		}
		if other.bank == pair.bank && other.target != pair.target && !targetTaken[other.target] && targets[other.target].txn.Date != targets[pair.target].txn.Date {
			return true
		}
	}
	return false
}

func postDateHint(reason string, target postDateTarget) ImportDuplicateHint {
	return ImportDuplicateHint{
		Reason:    reason,
		Date:      target.txn.Date,
		Payee:     target.txn.Payee,
		Narration: target.txn.Narration,
		Amount:    fromCents(target.amount),
		Currency:  target.currency,
		Source:    metadataString(target.txn.Metadata["source"]),
	}
}

func postDateBankKey(date, postDate, account string, amount int, currency string) string {
	return fmt.Sprintf("%s|%s|%s|%d|%s", date, postDate, account, amount, currency)
}

func importEntryPostDateKey(entry ImportEntry) string {
	postDate := entry.Metadata["post_date"]
	if postDate == "" {
		return ""
	}
	for _, posting := range entry.Postings {
		if strings.HasPrefix(posting.Account, "Liabilities:") {
			if amount := cents(posting.Amount); amount != 0 {
				return postDateBankKey(entry.Date, postDate, posting.Account, amount, posting.Currency)
			}
		}
	}
	return ""
}

func absInt(value int) int {
	if value < 0 {
		return -value
	}
	return value
}

func (s *Server) savePostDateMatch(ctx context.Context, importID string, match postDateMatchResult) error {
	if len(match.Fills) == 0 && len(match.Hints) == 0 {
		return nil
	}
	raw, err := json.Marshal(match)
	if err != nil {
		return err
	}
	_, err = s.putImportFile(ctx, importID, postDateMatchFileName, raw)
	return err
}

func (s *Server) loadPostDateMatch(ctx context.Context, importID string) (postDateMatchResult, error) {
	file, ok, err := s.runtime().GetFile(ctx, "imports", importFileKey(importID, postDateMatchFileName))
	if err != nil || !ok {
		return postDateMatchResult{}, err
	}
	var match postDateMatchResult
	if err := json.Unmarshal(file.Content, &match); err != nil {
		return postDateMatchResult{}, fmt.Errorf("读取记账日匹配结果失败: %w", err)
	}
	return match, nil
}

func decoratePostDateHints(entries []ImportEntry, hints map[string]ImportDuplicateHint) {
	if len(hints) == 0 {
		return
	}
	for i := range entries {
		if hint, ok := hints[importEntryPostDateKey(entries[i])]; ok {
			hint := hint
			entries[i].DuplicateHint = &hint
		}
	}
}

func postDateMatchWarning(match postDateMatchResult) string {
	if len(match.Fills) == 0 && len(match.Hints) == 0 {
		return ""
	}
	return fmt.Sprintf("记账日匹配：%d 条与已有分录金额一致，提交时只补写 post_date，不新增分录；%d 条疑似与已有分录重复，请确认后再导入。", len(match.Fills), len(match.Hints))
}

// applyPostDateFills writes post_date metadata onto the matched entries inside
// the import's write transaction, so a failed bean-check rolls both back.
func applyPostDateFills(tx *LedgerWriteTransaction, cfg Config, fills []importPostDateFill, statementHash string) error {
	byFile := map[string][]importPostDateFill{}
	for _, fill := range fills {
		file, err := editableLedgerFile(cfg, fill.Target.File)
		if err != nil {
			return err
		}
		byFile[filepath.Clean(file)] = append(byFile[filepath.Clean(file)], fill)
	}
	files := make([]string, 0, len(byFile))
	for file := range byFile {
		files = append(files, file)
	}
	sort.Strings(files)
	if err := tx.PrefetchFiles(files); err != nil {
		return err
	}
	statementSource := postDateStatementSource(statementHash)
	for _, file := range files {
		before, err := tx.ReadFile(file)
		if err != nil {
			return err
		}
		text := string(before)
		// Later lines first, so earlier source lines stay valid.
		fileFills := byFile[file]
		sort.SliceStable(fileFills, func(i, j int) bool { return fileFills[i].Target.Line > fileFills[j].Target.Line })
		for _, fill := range fileFills {
			text, err = insertPostDateMetadata(text, fill, valueOr(fill.Source, statementSource))
			if err != nil {
				return err
			}
		}
		if text != string(before) {
			if err := tx.WriteFile(file, []byte(text), 0o644); err != nil {
				return err
			}
		}
	}
	return nil
}

func insertPostDateMetadata(text string, fill importPostDateFill, source string) (string, error) {
	lines, start, end, err := transactionBlock(text, fill.Target)
	if err != nil {
		return "", fmt.Errorf("补写记账日失败（%s %s）：%w", fill.Date, fill.Payee, err)
	}
	if !strings.HasPrefix(strings.TrimSpace(lines[start]), fill.Date) {
		return "", errors.New("补写记账日失败：原交易日期已变化，请重新上传账单")
	}
	insertAt := start + 1
	indent := "  "
	for index := start + 1; index < end; index++ {
		key, lineIndent, ok := beanMetadataLineKey(lines[index])
		if !ok {
			break
		}
		if key == "post_date" {
			return text, nil
		}
		indent = lineIndent
		if key > "post_date" {
			break
		}
		insertAt = index + 1
	}
	added := []string{
		fmt.Sprintf("%spost_date: %q", indent, fill.PostDate),
		fmt.Sprintf("%spost_date_source: %q", indent, source),
	}
	next := append([]string{}, lines[:insertAt]...)
	next = append(next, added...)
	next = append(next, lines[insertAt:]...)
	return strings.Join(next, "\n"), nil
}

func beanMetadataLineKey(line string) (string, string, bool) {
	trimmed := strings.TrimLeft(line, " \t")
	if trimmed == line || trimmed == "" {
		return "", "", false
	}
	colon := strings.Index(trimmed, ":")
	if colon <= 0 {
		return "", "", false
	}
	key := trimmed[:colon]
	if key[0] < 'a' || key[0] > 'z' {
		return "", "", false
	}
	for _, char := range key {
		if !(char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' || char >= '0' && char <= '9' || char == '_' || char == '-') {
			return "", "", false
		}
	}
	return key, line[:len(line)-len(trimmed)], true
}

func postDateFillsOrEmpty(fills []importPostDateFill) []importPostDateFill {
	if fills == nil {
		return []importPostDateFill{}
	}
	return fills
}

func selectPostDateFills(fills []importPostDateFill, excluded []string) []importPostDateFill {
	skip := map[string]bool{}
	for _, id := range excluded {
		skip[id] = true
	}
	selected := make([]importPostDateFill, 0, len(fills))
	for _, fill := range fills {
		if !skip[fill.ID] {
			selected = append(selected, fill)
		}
	}
	return selected
}

func postDateStatementSource(statementHash string) string {
	source := "hsbchk-credit"
	if len(statementHash) >= 12 {
		source += ":" + statementHash[:12]
	}
	return source
}
