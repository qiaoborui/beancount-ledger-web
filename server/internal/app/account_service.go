package app

import (
	"errors"
	"strings"
	"time"
)

var (
	ErrAccountRequired = errors.New("account is required")
	ErrAccountNotFound = errors.New("account not found")
	ErrAccountRange    = errors.New("invalid account range: expected start and end as YYYY-MM-DD with start before end")
	ErrAccountCurrency = errors.New("account currency is required or unavailable")
)

type AccountService struct {
	cache    *LedgerCache
	writer   *LedgerWriter
	snapshot func() (*LedgerSnapshot, error)
}

type AccountDetailResult struct {
	Account        string             `json:"account"`
	Label          string             `json:"label"`
	Alias          *string            `json:"alias"`
	Group          string             `json:"group"`
	Active         bool               `json:"active"`
	Currency       string             `json:"currency"`
	Rows           []AccountDetailRow `json:"rows"`
	CurrentBalance int                `json:"currentBalance"`
	Start          string             `json:"start,omitempty"`
	End            string             `json:"end,omitempty"`
	OpeningBalance int                `json:"openingBalance"`
	ClosingBalance int                `json:"closingBalance"`
	PeriodChange   int                `json:"periodChange"`
}

func NewAccountService(cache *LedgerCache, writer *LedgerWriter) *AccountService {
	return NewAccountServiceWithSnapshot(cache, writer, cache.Snapshot)
}

func NewAccountServiceWithSnapshot(cache *LedgerCache, writer *LedgerWriter, snapshot func() (*LedgerSnapshot, error)) *AccountService {
	if snapshot == nil {
		snapshot = cache.Snapshot
	}
	return &AccountService{cache: cache, writer: writer, snapshot: snapshot}
}

func (s *AccountService) List() ([]Account, error) {
	snapshot, err := s.snapshot()
	if err != nil {
		return nil, err
	}
	return snapshot.Accounts, nil
}

func (s *AccountService) Append(input AccountInput) (AccountInput, error) {
	input.Currency = defaultAccountCurrency(input.Account, input.Currency)
	if err := s.writer.AppendAccount(input); err != nil {
		return AccountInput{}, err
	}
	return input, nil
}

func (s *AccountService) ApplyOperations(operations []AccountOperation) ([]string, error) {
	return s.writer.ApplyAccountOperations(operations)
}

func (s *AccountService) Detail(account, currency, start, end string) (AccountDetailResult, error) {
	if account == "" {
		return AccountDetailResult{}, ErrAccountRequired
	}
	if !validAccountRange(start, end) {
		return AccountDetailResult{}, ErrAccountRange
	}
	snapshot, err := s.snapshot()
	if err != nil {
		return AccountDetailResult{}, err
	}
	acct, ok := snapshotAccountMap(snapshot)[account]
	if !ok {
		return AccountDetailResult{}, ErrAccountNotFound
	}
	accountBalances := snapshotRawBalances(snapshot)[account]
	currency, err = accountDetailCurrency(acct, accountBalances, currency)
	if err != nil {
		return AccountDetailResult{}, err
	}
	currentBalance := accountBalances[currency]
	rows, openingBalance, closingBalance := accountDetailRowsForRange(
		AccountDetailFromSortedInCurrency(account, currency, snapshotTransactionsAsc(snapshot)),
		start,
		end,
		currentBalance,
	)
	return AccountDetailResult{
		Account:        acct.Account,
		Label:          acct.Label,
		Alias:          acct.Alias,
		Group:          acct.Group,
		Active:         acct.Active,
		Currency:       currency,
		Rows:           rows,
		CurrentBalance: currentBalance,
		Start:          start,
		End:            end,
		OpeningBalance: openingBalance,
		ClosingBalance: closingBalance,
		PeriodChange:   closingBalance - openingBalance,
	}, nil
}

func accountDetailCurrency(account Account, balances map[string]int, requested string) (string, error) {
	requested = strings.TrimSpace(requested)
	if requested != "" {
		if requested == account.Currency {
			return requested, nil
		}
		if _, ok := balances[requested]; ok {
			return requested, nil
		}
		return "", ErrAccountCurrency
	}
	if account.Currency != "" {
		return account.Currency, nil
	}
	if len(balances) == 1 {
		for currency := range balances {
			return currency, nil
		}
	}
	return "", ErrAccountCurrency
}

func validAccountRange(start, end string) bool {
	if start == "" && end == "" {
		return true
	}
	startDate, startErr := time.Parse("2006-01-02", start)
	endDate, endErr := time.Parse("2006-01-02", end)
	return startErr == nil && endErr == nil && startDate.Before(endDate)
}

func accountDetailRowsForRange(rows []AccountDetailRow, start, end string, currentBalance int) ([]AccountDetailRow, int, int) {
	if start == "" && end == "" {
		return rows, 0, currentBalance
	}

	openingBalance := 0
	closingBalance := 0
	periodRows := make([]AccountDetailRow, 0, len(rows))
	for _, row := range rows {
		if row.Date < start {
			openingBalance = row.Balance
		}
		if row.Date < end {
			closingBalance = row.Balance
		}
		if row.Date >= start && row.Date < end {
			periodRows = append(periodRows, row)
		}
	}
	return periodRows, openingBalance, closingBalance
}

func (s *AccountService) Statuses() ([]AccountStatus, error) {
	snapshot, err := s.snapshot()
	if err != nil {
		return nil, err
	}
	return AccountStatusIndicators(snapshot.Transactions, snapshot.BalanceAssertions, snapshot.Accounts), nil
}

func FindAccount(accounts []Account, account string) *Account {
	for i := range accounts {
		if accounts[i].Account == account {
			return &accounts[i]
		}
	}
	return nil
}
