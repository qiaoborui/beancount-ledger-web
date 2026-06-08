package app

import (
	"errors"
	"strings"
)

type ReconciliationService struct {
	cache  *LedgerCache
	writer *LedgerWriter
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
	return &ReconciliationService{cache: cache, writer: writer}
}

func (s *ReconciliationService) Reconcile(input ReconcileRequest) (ReconciliationResult, error) {
	snapshot, err := s.cache.Snapshot()
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
	ledgerBalance := balanceBefore(input.Account, accountInfo.Currency, snapshot.Transactions, input.BalanceDate)
	actual := cents(input.ActualAmount)
	diff := actual - ledgerBalance
	adjustmentDate := input.AdjustmentDate
	if adjustmentDate == "" {
		adjustmentDate = input.BalanceDate
	}
	beanText := ""
	var adjustment *LedgerEntry
	if diff != 0 {
		entry := reconciliationAdjustment(*accountInfo, input.Account, diff, adjustmentDate)
		adjustment = &entry
		beanText += TransactionToBean(entry) + "\n"
	}
	balance := LedgerEntry{Kind: "balance", Date: input.BalanceDate, Account: input.Account, Amount: fromCents(actual), Currency: accountInfo.Currency}
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

func reconciliationAdjustment(accountInfo Account, account string, diff int, date string) LedgerEntry {
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
		Currency:    accountInfo.Currency,
		Confidence:  1,
		NeedsReview: false,
		Postings: []EntryPosting{
			{Account: account, Amount: fromCents(diff), Currency: accountInfo.Currency},
			{Account: other, Amount: fromCents(-diff), Currency: accountInfo.Currency},
		},
	}
}
