package app

import (
	"errors"
	"strings"
	"time"
)

type TransactionService struct {
	writer   *LedgerWriter
	snapshot func() (*LedgerSnapshot, error)
}

func NewTransactionService(cache *LedgerCache, writer *LedgerWriter) *TransactionService {
	return NewTransactionServiceWithSnapshot(cache, writer, nil)
}

func NewTransactionServiceWithSnapshot(cache *LedgerCache, writer *LedgerWriter, snapshot func() (*LedgerSnapshot, error)) *TransactionService {
	if snapshot == nil {
		if cache != nil {
			snapshot = cache.Snapshot
		} else {
			snapshot = func() (*LedgerSnapshot, error) {
				return nil, errors.New("ledger snapshot is unavailable")
			}
		}
	}
	return &TransactionService{writer: writer, snapshot: snapshot}
}

func (s *TransactionService) Update(source TransactionSource, entry LedgerEntry) error {
	return s.writer.ReplaceTransactionBlock(source, entry)
}

func (s *TransactionService) AddTags(sources []TransactionSource, tags []string) error {
	snapshot, err := s.snapshot()
	if err != nil {
		return err
	}
	return s.writer.addTransactionTagsFromSnapshot(sources, tags, snapshot)
}

func (s *TransactionService) Delete(source TransactionSource, reason string) error {
	return s.writer.CommentTransactionBlock(source, reason)
}

func (s *TransactionService) Reverse(input ReverseTransactionRequest) (LedgerEntry, error) {
	snapshot, err := s.snapshot()
	if err != nil {
		return LedgerEntry{}, err
	}
	original := FindTransaction(snapshot.Transactions, input.Source)
	if original == nil {
		return LedgerEntry{}, errors.New("找不到原交易，账本可能已被修改，请刷新后重试")
	}
	// Editing needs lossless comment round-tripping; a reversal leaves the
	// original untouched. Recover its exact posting model from the same snapshot
	// while allowing comments, retaining all other lossless-model guards.
	reversible := *original
	if reversible.Entry == nil {
		for _, raw := range snapshot.BeanEntries {
			if raw.Kind != "transaction" || raw.File != original.Source.File || raw.Line != original.Source.Line {
				continue
			}
			if original.Source.Hash != "" && transactionHash(raw.RawLines) != original.Source.Hash {
				continue
			}
			clean := raw
			clean.RawLines = make([]string, 0, len(raw.RawLines))
			for _, line := range raw.RawLines {
				if hasBeanComment(line) {
					tokens := scanBeanLine(line)
					if len(tokens) == 0 {
						continue
					}
					indent := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
					line = indent + renderBeanTokens(tokens)
				}
				clean.RawLines = append(clean.RawLines, line)
			}
			reversible.Entry = EditableLedgerEntryFromBeanTransaction(clean)
			break
		}
	}
	reverseDate := input.Date
	if reverseDate == "" {
		reverseDate = time.Now().Format("2006-01-02")
	}
	entry, err := ReverseTransactionEntry(reversible, reverseDate)
	if err != nil {
		return LedgerEntry{}, err
	}
	if err := s.writer.AppendBeanTextWithSource(reverseDate, TransactionToBean(entry), ledgerWriteSourceTransactionReversal); err != nil {
		return LedgerEntry{}, err
	}
	return entry, nil
}

func FindTransaction(txns []Transaction, source TransactionSource) *Transaction {
	for i := range txns {
		txn := &txns[i]
		if txn.Source.File != source.File {
			continue
		}
		if source.Hash != "" && txn.Source.Hash == source.Hash {
			return txn
		}
		if source.Hash == "" && txn.Source.Line == source.Line {
			return txn
		}
	}
	return nil
}

func ReverseTransactionEntry(original Transaction, reverseDate string) (LedgerEntry, error) {
	if original.Entry == nil {
		return LedgerEntry{}, errors.New("交易缺少可安全冲销的原始分录，请使用账本编辑器处理")
	}
	entry := *original.Entry
	entry.Date = reverseDate
	entry.Narration = "冲销：" + entry.Narration
	entry.Tags = append([]string(nil), entry.Tags...)
	entry.Links = append([]string(nil), entry.Links...)
	entry.Metadata = make(map[string]MetadataValue, len(original.Entry.Metadata)+1)
	for key, value := range original.Entry.Metadata {
		entry.Metadata[key] = value
	}
	entry.Metadata["reversal"] = true
	entry.Postings = append([]EntryPosting(nil), entry.Postings...)
	for i := range entry.Postings {
		posting := &entry.Postings[i]
		// Preserve Beancount's inferred balancing leg.
		if posting.Amount == "" {
			continue
		}
		if err := validateBeanDecimal("amount", posting.Amount); err != nil {
			return LedgerEntry{}, err
		}
		// Sign inversion on decimal text preserves every digit and the precision
		// Beancount uses for tolerance inference. Lot costs and prices stay positive.
		amount := strings.TrimSpace(posting.Amount)
		if strings.HasPrefix(amount, "-") {
			posting.Amount = strings.TrimPrefix(amount, "-")
		} else {
			posting.Amount = "-" + strings.TrimPrefix(amount, "+")
		}
	}
	return entry, nil
}
