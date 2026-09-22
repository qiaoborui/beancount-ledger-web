package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Count client downloads from RoundTrip entry through the underlying Body.Close
// return. A server handler can still be unwinding after the client frees its
// prefetch worker, so handler lifetime is not the production concurrency bound.
type validationDownloadMetrics struct {
	mu        sync.Mutex
	requests  int
	active    int
	maxActive int
}

func isValidationContentDownload(r *http.Request) bool {
	return r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/repos/owner/ledger/contents/")
}

// Only use in nonparallel tests (and without parallel ancestors). Keep the
// original transport/pool intact; restore it after all requests have finished.
func (metrics *validationDownloadMetrics) installDefaultTransport(t *testing.T) {
	t.Helper()
	original := http.DefaultTransport
	http.DefaultTransport = validationContentTransport{base: original, metrics: metrics}
	t.Cleanup(func() { http.DefaultTransport = original })
}

type validationContentTransport struct {
	base    http.RoundTripper
	metrics *validationDownloadMetrics
}

func (tr validationContentTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if !isValidationContentDownload(r) {
		return tr.base.RoundTrip(r)
	}
	metrics := tr.metrics
	metrics.mu.Lock()
	metrics.requests++
	metrics.active++
	if metrics.active > metrics.maxActive {
		metrics.maxActive = metrics.active
	}
	metrics.mu.Unlock()
	finish := func() {
		metrics.mu.Lock()
		metrics.active--
		metrics.mu.Unlock()
	}
	resp, err := tr.base.RoundTrip(r)
	if err != nil {
		finish()
		return resp, err
	}
	resp.Body = &validationContentBody{ReadCloser: resp.Body, finish: finish}
	return resp, nil
}

type validationContentBody struct {
	io.ReadCloser
	finish func()
	once   sync.Once
	err    error
}

func (body *validationContentBody) Close() error {
	body.once.Do(func() {
		body.err = body.ReadCloser.Close()
		body.finish()
	})
	return body.err
}

func (metrics *validationDownloadMetrics) take(t testing.TB) (requests, maxActive int) {
	t.Helper()
	metrics.mu.Lock()
	defer metrics.mu.Unlock()
	if metrics.active != 0 {
		t.Fatalf("write returned with %d content downloads still active", metrics.active)
	}
	requests, maxActive = metrics.requests, metrics.maxActive
	metrics.requests, metrics.maxActive = 0, 0
	return
}

func (metrics *validationDownloadMetrics) assertActive(t *testing.T, want int) {
	t.Helper()
	metrics.mu.Lock()
	defer metrics.mu.Unlock()
	if metrics.active != want {
		t.Errorf("active client downloads=%d, want %d", metrics.active, want)
	}
}

// Make the old measurement's race deterministic: all six original handlers
// retain their stack until the seventh request enters. Their complete large
// responses are readable without Flush, just as in the performance fixture.
func TestValidationDownloadMetricsHandlerLifecycle(t *testing.T) {
	metrics := &validationDownloadMetrics{}
	metrics.installDefaultTransport(t)
	files := validationPerformanceLedger()
	fake := &fakeGitHubLedgerAPI{
		t: t, files: files, blobs: map[string]string{}, treeBlobs: map[string]string{}, contentReads: map[string]int{},
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	allSix := make(chan struct{})
	seventh := make(chan struct{})
	var arrived, activeHandlers, maxHandlers, gateFailures atomic.Int32
	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		active := activeHandlers.Add(1)
		defer activeHandlers.Add(-1)
		for old := maxHandlers.Load(); active > old; old = maxHandlers.Load() {
			if maxHandlers.CompareAndSwap(old, active) {
				break
			}
		}
		n := arrived.Add(1)
		if n == 6 {
			close(allSix)
		}
		if n == 7 {
			close(seventh)
		}
		if n <= 6 {
			select {
			case <-allSix:
			case <-ctx.Done():
				gateFailures.Add(1)
				return
			}
		}
		fake.handle(w, r)
		if n <= 6 {
			select {
			case <-seventh:
			case <-ctx.Done():
				gateFailures.Add(1)
			}
		}
	}))
	t.Cleanup(func() {
		cancel() // Unblock handlers even if prefetch or an assertion fails.
		fake.server.Close()
	})
	cfg := githubAPITestConfig(t, fake)
	client, err := newGitHubLedgerClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	tx := &githubLedgerTransaction{
		ctx: ctx, ledger: client, baseCommitSHA: "base-commit",
		cache: map[string]fileSnapshot{}, writes: map[string][]byte{},
	}
	paths := make([]string, 7)
	for i := range paths {
		paths[i] = filepath.Join(cfg.LedgerRoot, fmt.Sprintf("transactions/%03d.bean", i))
	}
	if err := tx.prefetch(paths); err != nil {
		t.Fatal(err)
	}
	// Check client quiescence before joining handlers: no sleep or retry is
	// allowed to hide a stale client count. Close then joins server cleanup.
	requests, maxActive := metrics.take(t)
	fake.server.Close()
	if requests != 7 || maxActive != 6 {
		t.Errorf("content GETs=%d client peak=%d, want 7 and 6", requests, maxActive)
	}
	if arrived.Load() != 7 || maxHandlers.Load() != 7 || activeHandlers.Load() != 0 || gateFailures.Load() != 0 {
		t.Errorf("handler arrivals=%d peak=%d active=%d gate failures=%d, want 7/7/0/0", arrived.Load(), maxHandlers.Load(), activeHandlers.Load(), gateFailures.Load())
	}
	for i, path := range paths {
		rel := fmt.Sprintf("transactions/%03d.bean", i)
		if got := tx.cache[rel]; !got.existed || string(got.content) != files[rel] {
			t.Errorf("prefetch did not retain complete content for %s", path)
		}
	}
	t.Logf("content GETs=%d client peak=%d handler peak=%d", requests, maxActive, maxHandlers.Load())
}

type validationRoundTripFunc func(*http.Request) (*http.Response, error)

func (f validationRoundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type validationCloseGate struct {
	io.Reader
	started chan struct{}
	release chan struct{}
	closes  atomic.Int32
	err     error
}

func (body *validationCloseGate) Close() error {
	if body.closes.Add(1) == 1 {
		close(body.started)
	}
	<-body.release
	return body.err
}

func TestValidationDownloadMetricsBodyLifecycle(t *testing.T) {
	for _, closeErr := range []error{nil, errors.New("synthetic close failure")} {
		name := "success"
		if closeErr != nil {
			name = "close error"
		}
		t.Run(name, func(t *testing.T) {
			metrics := &validationDownloadMetrics{}
			body := &validationCloseGate{
				Reader: strings.NewReader("{}"), started: make(chan struct{}), release: make(chan struct{}), err: closeErr,
			}
			var releaseOnce sync.Once
			release := func() { releaseOnce.Do(func() { close(body.release) }) }
			t.Cleanup(release)
			transport := validationContentTransport{metrics: metrics, base: validationRoundTripFunc(func(*http.Request) (*http.Response, error) {
				metrics.assertActive(t, 1) // Count before the delegate returns headers.
				return &http.Response{StatusCode: http.StatusOK, Body: body}, nil
			})}
			req := httptest.NewRequest(http.MethodGet, "http://fixture/repos/owner/ledger/contents/main.bean", nil)
			resp, err := transport.RoundTrip(req)
			if err != nil {
				t.Fatal(err)
			}
			metrics.assertActive(t, 1)
			if _, err := io.ReadAll(resp.Body); err != nil {
				t.Fatal(err)
			}
			metrics.assertActive(t, 1) // EOF alone does not release the worker.
			done := make(chan error, 2)
			go func() { done <- resp.Body.Close() }()
			<-body.started
			metrics.assertActive(t, 1) // Underlying Close has not returned yet.
			go func() { done <- resp.Body.Close() }()
			release()
			for range 2 {
				if err := <-done; err != closeErr {
					t.Errorf("Close error=%v, want %v", err, closeErr)
				}
			}
			if err := resp.Body.Close(); err != closeErr {
				t.Errorf("repeated Close error=%v, want %v", err, closeErr)
			}
			if body.closes.Load() != 1 {
				t.Errorf("underlying closes=%d, want 1", body.closes.Load())
			}
			requests, peak := metrics.take(t)
			if requests != 1 || peak != 1 {
				t.Errorf("requests=%d peak=%d, want 1/1", requests, peak)
			}
			requests, peak = metrics.take(t)
			if requests != 0 || peak != 0 {
				t.Errorf("reset requests=%d peak=%d, want 0/0", requests, peak)
			}
		})
	}
}

func TestValidationDownloadMetricsTransportError(t *testing.T) {
	metrics := &validationDownloadMetrics{}
	wantErr := errors.New("synthetic transport failure")
	transport := validationContentTransport{metrics: metrics, base: validationRoundTripFunc(func(*http.Request) (*http.Response, error) {
		metrics.assertActive(t, 1)
		return nil, wantErr
	})}
	req := httptest.NewRequest(http.MethodGet, "http://fixture/repos/owner/ledger/contents/main.bean", nil)
	if resp, err := transport.RoundTrip(req); resp != nil || err != wantErr {
		t.Fatalf("RoundTrip=%v, %v; want nil, %v", resp, err, wantErr)
	}
	requests, peak := metrics.take(t)
	if requests != 1 || peak != 1 {
		t.Errorf("requests=%d peak=%d, want 1/1", requests, peak)
	}
}

func TestValidationDownloadMetricsIgnoresOtherRequests(t *testing.T) {
	for _, test := range []struct{ method, path string }{
		{http.MethodPost, "/repos/owner/ledger/contents/main.bean"},
		{http.MethodGet, "/repos/owner/ledger/git/trees/base-commit"},
		{http.MethodGet, "/repos/other/ledger/contents/main.bean"},
	} {
		t.Run(test.method+test.path, func(t *testing.T) {
			metrics := &validationDownloadMetrics{}
			want := &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("{}"))}
			req := httptest.NewRequest(test.method, "http://fixture"+test.path, nil)
			transport := validationContentTransport{metrics: metrics, base: validationRoundTripFunc(func(got *http.Request) (*http.Response, error) {
				if got != req {
					t.Error("delegate request changed")
				}
				metrics.assertActive(t, 0)
				return want, nil
			})}
			body := want.Body
			resp, err := transport.RoundTrip(req)
			if err != nil || resp != want || resp.Body != body {
				t.Fatalf("unmeasured response changed: %v, %v", resp, err)
			}
			resp.Body.Close()
			requests, peak := metrics.take(t)
			if requests != 0 || peak != 0 {
				t.Errorf("requests=%d peak=%d, want 0/0", requests, peak)
			}
		})
	}
}
