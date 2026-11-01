package app

import (
	"errors"
	"path/filepath"
	"strings"
)

// LocalAgentPosting is one posting of a committed transaction, as the
// on-device reconciliation compares it with a statement row.
type LocalAgentPosting struct {
	Date      string
	Payee     string
	Narration string
	Account   string
	// Amount is in cents (minor units), signed as in the ledger.
	Amount   int
	Currency string
	File     string
	Line     int
}

// maxLocalAgentPostings bounds one reconciliation read, so a broad account
// prefix over many years cannot exhaust the phone's memory.
const maxLocalAgentPostings = 20000

// Postings lists the postings to accounts (each an account name or a parent
// such as Liabilities:CreditCard) dated in [start, end). Source files are
// workspace-relative.
func (s *LocalAgentSession) Postings(start, end string, accounts []string) ([]LocalAgentPosting, error) {
	if err := requireAgentSensitive(s.page); err != nil {
		return nil, err
	}
	if s.server == nil || s.server.queryPort == nil {
		return nil, errors.New("ledger is not available")
	}
	if len(accounts) == 0 {
		return nil, errors.New("at least one account is required")
	}
	result, err := s.server.queryPort.Transactions(start, end, true, "")
	if err != nil {
		return nil, err
	}
	prefix := s.root + string(filepath.Separator)
	var postings []LocalAgentPosting
	for _, transaction := range result.Transactions {
		for _, posting := range transaction.Postings {
			if !accountMatches(posting.Account, accounts) {
				continue
			}
			if len(postings) >= maxLocalAgentPostings {
				return nil, errors.New("too many postings in range; narrow the account or the dates")
			}
			postings = append(postings, LocalAgentPosting{
				Date: transaction.Date, Payee: transaction.Payee, Narration: transaction.Narration,
				Account: posting.Account, Amount: posting.Amount, Currency: posting.Currency,
				File: strings.TrimPrefix(transaction.Source.File, prefix), Line: transaction.Source.Line,
			})
		}
	}
	return postings, nil
}

func accountMatches(account string, accounts []string) bool {
	for _, wanted := range accounts {
		wanted = strings.TrimSuffix(strings.TrimSpace(wanted), ":")
		if wanted != "" && (account == wanted || strings.HasPrefix(account, wanted+":")) {
			return true
		}
	}
	return false
}
