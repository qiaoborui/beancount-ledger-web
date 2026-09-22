// Package sqlite is a small, single-owner adapter for the system SQLite library.
//
// A DB and its Rows have one serial owner. Only Interrupt may be called from
// another goroutine, including concurrently with Close. Close must not race with
// any other method. Neither DB nor Rows may be copied. There are no finalizers:
// the owner must close them. A DB supports at most one live Rows.
//
// This package requires cgo, sqlite3 headers and libsqlite3 (SQLite >= 3.37).
// There is intentionally no non-cgo or unavailable-platform implementation.
package sqlite

/*
#cgo LDFLAGS: -lsqlite3
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdatomic.h>

#if SQLITE_VERSION_NUMBER < 3037000
#error SQLite 3.37 or later is required
#endif

// A connection-local VFS wrapper delegates real database/journal IO to the
// system VFS but FAILS CLOSED for scratch files. No process-global temp directory
// is changed. Registration is global (SQLite serializes its registry), but names
// and policy are unique per connection and never become the default VFS.
// Disk-spilling sorts require a future protected-directory VFS implementation;
// they must NOT silently fall back to an OS temporary directory on mobile.
typedef struct adapter_vfs {
    sqlite3_vfs vfs;
    sqlite3_vfs *base;
    char name[64];
} adapter_vfs;

static int av_open(sqlite3_vfs *v, sqlite3_filename name, sqlite3_file *file, int flags, int *out) {
    adapter_vfs *a = (adapter_vfs*)v;
    int scratch = SQLITE_OPEN_TEMP_DB | SQLITE_OPEN_TEMP_JOURNAL |
                  SQLITE_OPEN_TRANSIENT_DB | SQLITE_OPEN_SUBJOURNAL |
                  SQLITE_OPEN_DELETEONCLOSE;
    file->pMethods = NULL; // Required even when xOpen rejects the file.
    if (!name || (flags & scratch)) return SQLITE_CANTOPEN;
    return a->base->xOpen(a->base, name, file, flags, out);
}
static int av_delete(sqlite3_vfs *v, const char *p, int s) {
    sqlite3_vfs *b = ((adapter_vfs*)v)->base; return b->xDelete(b,p,s);
}
static int av_access(sqlite3_vfs *v, const char *p, int f, int *r) {
    sqlite3_vfs *b = ((adapter_vfs*)v)->base; return b->xAccess(b,p,f,r);
}
static int av_full(sqlite3_vfs *v, const char *p, int n, char *r) {
    sqlite3_vfs *b = ((adapter_vfs*)v)->base; return b->xFullPathname(b,p,n,r);
}
static int av_random(sqlite3_vfs *v, int n, char *r) {
    sqlite3_vfs *b = ((adapter_vfs*)v)->base; return b->xRandomness(b,n,r);
}
static int av_sleep(sqlite3_vfs *v, int n) {
    sqlite3_vfs *b = ((adapter_vfs*)v)->base; return b->xSleep(b,n);
}
static int av_time(sqlite3_vfs *v, double *r) {
    sqlite3_vfs *b = ((adapter_vfs*)v)->base; return b->xCurrentTime(b,r);
}
static int av_error(sqlite3_vfs *v, int n, char *r) {
    sqlite3_vfs *b = ((adapter_vfs*)v)->base;
    return b->xGetLastError ? b->xGetLastError(b,n,r) : 0;
}
static adapter_vfs *av_new(void) {
    sqlite3_vfs *base = sqlite3_vfs_find(NULL);
    if (!base) return NULL;
    adapter_vfs *a = calloc(1,sizeof(*a));
    if (!a) return NULL;
    a->base = base;
    snprintf(a->name,sizeof(a->name),"readindex-%p",(void*)a);
    a->vfs.iVersion = 1;
    a->vfs.szOsFile = base->szOsFile;
    a->vfs.mxPathname = base->mxPathname;
    a->vfs.zName = a->name;
    a->vfs.xOpen = av_open; a->vfs.xDelete = av_delete;
    a->vfs.xAccess = av_access; a->vfs.xFullPathname = av_full;
    a->vfs.xRandomness = av_random; a->vfs.xSleep = av_sleep;
    a->vfs.xCurrentTime = av_time; a->vfs.xGetLastError = av_error;
    // Extension loading is disabled; dlopen callbacks are deliberately absent.
    if (sqlite3_vfs_register(&a->vfs,0) != SQLITE_OK) { free(a); return NULL; }
    return a;
}
static void av_free(adapter_vfs *a) {
    if (a) { sqlite3_vfs_unregister(&a->vfs); free(a); }
}
static int bind_text(sqlite3_stmt *s, int i, const char *p, int n) {
    return sqlite3_bind_text(s,i,p,n,SQLITE_TRANSIENT);
}
static int harden(sqlite3 *db) {
    int rc = sqlite3_db_config(db,SQLITE_DBCONFIG_DEFENSIVE,1,NULL);
    if (rc == SQLITE_OK) rc = sqlite3_db_config(db,SQLITE_DBCONFIG_TRUSTED_SCHEMA,0,NULL);
    // Apple builds omit extension loading and reject its db_config operation.
    // Require runtime proof of omission; otherwise disabling must succeed.
    if (rc == SQLITE_OK && !sqlite3_compileoption_used("OMIT_LOAD_EXTENSION"))
        rc = sqlite3_db_config(db,SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION,0,NULL);
    return rc;
}
static int authorize(void *integrity, int op, const char *a, const char *b, const char *c, const char *d) {
    (void)c; (void)d;
    if (op == SQLITE_PRAGMA)
        return integrity && a && strcmp(a,"integrity_check") == 0 && !b ? SQLITE_OK : SQLITE_DENY;
    switch (op) {
    case SQLITE_ATTACH: case SQLITE_DETACH:
    case SQLITE_CREATE_TEMP_INDEX: case SQLITE_CREATE_TEMP_TABLE:
    case SQLITE_CREATE_TEMP_TRIGGER: case SQLITE_CREATE_TEMP_VIEW:
    case SQLITE_CREATE_VTABLE: case SQLITE_DROP_VTABLE:
        return SQLITE_DENY;
    default: return SQLITE_OK;
    }
}
static int forced_memory_temp(void) { return sqlite3_compileoption_used("TEMP_STORE=3"); }
static int protect_policy(sqlite3 *db) { return sqlite3_set_authorizer(db,authorize,NULL); }
// The flag outlives both the progress callback and the joined watcher. Unlike
// Interrupt alone it also catches cancellation between prepare/step calls.
typedef struct { atomic_int cancelled; } adapter_cancel;
static adapter_cancel *cancel_new(void) {
    adapter_cancel *c = malloc(sizeof(*c));
    if (c) atomic_init(&c->cancelled,0);
    return c;
}
static void cancel_set(adapter_cancel *c) { atomic_store(&c->cancelled,1); }
static int cancel_progress(void *c) { return atomic_load(&((adapter_cancel*)c)->cancelled); }
static void cancel_install(sqlite3 *db, adapter_cancel *c) {
    sqlite3_progress_handler(db,c ? 1000 : 0,c ? cancel_progress : NULL,c);
}
static int integrity_policy(sqlite3 *db) {
    // Non-null capability is private C state, never an SQL-settable option.
    return sqlite3_set_authorizer(db,authorize,db);
}
static int owned_file(const char *path) {
    struct stat s;
    return lstat(path,&s) == 0 && S_ISREG(s.st_mode) &&
           s.st_uid == geteuid() && (s.st_mode & 07777) == 0600;
}
*/
import "C"

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"unsafe"
)

const (
	// MaxLength bounds each value AND SQLite's encoded row. This accommodates a
	// 1MiB source record plus row headers/ordinary metadata, not two 1MiB values.
	MaxLength    = 2 * 1024 * 1024
	MaxSQLLength = 64 * 1024
)

// Error contains only a SQLite result code, never SQL, paths or ledger values.
// Code may be an extended result code; Code & 255 is the primary result code.
type Error struct{ Code int }

func (e *Error) Error() string { return fmt.Sprintf("sqlite code %d", e.Code) }
func result(rc C.int) error {
	if rc == C.SQLITE_OK {
		return nil
	}
	return &Error{Code: int(rc)}
}
func misuse() error { return result(C.SQLITE_MISUSE) }

// DB owns a native connection and its private VFS policy. mu protects only the
// native handle's lifetime against Interrupt, never sqlite3_step.
type DB struct {
	mu     sync.Mutex
	handle *C.sqlite3
	vfs    *C.adapter_vfs
	active *Rows
}

// Open opens an EXISTING regular file owned by the effective user with mode
// exactly 0600, in either mode. The caller must create new files exclusively
// (O_EXCL,0600), and own/protect the parent directory against path replacement.
// The path is a literal filename (no URI, in-memory name, symlink or creation).
// This is not a hostile-filesystem sandbox: validation is subject to TOCTOU if
// the caller allows concurrent replacement. Mobile file-protection attributes
// of the database, parent directory and rollback journal remain caller duties.
//
// Scratch-file creation is denied by the VFS, so a disk-spilling sort fails
// rather than putting data in an unprotected global temp directory. PRAGMA,
// ATTACH/DETACH, virtual table DDL and temporary schema creation are denied
// after configuration. Use only application-owned schemas and SQL: this is not
// an arbitrary-SQL sandbox (including any globally auto-registered extensions).
func Open(path string, writable bool) (*DB, error) {
	return OpenContext(context.Background(), path, writable)
}

// OpenContext is Open with cancellation during native configuration. The initial
// filesystem open cannot be interrupted before SQLite returns its handle.
func OpenContext(ctx context.Context, path string, writable bool) (*DB, error) {
	if ctx == nil {
		return nil, misuse()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if path == "" || path == ":memory:" || strings.HasPrefix(path, "file:") || strings.IndexByte(path, 0) >= 0 {
		return nil, misuse()
	}
	if C.sqlite3_libversion_number() < 3037000 || C.sqlite3_threadsafe() == 0 {
		return nil, misuse()
	}
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	if C.owned_file(cp) == 0 {
		return nil, result(C.SQLITE_CANTOPEN)
	}
	v := C.av_new()
	if v == nil {
		return nil, result(C.SQLITE_NOMEM)
	}
	db := &DB{vfs: v}
	flags := C.int(C.SQLITE_OPEN_READONLY | C.SQLITE_OPEN_FULLMUTEX | C.SQLITE_OPEN_PRIVATECACHE | C.SQLITE_OPEN_NOFOLLOW)
	if writable {
		flags = C.SQLITE_OPEN_READWRITE | C.SQLITE_OPEN_FULLMUTEX | C.SQLITE_OPEN_PRIVATECACHE | C.SQLITE_OPEN_NOFOLLOW
	}
	rc := C.sqlite3_open_v2(cp, &db.handle, flags, v.vfs.zName)
	if rc != C.SQLITE_OK {
		db.Close()
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return nil, result(rc)
	}
	join, err := db.watchContext(ctx)
	if err != nil {
		db.Close()
		return nil, err
	}
	defer func() {
		if join != nil {
			join()
		}
	}()
	fail := func(err error) (*DB, error) {
		join()
		join = nil
		db.Close()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}
	if C.owned_file(cp) == 0 {
		return fail(result(C.SQLITE_CANTOPEN))
	}
	C.sqlite3_extended_result_codes(db.handle, 1)
	C.sqlite3_limit(db.handle, C.SQLITE_LIMIT_LENGTH, MaxLength)
	C.sqlite3_limit(db.handle, C.SQLITE_LIMIT_SQL_LENGTH, MaxSQLLength)
	C.sqlite3_limit(db.handle, C.SQLITE_LIMIT_VARIABLE_NUMBER, 256)
	C.sqlite3_limit(db.handle, C.SQLITE_LIMIT_ATTACHED, 0)
	C.sqlite3_limit(db.handle, C.SQLITE_LIMIT_WORKER_THREADS, 0)
	if err := result(C.harden(db.handle)); err != nil {
		return fail(err)
	}
	pragmas := []string{"PRAGMA cache_size=-8192", "PRAGMA mmap_size=0", "PRAGMA temp_store=FILE"}
	if writable {
		pragmas = append(pragmas, "PRAGMA journal_mode=DELETE", "PRAGMA synchronous=FULL")
	} else {
		pragmas = append(pragmas, "PRAGMA query_only=ON")
	}
	for _, q := range pragmas {
		if err := ctx.Err(); err != nil {
			return fail(err)
		}
		if err := db.Exec(q); err != nil {
			return fail(err)
		}
	}
	// SQLITE_TEMP_STORE=3 builds cannot honor temp_store=FILE. Reject them.
	if C.forced_memory_temp() != 0 {
		return fail(misuse())
	}
	expected := map[string]string{"cache_size": "-8192", "mmap_size": "0", "temp_store": "1"}
	if writable {
		expected["journal_mode"] = "delete"
		expected["synchronous"] = "2"
	} else {
		expected["query_only"] = "1"
	}
	for name, want := range expected {
		if err := ctx.Err(); err != nil {
			return fail(err)
		}
		r, err := db.Query("PRAGMA " + name)
		if err != nil {
			return fail(err)
		}
		ok := r.Next() && r.Text(0) == want
		err = r.Close()
		if err != nil {
			return fail(err)
		}
		if !ok {
			return fail(misuse())
		}
	}
	if err := result(C.protect_policy(db.handle)); err != nil {
		return fail(err)
	}
	join()
	join = nil
	if err := ctx.Err(); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

// watchContext requires serial ownership and must be joined before close or
// reuse. It must not be nested on the same DB (one native progress handler).
func (db *DB) watchContext(ctx context.Context) (func(), error) {
	flag := C.cancel_new()
	if flag == nil {
		return nil, result(C.SQLITE_NOMEM)
	}
	C.cancel_install(db.handle, flag)
	stop, done := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		select {
		case <-ctx.Done():
			C.cancel_set(flag)
			db.Interrupt()
		case <-stop:
		}
	}()
	return func() {
		close(stop)
		<-done
		C.cancel_install(db.handle, nil)
		C.free(unsafe.Pointer(flag))
	}, nil
}

// IntegrityCheck runs only the fixed integrity_check PRAGMA on this connection,
// with the same fail-closed VFS and limits as ordinary queries. Diagnostics are
// reduced to result codes: corrupt table names, values and paths never escape.
// No Rows may be active. The temporary authorization is restored on every exit;
// callers cannot enable PRAGMAs via SQL. Like other methods it has one owner.
func (db *DB) IntegrityCheck(ctx context.Context) (err error) {
	if ctx == nil || db == nil || db.handle == nil {
		return misuse()
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if db.active != nil {
		return result(C.SQLITE_BUSY)
	}
	join, err := db.watchContext(ctx)
	if err != nil {
		return err
	}
	defer func() {
		join()
		if ctx.Err() != nil {
			err = ctx.Err()
		}
	}()
	if err = result(C.integrity_policy(db.handle)); err != nil {
		return err
	}
	defer func() {
		restore := result(C.protect_policy(db.handle))
		if err == nil {
			err = restore
		}
	}()
	rows, err := db.Query("PRAGMA integrity_check")
	if err != nil {
		return err
	}
	valid := rows.Next() && rows.Text(0) == "ok"
	valid = !rows.Next() && valid
	if err = rows.Close(); err != nil {
		return err
	}
	if !valid {
		return result(C.SQLITE_CORRUPT)
	}
	return nil
}

func (db *DB) prepare(query string, args []any) (*C.sqlite3_stmt, error) {
	if db == nil || db.handle == nil {
		return nil, misuse()
	}
	if db.active != nil {
		return nil, result(C.SQLITE_BUSY)
	}
	if len(query) > MaxSQLLength {
		return nil, result(C.SQLITE_TOOBIG)
	}
	if strings.IndexByte(query, 0) >= 0 {
		return nil, misuse()
	}
	cq := C.CString(query)
	defer C.free(unsafe.Pointer(cq))
	var stmt *C.sqlite3_stmt
	var tail *C.char
	rc := C.sqlite3_prepare_v2(db.handle, cq, C.int(len(query)+1), &stmt, &tail)
	if rc != C.SQLITE_OK {
		if stmt != nil {
			C.sqlite3_finalize(stmt)
		}
		return nil, result(rc)
	}
	bad := func(err error) (*C.sqlite3_stmt, error) { C.sqlite3_finalize(stmt); return nil, err }
	if stmt == nil {
		return bad(misuse())
	}
	// Parse any tail before running the first statement. Accept whitespace and
	// comments, reject a second statement (even without bind parameters).
	var extra *C.sqlite3_stmt
	rc = C.sqlite3_prepare_v2(db.handle, tail, -1, &extra, nil)
	if extra != nil {
		C.sqlite3_finalize(extra)
		return bad(misuse())
	}
	if rc != C.SQLITE_OK {
		return bad(result(rc))
	}
	if int(C.sqlite3_bind_parameter_count(stmt)) != len(args) {
		return bad(result(C.SQLITE_RANGE))
	}
	for i, a := range args {
		n := C.int(i + 1)
		switch x := a.(type) {
		case nil:
			rc = C.sqlite3_bind_null(stmt, n)
		case bool:
			value := C.sqlite3_int64(0)
			if x {
				value = 1
			}
			rc = C.sqlite3_bind_int64(stmt, n, value)
		case int:
			rc = C.sqlite3_bind_int64(stmt, n, C.sqlite3_int64(x))
		case int64:
			rc = C.sqlite3_bind_int64(stmt, n, C.sqlite3_int64(x))
		case string:
			if len(x) > MaxLength {
				return bad(result(C.SQLITE_TOOBIG))
			}
			p := C.CString(x)
			rc = C.bind_text(stmt, n, p, C.int(len(x)))
			C.free(unsafe.Pointer(p)) // SQLITE_TRANSIENT copied the exact bytes.
		default:
			return bad(result(C.SQLITE_MISMATCH))
		}
		if rc != C.SQLITE_OK {
			return bad(result(rc))
		}
	}
	return stmt, nil
}

// Exec executes exactly one statement, discarding any result rows. It does not
// wrap transactions, retry SQLITE_BUSY, or escape/modify the query.
func (db *DB) Exec(query string, args ...any) error {
	stmt, err := db.prepare(query, args)
	if err != nil {
		return err
	}
	for {
		rc := C.sqlite3_step(stmt)
		if rc == C.SQLITE_ROW {
			continue
		}
		final := C.sqlite3_finalize(stmt)
		if rc != C.SQLITE_DONE {
			return result(rc)
		}
		return result(final)
	}
}

// Query prepares and binds; execution begins at Next. Even after exhaustion,
// Close is required before another statement on this DB (or call DB.Close).
func (db *DB) Query(query string, args ...any) (*Rows, error) {
	stmt, err := db.prepare(query, args)
	if err != nil {
		return nil, err
	}
	r := &Rows{db: db, stmt: stmt}
	db.active = r
	return r, nil
}

// Rows owns one native statement. Text returns an owned Go string, including
// embedded NULs. Accessors require a current row and a zero-based column index;
// misuse returns a zero value and sets Err to SQLITE_MISUSE. SQLite performs
// its usual text/integer conversions; callers choose appropriate SQL types.
type Rows struct {
	db   *DB
	stmt *C.sqlite3_stmt
	row  bool
	done bool
	err  error
}

func (r *Rows) Next() bool {
	if r == nil || r.stmt == nil || r.done || r.err != nil {
		return false
	}
	r.row = false
	rc := C.sqlite3_step(r.stmt)
	if rc == C.SQLITE_ROW {
		r.row = true
		return true
	}
	r.done = true
	if rc != C.SQLITE_DONE {
		r.err = result(rc)
	}
	return false
}
func (r *Rows) column(i int) bool {
	if r == nil {
		return false
	}
	if r.stmt == nil || !r.row || r.err != nil || i < 0 || i >= int(C.sqlite3_column_count(r.stmt)) {
		if r.err == nil {
			r.err = misuse()
		}
		return false
	}
	return true
}
func (r *Rows) Text(i int) string {
	if !r.column(i) {
		return ""
	}
	p := C.sqlite3_column_text(r.stmt, C.int(i))
	n := C.sqlite3_column_bytes(r.stmt, C.int(i))
	if p == nil {
		if C.sqlite3_errcode(r.db.handle) == C.SQLITE_NOMEM {
			r.err = result(C.SQLITE_NOMEM)
		}
		return ""
	}
	return C.GoStringN((*C.char)(unsafe.Pointer(p)), n)
}
func (r *Rows) Int64(i int) int64 {
	if !r.column(i) {
		return 0
	}
	return int64(C.sqlite3_column_int64(r.stmt, C.int(i)))
}
func (r *Rows) IsNull(i int) bool {
	if !r.column(i) {
		return false
	}
	return C.sqlite3_column_type(r.stmt, C.int(i)) == C.SQLITE_NULL
}
func (r *Rows) Err() error {
	if r == nil {
		return misuse()
	}
	return r.err
}

// Close is idempotent and returns a prior iteration/access error if present.
func (r *Rows) Close() error {
	if r == nil {
		return nil
	}
	if r.stmt != nil {
		rc := C.sqlite3_finalize(r.stmt)
		r.stmt = nil
		r.row = false
		r.done = true
		if r.err == nil {
			r.err = result(rc)
		}
		if r.db.active == r {
			r.db.active = nil
		}
	}
	return r.err
}

// Close finalizes outstanding Rows before closing the connection. Uncommitted
// transactions roll back. It is idempotent; it may race ONLY with Interrupt.
func (db *DB) Close() error {
	if db == nil {
		return nil
	}
	var err error
	if db.active != nil {
		err = db.active.Close()
	}
	db.mu.Lock()
	defer db.mu.Unlock()
	if db.handle != nil {
		rc := C.sqlite3_close(db.handle)
		if rc != C.SQLITE_OK {
			return result(rc)
		}
		db.handle = nil
	}
	C.av_free(db.vfs)
	db.vfs = nil
	return err
}

// Interrupt is safe concurrently with execution and Close. Like SQLite itself,
// it only affects work already executing, not a future Next/Exec. Callers must
// synchronize their cancellation goroutine before starting unrelated work.
func (db *DB) Interrupt() {
	if db == nil {
		return
	}
	db.mu.Lock()
	defer db.mu.Unlock()
	if db.handle != nil {
		C.sqlite3_interrupt(db.handle)
	}
}

// Changes reports sqlite3_changes64 for the last completed INSERT/UPDATE/DELETE.
// A closed DB reports zero. It is not a cumulative counter or a row count.
func (db *DB) Changes() int64 {
	if db == nil || db.handle == nil {
		return 0
	}
	return int64(C.sqlite3_changes64(db.handle))
}
