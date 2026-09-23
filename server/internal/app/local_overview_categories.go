package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"sort"
	"strings"
	"time"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

const localOverviewCategoryGroups = 4096
const localOverviewCategoryWorkingBytes = 8 << 20

var errLocalOverviewCategoryCapacity = errors.New("overview categories exceed group, working-state or response capacity; narrow the date range")

type localOverviewCategories struct {
	Revision                string                  `json:"revision"`
	Start                   string                  `json:"start"`
	End                     string                  `json:"end"`
	SensitiveUnlocked       bool                    `json:"sensitiveUnlocked"`
	PositiveTotalMinorUnits int                     `json:"positiveTotalMinorUnits"`
	Categories              []localOverviewCategory `json:"categories"`
}

type localOverviewCategory struct {
	Label                    string          `json:"label"`
	TotalMinorUnits          int             `json:"totalMinorUnits"`
	PositiveTransactionCount int             `json:"positiveTransactionCount"`
	Representative           json.RawMessage `json:"representative"`
}

type localOverviewCategoryGroup struct {
	label, key     string
	total, count   int
	representative int // descending snapshot index, not a copied/projected history
}

// Native GET /api/ledger/overview/categories. The caller supplies a fresh,
// committed snapshot and rejects staging/importFile before calling this helper.
// Like pages, ranges are inclusive start/exclusive end and revision includes the
// model identity. No currency conversion: Swift sums signed posting minor units.
func localOverviewCategoriesResponse(cfg Config, snapshot *LedgerSnapshot, query map[string]string) (int, json.RawMessage, error) {
	start, end := query["start"], query["end"]
	if start == "" {
		start = "0001-01-01"
	}
	if end == "" {
		end = "9999-12-31"
	}
	for _, date := range []string{start, end} {
		if parsed, err := time.Parse("2006-01-02", date); err != nil || parsed.Format("2006-01-02") != date {
			return http.StatusBadRequest, nil, errors.New("invalid overview categories date")
		}
	}
	if start >= end {
		return http.StatusBadRequest, nil, errors.New("invalid overview categories range")
	}
	// This aggregate is date-only, not a page. Never silently ignore a filter.
	for key := range query {
		if key != "start" && key != "end" {
			return http.StatusBadRequest, nil, errors.New("unsupported overview categories query parameter")
		}
	}
	if snapshot == nil {
		return http.StatusInternalServerError, nil, errors.New("missing overview categories snapshot")
	}
	capacity := func() (int, json.RawMessage, error) {
		return http.StatusRequestEntityTooLarge, nil, errLocalOverviewCategoryCapacity
	}
	groups := make(map[string]*localOverviewCategoryGroup)
	used := 0
	var accounts map[string]int
	txns := snapshotTransactionsDesc(snapshot)
	for index := 0; index < txns.Len(); index++ {
		txn := txns.At(index)
		if txn.Date < start || txn.Date >= end {
			continue
		}
		eligible, total := false, 0
		for _, posting := range txn.Postings {
			if posting.Amount == 0 || !strings.HasPrefix(posting.Account, "Expenses:") {
				continue
			}
			eligible = true
			var ok bool
			total, ok = localOverviewAdd(total, posting.Amount)
			if !ok {
				return capacity()
			}
		}
		if !eligible {
			continue
		}
		// Swift checks eligibility before computing the visual category. Ineligible
		// (even very large) income/transfer rows consume no aggregate state.
		multiple, account := false, ""
		for _, posting := range txn.Postings {
			if posting.Amount == 0 || (!strings.HasPrefix(posting.Account, "Expenses:") && !strings.HasPrefix(posting.Account, "Income:")) {
				continue
			}
			if !multiple {
				if len(posting.Account) > localOverviewCategoryWorkingBytes {
					return capacity()
				}
				// Swift Set<String> uses canonical Unicode equivalence, not bytes.
				if account == "" {
					account = posting.Account
				} else if norm.NFC.String(account) != norm.NFC.String(posting.Account) {
					multiple = true
				}
			}
		}
		label := "多分类"
		if !multiple {
			if accounts == nil {
				var size int
				var ok bool
				accounts, size, ok = localOverviewAccountIndex(snapshot, localOverviewCategoryWorkingBytes-used)
				if !ok {
					return capacity()
				}
				used += size
			}
			var ok bool
			label, ok = localOverviewAccountLabel(snapshot, accounts, account)
			if !ok {
				return capacity()
			}
		}
		key := norm.NFC.String(label)
		group := groups[key]
		if group == nil {
			// Count immutable referenced summary payload too, not just map nodes.
			// Metadata/editor drafts are not part of the compact projection.
			size := localOverviewSummaryBytes(txn) + 256 + len(label) + len(key)
			if len(groups) == localOverviewCategoryGroups || size > localOverviewCategoryWorkingBytes-used {
				return capacity()
			}
			used += size
			group = &localOverviewCategoryGroup{label: label, key: key, representative: index}
			groups[key] = group
		}
		var ok bool
		group.total, ok = localOverviewAdd(group.total, total)
		if !ok {
			return capacity()
		}
		if total > 0 {
			group.count++
		}
	}
	result := localOverviewCategories{
		Revision: fmt.Sprintf("%s:%d", snapshot.Version, snapshot.localReadModelID),
		Start:    start, End: end, SensitiveUnlocked: true,
		Categories: make([]localOverviewCategory, 0, 4),
	}
	positive := make([]*localOverviewCategoryGroup, 0, len(groups))
	for _, group := range groups {
		if group.total <= 0 {
			continue
		}
		var ok bool
		result.PositiveTotalMinorUnits, ok = localOverviewAdd(result.PositiveTotalMinorUnits, group.total)
		if !ok {
			return capacity()
		}
		positive = append(positive, group)
	}
	sort.Slice(positive, func(i, j int) bool {
		if positive[i].total != positive[j].total {
			return positive[i].total > positive[j].total
		}
		return positive[i].key < positive[j].key
	})
	if len(positive) > 4 {
		positive = positive[:4]
	}
	for _, group := range positive {
		txn := txns.At(group.representative)
		if localOverviewSummaryBytes(txn)+len(group.label) > localTransactionPageBytes {
			return capacity()
		}
		// Reuse the existing page projection (including source confinement,
		// metadata/draft omission and ordered, zero-inclusive postings). Only
		// the final <=4 representatives are projected, never the full ledger.
		one := &LedgerSnapshot{LedgerVersion: snapshot.LedgerVersion, localReadModelID: snapshot.localReadModelID,
			Transactions: []Transaction{txn}, transactionsDesc: []int{0}}
		status, raw, err := localTransactionPageResponse(cfg, one, map[string]string{"start": start, "end": end, "limit": "1"})
		if err != nil {
			if status == http.StatusRequestEntityTooLarge {
				return capacity()
			}
			return status, nil, err
		}
		var page struct {
			Transactions []json.RawMessage `json:"transactions"`
		}
		if err := json.Unmarshal(raw, &page); err != nil || len(page.Transactions) != 1 {
			return http.StatusInternalServerError, nil, errors.New("invalid overview representative projection")
		}
		result.Categories = append(result.Categories, localOverviewCategory{
			Label: group.label, TotalMinorUnits: group.total, PositiveTransactionCount: group.count,
			Representative: page.Transactions[0],
		})
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return http.StatusInternalServerError, nil, errors.New("cannot encode overview categories")
	}
	if len(raw) > localTransactionPageBytes {
		return capacity()
	}
	return http.StatusOK, raw, nil
}

func localOverviewAdd(a, b int) (int, bool) {
	if (b > 0 && a > math.MaxInt-b) || (b < 0 && a < math.MinInt-b) {
		return 0, false
	}
	return a + b, true
}

// Swift builds accountLabels from the ordered Accounts array: canonically
// equivalent definitions overwrite earlier ones even when AccountMap has an
// exact byte-key hit. Build this bounded index once, never scan accounts per row.
// Store snapshot indices and charge both map overhead and referenced account
// strings to the same working-state budget used by category groups.
func localOverviewAccountIndex(snapshot *LedgerSnapshot, budget int) (map[string]int, int, bool) {
	index := make(map[string]int)
	used := 0
	for i := len(snapshot.Accounts) - 1; i >= 0; i-- {
		acct := &snapshot.Accounts[i]
		if len(acct.Account) > localOverviewCategoryWorkingBytes {
			return nil, 0, false
		}
		key := norm.NFC.String(acct.Account)
		if _, found := index[key]; found {
			continue // Last canonical definition wins, including empty labels.
		}
		size := 256
		for _, length := range []int{len(key), len(acct.Account), len(acct.Label)} {
			if length > budget-size {
				return nil, 0, false
			}
			size += length
		}
		if acct.Alias != nil {
			if len(*acct.Alias) > budget-size {
				return nil, 0, false
			}
			size += len(*acct.Alias)
		}
		if size > budget {
			return nil, 0, false
		}
		index[key] = i
		budget -= size
		used += size
	}
	return index, used, true
}

// Match TransactionCategoryPresentation.accountLabels + displayName, rather
// than accountDisplayLabel/labelFor, which intentionally use different fallbacks.
func localOverviewAccountLabel(snapshot *LedgerSnapshot, accounts map[string]int, account string) (string, bool) {
	index, found := accounts[norm.NFC.String(account)]
	trim := func(s string) string {
		// Foundation whitespacesAndNewlines also includes zero-width space.
		return strings.TrimFunc(s, func(r rune) bool { return unicode.IsSpace(r) || r == '\u200b' })
	}
	label := ""
	if found {
		acct := &snapshot.Accounts[index]
		if len(acct.Label) > localOverviewCategoryWorkingBytes {
			return "", false
		}
		label = trim(acct.Label)
		if label == "" || norm.NFC.String(label) == norm.NFC.String(account) {
			label = account
			if acct.Alias != nil {
				label = *acct.Alias
			}
		}
		if len(label) > localOverviewCategoryWorkingBytes {
			return "", false
		}
		label = trim(label)
		if label != "" && norm.NFC.String(label) != norm.NFC.String(account) {
			return label, true
		}
	}
	// Swift split omits empty subsequences, then drops the root component.
	// Bound separator expansion before allocating split/join storage.
	if len(account) > localOverviewCategoryWorkingBytes/8 {
		return "", false
	}
	// The common one-component suffix can be referenced without per-row
	// split/join allocations. More complex paths retain Swift's empty rules.
	if _, suffix, ok := strings.Cut(account, ":"); ok && suffix != "" && !strings.Contains(suffix, ":") {
		return suffix, true
	}
	parts := strings.FieldsFunc(account, func(r rune) bool { return r == ':' })
	if len(parts) > 1 {
		return strings.Join(parts[1:], " › "), true
	}
	return account, true
}

// Saturating estimate bounds retained compact payload plus slice/map overhead.
// It deliberately excludes rich draft/metadata sizes, as transaction pages do.
func localOverviewSummaryBytes(txn Transaction) int {
	size := 256
	add := func(n int) {
		if n > localOverviewCategoryWorkingBytes || size > localOverviewCategoryWorkingBytes-n {
			size = localOverviewCategoryWorkingBytes + 1
		} else {
			size += n
		}
	}
	for _, s := range []string{txn.Date, txn.Payee, txn.Narration, txn.Source.File, txn.Source.Hash, txn.Source.GitSHA} {
		add(len(s))
	}
	for _, values := range [][]string{txn.Tags, txn.Links} {
		for _, s := range values {
			add(16)
			add(len(s))
			if size > localOverviewCategoryWorkingBytes {
				return size
			}
		}
	}
	for _, posting := range txn.Postings {
		add(64)
		add(len(posting.Account))
		add(len(posting.Currency))
		add(len(posting.Flag))
		if size > localOverviewCategoryWorkingBytes {
			return size
		}
	}
	return size
}
