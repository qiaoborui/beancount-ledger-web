package app

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

var runtimeJSONDriver = &runtimeJSONCaptureDriver{}

func init() {
	sql.Register("runtime-json-capture", runtimeJSONDriver)
}

type runtimeJSONCaptureDriver struct {
	mu   sync.Mutex
	args []driver.NamedValue
}

func (d *runtimeJSONCaptureDriver) Open(string) (driver.Conn, error) {
	return &runtimeJSONCaptureConn{driver: d}, nil
}

type runtimeJSONCaptureConn struct {
	driver *runtimeJSONCaptureDriver
}

func (c *runtimeJSONCaptureConn) Prepare(string) (driver.Stmt, error) {
	return nil, driver.ErrSkip
}

func (c *runtimeJSONCaptureConn) Close() error { return nil }

func (c *runtimeJSONCaptureConn) Begin() (driver.Tx, error) {
	return nil, errors.New("transactions are not supported")
}

func (c *runtimeJSONCaptureConn) ExecContext(_ context.Context, _ string, args []driver.NamedValue) (driver.Result, error) {
	c.driver.mu.Lock()
	c.driver.args = append([]driver.NamedValue(nil), args...)
	c.driver.mu.Unlock()
	return driver.RowsAffected(1), nil
}

func TestPostgresRuntimeStoreWritesJSONAsText(t *testing.T) {
	runtimeJSONDriver.mu.Lock()
	runtimeJSONDriver.args = nil
	runtimeJSONDriver.mu.Unlock()

	db, err := sql.Open("runtime-json-capture", "")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	store := &postgresRuntimeStore{db: db}
	if err := store.PutJSON(context.Background(), "auth", "passkeys", map[string]any{"ok": true}); err != nil {
		t.Fatal(err)
	}

	runtimeJSONDriver.mu.Lock()
	args := append([]driver.NamedValue(nil), runtimeJSONDriver.args...)
	runtimeJSONDriver.mu.Unlock()
	if len(args) != 3 {
		t.Fatalf("captured args=%#v", args)
	}
	if _, ok := args[2].Value.(string); !ok {
		t.Fatalf("JSONB value type=%T, want string so pgx does not encode it as bytea", args[2].Value)
	}
}

func TestPostgresRuntimeStoreRoundTrip(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := openPostgres(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store, err := NewRuntimeStoreWithDB(db)
	if err != nil {
		t.Fatal(err)
	}
	scope := fmt.Sprintf("integration-%d", time.Now().UnixNano())
	defer db.ExecContext(context.Background(), `DELETE FROM runtime_json WHERE scope = $1`, scope)

	type payload struct {
		Enabled bool     `json:"enabled"`
		Names   []string `json:"names"`
	}
	want := payload{Enabled: true, Names: []string{"runtime", "postgres"}}
	if err := store.PutJSON(context.Background(), scope, "round-trip", want); err != nil {
		t.Fatal(err)
	}
	var got payload
	ok, err := store.GetJSON(context.Background(), scope, "round-trip", &got)
	if err != nil {
		t.Fatal(err)
	}
	if !ok || !got.Enabled || strings.Join(got.Names, ",") != strings.Join(want.Names, ",") {
		t.Fatalf("round trip ok=%v got=%#v", ok, got)
	}
}

func TestFilesystemRuntimeStorePreservesLegacyPaths(t *testing.T) {
	root := t.TempDir()
	store := newFilesystemRuntimeStore(root)
	type payload struct {
		Value string `json:"value"`
	}
	if err := store.PutJSON(context.Background(), "auth", "passkeys", payload{Value: "ok"}); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(root, "passkeys.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"value": "ok"`) {
		t.Fatalf("legacy passkey path was not written:\n%s", raw)
	}
	var got payload
	ok, err := store.GetJSON(context.Background(), "auth", "passkeys", &got)
	if err != nil || !ok || got.Value != "ok" {
		t.Fatalf("GetJSON ok=%v got=%#v err=%v", ok, got, err)
	}
}

func TestFilesystemRuntimeStoreLockSerializes(t *testing.T) {
	store := newFilesystemRuntimeStore(t.TempDir())
	order := []string{}
	var orderMu sync.Mutex
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	done := make(chan struct{}, 2)

	go func() {
		_ = store.WithLock(context.Background(), "same", func() error {
			orderMu.Lock()
			order = append(order, "first")
			orderMu.Unlock()
			close(firstStarted)
			<-releaseFirst
			return nil
		})
		done <- struct{}{}
	}()

	<-firstStarted
	go func() {
		_ = store.WithLock(context.Background(), "same", func() error {
			orderMu.Lock()
			order = append(order, "second")
			orderMu.Unlock()
			return nil
		})
		done <- struct{}{}
	}()

	time.Sleep(25 * time.Millisecond)
	orderMu.Lock()
	if len(order) != 1 || order[0] != "first" {
		t.Fatalf("second lock entered before first released: %#v", order)
	}
	orderMu.Unlock()
	close(releaseFirst)
	<-done
	<-done

	orderMu.Lock()
	defer orderMu.Unlock()
	if len(order) != 2 || order[1] != "second" {
		t.Fatalf("locks did not serialize in order: %#v", order)
	}
}
