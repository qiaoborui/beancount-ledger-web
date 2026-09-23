package app

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const localTransactionPageBytes = 1 << 20
const localTransactionPageDefault = 100
const localTransactionPageMax = 500

// Process-scoped MAC makes cursors opaque: restarting the app requires a fresh
// first page, and clients cannot substitute a source revision or filter set.
var localCursorKey = func() []byte {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		panic("cannot initialize local cursor signing")
	}
	return key
}()

type localTransactionCursor struct {
	Scope  string `json:"scope"`
	Offset int    `json:"offset"`
}

type localTransactionPage struct {
	Revision          string        `json:"revision"`
	Transactions      []Transaction `json:"transactions"`
	NextCursor        string        `json:"nextCursor,omitempty"`
	SensitiveUnlocked bool          `json:"sensitiveUnlocked"`
}

func signLocalCursor(value localTransactionCursor) string {
	data, _ := json.Marshal(value)
	mac := hmac.New(sha256.New, localCursorKey)
	mac.Write(data)
	return base64.RawURLEncoding.EncodeToString(data) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func decodeLocalCursor(raw string) (localTransactionCursor, error) {
	var value localTransactionCursor
	if len(raw) > 1024 {
		return value, errors.New("invalid transaction cursor")
	}
	parts := strings.Split(raw, ".")
	if len(parts) != 2 {
		return value, errors.New("invalid transaction cursor")
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return value, errors.New("invalid transaction cursor")
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return value, errors.New("invalid transaction cursor")
	}
	mac := hmac.New(sha256.New, localCursorKey)
	mac.Write(data)
	if !hmac.Equal(signature, mac.Sum(nil)) || json.Unmarshal(data, &value) != nil || value.Offset < 0 {
		return value, errors.New("invalid transaction cursor")
	}
	return value, nil
}

// Native-only additive route. Existing HTTP transaction contracts stay intact.
// Select rows before serialization; never build an all-history response to slice.
func localTransactionPageResponse(cfg Config, snapshot *LedgerSnapshot, query map[string]string) (int, json.RawMessage, error) {
	start, end := query["start"], query["end"]
	if start == "" {
		start = "0001-01-01"
	}
	if end == "" {
		end = "9999-12-31"
	}
	for _, date := range []string{start, end} {
		if _, err := time.Parse("2006-01-02", date); err != nil {
			return 400, nil, errors.New("invalid transaction page date")
		}
	}
	if start >= end {
		return 400, nil, errors.New("invalid transaction page range")
	}
	limit := localTransactionPageDefault
	if raw := query["limit"]; raw != "" {
		var err error
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 1 || limit > localTransactionPageMax {
			return 400, nil, errors.New("transaction page limit must be 1..500")
		}
	}
	filter, err := ParseTransactionQuery(query["q"])
	if err != nil {
		return 400, nil, err
	}
	effectiveStart, effectiveEnd := transactionQueryEffectiveRange(start, end, filter)
	modelRevision := fmt.Sprintf("%s:%d", snapshot.Version, snapshot.localReadModelID)
	scopeBytes, _ := json.Marshal([]string{cfg.LedgerRoot, cfg.localEntrypoint, modelRevision, effectiveStart, effectiveEnd, query["q"]})
	scope := fmt.Sprintf("%x", sha256.Sum256(scopeBytes))
	offset := 0
	if raw := query["cursor"]; raw != "" {
		cursor, err := decodeLocalCursor(raw)
		if err != nil {
			return 400, nil, err
		}
		if cursor.Scope != scope {
			return http.StatusConflict, nil, errors.New("transaction cursor is stale; restart from first page")
		}
		offset = cursor.Offset
	}
	txns := snapshotTransactionsDesc(snapshot)
	if offset > len(txns) {
		return 400, nil, errors.New("invalid transaction cursor position")
	}
	page := localTransactionPage{Revision: modelRevision, Transactions: make([]Transaction, 0, limit), SensitiveUnlocked: true}
	// Reserve enough for revision/cursor/envelope fields; exact final size checked.
	used := 4096
	for index := offset; index < len(txns); index++ {
		txn := txns[index]
		if txn.Date < effectiveStart || txn.Date >= effectiveEnd || (filter != nil && !filter.Matches(txn)) {
			continue
		}
		if len(page.Transactions) == limit {
			page.NextCursor = signLocalCursor(localTransactionCursor{scope, index})
			break
		}
		// Listing projection deliberately omits rich editor drafts and metadata.
		// These remain in the model for filtering and legacy/detail requests.
		txn.Entry = nil
		txn.Metadata = nil
		if txn.Postings == nil {
			txn.Postings = []Posting{}
		}
		if filepath.IsAbs(txn.Source.File) {
			relative, err := filepath.Rel(cfg.LedgerRoot, txn.Source.File)
			if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
				return 500, nil, errors.New("transaction source is outside workspace")
			}
			txn.Source.File = filepath.ToSlash(relative)
		}
		encoded, err := json.Marshal(txn)
		if err != nil {
			return 500, nil, errors.New("cannot encode transaction row")
		}
		if used+len(encoded)+1 > localTransactionPageBytes {
			if len(page.Transactions) == 0 {
				return http.StatusRequestEntityTooLarge, nil, errors.New("single transaction summary exceeds page byte budget")
			}
			page.NextCursor = signLocalCursor(localTransactionCursor{scope, index})
			break
		}
		used += len(encoded) + 1
		page.Transactions = append(page.Transactions, txn)
	}
	encoded, err := json.Marshal(page)
	if err != nil || len(encoded) > localTransactionPageBytes {
		return 500, nil, errors.New("transaction page exceeds byte budget")
	}
	return http.StatusOK, encoded, nil
}
