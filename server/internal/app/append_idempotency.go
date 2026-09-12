package app

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

var errAppendIdempotencyConflict = errors.New("the write operation ID was already used for different ledger content")

func validateAppendOperationIDs(ids []string, count int) error {
	if len(ids) == 0 {
		return nil
	}
	if len(ids) != count {
		return errors.New("operationIds must match entries")
	}
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		if len(id) == 0 || len(id) > 128 {
			return errors.New("operation ID must contain 1 to 128 characters")
		}
		for _, char := range id {
			if !(char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' || char >= '0' && char <= '9' || char == '-' || char == '_') {
				return errors.New("operation ID must contain only letters, numbers, hyphens and underscores")
			}
		}
		if seen[id] {
			return errors.New("operationIds must be unique")
		}
		seen[id] = true
	}
	return nil
}

func newAppendOperationIDs(count int) []string {
	ids := make([]string, count)
	for index := range ids {
		ids[index] = rand.Text()
	}
	return ids
}

// Receipts are durable ledger provenance, committed with the entry itself.
// Keeping them in the same transaction also covers a successful Git commit
// whose response was lost, including process restarts and batch-to-single replay.
type appendOperationReceipt struct {
	Version       int    `json:"version"`
	ContentSHA256 string `json:"contentSHA256"`
}

func (w *LedgerWriter) appendReceiptPath(id string) string {
	sum := sha256.Sum256([]byte(id))
	name := hex.EncodeToString(sum[:])
	return filepath.Join(w.cfg.LedgerRoot, ".ledger-write-receipts", name[:2], name+".json")
}

func appendReceipt(item appendItem) appendOperationReceipt {
	sum := sha256.Sum256([]byte(item.beanText))
	return appendOperationReceipt{Version: 1, ContentSHA256: hex.EncodeToString(sum[:])}
}

func (w *LedgerWriter) appendOperationCompleted(tx *LedgerWriteTransaction, item appendItem) (bool, error) {
	if item.operationID == "" {
		return false, nil
	}
	content, err := tx.ReadFile(w.appendReceiptPath(item.operationID))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var receipt appendOperationReceipt
	if err := json.Unmarshal(content, &receipt); err != nil || receipt.Version != 1 {
		return false, errors.New("invalid ledger write receipt")
	}
	if receipt != appendReceipt(item) {
		return false, errAppendIdempotencyConflict
	}
	return true, nil
}

func (w *LedgerWriter) recordAppendOperation(tx *LedgerWriteTransaction, item appendItem) error {
	if item.operationID == "" {
		return nil
	}
	content, err := json.Marshal(appendReceipt(item))
	if err != nil {
		return fmt.Errorf("encode ledger write receipt: %w", err)
	}
	return tx.WriteFile(w.appendReceiptPath(item.operationID), append(content, '\n'), 0o600)
}
