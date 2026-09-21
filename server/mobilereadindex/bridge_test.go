//go:build cgo

package mobilereadindex

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/readindex"
)

const header = `{"type":"header","version":1,"source_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","entry_file":"main.bean","runtime":"beancount/3.2.3 python/3.13.2","exporter":"bounded-v1"}`

func tx(id int, narration string) string {
	text, _ := json.Marshal(narration)
	return fmt.Sprintf(`{"type":"directive","id":%d,"value":{"Kind":"transaction","Date":"2026-01-01","File":"main.bean","Line":%d,"Flag":"*","Narration":%s,"Tags":[],"Links":[]}}`, id, id, text)
}

func stream(records ...string) string {
	all := append([]string{header}, records...)
	raw := strings.Join(all, "\n") + "\n"
	directives, postings := 0, 0
	for _, record := range records {
		var key struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal([]byte(record), &key)
		if key.Type == "directive" {
			directives++
		}
		if key.Type == "posting" {
			postings++
		}
	}
	return raw + fmt.Sprintf(`{"type":"footer","records":%d,"directives":%d,"postings":%d,"sha256":"%x"}`+"\n", len(all), directives, postings, sha256.Sum256([]byte(raw)))
}

func newTestBridge(t *testing.T) *Bridge {
	t.Helper()
	parent := t.TempDir()
	if err := os.Chmod(parent, 0700); err != nil {
		t.Fatal(err)
	}
	parent, err := filepath.EvalSymlinks(parent)
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(parent, "derived")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	b := NewBridge(root)
	if b.root == "" {
		t.Fatal("invalid test root")
	}
	t.Cleanup(b.Close)
	return b
}

func wantCode(t *testing.T, raw, code string) {
	t.Helper()
	want := `{"error":{"code":"` + code + `"}}`
	if raw != want {
		t.Fatalf("got %.200s (%d bytes), want %s", raw, len(raw), want)
	}
}

func writePrivate(t *testing.T, path, raw string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
}

func buildFixture(t *testing.T, b *Bridge, name, raw string) (string, readindex.Manifest) {
	t.Helper()
	writePrivate(t, filepath.Join(b.root, name+".stream"), raw)
	manifest := b.Build(name+".stream", name+".sqlite")
	var m readindex.Manifest
	if err := json.Unmarshal([]byte(manifest), &m); err != nil || len(m.Revision) != 64 {
		t.Fatalf("build: %s (%v)", manifest, err)
	}
	if len(manifest) > maxManifestBytes {
		t.Fatal("manifest cap")
	}
	return manifest, m
}

func openFixture(t *testing.T, b *Bridge, name, manifest string, m readindex.Manifest) {
	t.Helper()
	if got := b.Open(name+".sqlite", manifest); got != `{"revision":"`+m.Revision+`"}` {
		t.Fatal(got)
	}
}

func TestLockedDefaultAndLifecycle(t *testing.T) {
	b := newTestBridge(t)
	wantCode(t, b.Build("missing", "db"), "unavailable")
	wantCode(t, b.Open("missing", "{}"), "unavailable")
	wantCode(t, b.Transactions("{}"), "unavailable")
	wantCode(t, b.Detail(1), "unavailable")
	b.Cancel()
	wantCode(t, b.Detail(1), "unavailable")
	b.Unlock()
	wantCode(t, b.Transactions("{}"), "unavailable")
	manifest, m := buildFixture(t, b, "one", stream(tx(1, "synthetic <>& 中文")))
	wantCode(t, b.Detail(1), "unavailable") // Build does not select or fall back.
	openFixture(t, b, "one", manifest, m)
	reader := b.reader
	b.Cancel()
	if strings.Contains(b.Detail(1), `"error"`) {
		t.Fatal("Cancel lost reader")
	}
	b.Lock()
	if b.reader != nil {
		t.Fatal("lock retained reader")
	}
	if _, err := reader.Detail(context.Background(), 1); !errors.Is(err, readindex.ErrUnavailable) {
		t.Fatal("reader not closed", err)
	}
	b.Unlock()
	wantCode(t, b.Detail(1), "unavailable")
	openFixture(t, b, "one", manifest, m)
	reader = b.reader
	b.Close()
	b.Close()
	b.Unlock()
	b.Cancel()
	wantCode(t, b.Detail(1), "unavailable")
	if _, err := reader.Detail(context.Background(), 1); !errors.Is(err, readindex.ErrUnavailable) {
		t.Fatal("close leaked reader", err)
	}
	var zero Bridge
	zero.Unlock()
	zero.Cancel()
	zero.Lock()
	zero.Close()
	wantCode(t, zero.Detail(1), "unavailable")
	var nilBridge *Bridge
	nilBridge.Unlock()
	nilBridge.Cancel()
	nilBridge.Lock()
	nilBridge.Close()
	wantCode(t, nilBridge.Transactions("{}"), "unavailable")
}

func TestRevisionReplacementAndRawResults(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	manifest, m := buildFixture(t, b, "one", stream(tx(1, "<>& decimal"), `{"type":"posting","entry_id":1,"ordinal":0,"value":{"account":"Assets:Test","Quantity":{"Number":"12345678901234567890.000000000001","Currency":"USD"}}}`, tx(2, "other")))
	openFixture(t, b, "one", manifest, m)
	old := b.reader
	page, err := old.Transactions(context.Background(), readindex.PageRequest{Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	expected, _ := json.Marshal(page)
	if got := b.Transactions(`{"limit":1}`); got != string(expected) {
		t.Fatal("page is not raw core representation")
	}
	detail, err := old.Detail(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	expected, _ = json.Marshal(detail)
	if got := b.Detail(1); got != string(expected) {
		t.Fatal("detail changed")
	}
	second, m2 := buildFixture(t, b, "two", stream(tx(1, "changed")))
	wantCode(t, b.Open("two.sqlite", manifest), "revision_mismatch")
	if b.reader != old {
		t.Fatal("failed replacement changed reader")
	}
	wantCode(t, b.Open("missing", manifest), "unavailable")
	openFixture(t, b, "two", second, m2)
	if _, err := old.Detail(context.Background(), 1); !errors.Is(err, readindex.ErrUnavailable) {
		t.Fatal("old reader not closed")
	}
	req, _ := json.Marshal(readindex.PageRequest{Cursor: page.NextCursor})
	wantCode(t, b.Transactions(string(req)), "revision_mismatch")
	selected := b.reader
	openFixture(t, b, "two", second, m2)
	if _, err := selected.Detail(context.Background(), 1); !errors.Is(err, readindex.ErrUnavailable) {
		t.Fatal("same-revision reopen leaked reader")
	}
	wantCode(t, b.Detail(999), "not_found")
	wantCode(t, b.Detail(0), "invalid_request")
}

func TestStrictJSONAndBounds(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	manifest, m := buildFixture(t, b, "one", stream(tx(1, "one")))
	openFixture(t, b, "one", manifest, m)
	for _, raw := range []string{"", "null", "[]", "{} {}", `{"limit":1}true`, `{"Limit":1}`, `{"limit":1,"limit":2}`, `{"limit":null}`, `{"limit":1.0}`, `{"limit":"1"}`, `{"cursor":null}`, `{"unknown":1}`, `{"limit":-1}`, `{"limit":501}`, `{"limit":9223372036854775808}`, `{"cursor":{}}`, "{\xff}", strings.Repeat(" ", maxRequestBytes) + "{}"} {
		wantCode(t, b.Transactions(raw), "invalid_request")
	}
	wantCode(t, b.Transactions(`{"cursor":"bad"}`), "invalid_cursor")
	for _, raw := range []string{"null", "[]", "{} {}", `{"unknown":1}`, `{"revision":null}`, `{"revision":"x","revision":"y"}`, strings.Replace(manifest, `"revision":`, `"Revision":`, 1), manifest + "0", strings.Repeat(" ", maxManifestBytes) + "{}"} {
		wantCode(t, b.Open("one.sqlite", raw), "invalid_request")
	}
	if got := b.Transactions(strings.Repeat(" ", maxRequestBytes-2) + "{}"); strings.Contains(got, `"error"`) {
		t.Fatal(got)
	}
	openFixture(t, b, "one", strings.Repeat(" ", maxManifestBytes-len(manifest))+manifest, m)
}

func TestPagingExactByteCap(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	// Tune one ASCII record so the complete raw Page is exactly 1MiB. Any bridge
	// envelope or trailing newline would violate the boundary.
	revision := strings.Repeat("a", 64)
	shell := readindex.Page{Revision: revision, Transactions: []readindex.Transaction{{ID: 1, Date: "2026-01-01", Record: json.RawMessage(tx(1, ""))}}}
	raw, _ := json.Marshal(shell)
	narration := strings.Repeat("x", readindex.MaxResponseBytes-len(raw))
	manifest, m := buildFixture(t, b, "exact", stream(tx(1, narration)))
	openFixture(t, b, "exact", manifest, m)
	got := b.Transactions("{}")
	if len(got) != readindex.MaxResponseBytes {
		t.Fatalf("got %d bytes, want exactly cap", len(got))
	}
	core, err := b.reader.Transactions(context.Background(), readindex.PageRequest{})
	if err != nil {
		t.Fatal(err)
	}
	expected, _ := json.Marshal(core)
	if got != string(expected) {
		t.Fatal("not raw page")
	}
	// One more byte must fail, not truncate or return an oversized envelope.
	manifest, m = buildFixture(t, b, "over", stream(tx(1, narration+"x")))
	openFixture(t, b, "over", manifest, m)
	wantCode(t, b.Transactions("{}"), "resource_limit")
	// Escaping can multiply size; pages split with exact opaque cursors.
	records := []string{}
	for id := 1; id <= 9; id++ {
		records = append(records, tx(id, strings.Repeat("<&中文", 18000)))
	}
	manifest, m = buildFixture(t, b, "pages", stream(records...))
	openFixture(t, b, "pages", manifest, m)
	req := readindex.PageRequest{Limit: 500}
	count, last := 0, int64(10)
	for {
		request, _ := json.Marshal(req)
		result := b.Transactions(string(request))
		if len(result) > readindex.MaxResponseBytes {
			t.Fatal("page exceeds cap")
		}
		expected, err := b.reader.Transactions(context.Background(), req)
		if err != nil {
			t.Fatal(err)
		}
		exact, _ := json.Marshal(expected)
		if result != string(exact) {
			t.Fatal("changed wire format")
		}
		for _, item := range expected.Transactions {
			if item.ID != last-1 {
				t.Fatal("lost/duplicate row")
			}
			last = item.ID
			count++
		}
		if expected.NextCursor == "" {
			break
		}
		req.Cursor = expected.NextCursor
	}
	if count != 9 {
		t.Fatal(count)
	}
}

func TestDetailByteCap(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	shell := readindex.Detail{Revision: strings.Repeat("a", 64), ID: 1, Records: []json.RawMessage{json.RawMessage(tx(1, ""))}}
	raw, _ := json.Marshal(shell)
	narration := strings.Repeat("x", readindex.MaxResponseBytes-len(raw))
	for _, extra := range []int{0, 1} {
		name := fmt.Sprintf("detail%d", extra)
		manifest, m := buildFixture(t, b, name, stream(tx(1, narration+strings.Repeat("x", extra))))
		openFixture(t, b, name, manifest, m)
		result := b.Detail(1)
		if extra == 1 {
			wantCode(t, result, "resource_limit")
			continue
		}
		if len(result) != readindex.MaxResponseBytes {
			t.Fatalf("detail cap: %d", len(result))
		}
		core, err := b.reader.Detail(context.Background(), 1)
		if err != nil {
			t.Fatal(err)
		}
		expected, _ := json.Marshal(core)
		if result != string(expected) {
			t.Fatal("not raw detail")
		}
	}
}

func TestGomobileSurface(t *testing.T) {
	typ := reflect.TypeOf((*Bridge)(nil))
	methods := map[string]bool{"Build": true, "Open": true, "Accounts": true, "AccountBalances": true, "AccountSummary": true, "AccountActivity": true, "Transactions": true, "Detail": true, "DetailRecords": true, "Cancel": true, "Lock": true, "Unlock": true, "Close": true}
	for i := 0; i < typ.NumMethod(); i++ {
		method := typ.Method(i)
		if !methods[method.Name] {
			t.Fatal("unexpected export", method.Name)
		}
		delete(methods, method.Name)
		for j := 1; j < method.Type.NumIn(); j++ {
			kind := method.Type.In(j).Kind()
			if kind != reflect.String && kind != reflect.Bool && kind != reflect.Int64 {
				t.Fatal("unsafe parameter", method.Name, kind)
			}
		}
		for j := 0; j < method.Type.NumOut(); j++ {
			kind := method.Type.Out(j).Kind()
			if kind != reflect.String && kind != reflect.Bool && kind != reflect.Int64 {
				t.Fatal("unsafe result", method.Name, kind)
			}
		}
	}
	if len(methods) != 0 {
		t.Fatal("missing methods", methods)
	}
	constructor := reflect.TypeOf(NewBridge)
	if constructor.NumIn() != 1 || constructor.In(0).Kind() != reflect.String || constructor.NumOut() != 1 || constructor.Out(0) != typ {
		t.Fatal("constructor changed")
	}
}

func TestEpochSuppressesInFlightAndBusy(t *testing.T) {
	for _, action := range []string{"cancel", "lock", "close", "lock-unlock"} {
		t.Run(action, func(t *testing.T) {
			b := newTestBridge(t)
			b.Unlock()
			manifest, m := buildFixture(t, b, "one", stream(tx(1, "private")))
			openFixture(t, b, "one", manifest, m)
			started, release := make(chan context.Context, 1), make(chan struct{})
			output := make(chan string, 1)
			go func() {
				output <- b.run(func(ctx context.Context) (string, error) {
					result, err := b.reader.Detail(ctx, 1)
					if err != nil {
						return "", err
					}
					raw, _ := encode(result, readindex.MaxResponseBytes)
					started <- ctx
					<-release // model native completion/marshalling that ignores cancellation
					return raw, nil
				})
			}()
			ctx := <-started
			wantCode(t, b.Detail(1), "busy")
			wantCode(t, b.Build("one.stream", "other.sqlite"), "busy")
			wantCode(t, b.Open("one.sqlite", manifest), "busy")
			done := make(chan struct{})
			go func() {
				switch action {
				case "cancel":
					b.Cancel()
				case "lock":
					b.Lock()
				case "close":
					b.Close()
				case "lock-unlock":
					b.Lock()
					b.Unlock()
				}
				close(done)
			}()
			select {
			case <-ctx.Done():
			case <-time.After(5 * time.Second):
				t.Fatal("control blocked behind native operation")
			}
			close(release)
			result := <-output
			<-done
			if action == "cancel" {
				wantCode(t, result, "canceled")
			} else {
				wantCode(t, result, "unavailable")
			}
			if action != "cancel" && b.reader != nil {
				t.Fatal("reader retained")
			}
		})
	}
}

func TestCanceledCandidateCannotReplaceReader(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	manifest, m := buildFixture(t, b, "one", stream(tx(1, "old")))
	openFixture(t, b, "one", manifest, m)
	old := b.reader
	_, m2 := buildFixture(t, b, "two", stream(tx(1, "new")))
	candidate, err := readindex.Open(filepath.Join(b.root, "two.sqlite"), m2)
	if err != nil {
		t.Fatal(err)
	}
	result := b.runCandidate(func(ctx context.Context) (string, *readindex.Index, error) {
		b.Cancel()
		return `{"revision":"new"}`, candidate, nil
	})
	wantCode(t, result, "canceled")
	if b.reader != old {
		t.Fatal("canceled candidate selected")
	}
	if _, err := candidate.Detail(context.Background(), 1); !errors.Is(err, readindex.ErrUnavailable) {
		t.Fatal("candidate leak")
	}
}

func TestConcurrentOperationsAndControls(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	manifest, m := buildFixture(t, b, "one", stream(tx(1, "synthetic")))
	openFixture(t, b, "one", manifest, m)
	var wg sync.WaitGroup
	for worker := 0; worker < 12; worker++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for n := 0; n < 30; n++ {
				var raw string
				switch (worker + n) % 8 {
				case 0:
					raw = b.Open("one.sqlite", manifest)
				case 1:
					raw = b.Transactions(`{"limit":1}`)
				case 2:
					raw = b.Detail(1)
				case 3:
					b.Cancel()
				case 4:
					b.Lock()
				case 5:
					b.Unlock()
				case 6:
					raw = b.Build("one.stream", fmt.Sprintf("build-%d-%d.sqlite", worker, n))
				case 7:
					b.Unlock()
					raw = b.Detail(1)
				}
				if raw != "" && (!json.Valid([]byte(raw)) || len(raw) > readindex.MaxResponseBytes) {
					t.Error("bad concurrent output")
				}
			}
		}(worker)
	}
	wg.Wait()
	b.Lock()
	if b.reader != nil {
		t.Fatal("reader leaked")
	}
	b.Unlock()
	openFixture(t, b, "one", manifest, m)
	if strings.Contains(b.Detail(1), `"error"`) {
		t.Fatal("bridge failed after concurrency")
	}
}

// Exercise native Build/Open cancellation using the same root context as the
// public calls, without timers or process-global fault-injection hooks.
func TestNativeBuildOpenCancellation(t *testing.T) {
	for _, operation := range []string{"build", "open"} {
		for _, control := range []string{"cancel", "lock"} {
			t.Run(operation+"-"+control, func(t *testing.T) {
				b := newTestBridge(t)
				b.Unlock()
				manifest, m := buildFixture(t, b, "one", stream(tx(1, "old")))
				openFixture(t, b, "one", manifest, m)
				old := b.reader
				contextReady := make(chan context.Context, 1)
				result := make(chan string, 1)
				go func() {
					result <- b.runCandidate(func(ctx context.Context) (string, *readindex.Index, error) {
						contextReady <- ctx
						<-ctx.Done()
						if operation == "build" {
							built, err := readindex.Build(ctx, strings.NewReader(stream(tx(1, "new"))), filepath.Join(b.root, "canceled.sqlite"))
							if built != (readindex.Manifest{}) {
								return "", nil, errors.New("partial canceled manifest")
							}
							return "", nil, err
						}
						candidate, err := readindex.OpenContext(ctx, filepath.Join(b.root, "one.sqlite"), m)
						return "", candidate, err
					})
				}()
				<-contextReady
				done := make(chan struct{})
				go func() {
					if control == "cancel" {
						b.Cancel()
					} else {
						b.Lock()
					}
					close(done)
				}()
				raw := <-result
				<-done
				if control == "cancel" {
					wantCode(t, raw, "canceled")
					if b.reader != old {
						t.Fatal("canceled native operation replaced reader")
					}
				} else {
					wantCode(t, raw, "unavailable")
					if b.reader != nil {
						t.Fatal("locked reader retained")
					}
				}
				if _, err := os.Lstat(filepath.Join(b.root, "canceled.sqlite")); !os.IsNotExist(err) {
					t.Fatal("canceled build published a database")
				}
			})
		}
	}
}

func TestCancellationDuringStreamConsumption(t *testing.T) {
	b := newTestBridge(t)
	b.Unlock()
	reached, release := make(chan struct{}), make(chan struct{})
	input := &pausedStream{Reader: strings.NewReader(stream(tx(1, "new"))), reached: reached, release: release}
	result := make(chan string, 1)
	go func() {
		result <- b.run(func(ctx context.Context) (string, error) {
			_, err := readindex.Build(ctx, input, filepath.Join(b.root, "canceled.sqlite"))
			return `{"private":"must not escape"}`, err
		})
	}()
	<-reached
	b.Cancel()
	close(release)
	wantCode(t, <-result, "canceled")
	entries, err := os.ReadDir(b.root)
	if err != nil || len(entries) != 0 {
		t.Fatal("canceled native builder leaked artifacts", err)
	}
}

type pausedStream struct {
	*strings.Reader
	reached chan struct{}
	release chan struct{}
	once    sync.Once
}

func (s *pausedStream) Read(p []byte) (int, error) {
	s.once.Do(func() { close(s.reached); <-s.release })
	return s.Reader.Read(p)
}
