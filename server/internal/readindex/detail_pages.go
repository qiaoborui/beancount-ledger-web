package readindex

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
)

// DetailPageRequest selects a source-ordered chunk of one directive's records.
// Zero Limit means 100; other limits must be in 1..500.
type DetailPageRequest struct {
	ID     int64  `json:"id"`
	Limit  int    `json:"limit"`
	Cursor string `json:"cursor,omitempty"`
}

// DetailPage is one bounded chunk, not necessarily a complete directive.
// Missing IDs return ErrNotFound; a valid cursor at the final record returns
// an empty, non-nil Records array with no next cursor.
type DetailPage struct {
	Revision   string            `json:"revision"`
	ID         int64             `json:"id"`
	Records    []json.RawMessage `json:"records"`
	NextCursor string            `json:"next_cursor,omitempty"`
}

type detailCursor struct {
	Operation string `json:"operation"`
	Revision  string `json:"revision"`
	ID        int64  `json:"id"`
	LastSeq   int64  `json:"last_seq"`
}

const detailRecordsOperation = "detail_records"
const detailRecordsQuery = "SELECT seq, raw FROM records INDEXED BY records_entry WHERE entry_id=? AND seq>? ORDER BY seq LIMIT ?"

func encodeDetailCursor(c detailCursor) string {
	raw, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(raw)
}

func decodeDetailCursor(raw, revision string, id int64) (detailCursor, error) {
	var c detailCursor
	if len(raw) > maxCursorBytes {
		return c, ErrInvalidCursor
	}
	b, err := base64.RawURLEncoding.Strict().DecodeString(raw)
	if err != nil || json.Unmarshal(b, &c) != nil || encodeDetailCursor(c) != raw ||
		c.Operation != detailRecordsOperation || c.ID != id || c.ID <= 0 || c.LastSeq <= 0 || len(c.Revision) != 64 {
		return detailCursor{}, ErrInvalidCursor
	}
	if _, err = hex.DecodeString(c.Revision); err != nil || strings.ToLower(c.Revision) != c.Revision {
		return detailCursor{}, ErrInvalidCursor
	}
	if c.Revision != revision {
		return detailCursor{}, ErrRevisionMismatch
	}
	return c, nil
}

// DetailRecords returns exact raw records in seq order without materializing a
// whole directive. Both retained raw bytes and the encoded page (including JSON
// escaping, wrappers and cursor) are capped at 1MiB. A row that cannot fit alone
// returns ErrResourceLimit; a byte boundary never consumes an undelivered row.
// Cursors validate an existing boundary, operation, entry and revision; they are
// not signed authentication tokens. A canonical cursor for any real boundary
// of this entry is valid. Detail's all-or-error contract is unchanged.
func (i *Index) DetailRecords(ctx context.Context, request DetailPageRequest) (DetailPage, error) {
	if i == nil {
		return DetailPage{}, ErrUnavailable
	}
	if ctx == nil || request.ID <= 0 {
		return DetailPage{}, ErrInvalidRequest
	}
	if err := ctx.Err(); err != nil {
		return DetailPage{}, err
	}
	limit := request.Limit
	if limit == 0 {
		limit = DefaultPageSize
	}
	if limit < 1 || limit > MaxPageSize {
		return DetailPage{}, ErrInvalidRequest
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return DetailPage{}, err
	}
	if i.db == nil {
		return DetailPage{}, ErrUnavailable
	}
	join := cancelSQLite(ctx, i.db)
	defer join()
	var lastSeq int64
	if request.Cursor != "" {
		c, err := decodeDetailCursor(request.Cursor, i.manifest.Revision, request.ID)
		if err != nil {
			return DetailPage{}, err
		}
		rows, err := i.db.Query("SELECT entry_id FROM records WHERE seq=?", c.LastSeq)
		if err != nil {
			return DetailPage{}, dbError(ctx, err, ErrCorrupt)
		}
		valid := rows.Next() && rows.Int64(0) == request.ID
		if err = rows.Close(); err != nil {
			return DetailPage{}, dbError(ctx, err, ErrCorrupt)
		}
		if !valid {
			return DetailPage{}, ErrInvalidCursor
		}
		lastSeq = c.LastSeq
	}
	if err := ctx.Err(); err != nil {
		return DetailPage{}, err
	}
	rows, err := i.db.Query(detailRecordsQuery, request.ID, lastSeq, limit+1)
	if err != nil {
		return DetailPage{}, dbError(ctx, err, ErrCorrupt)
	}
	defer rows.Close() // finalize before cancellation join and mutex unlock
	page := DetailPage{Revision: i.manifest.Revision, ID: request.ID, Records: []json.RawMessage{}}
	itemBytes, retainedBytes := 0, 0
	present := rows.Next()
	for present && len(page.Records) < limit {
		if err = ctx.Err(); err != nil {
			return DetailPage{}, err
		}
		seq, record := rows.Int64(0), json.RawMessage(rows.Text(1))
		encoded, e := json.Marshal(record)
		if e != nil {
			return DetailPage{}, ErrCorrupt
		}
		// Look ahead without copying the following row into Go memory.
		present = rows.Next()
		if err = rows.Err(); err != nil {
			return DetailPage{}, dbError(ctx, err, ErrCorrupt)
		}
		cursor := ""
		if present {
			cursor = encodeDetailCursor(detailCursor{Operation: detailRecordsOperation, Revision: page.Revision, ID: page.ID, LastSeq: seq})
		}
		shell, _ := json.Marshal(DetailPage{Revision: page.Revision, ID: page.ID, Records: []json.RawMessage{}, NextCursor: cursor})
		if len(shell)+itemBytes+len(encoded)+len(page.Records) > MaxResponseBytes || retainedBytes+len(record) > MaxResponseBytes {
			if len(page.Records) == 0 {
				return DetailPage{}, ErrResourceLimit
			}
			// The previous accepted row reserved its cursor; retry this row next call.
			break
		}
		itemBytes += len(encoded)
		retainedBytes += len(record)
		page.Records = append(page.Records, record)
		page.NextCursor = cursor
	}
	if err = rows.Close(); err != nil {
		return DetailPage{}, dbError(ctx, err, ErrCorrupt)
	}
	if err = ctx.Err(); err != nil {
		return DetailPage{}, err
	}
	if len(page.Records) == 0 && request.Cursor == "" {
		return DetailPage{}, ErrNotFound
	}
	encoded, err := json.Marshal(page)
	if err != nil {
		return DetailPage{}, ErrCorrupt
	}
	if len(encoded) > MaxResponseBytes {
		return DetailPage{}, ErrResourceLimit
	}
	if err = ctx.Err(); err != nil {
		return DetailPage{}, err
	}
	return page, nil
}
