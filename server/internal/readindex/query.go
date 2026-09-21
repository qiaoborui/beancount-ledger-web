package readindex

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/boundedstream"
	"github.com/borui/beancount-ledger-web/server/internal/readindex/sqlite"
)

const (
	MaxResponseBytes = 1 << 20
	DefaultPageSize  = 100
	MaxPageSize      = 500
	maxCursorBytes   = 512
)

// Index owns a single read-only native connection. Methods (including Close)
// are serialized. Files and ancestors must not be replaced/modified while open.
// Cancellation interrupts native work, but waiting for this mutex is not an
// independently cancellable operation. No ledger data is retained on Index.
type Index struct {
	mu       sync.Mutex
	db       *sqlite.DB
	manifest Manifest
}

type PageRequest struct {
	Limit  int    `json:"limit"`
	Cursor string `json:"cursor,omitempty"`
}

// Transaction contains the exact source directive, not an accounting snapshot.
// Postings and metadata are available separately through Detail.
type Transaction struct {
	ID     int64           `json:"id"`
	Date   string          `json:"date"`
	Record json.RawMessage `json:"record"`
}

type Page struct {
	Revision     string        `json:"revision"`
	Transactions []Transaction `json:"transactions"`
	NextCursor   string        `json:"next_cursor,omitempty"`
}

type Detail struct {
	Revision string            `json:"revision"`
	ID       int64             `json:"id"`
	Records  []json.RawMessage `json:"records"` // directive, metadata, postings in source order
}

// Open is an explicitly non-cancellable convenience wrapper for OpenContext.
func Open(path string, expected Manifest) (*Index, error) {
	return OpenContext(context.Background(), path, expected)
}

// OpenContext verifies the exact application schema BEFORE physical integrity, stored
// manifest and a streaming replay of the raw records against that manifest.
// This deliberately costs O(stream size) at reopen, with bounded memory. It
// detects logical raw-record/index tampering that integrity_check alone cannot.
// expected must be the complete Manifest returned by Build, not a wildcard.
func OpenContext(ctx context.Context, path string, expected Manifest) (*Index, error) {
	if ctx == nil {
		return nil, ErrInvalidRequest
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if path == "" {
		return nil, ErrUnavailable
	}
	full, err := filepath.Abs(path)
	if err != nil || !privateDir(filepath.Dir(full)) {
		return nil, ErrUnavailable
	}
	db, err := sqlite.OpenContext(ctx, full, false)
	if err != nil {
		return nil, dbError(ctx, err, ErrUnavailable)
	}
	success := false
	defer func() {
		if !success {
			_ = db.Close()
		}
	}()
	join := cancelSQLite(ctx, db)
	defer join()
	if err = verifySchema(ctx, db); err != nil {
		return nil, err
	}
	if err = db.IntegrityCheck(ctx); err != nil {
		return nil, dbError(ctx, err, ErrCorrupt)
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	rows, err := db.Query("SELECT singleton, raw FROM manifest")
	if err != nil {
		return nil, dbError(ctx, err, ErrCorrupt)
	}
	var m Manifest
	valid := rows.Next() && rows.Int64(0) == 1
	if valid {
		raw := rows.Text(1)
		valid = len(raw) <= MaxResponseBytes && json.Unmarshal([]byte(raw), &m) == nil
		encoded, _ := json.Marshal(m)
		valid = valid && string(encoded) == raw // unknown/duplicate fields fail closed
	}
	valid = !rows.Next() && valid
	if err = rows.Close(); err != nil {
		return nil, dbError(ctx, err, ErrCorrupt)
	}
	if !valid || m.SchemaVersion != SchemaVersion {
		return nil, ErrCorrupt
	}
	if err = verifyRecords(ctx, db, m); err != nil {
		return nil, err
	}
	if m != expected {
		return nil, ErrRevisionMismatch
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	success = true
	return &Index{db: db, manifest: m}, nil
}

func verifySchema(ctx context.Context, db *sqlite.DB) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	rows, err := db.Query("SELECT name, type, tbl_name, sql FROM sqlite_schema")
	if err != nil {
		return dbError(ctx, err, ErrCorrupt)
	}
	defer rows.Close()
	seen := make(map[string]bool, len(schema)) // constant size, never entry-wide
	for rows.Next() {
		if err := ctx.Err(); err != nil {
			return err
		}
		name := rows.Text(0)
		found := false
		for _, object := range schema {
			if name == object.name && rows.Text(1) == object.kind && rows.Text(2) == object.table && rows.Text(3) == object.sql {
				found = true
				break
			}
		}
		if !found || seen[name] {
			return ErrCorrupt
		}
		seen[name] = true
	}
	if err = rows.Err(); err != nil {
		return dbError(ctx, err, ErrCorrupt)
	}
	if len(seen) != len(schema) {
		return ErrCorrupt
	}
	return nil
}

// recordReader exposes a single indexed record at a time to the existing
// verifier. It checks the materialized keys while the native row is current.
type recordReader struct {
	ctx      context.Context
	rows     *sqlite.Rows
	pending  string
	seq      int64
	manifest Manifest
	err      error
}

func (r *recordReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	if len(p) == 0 {
		return 0, nil
	}
	if r.err != nil {
		return 0, r.err
	}
	if r.pending == "" {
		if !r.rows.Next() {
			if r.rows.Err() != nil {
				r.err = dbError(r.ctx, r.rows.Err(), ErrCorrupt)
				return 0, r.err
			}
			return 0, io.EOF
		}
		r.seq++
		raw := r.rows.Text(2)
		if len(raw)+1 > boundedstream.MaxRecordBytes || strings.ContainsRune(raw, '\n') || r.rows.Int64(0) != r.seq {
			r.err = ErrCorrupt
			return 0, r.err
		}
		key, err := keys([]byte(raw))
		if err != nil || r.rows.Int64(1) != key.EntryID {
			r.err = ErrCorrupt
			return 0, r.err
		}
		if key.Type == "header" {
			r.manifest.Runtime, r.manifest.Exporter, r.manifest.Entrypoint = key.Runtime, key.Exporter, key.Entrypoint
		}
		if key.Type == "directive" && key.Value.Kind == "transaction" {
			if r.rows.IsNull(3) || r.rows.Int64(3) != key.ID || r.rows.Text(4) != key.Value.Date || r.rows.Int64(5) != r.seq {
				r.err = ErrCorrupt
				return 0, r.err
			}
			r.manifest.Transactions++
		} else if !r.rows.IsNull(3) {
			r.err = ErrCorrupt
			return 0, r.err
		}
		if err = r.rows.Err(); err != nil {
			r.err = dbError(r.ctx, err, ErrCorrupt)
			return 0, r.err
		}
		r.pending = raw + "\n"
	}
	n := copy(p, r.pending)
	r.pending = r.pending[n:]
	return n, nil
}

func verifyRecords(ctx context.Context, db *sqlite.DB, want Manifest) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	rows, err := db.Query("SELECT r.seq, r.entry_id, r.raw, t.id, t.date, t.seq FROM records AS r LEFT JOIN transactions AS t INDEXED BY transactions_seq ON t.seq=r.seq ORDER BY r.seq")
	if err != nil {
		return dbError(ctx, err, ErrCorrupt)
	}
	reader := &recordReader{ctx: ctx, rows: rows}
	summary, verifyErr := boundedstream.Verify(ctx, reader, nil)
	endErr := rows.Close()
	if err := ctx.Err(); err != nil {
		return err
	}
	if reader.err != nil {
		return reader.err
	}
	if verifyErr != nil {
		return ErrCorrupt
	}
	if endErr != nil {
		return dbError(ctx, endErr, ErrCorrupt)
	}
	if finishManifest(reader.manifest, summary) != want {
		return ErrCorrupt
	}
	// The LEFT JOIN also needs the inverse check for orphan transaction rows.
	rows, err = db.Query("SELECT count(*) FROM transactions")
	if err != nil {
		return dbError(ctx, err, ErrCorrupt)
	}
	ok := rows.Next() && rows.Int64(0) == want.Transactions
	err = rows.Close()
	if err != nil {
		return dbError(ctx, err, ErrCorrupt)
	}
	if !ok {
		return ErrCorrupt
	}
	return nil
}

func (i *Index) Close() error {
	if i == nil {
		return nil
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.db == nil {
		return nil
	}
	err := i.db.Close()
	i.db = nil
	return dbError(nil, err, ErrUnavailable)
}

type pageCursor struct {
	Revision string `json:"revision"`
	Date     string `json:"date"`
	ID       int64  `json:"id"`
}

func encodeCursor(c pageCursor) string {
	raw, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(raw)
}

func decodeCursor(raw, revision string) (pageCursor, error) {
	var c pageCursor
	if len(raw) > maxCursorBytes {
		return c, ErrInvalidCursor
	}
	b, err := base64.RawURLEncoding.Strict().DecodeString(raw)
	if err != nil {
		return c, ErrInvalidCursor
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(&c) != nil || c.ID <= 0 || len(c.Revision) != 64 || encodeCursor(c) != raw {
		return pageCursor{}, ErrInvalidCursor
	}
	date, err := time.Parse("2006-01-02", c.Date)
	if err != nil || date.Format("2006-01-02") != c.Date {
		return pageCursor{}, ErrInvalidCursor
	}
	if c.Revision != revision {
		return pageCursor{}, ErrRevisionMismatch
	}
	return c, nil
}

// Transactions returns DESC(date,id) keyset pages. Zero limit means 100; limits
// outside 1..500 are rejected, not silently changed. Cursors bind an existing
// transaction boundary and this exact revision. They are opaque, not secrets or
// authentication tokens. The bound is the actual encoding/json representation
// of Page, including escaped JSON, wrappers and its next cursor (no trailing LF).
// Retained raw bytes also have a 1MiB budget so whitespace-heavy records cannot
// defeat the memory bound by compacting to tiny serialized values.
func (i *Index) Transactions(ctx context.Context, request PageRequest) (Page, error) {
	if i == nil {
		return Page{}, ErrUnavailable
	}
	if ctx == nil {
		return Page{}, ErrInvalidRequest
	}
	if err := ctx.Err(); err != nil {
		return Page{}, err
	}
	limit := request.Limit
	if limit == 0 {
		limit = DefaultPageSize
	}
	if limit < 1 || limit > MaxPageSize {
		return Page{}, ErrInvalidRequest
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return Page{}, err
	}
	if i.db == nil {
		return Page{}, ErrUnavailable
	}
	join := cancelSQLite(ctx, i.db)
	defer join()
	query := "SELECT t.id, t.date, r.raw FROM transactions AS t INDEXED BY transactions_date_id JOIN records AS r ON r.seq=t.seq"
	var args []any
	if request.Cursor != "" {
		c, err := decodeCursor(request.Cursor, i.manifest.Revision)
		if err != nil {
			return Page{}, err
		}
		rows, err := i.db.Query("SELECT date FROM transactions WHERE id=?", c.ID)
		if err != nil {
			return Page{}, dbError(ctx, err, ErrCorrupt)
		}
		valid := rows.Next() && rows.Text(0) == c.Date
		err = rows.Close()
		if err != nil {
			return Page{}, dbError(ctx, err, ErrCorrupt)
		}
		if !valid {
			return Page{}, ErrInvalidCursor
		}
		query += " WHERE (t.date, t.id) < (?, ?)"
		args = append(args, c.Date, c.ID)
	}
	query += " ORDER BY t.date DESC, t.id DESC LIMIT ?"
	args = append(args, limit+1)
	if err := ctx.Err(); err != nil {
		return Page{}, err
	}
	rows, err := i.db.Query(query, args...)
	if err != nil {
		return Page{}, dbError(ctx, err, ErrCorrupt)
	}
	defer rows.Close() // precedes cancellation join and mutex unlock
	page := Page{Revision: i.manifest.Revision, Transactions: make([]Transaction, 0)}
	itemBytes, retainedBytes := 0, 0
	present := rows.Next()
	for present && len(page.Transactions) < limit {
		if err = ctx.Err(); err != nil {
			return Page{}, err
		}
		item := Transaction{ID: rows.Int64(0), Date: rows.Text(1), Record: json.RawMessage(rows.Text(2))}
		raw, e := json.Marshal(item)
		if e != nil {
			return Page{}, ErrCorrupt
		}
		// One row of lookahead establishes whether this candidate needs a cursor.
		present = rows.Next()
		if err = rows.Err(); err != nil {
			return Page{}, dbError(ctx, err, ErrCorrupt)
		}
		cursor := ""
		if present {
			cursor = encodeCursor(pageCursor{Revision: page.Revision, Date: item.Date, ID: item.ID})
		}
		shell, _ := json.Marshal(Page{Revision: page.Revision, Transactions: []Transaction{}, NextCursor: cursor})
		commas := len(page.Transactions) // new total count minus one
		if len(shell)+itemBytes+len(raw)+commas > MaxResponseBytes || retainedBytes+len(item.Record) > MaxResponseBytes {
			if len(page.Transactions) == 0 {
				return Page{}, ErrResourceLimit
			}
			// Previous candidate reserved a cursor because this row existed.
			break
		}
		itemBytes += len(raw)
		retainedBytes += len(item.Record)
		page.Transactions = append(page.Transactions, item)
		page.NextCursor = cursor
	}
	if err = rows.Close(); err != nil {
		return Page{}, dbError(ctx, err, ErrCorrupt)
	}
	if err = ctx.Err(); err != nil {
		return Page{}, err
	}
	// Guard the accounting against future wire-structure changes.
	raw, err := json.Marshal(page)
	if err != nil {
		return Page{}, ErrCorrupt
	}
	if len(raw) > MaxResponseBytes {
		return Page{}, ErrResourceLimit
	}
	if err := ctx.Err(); err != nil {
		return Page{}, err
	}
	return page, nil
}

// Detail returns every raw record of one directive in sequence, or no result at
// all. Oversize details never return a successful truncated directive/posting.
// Both serialized bytes and retained raw record bytes must fit in 1MiB.
func (i *Index) Detail(ctx context.Context, id int64) (Detail, error) {
	if i == nil {
		return Detail{}, ErrUnavailable
	}
	if ctx == nil || id <= 0 {
		return Detail{}, ErrInvalidRequest
	}
	if err := ctx.Err(); err != nil {
		return Detail{}, err
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return Detail{}, err
	}
	if i.db == nil {
		return Detail{}, ErrUnavailable
	}
	join := cancelSQLite(ctx, i.db)
	defer join()
	rows, err := i.db.Query("SELECT raw FROM records INDEXED BY records_entry WHERE entry_id=? ORDER BY seq", id)
	if err != nil {
		return Detail{}, dbError(ctx, err, ErrCorrupt)
	}
	defer rows.Close()
	detail := Detail{Revision: i.manifest.Revision, ID: id, Records: []json.RawMessage{}}
	shell, _ := json.Marshal(detail)
	size, retainedBytes := len(shell), 0
	for rows.Next() {
		if err = ctx.Err(); err != nil {
			return Detail{}, err
		}
		raw := json.RawMessage(rows.Text(0))
		encoded, e := json.Marshal(raw) // include compaction AND HTML escaping
		if e != nil {
			return Detail{}, ErrCorrupt
		}
		size += len(encoded)
		retainedBytes += len(raw)
		if len(detail.Records) != 0 {
			size++
		}
		if size > MaxResponseBytes || retainedBytes > MaxResponseBytes {
			return Detail{}, ErrResourceLimit
		}
		detail.Records = append(detail.Records, raw)
	}
	if err = rows.Close(); err != nil {
		return Detail{}, dbError(ctx, err, ErrCorrupt)
	}
	if err = ctx.Err(); err != nil {
		return Detail{}, err
	}
	if len(detail.Records) == 0 {
		return Detail{}, ErrNotFound
	}
	encoded, err := json.Marshal(detail)
	if err != nil {
		return Detail{}, ErrCorrupt
	}
	if len(encoded) > MaxResponseBytes {
		return Detail{}, ErrResourceLimit
	}
	if err := ctx.Err(); err != nil {
		return Detail{}, err
	}
	return detail, nil
}
