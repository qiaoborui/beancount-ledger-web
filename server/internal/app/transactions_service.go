package app

import (
	"errors"
	"time"
)

type TransactionService struct {
	cache  *LedgerCache
	writer *LedgerWriter
}

func NewTransactionService(cache *LedgerCache, writer *LedgerWriter) *TransactionService {
	return &TransactionService{cache: cache, writer: writer}
}

func (s *TransactionService) Update(source TransactionSource, entry LedgerEntry) error {
	return s.writer.ReplaceTransactionBlock(source, entry)
}

func (s *TransactionService) Delete(source TransactionSource, reason string) error {
	return s.writer.CommentTransactionBlock(source, reason)
}

func (s *TransactionService) Reverse(input ReverseTransactionRequest) (LedgerEntry, error) {
	snapshot, err := s.cache.Snapshot()
	if err != nil {
		return LedgerEntry{}, err
	}
	original := FindTransaction(snapshot.Transactions, input.Source)
	if original == nil {
		return LedgerEntry{}, errors.New("找不到原交易，账本可能已被修改，请刷新后重试")
	}
	reverseDate := input.Date
	if reverseDate == "" {
		reverseDate = time.Now().Format("2006-01-02")
	}
	entry := ReverseTransactionEntry(*original, reverseDate)
	if err := s.writer.AppendBeanTextWithSource(reverseDate, TransactionToBean(entry), ledgerWriteSourceTransactionReversal); err != nil {
		return LedgerEntry{}, err
	}
	return entry, nil
}

func FindTransaction(txns []Transaction, source TransactionSource) *Transaction {
	for i := range txns {
		txn := &txns[i]
		if txn.Source.File == source.File && (txn.Source.Line == source.Line || (source.Hash != "" && txn.Source.Hash == source.Hash)) {
			return txn
		}
	}
	return nil
}

func ReverseTransactionEntry(original Transaction, reverseDate string) LedgerEntry {
	entry := LedgerEntry{
		Kind:        "transaction",
		Date:        reverseDate,
		Payee:       original.Payee,
		Narration:   "冲销：" + original.Narration,
		Metadata:    map[string]MetadataValue{"reversal": true},
		Tags:        original.Tags,
		Currency:    "CNY",
		Confidence:  1,
		NeedsReview: false,
	}
	for _, posting := range original.Postings {
		entry.Postings = append(entry.Postings, EntryPosting{Account: posting.Account, Amount: fromCents(-posting.Amount), Currency: posting.Currency})
	}
	return entry
}
