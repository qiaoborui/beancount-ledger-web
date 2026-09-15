package mobilegit

import (
	"bytes"
	"compress/zlib"
	"context"
	"crypto/sha1"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-git/go-git/v5/plumbing"
)

func TestPackPreflightRejectsActualLengthMismatch(t *testing.T) {
	for _, test := range []struct {
		name     string
		kind     byte
		declared byte
		actual   int
		code     string
	}{
		{"delta-inflate-bomb", 7, 1, 65 << 20, "git.limit_exceeded"},
		{"short-blob", 3, 2, 1, "git.invalid_request"},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "cache")
			repository, err := openStorage(root)
			if err != nil {
				t.Fatal(err)
			}
			storage, err := newFetchStorage(context.Background(), repository.Storer, root)
			if err != nil {
				t.Fatal(err)
			}
			pack := bytes.NewBufferString("PACK")
			_ = binary.Write(pack, binary.BigEndian, uint32(2))
			_ = binary.Write(pack, binary.BigEndian, uint32(1))
			pack.WriteByte(test.kind<<4 | test.declared)
			if test.kind == 7 {
				pack.Write(make([]byte, 20))
			}
			compressed := zlib.NewWriter(pack)
			chunk := make([]byte, 32<<10)
			for remaining := test.actual; remaining > 0; {
				n := min(remaining, len(chunk))
				if _, err := compressed.Write(chunk[:n]); err != nil {
					t.Fatal(err)
				}
				remaining -= n
			}
			if err := compressed.Close(); err != nil {
				t.Fatal(err)
			}
			hash := sha1.Sum(pack.Bytes())
			pack.Write(hash[:])
			writer, err := storage.PackfileWriter()
			if err != nil {
				t.Fatal(err)
			}
			if _, err := writer.Write(pack.Bytes()); err != nil {
				t.Fatal(err)
			}
			assertCode(t, writer.Close(), test.code)
		})
	}
}

func TestCancellationBeforeRequestRegistration(t *testing.T) {
	const id = "pre-registration-fixture"
	DispatchJSON(`{"version":1,"operation":"cancel","requestID":"` + id + `"}`)
	root := t.TempDir()
	snapshot := filepath.Join(root, "snapshot")
	write(t, snapshot, "main.bean", "; cancel before dispatch\n")
	raw, _ := json.Marshal(request{Version: 1, Operation: "commit", RequestID: id,
		StorageRoot: filepath.Join(root, "cache"), Directory: snapshot, Message: "Must be cancelled"})
	var result response
	if err := json.Unmarshal([]byte(DispatchJSON(string(raw))), &result); err != nil {
		t.Fatal(err)
	}
	if result.Error == nil || result.Error.Code != "git.cancelled" {
		t.Fatalf("early cancellation lost: %+v", result)
	}
	if _, err := os.Stat(filepath.Join(root, "cache")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("cancelled request created cache")
	}
}

func TestHTTPSRedirectsPreserveCredentialOrigin(t *testing.T) {
	original, _ := http.NewRequest(http.MethodGet, "https://git.example/repo.git/info/refs", nil)
	for _, test := range []struct {
		url string
		ok  bool
	}{
		{"https://git.example/redirect/info/refs", true},
		{"https://GIT.EXAMPLE/redirect/info/refs", true},
		{"https://evil.example/redirect/info/refs", false},
		{"https://git.example.evil.example/redirect/info/refs", false},
		{"https://git.example:8443/redirect/info/refs", false},
		{"http://git.example/redirect/info/refs", false},
		{"https://token@git.example/redirect/info/refs", false},
	} {
		next, _ := http.NewRequest(http.MethodGet, test.url, nil)
		err := sameHostHTTPSRedirect(next, []*http.Request{original})
		if (err == nil) != test.ok {
			t.Errorf("redirect %s: %v", test.url, err)
		}
	}
	assertCode(t, sameHostHTTPSRedirect(original, []*http.Request{original, original, original, original, original}), "git.invalid_request")
}

func TestIncomingPackRejectsDeclaredObjectBudgetsAndCleansTemporaryFiles(t *testing.T) {
	for _, kind := range []string{"count", "object-size", "truncated", "transfer-size", "cancelled"} {
		t.Run(kind, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "cache")
			repository, err := openStorage(root)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			storage, err := newFetchStorage(ctx, repository.Storer, root)
			if err != nil {
				t.Fatal(err)
			}
			writer, err := storage.PackfileWriter()
			if err != nil {
				t.Fatal(err)
			}
			pack := bytes.NewBufferString("PACK")
			_ = binary.Write(pack, binary.BigEndian, uint32(2))
			count := uint32(1)
			if kind == "count" {
				count = maxFetchObjects + 1
			}
			_ = binary.Write(pack, binary.BigEndian, count)
			if kind == "object-size" {
				size := int64(maxFileBytes + 1)
				first := byte(3<<4) | byte(size&15)
				size >>= 4
				for size > 0 {
					pack.WriteByte(first | 0x80)
					first = byte(size & 127)
					size >>= 7
				}
				pack.WriteByte(first)
			}
			if kind == "transfer-size" {
				writer.(*fetchPackWriter).remaining = 1
			}
			if kind == "cancelled" {
				cancel()
			}
			_, writeErr := writer.Write(pack.Bytes())
			closeErr := writer.Close()
			if kind == "cancelled" {
				if !errors.Is(writeErr, context.Canceled) || !errors.Is(closeErr, context.Canceled) {
					t.Fatalf("cancelled write=%v close=%v", writeErr, closeErr)
				}
			} else if kind == "truncated" {
				if closeErr == nil {
					t.Fatal("truncated pack accepted")
				}
			} else {
				assertCode(t, closeErr, "git.limit_exceeded")
			}
			leftovers, _ := filepath.Glob(filepath.Join(root, "mobilegit-fetch-*.pack"))
			if len(leftovers) != 0 {
				t.Fatalf("temporary pack retained: %v", leftovers)
			}
		})
	}
}

func TestExpandedObjectAndCacheBudgets(t *testing.T) {
	root := filepath.Join(t.TempDir(), "cache")
	repository, err := openStorage(root)
	if err != nil {
		t.Fatal(err)
	}
	storage, err := newFetchStorage(context.Background(), repository.Storer, root)
	if err != nil {
		t.Fatal(err)
	}
	for _, size := range []int64{-1, maxFileBytes + 1} {
		writer, header, err := storage.LazyWriter()
		if err != nil {
			t.Fatal(err)
		}
		assertCode(t, header(plumbing.BlobObject, size), "git.limit_exceeded")
		_ = writer.Close()
	}
	storage.remaining = 1
	writer, header, err := storage.LazyWriter()
	if err != nil {
		t.Fatal(err)
	}
	assertCode(t, header(plumbing.BlobObject, 2), "git.limit_exceeded")
	_ = writer.Close()
	file, err := os.Create(filepath.Join(root, "cache-budget-fixture"))
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(maxCacheBytes + 1); err != nil {
		t.Fatal(err)
	}
	_ = file.Close()
	_, err = newFetchStorage(context.Background(), repository.Storer, root)
	assertCode(t, err, "git.limit_exceeded")
}

func TestStreamingHTTPBodyBudget(t *testing.T) {
	body := &boundedHTTPBody{ReadCloser: io.NopCloser(bytes.NewBufferString("12345")), remaining: 4}
	_, err := io.ReadAll(body)
	assertCode(t, err, "git.limit_exceeded")
	body = &boundedHTTPBody{ReadCloser: io.NopCloser(bytes.NewBufferString("1234")), remaining: 4}
	value, err := io.ReadAll(body)
	if err != nil || string(value) != "1234" {
		t.Fatalf("exact limit body=%q err=%v", value, err)
	}
}
