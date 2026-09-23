package app

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
)

// Native-only account history. Complete balances/counts accompany a bounded
// ascending row window; this is never passed to the legacy account handler.
type localAccountPage struct {
	Revision          string              `json:"revision"`
	SensitiveUnlocked bool                `json:"sensitiveUnlocked"`
	Detail            AccountDetailResult `json:"detail"`
	RowCount          int                 `json:"rowCount"`
	NextCursor        string              `json:"nextCursor,omitempty"`
}

func localAccountPageResponse(cfg Config, snapshot *LedgerSnapshot, query map[string]string) (int, json.RawMessage, error) {
	for key := range query {
		switch key {
		case "account", "currency", "start", "end", "limit", "cursor", "order":
		default:
			return 400, nil, errors.New("unsupported account page query parameter")
		}
	}
	order := query["order"]
	if order == "" {
		order = "asc"
	}
	if order != "asc" && order != "desc" {
		return 400, nil, errors.New("invalid account page order")
	}
	account, start, end := query["account"], query["start"], query["end"]
	if account == "" {
		return 400, nil, ErrAccountRequired
	}
	if !validAccountRange(start, end) {
		return 400, nil, ErrAccountRange
	}
	if snapshot == nil {
		return 500, nil, errors.New("missing account snapshot")
	}
	acct, ok := snapshotAccountMap(snapshot)[account]
	if !ok {
		return 404, nil, ErrAccountNotFound
	}
	currency, err := accountDetailCurrency(acct, snapshotRawBalances(snapshot)[account], query["currency"])
	if err != nil {
		return 400, nil, err
	}
	limit := localTransactionPageDefault
	if raw := query["limit"]; raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 1 || limit > localTransactionPageMax {
			return 400, nil, errors.New("account page limit must be 1..500")
		}
	}
	headerBudget := localTransactionPageBytes - 4096
	for _, value := range []string{cfg.LedgerRoot, cfg.localEntrypoint, snapshot.Version, acct.Account, acct.Label, acct.Group, currency, start, end} {
		if !localAccountChargeString(&headerBudget, value) {
			return 413, nil, errors.New("account metadata exceeds page budget")
		}
	}
	if acct.Alias != nil && !localAccountChargeString(&headerBudget, *acct.Alias) {
		return 413, nil, errors.New("account metadata exceeds page budget")
	}
	revision := fmt.Sprintf("%s:%d", snapshot.Version, snapshot.localReadModelID)
	scopeBytes, _ := json.Marshal([]string{cfg.LedgerRoot, cfg.localEntrypoint, revision, "native-account-page-v1", account, currency, start, end, order})
	scope := fmt.Sprintf("%x", sha256.Sum256(scopeBytes))
	offset := 0
	if raw := query["cursor"]; raw != "" {
		cursor, err := decodeLocalCursor(raw)
		if err != nil {
			return 400, nil, err
		}
		if cursor.Scope != scope {
			return http.StatusConflict, nil, errors.New("account cursor is stale; restart from first page")
		}
		offset = cursor.Offset
	}
	page := localAccountPage{Revision: revision, SensitiveUnlocked: true, Detail: AccountDetailResult{
		Account: acct.Account, Label: acct.Label, Alias: acct.Alias, Group: acct.Group, Active: acct.Active, Currency: currency,
		Start: start, End: end, Rows: make([]AccountDetailRow, 0, limit),
	}}
	txns := snapshotTransactionsAsc(snapshot)
	if offset > txns.Len() {
		return 400, nil, errors.New("invalid account cursor position")
	}
	// Reserve variable account metadata plus cursor/envelope headroom before rows.
	header, err := json.Marshal(page)
	if err != nil {
		return 500, nil, errors.New("cannot encode account page")
	}
	used := len(header) + 4096
	if used > localTransactionPageBytes {
		return 413, nil, errors.New("account metadata exceeds page budget")
	}
	balance := 0
	capacity := func() (int, json.RawMessage, error) {
		return 413, nil, errors.New("account history exceeds numeric or response capacity")
	}
	// Ascending totals establish exact legacy running balances, including
	// intermediate overflow checks. Descending then reverses this same sequence
	// (not the transaction-list descending order, which has different day ties).
	if order == "desc" {
		for index := 0; index < txns.Len(); index++ {
			txn := txns.At(index)
			change, matched, valid := localAccountChange(txn, account, currency)
			if !valid {
				return capacity()
			}
			if !matched {
				continue
			}
			balance, ok = localOverviewAdd(balance, change)
			if !ok {
				return capacity()
			}
			if start != "" && txn.Date < start {
				page.Detail.OpeningBalance = balance
			}
			if end == "" || txn.Date < end {
				page.Detail.ClosingBalance = balance
			}
			if start == "" || (txn.Date >= start && txn.Date < end) {
				page.RowCount++
			}
		}
		page.Detail.CurrentBalance = balance
	}
	for index := 0; index < txns.Len(); index++ {
		position := index
		if order == "desc" {
			position = txns.Len() - 1 - index
		}
		txn := txns.At(position)
		change, matched, valid := localAccountChange(txn, account, currency)
		if !valid {
			return capacity()
		}
		if !matched {
			continue
		}
		rowBalance := balance
		if order == "desc" {
			var valid bool
			balance, valid = localAccountSubtract(balance, change)
			if !valid {
				return capacity()
			}
		} else {
			balance, ok = localOverviewAdd(balance, change)
			if !ok {
				return capacity()
			}
			rowBalance = balance
			if start != "" && txn.Date < start {
				page.Detail.OpeningBalance = balance
			}
			if end == "" || txn.Date < end {
				page.Detail.ClosingBalance = balance
			}
		}
		if start != "" && (txn.Date < start || txn.Date >= end) {
			continue
		}
		if order == "asc" {
			page.RowCount++
		}
		if index < offset || page.NextCursor != "" {
			continue
		}
		if len(page.Detail.Rows) == limit {
			page.NextCursor = signLocalCursor(localTransactionCursor{scope, index})
			continue
		}
		if !localAccountRowFitsEncodingBudget(txn) {
			return capacity()
		}
		txn.Entry = nil
		// Account rows render TransactionPresentation: preserve only string type.
		if value, ok := txn.Metadata["type"].(string); ok {
			txn.Metadata = map[string]MetadataValue{"type": value}
		} else {
			txn.Metadata = nil
		}
		if txn.Postings == nil {
			txn.Postings = []Posting{}
		}
		if filepath.IsAbs(txn.Source.File) {
			relative, err := filepath.Rel(cfg.LedgerRoot, txn.Source.File)
			if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
				return 500, nil, errors.New("transaction source is outside workspace")
			}
			txn.Source.File = filepath.ToSlash(relative)
		}
		row := AccountDetailRow{Date: txn.Date, Payee: txn.Payee, Narration: txn.Narration, Change: change, Balance: rowBalance, Txn: txn}
		encoded, err := json.Marshal(row)
		if err != nil {
			return 500, nil, errors.New("cannot encode account row")
		}
		if used+len(encoded)+1 > localTransactionPageBytes {
			if len(page.Detail.Rows) == 0 {
				return capacity()
			}
			page.NextCursor = signLocalCursor(localTransactionCursor{scope, index})
			continue
		}
		used += len(encoded) + 1
		page.Detail.Rows = append(page.Detail.Rows, row)
	}
	if order == "asc" {
		page.Detail.CurrentBalance = balance
	}
	// Checked subtraction, including MinInt (which cannot be safely negated).
	closing, opening := page.Detail.ClosingBalance, page.Detail.OpeningBalance
	change, valid := localAccountSubtract(closing, opening)
	if !valid {
		return capacity()
	}
	page.Detail.PeriodChange = change
	encoded, err := json.Marshal(page)
	if err != nil {
		return 500, nil, errors.New("cannot encode account page")
	}
	if len(encoded) > localTransactionPageBytes {
		return capacity()
	}
	return http.StatusOK, encoded, nil
}

// Bound the input to encoding/json before allocation. JSON escaping can expand
// strings by at most 6x, so this conservative raw-payload/element budget bounds
// temporary encoding too; the exact escaped page limit is checked separately.
func localAccountChargeString(remaining *int, value string) bool {
	if len(value) > *remaining {
		return false
	}
	*remaining -= len(value)
	return true
}

func localAccountRowFitsEncodingBudget(txn Transaction) bool {
	remaining := localTransactionPageBytes - 1024
	for _, value := range []string{txn.Date, txn.Date, txn.Payee, txn.Payee, txn.Narration, txn.Narration, txn.Source.File, txn.Source.Hash, txn.Source.GitSHA} {
		if !localAccountChargeString(&remaining, value) {
			return false
		}
	}
	if value, ok := txn.Metadata["type"].(string); ok && !localAccountChargeString(&remaining, value) {
		return false
	}
	for _, value := range txn.Tags {
		if remaining < 4 {
			return false
		}
		remaining -= 4
		if !localAccountChargeString(&remaining, value) {
			return false
		}
	}
	for _, value := range txn.Links {
		if remaining < 4 {
			return false
		}
		remaining -= 4
		if !localAccountChargeString(&remaining, value) {
			return false
		}
	}
	for _, posting := range txn.Postings {
		if remaining < 128 {
			return false
		}
		remaining -= 128
		if !localAccountChargeString(&remaining, posting.Account) || !localAccountChargeString(&remaining, posting.Currency) || !localAccountChargeString(&remaining, posting.Flag) {
			return false
		}
	}
	return true
}

func localAccountChange(txn Transaction, account, currency string) (int, bool, bool) {
	change, matched := 0, false
	for _, posting := range txn.Postings {
		c := posting.Currency
		if c == "" {
			c = "CNY"
		}
		if posting.Account == account && c == currency {
			var ok bool
			change, ok = localOverviewAdd(change, posting.Amount)
			if !ok {
				return 0, false, false
			}
			matched = true
		}
	}
	return change, matched, true
}
func localAccountSubtract(a, b int) (int, bool) {
	value := a - b
	return value, !((b > 0 && value > a) || (b < 0 && value < a))
}
