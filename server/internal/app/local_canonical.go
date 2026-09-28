package app

import (
	"errors"
	"fmt"
	"math/big"
	"path/filepath"
	"sort"
	"strings"
)

// LocalCanonicalModel is the validated, booked and plugin-transformed output
// of the embedded Beancount loader. Decimal quantities cross JSON as strings.
// Source text is loaded independently for lossless editing and source hashes.
type LocalCanonicalModel struct {
	// Set only for an exclusively owned streamed model, under its cache mutex.
	normalizedRoot string
	Version        int               `json:"version"`
	Entries        []BeanEntry       `json:"entries"`
	Options        map[string]string `json:"options"`
	Commodities    []string          `json:"commodities,omitempty"`
}

func localCanonicalEntries(cfg Config, source []BeanEntry) ([]BeanEntry, error) {
	model := cfg.localCanonical
	if model.Version != 1 {
		return nil, errors.New("unsupported canonical ledger model version")
	}
	if cfg.localCanonicalOwned && model.normalizedRoot != "" {
		if model.normalizedRoot != cfg.LedgerRoot {
			return nil, errors.New("canonical model belongs to another workspace")
		}
		return model.Entries, nil
	}
	// Validate before mutating an owned array, so a rejected model cannot leave
	// partially normalized absolute paths/postings behind for a subsequent call.
	if cfg.localCanonicalOwned {
		for _, entry := range model.Entries {
			if _, err := canonicalAbsoluteSource(cfg.LedgerRoot, entry.File); err != nil {
				return nil, err
			}
			for _, posting := range entry.Postings {
				if posting.Quantity.Number == "" || posting.Quantity.Currency == "" {
					return nil, errors.New("canonical ledger contains an unbooked posting")
				}
			}
		}
	}
	bySource := make(map[string]int, len(source))
	for i := range source {
		bySource[canonicalSourceKey(source[i])] = i
	}
	var entries []BeanEntry
	if cfg.localCanonicalOwned {
		entries = model.Entries
	} else {
		entries = make([]BeanEntry, len(model.Entries))
	}
	for index, original := range model.Entries {
		entry := original
		var err error
		entry.File, err = canonicalAbsoluteSource(cfg.LedgerRoot, entry.File)
		if err != nil {
			return nil, err
		}

		entry.Amount = entry.AmountValue.Cents()
		if !cfg.localCanonicalOwned {
			entry.Postings = append([]parsedPosting(nil), original.Postings...)
		}
		for i := range entry.Postings {
			posting := &entry.Postings[i]
			if posting.Quantity.Number == "" || posting.Quantity.Currency == "" {
				return nil, errors.New("canonical ledger contains an unbooked posting")
			}
			posting.Amount, posting.Currency = posting.Quantity.Cents(), posting.Quantity.Currency
			posting.CostAmount, posting.CostCurrency = posting.Cost.Cents(), posting.Cost.Currency
			posting.PriceAmount, posting.PriceCurrency = posting.Price.Cents(), posting.Price.Currency
			posting.Blank, posting.TotalCost, posting.TotalPrice = false, false, false
			posting.Canonical = true
		}
		// The loader owns the semantic fields. Only the raw locator material is
		// copied from source, so canonical generated/modified postings survive.
		entry.RawLines = nil
		if index, ok := bySource[canonicalSourceKey(entry)]; ok {
			entry.RawLines = source[index].RawLines
		}
		entries[index] = entry
	}
	if cfg.localCanonicalOwned {
		model.normalizedRoot = cfg.LedgerRoot
	}
	return entries, nil
}

func canonicalAbsoluteSource(root, file string) (string, error) {
	if file == "" {
		return "", nil
	}
	if filepath.IsAbs(file) {
		return "", errors.New("canonical ledger source must be relative")
	}
	clean := filepath.Clean(filepath.FromSlash(file))
	if clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", errors.New("canonical ledger source escapes workspace")
	}
	return filepath.Join(root, clean), nil
}

func canonicalSourceKey(entry BeanEntry) string {
	return fmt.Sprintf("%s:%d:%s", entry.File, entry.Line, entry.Kind)
}

// Beancount permits commodities to be used without a commodity directive.
// The canonical currency catalog therefore includes booked units and their
// valuation currencies, so valid requests do not fall back to CNY merely
// because an optional declaration is absent.
func localCanonicalCommodities(entries []BeanEntry, model *LocalCanonicalModel) []string {
	seen := map[string]bool{}
	add := func(currency string) {
		if currency != "" {
			seen[currency] = true
		}
	}
	add(model.Options["operating_currency"])
	for _, currency := range model.Commodities {
		add(currency)
	}
	for _, entry := range entries {
		add(entry.Currency)
		add(entry.QuoteCurrency)
		add(entry.AmountValue.Currency)
		for _, currency := range entry.Currencies {
			add(currency)
		}
		for _, posting := range entry.Postings {
			add(posting.Quantity.Currency)
			add(posting.Cost.Currency)
			add(posting.Price.Currency)
		}
	}
	commodities := make([]string, 0, len(seen))
	for currency := range seen {
		commodities = append(commodities, currency)
	}
	sort.Strings(commodities)
	return commodities
}

func localCanonicalTransactions(entries, source []BeanEntry) []Transaction {
	// Canonical Beancount has already expanded pads. Do not run raw-source
	// expansion, accumulate its unused balances, or create canonical editor
	// drafts only to replace them with exact source drafts below.
	bySource := make(map[string]int, len(source))
	for i := range source {
		if source[i].Kind == "transaction" {
			bySource[canonicalSourceKey(source[i])] = i
		}
	}
	txns := make([]Transaction, 0, len(entries))
	for _, entry := range entries {
		if entry.Kind != "transaction" {
			continue
		}
		txn := Transaction{
			Date: entry.Date, Payee: entry.Payee, Narration: entry.Narration,
			Metadata: entry.Metadata, Tags: entry.Tags, Links: entry.Links,
			Postings: finalizeParsedPostings(entry.Postings),
			Source:   TransactionSource{File: entry.File, Line: entry.Line},
		}
		if index, ok := bySource[canonicalSourceKey(entry)]; ok {
			raw := source[index]
			txn.Source.Hash = transactionHash(raw.RawLines)
			txn.Entry = EditableLedgerEntryFromBeanTransaction(raw)
		} else {
			// A generated transaction has no editable transaction block. Give it
			// a stable identity that cannot resolve to its originating pad line.
			txn.Source.Line = 0
			txn.Source.Hash = "generated:" + transactionHash([]string{canonicalSourceKey(entry), fmt.Sprint(len(txns))})
		}
		txns = append(txns, txn)
	}
	return txns
}

// compactLocalCanonicalSource runs only after raw hashes and editor drafts have
// been built. Canonical entries already retain their exact RawLines; the only
// remaining source consumers are the entries endpoint's controls and reversal
// recovery for transactions whose lossless editor draft was rejected.
func compactLocalCanonicalSource(source []BeanEntry, txns []Transaction) []BeanEntry {
	fallback := make(map[string]struct{})
	for _, txn := range txns {
		if txn.Entry == nil && txn.Source.Line > 0 {
			key := canonicalSourceKey(BeanEntry{Kind: "transaction", File: txn.Source.File, Line: txn.Source.Line})
			fallback[key] = struct{}{}
		}
	}
	keep := func(entry BeanEntry) bool {
		switch entry.Kind {
		case "plugin", "include", "pushtag", "poptag", "pushmeta", "popmeta":
			return true
		case "transaction":
			_, needed := fallback[canonicalSourceKey(entry)]
			return needed
		default:
			return false
		}
	}
	count := 0
	for _, entry := range source {
		if keep(entry) {
			count++
		}
	}
	// Do not filter in place: even an empty subslice pins the full parser array.
	// Keep empty results nonnil so snapshotSourceBeanEntries cannot fall back to
	// canonical (possibly transformed/generated) entries during reversal.
	retained := make([]BeanEntry, count)
	next := 0
	for _, entry := range source {
		if keep(entry) {
			retained[next] = entry
			next++
		}
	}
	return retained
}

func snapshotSourceBeanEntries(snapshot *LedgerSnapshot) []BeanEntry {
	if snapshot.SourceBeanEntries != nil {
		return snapshot.SourceBeanEntries
	}
	return snapshot.BeanEntries
}

func canonicalInvestmentCostKey(posting parsedPosting) string {
	number := posting.Cost.Number
	if value, ok := new(big.Rat).SetString(number); ok {
		number = value.RatString()
	}
	return strings.Join([]string{posting.Cost.Currency, number, posting.CostDate, posting.CostLabel}, "\x00")
}

func canonicalInvestmentLots(lots []InvestmentLot, posting parsedPosting) (selected, other []InvestmentLot) {
	key := canonicalInvestmentCostKey(posting)
	for _, lot := range lots {
		if lot.canonicalCostKey == key && lot.Quantity > 0 {
			selected = append(selected, lot)
		} else {
			other = append(other, lot)
		}
	}
	return selected, other
}

// Canonical postings carry the loader's exact inventory key. Signed additions
// preserve NONE-booked unmatched reductions and short lots; matching additions
// net against that same key, exactly as Beancount's inventory does.
func applyCanonicalInvestmentLot(lots []InvestmentLot, delta InvestmentLot) []InvestmentLot {
	out := make([]InvestmentLot, 0, len(lots)+1)
	matched := false
	for _, lot := range lots {
		if lot.canonicalCostKey != delta.canonicalCostKey {
			out = append(out, lot)
			continue
		}
		matched = true
		lot.Quantity += delta.Quantity
		if roundedZero(lot.Quantity) {
			continue
		}
		if lot.UnitCost != nil {
			value := *lot.UnitCost * lot.Quantity
			lot.CostValue = &value
		}
		out = append(out, lot)
	}
	if !matched {
		out = append(out, delta)
	}
	return out
}
