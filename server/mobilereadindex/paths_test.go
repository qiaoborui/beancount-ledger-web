//go:build cgo

package mobilereadindex

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/borui/beancount-ledger-web/server/internal/readindex"
)

func TestPrivatePathConfinement(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	manifest, m := buildFixture(t, b, "one", stream(tx(1, "synthetic")))
	openFixture(t, b, "one", manifest, m)
	outside := newTestBridge(t)
	outside.Unlock()
	external, externalM := buildFixture(t, outside, "outside", stream(tx(1, "outside")))
	for _, path := range []string{"", "../outside", b.root + "/../outside", b.root + "-sibling/data", filepath.Join(outside.root, "outside.sqlite"), "file:/secret?mode=ro", strings.Repeat("x", maxPathBytes+1), "a\x00b", "a\xffb"} {
		result := b.Open(path, manifest)
		if !strings.Contains(result, `"error"`) || strings.Contains(result, path) && path != "" || len(result) > 100 {
			t.Fatalf("unsafe path response %.150s", result)
		}
	}
	wantCode(t, b.Build(filepath.Join(outside.root, "outside.stream"), "bad.sqlite"), "invalid_request")
	wantCode(t, b.Build("one.stream", filepath.Join(outside.root, "bad.sqlite")), "invalid_request")
	wantCode(t, b.Open(filepath.Join(outside.root, "outside.sqlite"), external), "invalid_request")
	// Both files and every directory below the root must be private, nonsymlink.
	for name, target := range map[string]string{"stream-link": filepath.Join(outside.root, "outside.stream"), "db-link": filepath.Join(outside.root, "outside.sqlite"), "dir-link": outside.root} {
		if err := os.Symlink(target, filepath.Join(b.root, name)); err != nil {
			t.Fatal(err)
		}
	}
	wantCode(t, b.Build("stream-link", "bad.sqlite"), "unavailable")
	wantCode(t, b.Open("db-link", external), "unavailable")
	wantCode(t, b.Open("dir-link/outside.sqlite", external), "unavailable")
	wantCode(t, b.Build("one.stream", "dir-link/new.sqlite"), "unavailable")
	wantCode(t, b.Build("one.stream", "db-link"), "unavailable")
	if err := os.Link(filepath.Join(outside.root, "outside.stream"), filepath.Join(b.root, "hardlink")); err != nil {
		t.Fatal(err)
	}
	wantCode(t, b.Build("hardlink", "bad.sqlite"), "unavailable")
	if err := os.Mkdir(filepath.Join(b.root, "public"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(b.root, "public"), 0755); err != nil {
		t.Fatal(err)
	}
	wantCode(t, b.Build("one.stream", "public/db"), "unavailable")
	for _, file := range []string{"one.stream", "one.sqlite"} {
		if err := os.Chmod(filepath.Join(b.root, file), 0640); err != nil {
			t.Fatal(err)
		}
		if file == "one.stream" {
			wantCode(t, b.Build(file, "bad.sqlite"), "unavailable")
		} else {
			wantCode(t, b.Open(file, manifest), "unavailable")
		}
		if err := os.Chmod(filepath.Join(b.root, file), 0600); err != nil {
			t.Fatal(err)
		}
	}
	fifo := filepath.Join(b.root, "fifo")
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	wantCode(t, b.Build("fifo", "bad.sqlite"), "unavailable")
	wantCode(t, b.Open("fifo", manifest), "unavailable")
	if _, err := openStream(fifo); !errors.Is(err, readindex.ErrUnavailable) {
		t.Fatal("FIFO opened")
	}
	if _, err := openStream(filepath.Join(b.root, "stream-link")); !errors.Is(err, readindex.ErrUnavailable) {
		t.Fatal("symlink opened")
	}
	// A failed path/open never replaces the selected revision or reads a fallback.
	if b.reader == nil {
		t.Fatal("lost reader")
	}
	page, err := b.reader.Transactions(context.Background(), readindex.PageRequest{})
	if err != nil || page.Revision != m.Revision || page.Revision == externalM.Revision {
		t.Fatal("selected revision changed")
	}
	// Private nested generations are supported, but parents must already exist.
	if err := os.Mkdir(filepath.Join(b.root, "generation"), 0700); err != nil {
		t.Fatal(err)
	}
	nested := b.Build("one.stream", "generation/index.sqlite")
	encoded, _ := encode(m, maxManifestBytes)
	if nested != encoded {
		t.Fatal("nested generation failed", nested)
	}
	wantCode(t, b.Build("one.stream", "missing/index.sqlite"), "unavailable")
	openFixture(t, b, "one", manifest, m)
}

func TestRootPinningAndOwnership(t *testing.T) {
	for _, kind := range []string{"relative", "missing", "public", "symlink", "ancestor-link", "ancestor-writable", "replaced", "foreign"} {
		t.Run(kind, func(t *testing.T) {
			base := newTestBridge(t)
			root := base.root
			switch kind {
			case "relative":
				root = "derived"
			case "missing":
				root = filepath.Join(root, "missing")
			case "public":
				if err := os.Chmod(root, 0755); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				root = filepath.Join(filepath.Dir(root), "link")
				if err := os.Symlink(base.root, root); err != nil {
					t.Fatal(err)
				}
			case "ancestor-link":
				link := filepath.Join(filepath.Dir(root), "link")
				if err := os.Symlink(base.root, link); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(filepath.Join(base.root, "child"), 0700); err != nil {
					t.Fatal(err)
				}
				root = filepath.Join(link, "child")
			case "ancestor-writable":
				if err := os.Chmod(filepath.Dir(root), 0777); err != nil {
					t.Fatal(err)
				}
				defer os.Chmod(filepath.Dir(root), 0700)
			case "foreign":
				// Ownership predicate is testable without requiring chown/root privileges.
				info, err := os.Lstat(root)
				if err != nil {
					t.Fatal(err)
				}
				stat := *info.Sys().(*syscall.Stat_t)
				stat.Uid = uint32(os.Geteuid()) + 1
				if owned(foreignInfo{info, &stat}, 0700) {
					t.Fatal("accepted foreign uid")
				}
				return
			}
			b := NewBridge(root)
			defer b.Close()
			b.Unlock()
			if kind == "replaced" {
				if err := os.Rename(root, root+"-old"); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(root, 0700); err != nil {
					t.Fatal(err)
				}
				writePrivate(t, filepath.Join(root, "data"), stream(tx(1, "replacement")))
				wantCode(t, b.Build("data", "index"), "unavailable")
			} else {
				wantCode(t, b.Build("data", "index"), "unavailable")
			}
		})
	}
}

func TestApplicationContainerAncestorBoundary(t *testing.T) {
	for _, kind := range []string{"valid", "host", "sibling", "relative", "dirty", "writable-container", "writable-child", "symlink-child", "symlink-container"} {
		t.Run(kind, func(t *testing.T) {
			base := t.TempDir()
			if err := os.Chmod(base, 0775); err != nil {
				t.Fatal(err)
			}
			container := filepath.Join(base, "container")
			parent := filepath.Join(container, "Library")
			root := filepath.Join(parent, "derived")
			if err := os.MkdirAll(root, 0700); err != nil {
				t.Fatal(err)
			}
			anchor := container
			switch kind {
			case "host":
				anchor = ""
			case "sibling":
				anchor = container + "-other"
			case "relative":
				anchor = "container"
			case "dirty":
				anchor += "/."
			case "writable-container", "writable-child":
				path := container
				if kind == "writable-child" {
					path = parent
				}
				if err := os.Chmod(path, 0775); err != nil {
					t.Fatal(err)
				}
			case "symlink-child", "symlink-container":
				path := parent
				if kind == "symlink-container" {
					path = container
				}
				if err := os.Rename(path, path+"-real"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(path+"-real", path); err != nil {
					t.Fatal(err)
				}
			}
			if got := ancestorsWithin(root, anchor); got != (kind == "valid") {
				t.Fatalf("ancestor policy accepted=%v", got)
			}
		})
	}
}

type foreignInfo struct {
	os.FileInfo
	stat *syscall.Stat_t
}

func (f foreignInfo) Sys() any { return f.stat }

func TestErrorsSanitizedAndNoSourceFallback(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	writePrivate(t, filepath.Join(b.root, "bad.stream"), "private /secret/ledger/source.bean value")
	wantCode(t, b.Build("bad.stream", "failed.sqlite"), "invalid_stream")
	entries, err := os.ReadDir(b.root)
	if err != nil || len(entries) != 1 {
		t.Fatal("failed build artifacts", err)
	}
	wantCode(t, b.Detail(1), "unavailable")
	manifest, m := buildFixture(t, b, "one", stream(tx(1, "synthetic")))
	original, err := os.ReadFile(filepath.Join(b.root, "one.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	wantCode(t, b.Build("one.stream", "one.sqlite"), "exists")
	after, err := os.ReadFile(filepath.Join(b.root, "one.sqlite"))
	if err != nil || string(after) != string(original) {
		t.Fatal("overwritten")
	}
	openFixture(t, b, "one", manifest, m)
	wantCode(t, failure(errors.New("private /secret/ledger.db")), "unavailable")
}
