package app

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

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
