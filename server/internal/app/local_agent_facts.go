package app

import (
	"errors"
	"sort"
	"time"
)

// LocalAgentFacts is a small picture of the ledger for suggesting questions
// before anything is asked: this and last month's totals with their largest
// categories, and the latest transactions. Amounts are in major units.
type LocalAgentFacts struct {
	Today      string                 `json:"today"`
	Months     []LocalAgentMonthFacts `json:"months"`
	Recent     []LocalAgentRecentFact `json:"recent"`
	Currency   string                 `json:"currency,omitempty"`
	AmountUnit string                 `json:"amountUnit"`
}

type LocalAgentMonthFacts struct {
	Month         string            `json:"month"`
	Income        string            `json:"income"`
	Expense       string            `json:"expense"`
	TopCategories map[string]string `json:"topCategories"`
}

type LocalAgentRecentFact struct {
	Date      string   `json:"date"`
	Payee     string   `json:"payee,omitempty"`
	Narration string   `json:"narration,omitempty"`
	Accounts  []string `json:"accounts"`
	Amount    string   `json:"amount,omitempty"`
}

const (
	localAgentFactCategories = 8
	localAgentFactRecent     = 15
)

// ContainsSensitiveAgentContent reports text an Agent must not keep, such
// as passwords, verification codes, tokens or full card numbers.
func ContainsSensitiveAgentContent(value string) bool { return containsSensitiveAgentContent(value) }

// Facts reads the picture for now.
func (s *LocalAgentSession) Facts(now time.Time) (LocalAgentFacts, error) {
	if err := requireAgentSensitive(s.page); err != nil {
		return LocalAgentFacts{}, err
	}
	if s.server == nil || s.server.queryPort == nil {
		return LocalAgentFacts{}, errors.New("ledger is not available")
	}
	facts := LocalAgentFacts{Today: now.Format("2006-01-02"), Recent: []LocalAgentRecentFact{}, AmountUnit: "major"}
	thisMonth := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, now.Location())
	for _, start := range []time.Time{thisMonth, thisMonth.AddDate(0, -1, 0)} {
		end := start.AddDate(0, 1, 0)
		result, err := s.server.queryPort.Summary(start.Format("2006-01-02"), end.Format("2006-01-02"), true,
			LedgerReadOptions{ComparisonDate: now.Format("2006-01-02")})
		if err != nil {
			return LocalAgentFacts{}, err
		}
		facts.Currency = result.Summary.Currency
		facts.Months = append(facts.Months, LocalAgentMonthFacts{Month: start.Format("2006-01"),
			Income: fromCents(result.Summary.Income), Expense: fromCents(result.Summary.Expense),
			TopCategories: topCategories(result.Summary.Categories, localAgentFactCategories)})
	}
	// A ledger not kept up to date still has latest transactions worth
	// suggesting from, so the window widens once.
	var transactions []Transaction
	for _, days := range []int{45, 365} {
		recent, err := s.server.queryPort.Transactions(now.AddDate(0, 0, -days).Format("2006-01-02"),
			now.AddDate(0, 0, 1).Format("2006-01-02"), true, "")
		if err != nil {
			return LocalAgentFacts{}, err
		}
		transactions = append([]Transaction(nil), recent.Transactions...)
		if len(transactions) >= localAgentFactRecent/3 {
			break
		}
	}
	sort.SliceStable(transactions, func(i, j int) bool { return transactions[i].Date > transactions[j].Date })
	if len(transactions) > localAgentFactRecent {
		transactions = transactions[:localAgentFactRecent]
	}
	for _, transaction := range transactions {
		fact := LocalAgentRecentFact{Date: transaction.Date, Payee: transaction.Payee, Narration: transaction.Narration, Accounts: []string{}}
		for _, posting := range transaction.Postings {
			fact.Accounts = append(fact.Accounts, posting.Account)
			if fact.Amount == "" && posting.Amount > 0 {
				fact.Amount = fromCents(posting.Amount) + " " + posting.Currency
			}
		}
		facts.Recent = append(facts.Recent, fact)
	}
	return facts, nil
}

// topCategories keeps the largest categories by absolute amount.
func topCategories(categories map[string]int, limit int) map[string]string {
	names := make([]string, 0, len(categories))
	for name := range categories {
		names = append(names, name)
	}
	abs := func(value int) int {
		if value < 0 {
			return -value
		}
		return value
	}
	sort.Slice(names, func(i, j int) bool {
		if a, b := abs(categories[names[i]]), abs(categories[names[j]]); a != b {
			return a > b
		}
		return names[i] < names[j]
	})
	if len(names) > limit {
		names = names[:limit]
	}
	top := make(map[string]string, len(names))
	for _, name := range names {
		top[name] = fromCents(categories[name])
	}
	return top
}
