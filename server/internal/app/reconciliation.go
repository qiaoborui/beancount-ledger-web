package app

import (
	"errors"
	"strings"
)

type ReconciliationService struct {
	writer   *LedgerWriter
	snapshot func() (*LedgerSnapshot, error)
}

type ReconciliationResult struct {
	OK            bool         `json:"ok"`
	LedgerBalance int          `json:"ledgerBalance"`
	Actual        int          `json:"actual"`
	Diff          int          `json:"diff"`
	Adjustment    *LedgerEntry `json:"adjustment"`
	Balance       LedgerEntry  `json:"balance"`
	BeanText      string       `json:"beanText"`
}

func NewReconciliationService(cache *LedgerCache, writer *LedgerWriter) *ReconciliationService {
	return NewReconciliationServiceWithSnapshot(cache, writer, nil)
}

func NewReconciliationServiceWithSnapshot(cache *LedgerCache, writer *LedgerWriter, snapshot func() (*LedgerSnapshot, error)) *ReconciliationService {
	if snapshot == nil {
		if cache != nil {
			snapshot = cache.Snapshot
		} else {
			snapshot = func() (*LedgerSnapshot, error) {
				return nil, errors.New("ledger snapshot is unavailable")
			}
		}
	}
	return &ReconciliationService{writer: writer, snapshot: snapshot}
}

func (s *ReconciliationService) Reconcile(input ReconcileRequest) (ReconciliationResult, error) {
	snapshot, err := s.snapshot()
	if err != nil {
		return ReconciliationResult{}, err
	}
	result, err := BuildReconciliation(snapshot, input)
	if err != nil {
		return ReconciliationResult{}, err
	}
	if err := s.writer.AppendBeanTextWithSource(input.BalanceDate, result.BeanText, ledgerWriteSourceReconciliation); err != nil {
		return ReconciliationResult{}, err
	}
	result.OK = true
	return result, nil
}

func BuildReconciliation(snapshot *LedgerSnapshot, input ReconcileRequest) (ReconciliationResult, error) {
	accountInfo := reconciliationAccount(snapshot, input.Account)
	if accountInfo == nil {
		return ReconciliationResult{}, errors.New("不支持的对账账户")
	}
	currency := defaultAccountCurrency(accountInfo.Account, accountInfo.Currency)
	ledgerBalance := balanceBefore(input.Account, currency, snapshot.Transactions, input.BalanceDate)
	actual := cents(input.ActualAmount)
	diff := actual - ledgerBalance
	adjustmentDate := input.AdjustmentDate
	if adjustmentDate == "" {
		adjustmentDate = input.BalanceDate
	}
	beanText := ""
	var adjustment *LedgerEntry
	if diff != 0 {
		entry := reconciliationAdjustment(*accountInfo, input.Account, diff, adjustmentDate, currency)
		adjustment = &entry
		beanText += TransactionToBean(entry) + "\n"
	}
	balance := LedgerEntry{Kind: "balance", Date: input.BalanceDate, Account: input.Account, Amount: fromCents(actual), Currency: currency}
	beanText += BalanceToBean(balance)
	return ReconciliationResult{LedgerBalance: ledgerBalance, Actual: actual, Diff: diff, Adjustment: adjustment, Balance: balance, BeanText: beanText}, nil
}

func reconciliationAccount(snapshot *LedgerSnapshot, account string) *Account {
	for i := range snapshot.Accounts {
		acct := &snapshot.Accounts[i]
		if acct.Active && (strings.HasPrefix(acct.Account, "Assets:") || strings.HasPrefix(acct.Account, "Liabilities:")) && acct.Account == account {
			return acct
		}
	}
	return nil
}

func reconciliationAdjustment(accountInfo Account, account string, diff int, date, currency string) LedgerEntry {
	other := "Equity:Balance-Adjustments"
	if accountInfo.Group == "wealth" && diff > 0 {
		other = "Income:Other"
	} else if accountInfo.Group == "wealth" && diff < 0 {
		other = "Expenses:Unknown"
	}
	return LedgerEntry{
		Kind:        "transaction",
		Date:        date,
		Payee:       accountInfo.Label,
		Narration:   "余额差额调整",
		Metadata:    map[string]MetadataValue{"purpose": "reconciliation"},
		Tags:        []string{},
		Currency:    currency,
		Confidence:  1,
		NeedsReview: false,
		Postings: []EntryPosting{
			{Account: account, Amount: fromCents(diff), Currency: currency},
			{Account: other, Amount: fromCents(-diff), Currency: currency},
		},
	}
}
