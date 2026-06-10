package app

import "errors"

var (
	ErrAccountRequired = errors.New("account is required")
	ErrAccountNotFound = errors.New("account not found")
)

type AccountService struct {
	cache  *LedgerCache
	writer *LedgerWriter
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
}

func NewAccountService(cache *LedgerCache, writer *LedgerWriter) *AccountService {
	return &AccountService{cache: cache, writer: writer}
}

func (s *AccountService) List() ([]Account, error) {
	snapshot, err := s.cache.Snapshot()
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

func (s *AccountService) Detail(account string) (AccountDetailResult, error) {
	if account == "" {
		return AccountDetailResult{}, ErrAccountRequired
	}
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return AccountDetailResult{}, err
	}
	acct, ok := snapshotAccountMap(snapshot)[account]
	if !ok {
		return AccountDetailResult{}, ErrAccountNotFound
	}
	return AccountDetailResult{
		Account:        acct.Account,
		Label:          acct.Label,
		Alias:          acct.Alias,
		Group:          acct.Group,
		Active:         acct.Active,
		Currency:       acct.Currency,
		Rows:           AccountDetailFromSorted(account, snapshotTransactionsAsc(snapshot)),
		CurrentBalance: snapshot.Balances[account],
	}, nil
}

func (s *AccountService) Statuses() ([]AccountStatus, error) {
	snapshot, err := s.cache.Snapshot()
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
