//go:build cgo

// Package mobilereadindex is the opt-in, native SQLite gomobile boundary. It
// deliberately has no dependency from mobilecore or the default application.
//
// The host must supply an existing, dedicated app-private DERIVED-data root,
// outside the source workspace, and keep its ancestors and contents immutable
// during operations. This is not a sandbox against the owning OS user. POSIX
// permissions do not replace iOS file protection; the host owns that policy.
package mobilereadindex

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"sync"

	"github.com/borui/beancount-ledger-web/server/internal/readindex"
)

// Bridge owns one selected reader and at most one operation (including a build).
// Concurrent operations fail busy instead of queuing. Open validates a candidate
// before replacing the selected reader. Call Close to release native resources;
// there are no finalizers. The zero value is unavailable. Do not copy a Bridge.
// All data-returning methods publish at an epoch check under mu: Lock/Cancel
// invalidate any operation that has not yet passed that check. The host must
// also discard already-delivered UI data on lock.
type Bridge struct {
	gate     sync.Mutex // serializes privacy transitions, not Cancel
	op       sync.Mutex
	mu       sync.Mutex
	root     string
	identity os.FileInfo
	locked   bool
	closed   bool
	epoch    uint64
	ctx      context.Context
	cancel   context.CancelFunc
	reader   *readindex.Index // owned by op, never accessed by cancellation
}

// NewBridge pins an existing owned 0700 directory, using an absolute path with
// no symlink components (including ancestors). Invalid roots produce a
// permanently unavailable bridge, without disclosing paths. Initially locked.
func NewBridge(root string) *Bridge {
	b := &Bridge{locked: true}
	b.root, b.identity = pinRoot(root)
	b.ctx, b.cancel = context.WithCancel(context.Background())
	b.cancel()
	return b
}

func failure(err error) string {
	code := "unavailable"
	switch {
	case errors.Is(err, context.Canceled):
		code = "canceled"
	case errors.Is(err, readindex.ErrInvalidRequest):
		code = "invalid_request"
	case errors.Is(err, readindex.ErrInvalidCursor):
		code = "invalid_cursor"
	case errors.Is(err, readindex.ErrRevisionMismatch):
		code = "revision_mismatch"
	case errors.Is(err, readindex.ErrNotFound):
		code = "not_found"
	case errors.Is(err, readindex.ErrResourceLimit):
		code = "resource_limit"
	case errors.Is(err, readindex.ErrCorrupt):
		code = "corrupt"
	case errors.Is(err, readindex.ErrInvalidStream):
		code = "invalid_stream"
	case errors.Is(err, readindex.ErrExists):
		code = "exists"
	}
	return `{"error":{"code":"` + code + `"}}`
}

// run never holds the state mutex during native work, including native Close.
func (b *Bridge) run(work func(context.Context) (string, error)) string {
	return b.runCandidate(func(ctx context.Context) (string, *readindex.Index, error) {
		result, err := work(ctx)
		return result, nil, err
	})
}

func (b *Bridge) runCandidate(work func(context.Context) (string, *readindex.Index, error)) string {
	if b == nil {
		return failure(readindex.ErrUnavailable)
	}
	b.mu.Lock()
	if b.locked || b.closed || b.root == "" || b.ctx == nil {
		b.mu.Unlock()
		return failure(readindex.ErrUnavailable)
	}
	if !b.op.TryLock() {
		b.mu.Unlock()
		return `{"error":{"code":"busy"}}`
	}
	ctx, epoch := b.ctx, b.epoch
	b.mu.Unlock()
	defer b.op.Unlock()
	result, candidate, err := work(ctx)
	b.mu.Lock()
	switch {
	case b.locked || b.closed:
		result = failure(readindex.ErrUnavailable)
	case b.epoch != epoch || ctx.Err() != nil:
		result = failure(context.Canceled)
	case err != nil:
		result = failure(err)
	default:
		if candidate != nil {
			// Commit the verified replacement atomically with epoch validation.
			// A later cancellation suppresses delivery, not an already committed Open.
			candidate, b.reader = b.reader, candidate
		}
	}
	b.mu.Unlock()
	// On failure close the rejected candidate; on success close the old reader.
	// Still under op, but never under the state mutex.
	if candidate != nil {
		_ = candidate.Close()
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.locked || b.closed {
		return failure(readindex.ErrUnavailable)
	}
	if b.epoch != epoch || ctx.Err() != nil {
		return failure(context.Canceled)
	}
	return result
}

// Unlock explicitly resets the privacy gate. It does not reopen a reader and
// cannot revive a closed bridge. Authentication is the host's responsibility.
func (b *Bridge) Unlock() {
	if b == nil {
		return
	}
	b.gate.Lock()
	defer b.gate.Unlock()
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed || b.root == "" || !b.locked {
		return
	}
	b.epoch++
	b.ctx, b.cancel = context.WithCancel(context.Background())
	b.locked = false
}

// Cancel invalidates pending output and interrupts Build/Open/queries, but
// preserves the selected reader and the current lock gate for subsequent calls.
func (b *Bridge) Cancel() {
	if b == nil {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.epoch++
	if b.cancel != nil {
		b.cancel()
	}
	if !b.locked && !b.closed && b.root != "" {
		b.ctx, b.cancel = context.WithCancel(context.Background())
	}
}

func (b *Bridge) stop(closeBridge bool) {
	if b == nil {
		return
	}
	b.gate.Lock()
	defer b.gate.Unlock()
	b.mu.Lock()
	b.locked = true
	b.closed = b.closed || closeBridge
	b.epoch++
	if b.cancel != nil {
		b.cancel()
	}
	b.mu.Unlock()
	b.op.Lock()
	defer b.op.Unlock()
	if b.reader != nil {
		_ = b.reader.Close()
		b.reader = nil
	}
}

// Lock cancels in-flight work, suppresses its output, and waits for reader
// destruction. Unlock is required before any further operations.
func (b *Bridge) Lock() { b.stop(false) }

// Close permanently locks the bridge and synchronously destroys its reader.
func (b *Bridge) Close() { b.stop(true) }

// Build verifies a bounded-v1 derived stream and exclusively publishes a SQLite
// index. Both paths must be inside the pinned root, with existing private parent
// directories. Success is the raw manifest (at most 16KiB), usable by Open.
// Cancellation near publication may leave a complete disposable index; no
// manifest is delivered after invalidation. Build never selects a reader.
func (b *Bridge) Build(streamPath, destination string) string {
	return b.run(func(ctx context.Context) (string, error) {
		source, err := b.checkedPath(streamPath, false)
		if err != nil {
			return "", err
		}
		target, err := b.checkedPath(destination, true)
		if err != nil {
			return "", err
		}
		f, err := openStream(source)
		if err != nil {
			return "", err
		}
		defer f.Close()
		m, err := readindex.Build(ctx, f, target)
		if err != nil {
			return "", err
		}
		return encode(m, maxManifestBytes)
	})
}

// Open returns {"revision":"..."}, not a handle. Failure preserves the old
// selected reader; success closes it. A candidate and the old idle reader may
// briefly coexist while validation runs, but cannot be queried concurrently.
func (b *Bridge) Open(databasePath, manifestJSON string) string {
	return b.runCandidate(func(ctx context.Context) (string, *readindex.Index, error) {
		var m readindex.Manifest
		if err := decodeObject(manifestJSON, maxManifestBytes, &m); err != nil {
			return "", nil, err
		}
		path, err := b.checkedPath(databasePath, false)
		if err != nil {
			return "", nil, err
		}
		candidate, err := readindex.OpenContext(ctx, path, m)
		if err != nil {
			return "", nil, err
		}
		result, err := encode(struct {
			Revision string `json:"revision"`
		}{m.Revision}, maxManifestBytes)
		return result, candidate, err
	})
}

// Transactions returns the exact raw readindex.Page JSON representation, with
// no envelope, no trailing newline, and a hard 1MiB encoded-byte cap.
func (b *Bridge) Transactions(requestJSON string) string {
	return b.run(func(ctx context.Context) (string, error) {
		var req readindex.PageRequest
		if err := decodeObject(requestJSON, maxRequestBytes, &req); err != nil {
			return "", err
		}
		if b.reader == nil {
			return "", readindex.ErrUnavailable
		}
		page, err := b.reader.Transactions(ctx, req)
		if err != nil {
			return "", err
		}
		return encode(page, readindex.MaxResponseBytes)
	})
}

// Detail returns raw readindex.Detail JSON, or a small sanitized error object.
func (b *Bridge) Detail(id int64) string {
	return b.run(func(ctx context.Context) (string, error) {
		if id <= 0 {
			return "", readindex.ErrInvalidRequest
		}
		if b.reader == nil {
			return "", readindex.ErrUnavailable
		}
		detail, err := b.reader.Detail(ctx, id)
		if err != nil {
			return "", err
		}
		return encode(detail, readindex.MaxResponseBytes)
	})
}

// DetailRecords returns one bounded source-ordered record page as raw JSON.
// Requests are strict flat JSON objects of at most 4096 bytes. Lifecycle,
// cancellation and busy behavior are identical to Transactions and Detail.
func (b *Bridge) DetailRecords(requestJSON string) string {
	return b.run(func(ctx context.Context) (string, error) {
		var req readindex.DetailPageRequest
		if err := decodeObject(requestJSON, maxRequestBytes, &req); err != nil {
			return "", err
		}
		if b.reader == nil {
			return "", readindex.ErrUnavailable
		}
		page, err := b.reader.DetailRecords(ctx, req)
		if err != nil {
			return "", err
		}
		return encode(page, readindex.MaxResponseBytes)
	})
}

func encode(v any, limit int) (string, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return "", readindex.ErrCorrupt
	}
	if len(raw) > limit {
		return "", readindex.ErrResourceLimit
	}
	return string(raw), nil
}
