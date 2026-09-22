package sqlite

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func newPath(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "synthetic.sqlite")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}
func openTest(t *testing.T, path string, writable bool) *DB {
	t.Helper()
	db, err := Open(path, writable)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := db.Close(); err != nil {
			t.Error(err)
		}
	})
	return db
}
func exec(t *testing.T, db *DB, q string, args ...any) {
	t.Helper()
	if err := db.Exec(q, args...); err != nil {
		t.Fatal(err)
	}
}
func query(t *testing.T, db *DB, q string, args ...any) *Rows {
	t.Helper()
	r, err := db.Query(q, args...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = r.Close() })
	return r
}
func code(t *testing.T, err error, want int) {
	t.Helper()
	var e *Error
	if !errors.As(err, &e) || e.Code&255 != want {
		t.Fatalf("error %v, want primary code %d", err, want)
	}
	if err.Error() != fmt.Sprintf("sqlite code %d", e.Code) {
		t.Fatalf("unsafe error: %q", err)
	}
}
func count(t *testing.T, db *DB) int64 {
	t.Helper()
	r := query(t, db, "SELECT count(*) FROM entries")
	defer r.Close()
	if !r.Next() {
		t.Fatal(r.Err())
	}
	return r.Int64(0)
}

func TestNativeConnectionHardening(t *testing.T) {
	// Apple's SQLite omits loadable extensions. Exercise native configuration
	// with a canonical path so SQLITE_OPEN_NOFOLLOW cannot mask its result.
	path, err := filepath.EvalSymlinks(newPath(t))
	if err != nil {
		t.Fatal(err)
	}
	db := openTest(t, path, true)
	exec(t, db, "CREATE TABLE entries (value TEXT) STRICT")
	exec(t, db, "INSERT INTO entries VALUES (?)", "synthetic")
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db = openTest(t, path, false)
	r := query(t, db, "SELECT value FROM entries")
	if !r.Next() || r.Text(0) != "synthetic" || r.Next() {
		t.Fatal("native writable/read-only connection did not preserve its row")
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestBindExactTextAndTypes(t *testing.T) {
	db := openTest(t, newPath(t), true)
	exec(t, db, "CREATE TABLE entries (id INTEGER PRIMARY KEY, text TEXT, amount TEXT, n INTEGER, flag INTEGER, nullable TEXT)")
	decimal := "-123456789012345678901234567890.00000000000000000000000000100"
	values := []string{"", "中文 café 🙂", "start\x00中\x00end", "\x00", strings.Repeat("x", 1024*1024)}
	for i, s := range values {
		exec(t, db, "INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?)", i, s, decimal, int64(math.MinInt64), true, nil)
		if db.Changes() != 1 {
			t.Fatal("incorrect changes")
		}
	}
	r := query(t, db, "SELECT text, amount, n, flag, nullable FROM entries ORDER BY id")
	var saved []string
	for _, want := range values {
		// Stress the native SQLITE_TRANSIENT copy and Go string ownership.
		runtime.GC()
		if !r.Next() {
			t.Fatalf("missing row: %v", r.Err())
		}
		got := r.Text(0)
		if got != want || r.Text(1) != decimal || r.Int64(2) != math.MinInt64 || r.Int64(3) != 1 || !r.IsNull(4) || r.IsNull(0) {
			t.Fatal("value did not round-trip exactly")
		}
		if r.Text(4) != "" || r.Int64(4) != 0 {
			t.Fatal("unexpected NULL conversion")
		}
		saved = append(saved, got)
	}
	if r.Next() || r.Err() != nil {
		t.Fatal(r.Err())
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	exec(t, db, "DELETE FROM entries")
	if db.Changes() != int64(len(values)) {
		t.Fatal("incorrect delete count")
	}
	for i, want := range values {
		if saved[i] != want {
			t.Fatal("returned string not owned")
		}
	}
	r = query(t, db, "SELECT ?, ?, ?", false, int64(math.MaxInt64), int(-7))
	if !r.Next() || r.Int64(0) != 0 || r.Int64(1) != math.MaxInt64 || r.Int64(2) != -7 {
		t.Fatal("integer/bool bind")
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestTransientBindingsOutliveCall(t *testing.T) {
	db := openTest(t, newPath(t), true)
	makeRows := func() *Rows {
		s := strings.Repeat("Z中\x00", 100000)
		return query(t, db, "SELECT ?", s)
	}
	r := makeRows()
	runtime.GC()
	if !r.Next() || r.Text(0) != strings.Repeat("Z中\x00", 100000) {
		t.Fatal("dangling native text binding")
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestTransactionsRollbackAndReadonlyReopen(t *testing.T) {
	path := newPath(t)
	db := openTest(t, path, true)
	exec(t, db, "CREATE TABLE entries (id INTEGER PRIMARY KEY, value TEXT)")
	exec(t, db, "BEGIN IMMEDIATE")
	exec(t, db, "INSERT INTO entries VALUES (?,?)", 1, "committed")
	exec(t, db, "COMMIT")
	exec(t, db, "BEGIN")
	exec(t, db, "INSERT INTO entries VALUES (?,?)", 2, "rolled back")
	exec(t, db, "ROLLBACK")
	if count(t, db) != 1 {
		t.Fatal("rollback lost")
	}
	exec(t, db, "BEGIN")
	exec(t, db, "INSERT INTO entries VALUES (?,?)", 3, "close rolls back")
	// DELETE journal is beside the protected database, not in global temp.
	stat, err := os.Stat(path + "-journal")
	if err != nil {
		t.Fatal(err)
	}
	if stat.Mode().Perm() != 0600 {
		t.Fatalf("journal mode %o", stat.Mode().Perm())
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path + "-journal"); !os.IsNotExist(err) {
		t.Fatal("journal was not deleted")
	}
	ro := openTest(t, path, false)
	if count(t, ro) != 1 {
		t.Fatal("close rollback/reopen failed")
	}
	code(t, ro.Exec("INSERT INTO entries VALUES (?,?)", 4, "not written"), 8) // READONLY
	if count(t, ro) != 1 {
		t.Fatal("readonly write succeeded")
	}
	code(t, ro.Exec("PRAGMA query_only=OFF"), 23) // AUTH
}

func TestOpenFilePolicyAndPrivacy(t *testing.T) {
	path := newPath(t)
	missing := filepath.Join(t.TempDir(), "SECRET_NOT_CREATED.sqlite")
	symlink := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(path, symlink); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"", ":memory:", "file:private?mode=memory", "bad\x00path", missing, t.TempDir(), symlink} {
		for _, write := range []bool{false, true} {
			db, err := Open(p, write)
			if db != nil || err == nil {
				if db != nil {
					db.Close()
				}
				t.Fatalf("unexpected open success for synthetic case")
			}
			var e *Error
			if !errors.As(err, &e) || err.Error() != fmt.Sprintf("sqlite code %d", e.Code) {
				t.Fatal("unsafe open error")
			}
		}
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatal("Open created missing file")
	}
	for _, mode := range []os.FileMode{0644, 0666, 0400, 0000} {
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
		for _, write := range []bool{true, false} {
			_, err := Open(path, write)
			code(t, err, 14)
		}
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.Repeat("SECRET_CORRUPT_FILE", 100)), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := Open(path, true)
	code(t, err, 26) // NOTADB
}

func TestLimitsAndRejectedBinds(t *testing.T) {
	db := openTest(t, newPath(t), true)
	exec(t, db, "CREATE TABLE entries (value TEXT)")
	for _, v := range []any{1.25, float32(2), []byte("SECRET_BYTES"), uint(4), int32(7), struct{}{}, (*string)(nil)} {
		code(t, db.Exec("INSERT INTO entries VALUES (?)", v), 20) // MISMATCH
	}
	for _, args := range [][]any{nil, {1, 2}} {
		code(t, db.Exec("INSERT INTO entries VALUES (?)", args...), 25)
	}
	code(t, db.Exec("SELECT 1", 1), 25)
	code(t, db.Exec("INSERT INTO entries VALUES (?)", strings.Repeat("x", MaxLength+1)), 18)
	code(t, db.Exec("SELECT "+strings.Repeat(" ", MaxSQLLength)), 18)
	// Each bound value fits, but the encoded record exceeds SQLITE_LIMIT_LENGTH.
	exec(t, db, "CREATE TABLE wide (a TEXT,b TEXT)")
	code(t, db.Exec("INSERT INTO wide VALUES (?,?)", strings.Repeat("a", 1024*1024), strings.Repeat("b", 1024*1024)), 18)
	code(t, db.Exec("SELECT randomblob(?)", MaxLength+1), 18)
	code(t, db.Exec("SELECT ?257", 1), 1)
	if count(t, db) != 0 {
		t.Fatal("failed bind executed write")
	}
	exec(t, db, "INSERT INTO entries VALUES (?)", "usable after failures")
}

func TestStatementBoundariesAndErrorPrivacy(t *testing.T) {
	db := openTest(t, newPath(t), true)
	exec(t, db, "CREATE TABLE entries (value TEXT UNIQUE)")
	exec(t, db, "INSERT INTO entries VALUES (?)", "SECRET_VALUE")
	code(t, db.Exec("INSERT INTO entries VALUES (?)", "SECRET_VALUE"), 19)
	for _, q := range []string{"", "-- comment", "SELECT 1\x00; DELETE FROM entries", "DELETE FROM entries; DELETE FROM entries"} {
		code(t, db.Exec(q), 21)
	}
	code(t, db.Exec("DELETE FROM entries; SECRET_INVALID_SQL"), 1)
	code(t, db.Exec("SELECT * FROM SECRET_TABLE"), 1)
	if count(t, db) != 1 {
		t.Fatal("first statement executed despite bad tail")
	}
	exec(t, db, "SELECT ?; /* harmless tail */ -- comment\n", "ok")
	exec(t, db, "SELECT 1; ; ; /* empty statements */")
	r := query(t, db, "INSERT INTO entries VALUES (?)", "SECRET_VALUE")
	if r.Next() {
		t.Fatal("unexpected row")
	}
	code(t, r.Err(), 19)
	code(t, r.Close(), 19)
	code(t, r.Close(), 19)
	exec(t, db, "INSERT INTO entries VALUES (?)", "still usable")
}

func TestPolicyCannotBeChanged(t *testing.T) {
	db := openTest(t, newPath(t), true)
	exec(t, db, "CREATE TABLE entries (value TEXT)")
	for _, q := range []string{
		"PRAGMA temp_store=MEMORY", "PRAGMA temp_store_directory='/SECRET_PATH'",
		"PRAGMA cache_size=1000000", "PRAGMA journal_mode=WAL", "PRAGMA query_only=OFF",
		"PRAGMA trusted_schema=ON", "PRAGMA writable_schema=ON", "PRAGMA mmap_size=10000000",
		"PRAGMA temp_store", "CREATE TEMP TABLE leak(value TEXT)",
		"CREATE TEMP VIEW leak AS SELECT 1", "ATTACH DATABASE ':memory:' AS another",
		"DETACH DATABASE another", "CREATE VIRTUAL TABLE ext USING fts5(value)",
	} {
		code(t, db.Exec(q), 23)
	}
	code(t, db.Exec("SELECT load_extension(?)", "/SECRET_EXTENSION"), 1)
	// VACUUM INTO goes through ATTACH authorization, even with a bound path.
	target := filepath.Join(t.TempDir(), "must-not-exist.sqlite")
	code(t, db.Exec("VACUUM INTO ?", target), 23)
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatal("VACUUM escaped file policy")
	}
}

func TestProtectedTempSortFailsClosed(t *testing.T) {
	db := openTest(t, newPath(t), true)
	exec(t, db, "CREATE TABLE entries (id INTEGER PRIMARY KEY, payload TEXT)")
	// Enough data to exceed the 8MiB cache and the native sorter's PMA buffer.
	// Only synthetic bytes are used. The DB/journal remain in t.TempDir().
	exec(t, db, `WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<16384)
        INSERT INTO entries SELECT x, printf('%01024d',16385-x) FROM n`)
	r := query(t, db, "SELECT payload FROM entries ORDER BY payload")
	for r.Next() {
	}
	code(t, r.Err(), 14) // CANTOPEN, not an unsafe global-temp fallback
	code(t, r.Close(), 14)
	// An index-provided ordering needs no sorter and continues to work.
	r = query(t, db, "SELECT id FROM entries ORDER BY id")
	n := int64(0)
	for r.Next() {
		n++
		if r.Int64(0) != n {
			t.Fatal("index ordering")
		}
	}
	if n != 16384 || r.Err() != nil {
		t.Fatalf("scan: %d, %v", n, r.Err())
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	// Small sorts may stay in SQLite memory; this is not a ban on SQL ORDER BY.
	r = query(t, db, "SELECT payload FROM entries WHERE id<4 ORDER BY payload")
	n = 0
	for r.Next() {
		n++
	}
	if n != 3 || r.Err() != nil {
		t.Fatal("small sort", r.Err())
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestRowsAndDBResourceLifetime(t *testing.T) {
	db := openTest(t, newPath(t), true)
	r := query(t, db, "SELECT 1 UNION ALL SELECT 2")
	code(t, db.Exec("SELECT 3"), 5) // BUSY while Rows live
	_, err := db.Query("SELECT 3")
	code(t, err, 5)
	if !r.Next() || r.Int64(0) != 1 {
		t.Fatal("first row")
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	if r.Next() {
		t.Fatal("closed rows advanced")
	}
	exec(t, db, "SELECT 3")
	r = query(t, db, "SELECT 4")
	if !r.Next() {
		t.Fatal(r.Err())
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if r.Next() {
		t.Fatal("DB.Close left a live statement")
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	code(t, db.Exec("SELECT 1"), 21)
	_, err = db.Query("SELECT 1")
	code(t, err, 21)
	if db.Changes() != 0 {
		t.Fatal("closed changes")
	}
	db.Interrupt()
}

func TestInvalidColumnAccess(t *testing.T) {
	for _, which := range []string{"before-next", "negative", "past-end", "after-done", "after-close"} {
		t.Run(which, func(t *testing.T) {
			db := openTest(t, newPath(t), true)
			r := query(t, db, "SELECT 1")
			i := 0
			switch which {
			case "negative":
				r.Next()
				i = -1
			case "past-end":
				r.Next()
				i = 1
			case "after-done":
				r.Next()
				r.Next()
			case "after-close":
				r.Close()
			}
			if r.Text(i) != "" || r.Int64(i) != 0 || r.IsNull(i) {
				t.Fatal("invalid accessor returned data")
			}
			code(t, r.Err(), 21)
			if r.Next() {
				t.Fatal("rows advanced after accessor error")
			}
			code(t, r.Close(), 21)
		})
	}
}

const expensiveQuery = `WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT sum(x) FROM n`

func interruptWhile(t *testing.T, db *DB, run func() error) {
	t.Helper()
	stop := make(chan struct{})
	exited := make(chan struct{})
	go func() {
		defer close(exited)
		tick := time.NewTicker(time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-stop:
				return
			case <-tick.C:
				db.Interrupt()
			}
		}
	}()
	start := time.Now()
	err := run()
	close(stop)
	<-exited        // no late interrupt of the next, unrelated query
	code(t, err, 9) // INTERRUPT
	if time.Since(start) > 5*time.Second {
		t.Fatal("interrupt blocked behind executing statement")
	}
}

func TestInterruptExecAndQuery(t *testing.T) {
	db := openTest(t, newPath(t), true)
	interruptWhile(t, db, func() error { return db.Exec(expensiveQuery) })
	r := query(t, db, expensiveQuery)
	interruptWhile(t, db, func() error {
		if r.Next() {
			t.Error("expensive query unexpectedly completed")
		}
		return r.Err()
	})
	code(t, r.Close(), 9)
	exec(t, db, "SELECT 1") // interrupt did not poison the connection
}

func TestInterruptConcurrentClose(t *testing.T) {
	path := newPath(t)
	for i := 0; i < 100; i++ {
		db := openTest(t, path, true)
		r := query(t, db, "SELECT 1")
		if !r.Next() {
			t.Fatal(r.Err())
		}
		stop := make(chan struct{})
		var wg sync.WaitGroup
		for j := 0; j < 4; j++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for {
					select {
					case <-stop:
						return
					default:
						db.Interrupt()
						runtime.Gosched()
					}
				}
			}()
		}
		if err := db.Close(); err != nil {
			t.Fatal(err)
		}
		close(stop)
		wg.Wait()
		if r.Next() {
			t.Fatal("statement survived close")
		}
		db.Interrupt()
	}
}

func TestIndependentVFSConnectionLifetimes(t *testing.T) {
	path := newPath(t)
	writer := openTest(t, path, true)
	exec(t, writer, "CREATE TABLE entries (value TEXT)")
	reader := openTest(t, path, false)
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if count(t, reader) != 0 {
		t.Fatal("other DB close invalidated VFS")
	}
	// SQLite registers each wrapper independently; no default VFS replacement.
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 25; j++ {
				db, err := Open(path, false)
				if err != nil {
					t.Error(err)
					return
				}
				if err := db.Exec("SELECT count(*) FROM entries"); err != nil {
					t.Error(err)
				}
				if err := db.Close(); err != nil {
					t.Error(err)
				}
			}
		}()
	}
	wg.Wait()
}

func TestNilZeroValues(t *testing.T) {
	for _, db := range []*DB{nil, {}} {
		db.Interrupt()
		if err := db.Close(); err != nil {
			t.Fatal(err)
		}
		code(t, db.Exec("SELECT 1"), 21)
		if db.Changes() != 0 {
			t.Fatal("zero changes")
		}
	}
	var r *Rows
	if r.Next() || r.Text(0) != "" || r.Int64(0) != 0 || r.IsNull(0) {
		t.Fatal("nil rows")
	}
	code(t, r.Err(), 21)
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestConstraintRollbackAndBusy(t *testing.T) {
	path := newPath(t)
	db := openTest(t, path, true)
	other := openTest(t, path, true)
	exec(t, db, "CREATE TABLE entries (value TEXT UNIQUE)")
	exec(t, db, "BEGIN IMMEDIATE")
	exec(t, db, "INSERT INTO entries VALUES (?)", "first")
	code(t, other.Exec("INSERT INTO entries VALUES (?)", "busy"), 5)
	code(t, db.Exec("INSERT INTO entries VALUES (?)", "first"), 19)
	exec(t, db, "ROLLBACK")
	if count(t, db) != 0 {
		t.Fatal("failed transaction not rolled back")
	}
	exec(t, other, "INSERT INTO entries VALUES (?)", "not busy")
	if count(t, db) != 1 {
		t.Fatal("database unusable after lock release")
	}
}

func TestFailedOpenAndStatementChurn(t *testing.T) {
	path := newPath(t)
	if err := os.WriteFile(path, []byte(strings.Repeat("synthetic-invalid", 100)), 0600); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 100; i++ {
		_, err := Open(path, true)
		code(t, err, 26)
	}
	db := openTest(t, newPath(t), true)
	for i := 0; i < 100; i++ {
		code(t, db.Exec("SELECT ?, ?", i, 1.5), 20)
		code(t, db.Exec("SELECT 1; SELECT 2"), 21)
		r := query(t, db, "SELECT ?", i)
		if !r.Next() || r.Int64(0) != int64(i) {
			t.Fatal("churn")
		}
		if err := r.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestInterruptedWriteRollsBack(t *testing.T) {
	db := openTest(t, newPath(t), true)
	exec(t, db, "CREATE TABLE entries (value INTEGER)")
	exec(t, db, "BEGIN")
	exec(t, db, "INSERT INTO entries VALUES (42)")
	interruptWhile(t, db, func() error {
		return db.Exec(`WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000)
            INSERT INTO entries SELECT x FROM n`)
	})
	// SQLite rolls back the whole explicit transaction for an interrupted DML.
	if count(t, db) != 0 {
		t.Fatal("interrupted write left partial transaction data")
	}
	exec(t, db, "BEGIN")
	exec(t, db, "INSERT INTO entries VALUES (7)")
	exec(t, db, "COMMIT")
	if count(t, db) != 1 {
		t.Fatal("connection unusable after interrupted DML")
	}
}

func assertPragmasDenied(t *testing.T, db *DB) {
	t.Helper()
	for _, q := range []string{"PRAGMA integrity_check", "PRAGMA integrity_check=1", "PRAGMA temp_store=MEMORY", "PRAGMA writable_schema=ON", "SELECT * FROM pragma_integrity_check", "SELECT * FROM pragma_temp_store"} {
		code(t, db.Exec(q), 23)
	}
}

func TestIntegrityCheckPolicyAndLifetime(t *testing.T) {
	path := newPath(t)
	db := openTest(t, path, true)
	exec(t, db, "CREATE TABLE entries (value INTEGER CHECK(value>0))")
	exec(t, db, "INSERT INTO entries VALUES (1)")
	for _, conn := range []*DB{db, openTest(t, path, false)} {
		assertPragmasDenied(t, conn)
		if err := conn.IntegrityCheck(context.Background()); err != nil {
			t.Fatal(err)
		}
		assertPragmasDenied(t, conn)
		r := query(t, conn, "SELECT value FROM entries")
		code(t, conn.IntegrityCheck(context.Background()), 5)
		if !r.Next() || r.Int64(0) != 1 {
			t.Fatal("busy integrity disrupted active rows")
		}
		if err := r.Close(); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if err := conn.IntegrityCheck(ctx); !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
		assertPragmasDenied(t, conn)
		code(t, conn.IntegrityCheck(nil), 21)
		if err := conn.Close(); err != nil {
			t.Fatal(err)
		}
		code(t, conn.IntegrityCheck(context.Background()), 21)
	}
}

// Change only equal-length schema text after closing every handle. This models
// untrusted on-disk input without relaxing the adapter's writable_schema policy.
func patchSchema(t *testing.T, path, old, replacement string) {
	t.Helper()
	if len(old) != len(replacement) {
		t.Fatal("schema patch changed length")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(b, []byte(old)) {
		t.Fatal("schema patch missing")
	}
	if err := os.WriteFile(path, bytes.ReplaceAll(b, []byte(old), []byte(replacement)), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestIntegrityCheckCorruptPrivacy(t *testing.T) {
	path := newPath(t)
	db := openTest(t, path, true)
	exec(t, db, "CREATE TABLE private_synthetic_name (value INTEGER CHECK(value>0))")
	exec(t, db, "INSERT INTO private_synthetic_name VALUES (1)")
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	patchSchema(t, path, "CHECK(value>0)", "CHECK(value>9)")
	db = openTest(t, path, true)
	err := db.IntegrityCheck(context.Background())
	code(t, err, 11)
	if err.Error() != "sqlite code 11" {
		t.Fatalf("diagnostic leaked: %q", err)
	}
	assertPragmasDenied(t, db)
	exec(t, db, "SELECT 1")
}

func TestIntegrityCheckExpressionSpillFailsClosed(t *testing.T) {
	path := newPath(t)
	db := openTest(t, path, true)
	exec(t, db, "CREATE TABLE entries (value INTEGER)")
	exec(t, db, "INSERT INTO entries VALUES (1)")
	items := make([]string, 80)
	for n := range items {
		items[n] = fmt.Sprintf("printf('%%0000001d',%d)", n)
	}
	exec(t, db, "CREATE INDEX crafted ON entries(CAST(value AS TEXT) IN ("+strings.Join(items, ",")+"))")
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	patchSchema(t, path, "%0000001d", "%0100000d")
	db = openTest(t, path, true)
	// SQLite may detect the rewritten index before spilling its ephemeral IN
	// btree. Both outcomes reject the index; TestProtectedTempSortFailsClosed
	// independently requires the VFS to deny scratch-file creation.
	err := db.IntegrityCheck(context.Background())
	var sqliteErr *Error
	if errors.As(err, &sqliteErr) && sqliteErr.Code&255 == 11 {
		code(t, err, 11)
	} else {
		code(t, err, 14)
	}
	assertPragmasDenied(t, db)
	exec(t, db, "SELECT value FROM entries NOT INDEXED")
}

func TestIntegrityCheckCancellationJoinsWatcher(t *testing.T) {
	db := openTest(t, newPath(t), true)
	exec(t, db, "CREATE TABLE entries (value INTEGER CHECK(value>0))")
	exec(t, db, `WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<500000) INSERT INTO entries SELECT x FROM n`)
	for pass := 0; pass < 5; pass++ {
		ctx, cancel := context.WithCancel(context.Background())
		finished := make(chan struct{})
		go func() { defer close(finished); time.Sleep(time.Millisecond); cancel() }()
		start := time.Now()
		err := db.IntegrityCheck(ctx)
		<-finished
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("check completed before cancellation: %v", err)
		}
		if time.Since(start) > 5*time.Second {
			t.Fatal("cancellation did not interrupt check")
		}
		assertPragmasDenied(t, db)
		exec(t, db, "SELECT 1")
	}
	if err := db.IntegrityCheck(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestOpenContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if db, err := OpenContext(ctx, newPath(t), false); db != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("%v %v", db, err)
	}
	_, err := OpenContext(nil, newPath(t), false)
	code(t, err, 21)
}

func TestIntegrityCheckReadOnlyPhysicalCorruption(t *testing.T) {
	path := newPath(t)
	db := openTest(t, path, true)
	exec(t, db, "CREATE TABLE entries (value TEXT)")
	exec(t, db, "INSERT INTO entries VALUES ('private-synthetic-value')")
	r := query(t, db, "SELECT rootpage FROM sqlite_schema WHERE name='entries'")
	if !r.Next() {
		t.Fatal(r.Err())
	}
	root := r.Int64(0)
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	pageSize := int64(b[16])<<8 | int64(b[17])
	if pageSize == 1 {
		pageSize = 65536
	}
	if root < 2 || root*pageSize > int64(len(b)) {
		t.Fatal("invalid test fixture root")
	}
	b[(root-1)*pageSize] = 0xff // invalid btree page type; schema remains readable
	if err := os.WriteFile(path, b, 0600); err != nil {
		t.Fatal(err)
	}
	db = openTest(t, path, false)
	err = db.IntegrityCheck(context.Background())
	code(t, err, 11)
	if err.Error() != "sqlite code 11" {
		t.Fatalf("diagnostic leaked: %q", err)
	}
	assertPragmasDenied(t, db)
	exec(t, db, "SELECT 1")
}
