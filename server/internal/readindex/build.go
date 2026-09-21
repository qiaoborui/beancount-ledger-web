// Package readindex builds immutable, disposable SQLite indexes from verified
// bounded-v1 streams. It never reads a ledger or falls back to a ledger snapshot.
package readindex

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"github.com/borui/beancount-ledger-web/server/internal/boundedstream"
	"github.com/borui/beancount-ledger-web/server/internal/readindex/sqlite"
)

const SchemaVersion = 2

var (
	ErrUnavailable      = errors.New("read index unavailable")
	ErrCorrupt          = errors.New("read index corrupt")
	ErrResourceLimit    = errors.New("read index resource limit exceeded")
	ErrInvalidStream    = errors.New("read index invalid stream")
	ErrExists           = errors.New("read index destination exists")
	ErrInvalidRequest   = errors.New("read index invalid request")
	ErrInvalidCursor    = errors.New("read index invalid cursor")
	ErrRevisionMismatch = errors.New("read index revision mismatch")
	ErrNotFound         = errors.New("read index entry not found")
)

// Manifest is the complete expected identity of an index. Revision hashes the
// JSON encoding of all other fields (with revision empty), not just the source
// assertion. It is an identity/checksum, not authentication of the source.
type Manifest struct {
	SchemaVersion  int    `json:"schema_version"`
	StreamVersion  int    `json:"stream_version"`
	SourceDigest   string `json:"source_digest"`
	Runtime        string `json:"runtime"`
	Exporter       string `json:"exporter"`
	Entrypoint     string `json:"entrypoint"`
	StreamDigest   string `json:"stream_digest"`
	Records        int64  `json:"records"` // excludes footer
	Directives     int64  `json:"directives"`
	Postings       int64  `json:"postings"`
	Options        int64  `json:"options"`
	Commodities    int64  `json:"commodities"`
	Metadata       int64  `json:"metadata"`
	Transactions   int64  `json:"transactions"`
	Bytes          int64  `json:"bytes"` // includes footer and all LFs
	MaxRecordBytes int    `json:"max_record_bytes"`
	Revision       string `json:"revision"`
}

type envelope struct {
	Type       string `json:"type"`
	ID         int64  `json:"id"`
	EntryID    int64  `json:"entry_id"`
	Runtime    string `json:"runtime"`
	Exporter   string `json:"exporter"`
	Entrypoint string `json:"entry_file"`
	Value      struct {
		Kind string `json:"Kind"`
		Date string `json:"Date"`
	} `json:"value"`
}

// Decode only index keys, never amounts or arbitrary typed values into floats.
// option/commodity/metadata value fields are not necessarily objects.
func keys(raw []byte) (envelope, error) {
	var e envelope
	var v struct {
		Type       string          `json:"type"`
		ID         int64           `json:"id"`
		EntryID    int64           `json:"entry_id"`
		Runtime    string          `json:"runtime"`
		Exporter   string          `json:"exporter"`
		Entrypoint string          `json:"entry_file"`
		Value      json.RawMessage `json:"value"`
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		return e, ErrCorrupt
	}
	e.Type, e.ID, e.EntryID = v.Type, v.ID, v.EntryID
	e.Runtime, e.Exporter, e.Entrypoint = v.Runtime, v.Exporter, v.Entrypoint
	if e.Type == "directive" {
		if err := json.Unmarshal(v.Value, &e.Value); err != nil {
			return envelope{}, ErrCorrupt
		}
		e.EntryID = e.ID
	}
	return e, nil
}

func finishManifest(m Manifest, s boundedstream.Summary) Manifest {
	m.SchemaVersion, m.StreamVersion = SchemaVersion, s.Version
	m.SourceDigest, m.StreamDigest = s.SourceDigest, s.SHA256
	m.Records, m.Directives, m.Postings = s.Records, s.Directives, s.Postings
	m.Options, m.Commodities, m.Metadata = s.Options, s.Commodities, s.Metadata
	m.Bytes, m.MaxRecordBytes = s.Bytes, s.MaxRecordBytes
	m.Revision = ""
	b, _ := json.Marshal(m)
	h := sha256.Sum256(b)
	m.Revision = hex.EncodeToString(h[:])
	return m
}

var schema = []struct{ name, kind, table, sql string }{
	{"records", "table", "records", "CREATE TABLE records (seq INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, raw TEXT NOT NULL) STRICT"},
	{"records_entry", "index", "records", "CREATE INDEX records_entry ON records(entry_id, seq)"},
	{"transactions", "table", "transactions", "CREATE TABLE transactions (id INTEGER PRIMARY KEY, date TEXT NOT NULL, seq INTEGER NOT NULL) STRICT"},
	{"transactions_date_id", "index", "transactions", "CREATE INDEX transactions_date_id ON transactions(date DESC, id DESC)"},
	{"transactions_seq", "index", "transactions", "CREATE UNIQUE INDEX transactions_seq ON transactions(seq)"},
	{"postings", "table", "postings", "CREATE TABLE postings (seq INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, ordinal INTEGER NOT NULL, account TEXT NOT NULL, date TEXT NOT NULL, quantity TEXT NOT NULL, currency TEXT NOT NULL, cost_number TEXT, cost_currency TEXT, cost_date TEXT, cost_label TEXT, price_number TEXT, price_currency TEXT, flag TEXT) STRICT"},
	{"postings_account_currency_date", "index", "postings", "CREATE INDEX postings_account_currency_date ON postings(account, currency, date, seq)"},
	{"account_events", "table", "account_events", "CREATE TABLE account_events (seq INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, kind TEXT NOT NULL, account TEXT NOT NULL, date TEXT NOT NULL) STRICT"},
	{"account_events_catalog", "index", "account_events", "CREATE INDEX account_events_catalog ON account_events(kind, account, entry_id)"},
	{"account_events_latest", "index", "account_events", "CREATE INDEX account_events_latest ON account_events(account, kind, date DESC, entry_id DESC)"},
	{"prices", "table", "prices", "CREATE TABLE prices (seq INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, date TEXT NOT NULL, currency TEXT NOT NULL, quantity TEXT NOT NULL, quote_currency TEXT NOT NULL) STRICT"},
	{"prices_currency_date", "index", "prices", "CREATE INDEX prices_currency_date ON prices(currency, quote_currency, date, seq)"},
	{"manifest", "table", "manifest", "CREATE TABLE manifest (singleton INTEGER PRIMARY KEY CHECK(singleton=1), raw TEXT NOT NULL) STRICT"},
}

// cancelSQLite must be joined BEFORE closing/reusing the serially owned DB.
// Interrupt only affects current native work; callers also check ctx between
// statements. A blocked arbitrary Reader still requires caller-owned deadlines.
func cancelSQLite(ctx context.Context, db *sqlite.DB) func() {
	stop, done := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		select {
		case <-ctx.Done():
			db.Interrupt()
		case <-stop:
			// Joining a canceled operation must not race the ready Done arm.
			if ctx.Err() != nil {
				db.Interrupt()
			}
		}
	}()
	return func() { close(stop); <-done }
}

func dbError(ctx context.Context, err error, fallback error) error {
	if ctx != nil && ctx.Err() != nil {
		return ctx.Err()
	}
	if err == nil {
		return nil
	}
	var se *sqlite.Error
	if errors.As(err, &se) {
		switch se.Code & 255 {
		case 7, 13, 18:
			return ErrResourceLimit // NOMEM, FULL, TOOBIG
		case 11, 26:
			return ErrCorrupt
		}
	}
	return fallback
}

// Private directories are required even for read-only opens. Ancestors must be
// trusted by the caller; this is not a sandbox against the owning OS user.
func privateDir(path string) bool {
	s, err := os.Lstat(path)
	if err != nil || !s.IsDir() || s.Mode().Perm() != 0700 || s.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
		return false
	}
	st, ok := s.Sys().(*syscall.Stat_t)
	return ok && st.Uid == uint32(os.Geteuid())
}

func syncDir(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return ErrUnavailable
	}
	err = f.Sync()
	end := f.Close()
	if err != nil || end != nil {
		return ErrUnavailable
	}
	return nil
}

// Build exclusively publishes destination only after EOF verification, commit,
// physical integrity checking, close and fsync. Its parent must be an owned0700
// directory (or a single missing directory, which Build creates). Publication
// uses an exclusive hard link in that same directory; existing files, including
// symlinks, are never overwritten. Only this call's staging files are removed.
func Build(ctx context.Context, input io.Reader, destination string) (Manifest, error) {
	return build(ctx, input, destination, syncDir)
}

// Inject only directory fsync, without mutable process-global test hooks.
func build(ctx context.Context, input io.Reader, destination string, syncDirectory func(string) error) (result Manifest, err error) {
	if ctx == nil || input == nil || destination == "" {
		return Manifest{}, ErrInvalidRequest
	}
	if err := ctx.Err(); err != nil {
		return Manifest{}, err
	}
	path, err := filepath.Abs(destination)
	if err != nil {
		return Manifest{}, ErrUnavailable
	}
	dir := filepath.Dir(path)
	madeDir := false
	if err := os.Mkdir(dir, 0700); err == nil {
		madeDir = true
	} else if !os.IsExist(err) {
		return Manifest{}, ErrUnavailable
	}
	defer func() {
		if err != nil && madeDir {
			_ = os.Remove(dir)
		}
	}()
	if !privateDir(dir) {
		return Manifest{}, ErrUnavailable
	}
	if _, e := os.Lstat(path); e == nil {
		return Manifest{}, ErrExists
	} else if !os.IsNotExist(e) {
		return Manifest{}, ErrUnavailable
	}
	f, err := os.CreateTemp(dir, ".readindex-*") // O_EXCL, 0600
	if err != nil {
		return Manifest{}, ErrUnavailable
	}
	staging := f.Name()
	info, statErr := f.Stat()
	closeErr := f.Close()
	published := false
	defer func() {
		// No globbing: never delete another build's files or a preexisting DB.
		for _, suffix := range []string{"", "-journal", "-wal", "-shm"} {
			_ = os.Remove(staging + suffix)
		}
		if err != nil && published {
			if s, e := os.Lstat(path); e == nil && os.SameFile(info, s) {
				_ = os.Remove(path)
				_ = syncDirectory(dir)
			}
		}
	}()
	if statErr != nil || closeErr != nil {
		return Manifest{}, ErrUnavailable
	}
	db, e := sqlite.OpenContext(ctx, staging, true)
	if e != nil {
		return Manifest{}, dbError(ctx, e, ErrUnavailable)
	}
	// The defer order joins cancellation before native close/rollback.
	defer db.Close()
	join := cancelSQLite(ctx, db)
	defer func() {
		if join != nil {
			join()
		}
	}()
	if e = db.Exec("BEGIN IMMEDIATE"); e != nil {
		return Manifest{}, dbError(ctx, e, ErrUnavailable)
	}
	for _, object := range schema {
		if e = ctx.Err(); e != nil {
			return Manifest{}, e
		}
		if e = db.Exec(object.sql); e != nil {
			return Manifest{}, dbError(ctx, e, ErrUnavailable)
		}
	}
	var m Manifest
	var seq int64
	var visitErr error
	var projections projectionState
	summary, e := boundedstream.Verify(ctx, input, func(r boundedstream.Record) error {
		key, e := keys(r.Raw)
		if e != nil {
			visitErr = e
			return e
		}
		seq++
		if r.Type == "header" {
			m.Runtime, m.Exporter, m.Entrypoint = key.Runtime, key.Exporter, key.Entrypoint
		}
		if e = ctx.Err(); e == nil {
			e = db.Exec("INSERT INTO records(seq, entry_id, raw) VALUES (?, ?, ?)", seq, key.EntryID, string(r.Raw))
		}
		if e == nil && r.Type == "directive" && key.Value.Kind == "transaction" {
			m.Transactions++
			if e = ctx.Err(); e == nil {
				e = db.Exec("INSERT INTO transactions(id, date, seq) VALUES (?, ?, ?)", key.ID, key.Value.Date, seq)
			}
		}
		if e == nil {
			var p projection
			p, e = projections.project(r.Raw, key, seq)
			if e == nil {
				e = insertProjection(db, p)
			}
		}
		if e != nil {
			visitErr = dbError(ctx, e, ErrUnavailable)
		}
		return e
	})
	if e != nil {
		if ctx.Err() != nil {
			return Manifest{}, ctx.Err()
		}
		if visitErr != nil {
			return Manifest{}, visitErr
		}
		if errors.Is(e, boundedstream.ErrRead) {
			return Manifest{}, ErrUnavailable
		}
		return Manifest{}, ErrInvalidStream
	}
	m = finishManifest(m, summary)
	raw, _ := json.Marshal(m)
	if len(raw) > MaxResponseBytes {
		return Manifest{}, ErrResourceLimit
	}
	if e = ctx.Err(); e != nil {
		return Manifest{}, e
	}
	if e = db.Exec("INSERT INTO manifest(singleton, raw) VALUES (1, ?)", string(raw)); e != nil {
		return Manifest{}, dbError(ctx, e, ErrUnavailable)
	}
	// Verify has consumed the footer AND EOF before any commit is possible.
	if e = ctx.Err(); e != nil {
		return Manifest{}, e
	}
	if e = db.Exec("COMMIT"); e != nil {
		return Manifest{}, dbError(ctx, e, ErrUnavailable)
	}
	if e = verifySchema(ctx, db); e != nil {
		return Manifest{}, e
	}
	if e = db.IntegrityCheck(ctx); e != nil {
		return Manifest{}, dbError(ctx, e, ErrCorrupt)
	}
	join()
	join = nil
	if e = db.Close(); e != nil {
		return Manifest{}, dbError(ctx, e, ErrUnavailable)
	}
	f, e = os.OpenFile(staging, os.O_RDWR, 0)
	if e != nil {
		return Manifest{}, ErrUnavailable
	}
	e = f.Sync()
	closeErr = f.Close()
	if e != nil || closeErr != nil {
		return Manifest{}, ErrUnavailable
	}
	if e = ctx.Err(); e != nil {
		return Manifest{}, e
	}
	if e = os.Link(staging, path); e != nil {
		if os.IsExist(e) {
			return Manifest{}, ErrExists
		}
		return Manifest{}, ErrUnavailable
	}
	published = true
	if e = os.Remove(staging); e != nil {
		return Manifest{}, ErrUnavailable
	}
	if e = syncDirectory(dir); e != nil {
		return Manifest{}, e
	}
	if e = ctx.Err(); e != nil {
		return Manifest{}, e
	}
	if madeDir {
		if e = syncDirectory(filepath.Dir(dir)); e != nil {
			return Manifest{}, e
		}
	}
	if e = ctx.Err(); e != nil {
		return Manifest{}, e
	}
	return m, nil
}
