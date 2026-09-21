package readindex

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/borui/beancount-ledger-web/server/internal/readindex/sqlite"
)

const testHeader = `{"type":"header","version":1,"source_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","entry_file":"main.bean","runtime":"beancount/3.2.3 python/3.13.2","exporter":"bounded-v1"}`
const testPosting = `{"type":"posting","entry_id":1,"ordinal":0,"value":{"account":"Assets:Stock","Quantity":{"Number":"-12345678901234567890.000000000000000000000001E-20","Currency":"XYZ"},"Cost":{"Number":"12.34000000000000000000000001","Currency":"USD"},"CostDate":"2025-12-31","CostLabel":"lot <A> \\ \u4e2d","Price":{"Number":"1E-99999999","Currency":"USD"},"flag":"!"}}`
const testMetadata = `{"type":"metadata","entry_id":1,"posting":-1,"key":"precise","value":{"type":"decimal","value":"123456789012345678901234567890.000000000000000000000001"}}`

func transaction(id int, date, narration string) string {
	raw, _ := json.Marshal(narration)
	return fmt.Sprintf(`{"type":"directive","id":%d,"value":{"Kind":"transaction","Date":%q,"File":"main.bean","Line":%d,"Flag":"*","Narration":%s,"Tags":[],"Links":[]}}`, id, date, id, raw)
}

func makeStream(records ...string) string {
	var b strings.Builder
	directives, postings := 0, 0
	for _, raw := range records {
		b.WriteString(raw)
		b.WriteByte('\n')
		key, err := keys([]byte(raw))
		if err == nil {
			if key.Type == "directive" {
				directives++
			}
			if key.Type == "posting" {
				postings++
			}
		}
	}
	h := sha256.Sum256([]byte(b.String()))
	fmt.Fprintf(&b, `{"type":"footer","records":%d,"directives":%d,"postings":%d,"sha256":"%s"}`+"\n", len(records), directives, postings, hex.EncodeToString(h[:]))
	return b.String()
}

func destination(t *testing.T) string {
	t.Helper()
	// Exercise Build's single private-directory creation, not testing.TempDir's
	// system default permissions (which can be 0755).
	return filepath.Join(t.TempDir(), "private", "index.sqlite")
}

func buildText(t *testing.T, stream string) (string, Manifest) {
	t.Helper()
	path := destination(t)
	m, err := Build(context.Background(), strings.NewReader(stream), path)
	if err != nil {
		t.Fatal(err)
	}
	return path, m
}

func openIndex(t *testing.T, path string, m Manifest) *Index {
	t.Helper()
	i, err := Open(path, m)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := i.Close(); err != nil {
			t.Error(err)
		}
	})
	return i
}

func wantError(t *testing.T, err, want error) {
	t.Helper()
	if !errors.Is(err, want) {
		t.Fatalf("error %v, want %v", err, want)
	}
}

func TestExactRecordsManifestAndReopen(t *testing.T) {
	tx := transaction(1, "2026-01-01", "precision <>& 中文")
	// Valid whitespace and escape spelling must survive SQLite verbatim.
	tx = strings.Replace(tx, `"value":{`, `"value": { `, 1)
	records := []string{testHeader,
		`{"type":"option","key":"title","value":"Synthetic"}`,
		`{"type":"commodity","value":"USD"}`,
		tx, testMetadata, testPosting,
		`{"type":"metadata","entry_id":1,"posting":0,"key":"nested","value":{"type":"list","value":[{"type":"int","value":9007199254740993},{"type":"str","value":"x\\u00e9"}]}}`,
	}
	input := makeStream(records...)
	path, m := buildText(t, input)
	if m.SchemaVersion != 1 || m.StreamVersion != 1 || m.SourceDigest != strings.Repeat("a", 64) || m.Runtime != "beancount/3.2.3 python/3.13.2" || m.Exporter != "bounded-v1" || m.Entrypoint != "main.bean" || len(m.Revision) != 64 || m.Records != 7 || m.Directives != 1 || m.Postings != 1 || m.Metadata != 2 || m.Options != 1 || m.Commodities != 1 || m.Transactions != 1 || m.Bytes != int64(len(input)) {
		t.Fatalf("incorrect manifest: %+v", m)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for pass := 0; pass < 2; pass++ {
		i := openIndex(t, path, m)
		p, err := i.Transactions(context.Background(), PageRequest{})
		if err != nil {
			t.Fatal(err)
		}
		if p.Revision != m.Revision || len(p.Transactions) != 1 || p.NextCursor != "" || string(p.Transactions[0].Record) != tx {
			t.Fatal("transaction changed")
		}
		detail, err := i.Detail(context.Background(), 1)
		if err != nil {
			t.Fatal(err)
		}
		if detail.Revision != m.Revision || detail.ID != 1 || len(detail.Records) != 4 {
			t.Fatal("incomplete detail")
		}
		for j, raw := range detail.Records {
			if string(raw) != records[j+3] {
				t.Fatalf("record %d changed", j)
			}
		}
		// Returned records do not alias an Index cache/native row.
		clear(detail.Records[0])
		again, err := i.Detail(context.Background(), 1)
		if err != nil || string(again.Records[0]) != tx {
			t.Fatal("caller mutation changed index")
		}
		if err = i.Close(); err != nil {
			t.Fatal(err)
		}
		if err = i.Close(); err != nil {
			t.Fatal(err)
		}
		_, err = i.Transactions(context.Background(), PageRequest{})
		wantError(t, err, ErrUnavailable)
		_, err = i.Detail(context.Background(), 1)
		wantError(t, err, ErrUnavailable)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("read-only queries modified file")
	}
	db, err := sqlite.Open(path, false)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rows, err := db.Query("SELECT raw FROM records ORDER BY seq")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var rebuilt strings.Builder
	for rows.Next() {
		rebuilt.WriteString(rows.Text(0))
		rebuilt.WriteByte('\n')
	}
	if rows.Err() != nil || rebuilt.String() != input {
		t.Fatal("not all raw records preserved exactly")
	}
}

func TestPermissionsExclusiveAndCleanup(t *testing.T) {
	input := makeStream(testHeader, transaction(1, "2026-01-01", "synthetic"))
	path, m := buildText(t, input)
	for name, want := range map[string]os.FileMode{path: 0600, filepath.Dir(path): 0700} {
		s, err := os.Lstat(name)
		if err != nil || s.Mode().Perm() != want {
			t.Fatalf("mode mismatch: %v", err)
		}
	}
	original, _ := os.ReadFile(path)
	zero, err := Build(context.Background(), strings.NewReader(input), path)
	wantError(t, err, ErrExists)
	if zero != (Manifest{}) {
		t.Fatal("partial manifest")
	}
	current, _ := os.ReadFile(path)
	if !bytes.Equal(original, current) {
		t.Fatal("overwritten")
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Fatal("staging files leaked")
	}
	link := filepath.Join(filepath.Dir(path), "link.sqlite")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	_, err = Build(context.Background(), strings.NewReader(input), link)
	wantError(t, err, ErrExists)
	_, err = Open(link, m)
	wantError(t, err, ErrUnavailable)
	if err = os.Chmod(path, 0640); err != nil {
		t.Fatal(err)
	}
	_, err = Open(path, m)
	wantError(t, err, ErrUnavailable)
	if err = os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.Chmod(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	_, err = Open(path, m)
	wantError(t, err, ErrUnavailable)
	_, err = Build(context.Background(), strings.NewReader(input), filepath.Join(filepath.Dir(path), "other"))
	wantError(t, err, ErrUnavailable)
}

type eofFailure struct{ io.Reader }

func (r eofFailure) Read(p []byte) (int, error) {
	n, err := r.Reader.Read(p)
	if errors.Is(err, io.EOF) {
		return n, errors.New("sensitive-reader-path-or-value")
	}
	return n, err
}

type inspectEOF struct {
	io.Reader
	inspect func()
}

func (r inspectEOF) Read(p []byte) (int, error) {
	n, err := r.Reader.Read(p)
	if err == io.EOF {
		r.inspect()
	}
	return n, err
}

func TestMalformedRollbackAndVerifyThroughEOF(t *testing.T) {
	valid := makeStream(testHeader, transaction(1, "2026-01-01", "synthetic"), testMetadata, testPosting)
	for name, input := range map[string]string{
		"missing-footer": valid[:strings.LastIndex(valid, `{"type":"footer"`)],
		"footer-digest":  strings.Replace(valid, `"sha256":"`, `"sha256":"0`, 1),
		"footer-count":   strings.Replace(valid, `"directives":1`, `"directives":2`, 1),
		"trailing-byte":  valid + "x",
		"trailing-LF":    valid + "\n",
		"bad-schema":     makeStream(testHeader, strings.Replace(transaction(1, "2026-01-01", "secret-value"), `"id":1`, `"id":2`, 1)),
		"missing-LF":     strings.TrimSuffix(valid, "\n"),
		"empty":          "",
	} {
		t.Run(name, func(t *testing.T) {
			path := destination(t)
			if err := os.Mkdir(filepath.Dir(path), 0700); err != nil {
				t.Fatal(err)
			}
			unrelated := filepath.Join(filepath.Dir(path), "keep")
			if err := os.WriteFile(unrelated, []byte("keep"), 0600); err != nil {
				t.Fatal(err)
			}
			m, err := Build(context.Background(), strings.NewReader(input), path)
			wantError(t, err, ErrInvalidStream)
			if m != (Manifest{}) {
				t.Fatal("partial manifest")
			}
			if strings.Contains(err.Error(), "secret-value") || strings.Contains(err.Error(), path) {
				t.Fatal("unsafe error")
			}
			entries, _ := os.ReadDir(filepath.Dir(path))
			if len(entries) != 1 || entries[0].Name() != "keep" {
				t.Fatal("cleanup removed unrelated files or leaked partials")
			}
		})
	}
	path := destination(t)
	_, err := Build(context.Background(), eofFailure{strings.NewReader(valid)}, path)
	wantError(t, err, ErrUnavailable)
	if strings.Contains(err.Error(), "sensitive") {
		t.Fatal("reader error leaked")
	}
	if _, err = os.Lstat(filepath.Dir(path)); !os.IsNotExist(err) {
		t.Fatal("owned empty directory not cleaned")
	}
	checked := false
	_, err = Build(context.Background(), inspectEOF{strings.NewReader(valid), func() {
		checked = true
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Error("published before EOF")
		}
		entries, _ := os.ReadDir(filepath.Dir(path))
		for _, entry := range entries {
			if strings.HasSuffix(entry.Name(), "-journal") {
				continue
			}
			db, e := sqlite.Open(filepath.Join(filepath.Dir(path), entry.Name()), false)
			if e != nil {
				t.Error(e)
				continue
			}
			r, e := db.Query("SELECT count(*) FROM sqlite_schema")
			if e != nil {
				t.Error(e)
			} else {
				if !r.Next() || r.Int64(0) != 0 {
					t.Error("schema committed before EOF")
				}
				_ = r.Close()
			}
			_ = db.Close()
		}
	}}, path)
	if err != nil || !checked {
		t.Fatalf("EOF inspection: %v", err)
	}
}

func TestCancellation(t *testing.T) {
	input := makeStream(testHeader, transaction(1, "2026-01-01", "synthetic"))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	path := destination(t)
	_, err := Build(ctx, strings.NewReader(input), path)
	wantError(t, err, context.Canceled)
	if _, err = os.Lstat(filepath.Dir(path)); !os.IsNotExist(err) {
		t.Fatal("precanceled build created files")
	}
	ctx, cancel = context.WithCancel(context.Background())
	_, err = Build(ctx, inspectEOF{strings.NewReader(input), cancel}, path)
	wantError(t, err, context.Canceled)
	if _, err = os.Lstat(filepath.Dir(path)); !os.IsNotExist(err) {
		t.Fatal("canceled build leaked files")
	}
	path, m := buildText(t, input)
	i := openIndex(t, path, m)
	_, err = i.Transactions(ctx, PageRequest{})
	wantError(t, err, context.Canceled)
	_, err = i.Detail(ctx, 1)
	wantError(t, err, context.Canceled)
	// Force native work to be executing when the cancellation watcher interrupts.
	for pass := 0; pass < 5; pass++ {
		ctx, cancel := context.WithCancel(context.Background())
		join := cancelSQLite(ctx, i.db)
		rows, err := i.db.Query("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT x FROM n")
		if err != nil {
			t.Fatal(err)
		}
		if !rows.Next() {
			t.Fatal("recursive statement did not start")
		}
		cancel()
		join()
		for rows.Next() {
		}
		if err := rows.Close(); err == nil {
			t.Fatal("native statement was not interrupted")
		}
		if _, err := i.Detail(context.Background(), 1); err != nil {
			t.Fatalf("late interrupt leaked into next method: %v", err)
		}
	}
	ctx, cancel = context.WithCancel(context.Background())
	cancel()
	wantError(t, i.db.IntegrityCheck(ctx), context.Canceled)
}

func mutate(t *testing.T, path string, query string, args ...any) {
	t.Helper()
	db, err := sqlite.Open(path, true)
	if err != nil {
		t.Fatal(err)
	}
	if err = db.Exec(query, args...); err != nil {
		t.Fatal(err)
	}
	if err = db.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestCorruptionAndManifestMismatch(t *testing.T) {
	input := makeStream(testHeader, transaction(1, "2026-01-01", "synthetic"))
	mutations := map[string]func(*testing.T, string){
		"header": func(t *testing.T, p string) {
			f, e := os.OpenFile(p, os.O_WRONLY, 0)
			if e != nil {
				t.Fatal(e)
			}
			_, e = f.WriteAt([]byte("not a sqlite file"), 0)
			if e != nil {
				t.Fatal(e)
			}
			_ = f.Close()
		},
		"truncated": func(t *testing.T, p string) {
			if e := os.Truncate(p, 100); e != nil {
				t.Fatal(e)
			}
		},
		"raw": func(t *testing.T, p string) {
			mutate(t, p, "UPDATE records SET raw=? WHERE seq=2", transaction(1, "2026-01-01", "altered"))
		},
		"entry-key":        func(t *testing.T, p string) { mutate(t, p, "UPDATE records SET entry_id=2 WHERE seq=2") },
		"date-key":         func(t *testing.T, p string) { mutate(t, p, "UPDATE transactions SET date='2026-01-02'") },
		"id-key":           func(t *testing.T, p string) { mutate(t, p, "UPDATE transactions SET id=2") },
		"missing-header":   func(t *testing.T, p string) { mutate(t, p, "DELETE FROM transactions") },
		"orphan-header":    func(t *testing.T, p string) { mutate(t, p, "INSERT INTO transactions VALUES (2, '2026-01-01', 999)") },
		"missing-footer":   func(t *testing.T, p string) { mutate(t, p, "DELETE FROM records WHERE seq=3") },
		"seq-gap":          func(t *testing.T, p string) { mutate(t, p, "UPDATE records SET seq=4 WHERE seq=3") },
		"manifest-json":    func(t *testing.T, p string) { mutate(t, p, "UPDATE manifest SET raw='{}'") },
		"manifest-missing": func(t *testing.T, p string) { mutate(t, p, "DELETE FROM manifest") },
		"schema-index":     func(t *testing.T, p string) { mutate(t, p, "DROP INDEX transactions_date_id") },
		"schema-extra":     func(t *testing.T, p string) { mutate(t, p, "CREATE TABLE extra (value TEXT)") },
	}
	for name, change := range mutations {
		t.Run(name, func(t *testing.T) {
			p, m := buildText(t, input)
			change(t, p)
			i, err := Open(p, m)
			wantError(t, err, ErrCorrupt)
			if i != nil {
				_ = i.Close()
				t.Fatal("corrupt index returned")
			}
		})
	}
	p, m := buildText(t, input)
	changed := m
	changed.Runtime = "beancount/3.2.4 python/3.13.2"
	_, err := Open(p, changed)
	wantError(t, err, ErrRevisionMismatch)
	_, err = Open(p, Manifest{})
	wantError(t, err, ErrRevisionMismatch)
	_, err = Open(filepath.Join(filepath.Dir(p), "missing"), m)
	wantError(t, err, ErrUnavailable)
}

func TestPagingCursorsAndRevision(t *testing.T) {
	records := []string{testHeader}
	for id := 1; id <= 510; id++ {
		date := "2026-01-01"
		if id%2 == 0 {
			date = "2026-01-02"
		}
		records = append(records, transaction(id, date, "synthetic"))
	}
	path, m := buildText(t, makeStream(records...))
	i := openIndex(t, path, m)
	first, err := i.Transactions(context.Background(), PageRequest{})
	if err != nil || len(first.Transactions) != 100 || first.NextCursor == "" {
		t.Fatalf("default page: %v", err)
	}
	max, err := i.Transactions(context.Background(), PageRequest{Limit: 500})
	if err != nil || len(max.Transactions) != 500 || max.NextCursor == "" {
		t.Fatalf("max page: %v", err)
	}
	var ids []int64
	cursor := ""
	for {
		page, err := i.Transactions(context.Background(), PageRequest{Limit: 73, Cursor: cursor})
		if err != nil {
			t.Fatal(err)
		}
		wire, _ := json.Marshal(page)
		if len(wire) > MaxResponseBytes {
			t.Fatal("oversize page")
		}
		for _, tx := range page.Transactions {
			ids = append(ids, tx.ID)
		}
		cursor = page.NextCursor
		if cursor == "" {
			break
		}
	}
	var want []int64
	for id := 510; id >= 2; id -= 2 {
		want = append(want, int64(id))
	}
	for id := 509; id >= 1; id -= 2 {
		want = append(want, int64(id))
	}
	if !reflect.DeepEqual(ids, want) {
		t.Fatal("keyset order lost/duplicated entries")
	}
	for _, limit := range []int{-1, 501} {
		_, err = i.Transactions(context.Background(), PageRequest{Limit: limit})
		wantError(t, err, ErrInvalidRequest)
	}
	for _, bad := range []string{"?", strings.Repeat("a", 513), base64Cursor(`{"revision":"x","date":"2026-01-01","id":1}`), encodeCursor(pageCursor{m.Revision, "2026-01-03", 1}), encodeCursor(pageCursor{m.Revision, "2026-01-01", 999}), encodeCursor(pageCursor{m.Revision, "2026-01-01", -1}), encodeCursor(pageCursor{m.Revision, "2026-02-30", 1})} {
		_, err = i.Transactions(context.Background(), PageRequest{Cursor: bad})
		wantError(t, err, ErrInvalidCursor)
	}
	tail, err := i.Transactions(context.Background(), PageRequest{Cursor: encodeCursor(pageCursor{m.Revision, "2026-01-01", 1})})
	if err != nil || len(tail.Transactions) != 0 || tail.NextCursor != "" {
		t.Fatalf("tail page: %v", err)
	}
	records[0] = strings.Replace(testHeader, "beancount/3.2.3", "beancount/3.2.4", 1)
	second, m2 := buildText(t, makeStream(records...))
	j := openIndex(t, second, m2)
	if m.SourceDigest != m2.SourceDigest || m.Revision == m2.Revision {
		t.Fatal("revision omitted runtime/stream")
	}
	_, err = j.Transactions(context.Background(), PageRequest{Cursor: first.NextCursor})
	wantError(t, err, ErrRevisionMismatch)
	_, err = i.Detail(context.Background(), 999)
	wantError(t, err, ErrNotFound)
	_, err = i.Detail(context.Background(), 0)
	wantError(t, err, ErrInvalidRequest)
}

func base64Cursor(raw string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

func TestPageAndDetailByteLimits(t *testing.T) {
	records := []string{testHeader}
	for id := 1; id <= 5; id++ {
		records = append(records, transaction(id, "2026-01-01", strings.Repeat("x", 350000)))
	}
	path, m := buildText(t, makeStream(records...))
	i := openIndex(t, path, m)
	var ids []int64
	cursor := ""
	for {
		p, err := i.Transactions(context.Background(), PageRequest{Cursor: cursor})
		if err != nil {
			t.Fatal(err)
		}
		wire, _ := json.Marshal(p)
		if len(wire) > MaxResponseBytes || len(p.Transactions) > 2 {
			t.Fatal("byte budget ignored")
		}
		for _, tx := range p.Transactions {
			ids = append(ids, tx.ID)
		}
		cursor = p.NextCursor
		if cursor == "" {
			break
		}
	}
	if !reflect.DeepEqual(ids, []int64{5, 4, 3, 2, 1}) {
		t.Fatal("byte boundary skipped item")
	}
	// Raw JSON containing literal '<' is valid but json.Marshal expands it to
	// six bytes. Account the actual wire encoding, not only len(source).
	literal := strings.ReplaceAll(transaction(1, "2026-01-01", strings.Repeat("<", 180000)), `\u003c`, "<")
	path, m = buildText(t, makeStream(testHeader, literal))
	j := openIndex(t, path, m)
	p, err := j.Transactions(context.Background(), PageRequest{})
	wantError(t, err, ErrResourceLimit)
	if len(p.Transactions) != 0 || p.Revision != "" {
		t.Fatal("partial oversize page")
	}
	d, err := j.Detail(context.Background(), 1)
	wantError(t, err, ErrResourceLimit)
	if len(d.Records) != 0 {
		t.Fatal("partial oversize detail")
	}
	// A directive fitting in one source record can exceed the response bound
	// once the revision/id/date wrappers are serialized.
	tx := transaction(1, "2026-01-01", "")
	tx = transaction(1, "2026-01-01", strings.Repeat("x", MaxResponseBytes-len(tx)-1))
	path, m = buildText(t, makeStream(testHeader, tx))
	j = openIndex(t, path, m)
	_, err = j.Transactions(context.Background(), PageRequest{})
	wantError(t, err, ErrResourceLimit)
	_, err = j.Detail(context.Background(), 1)
	wantError(t, err, ErrResourceLimit)
	// Many individually valid postings must fail as a whole, never truncate.
	records = []string{testHeader, transaction(1, "2026-01-01", "synthetic")}
	for n := 0; n < 4; n++ {
		records = append(records, fmt.Sprintf(`{"type":"posting","entry_id":1,"ordinal":%d,"value":{"account":"Assets:%s","Quantity":{"Number":"1","Currency":"USD"}}}`, n, strings.Repeat("x", 300000)))
	}
	path, m = buildText(t, makeStream(records...))
	j = openIndex(t, path, m)
	_, err = j.Detail(context.Background(), 1)
	wantError(t, err, ErrResourceLimit)
	if _, err = j.Transactions(context.Background(), PageRequest{}); err != nil {
		t.Fatal(err)
	}
}

func TestEmptyAndNontransactionDetail(t *testing.T) {
	path, m := buildText(t, makeStream(testHeader))
	i := openIndex(t, path, m)
	p, err := i.Transactions(context.Background(), PageRequest{})
	if err != nil || len(p.Transactions) != 0 || p.Transactions == nil || p.NextCursor != "" {
		t.Fatalf("empty page: %v", err)
	}
	_, err = i.Detail(context.Background(), 1)
	wantError(t, err, ErrNotFound)
	raw := `{"type":"directive","id":1,"value":{"Kind":"open","Date":"2026-01-01","File":"main.bean","Line":1,"Account":"Assets:Cash","Currencies":["USD"]}}`
	path, m = buildText(t, makeStream(testHeader, raw))
	i = openIndex(t, path, m)
	p, err = i.Transactions(context.Background(), PageRequest{})
	if err != nil || len(p.Transactions) != 0 {
		t.Fatal("nontransaction appeared in list")
	}
	d, err := i.Detail(context.Background(), 1)
	if err != nil || len(d.Records) != 1 || string(d.Records[0]) != raw {
		t.Fatal("nontransaction detail unavailable")
	}
}

func TestConcurrentMethodsAndExclusiveBuilders(t *testing.T) {
	input := makeStream(testHeader, transaction(1, "2026-01-01", "synthetic"))
	path := destination(t)
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	manifests := make(chan Manifest, 2)
	for n := 0; n < 2; n++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			m, e := Build(context.Background(), strings.NewReader(input), path)
			errs <- e
			if e == nil {
				manifests <- m
			}
		}()
	}
	wg.Wait()
	close(errs)
	close(manifests)
	successes := 0
	for e := range errs {
		if e == nil {
			successes++
		} else {
			wantError(t, e, ErrExists)
		}
	}
	if successes != 1 {
		t.Fatal("exclusive publication failed")
	}
	m := <-manifests
	i := openIndex(t, path, m)
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Fatal("parallel staging leak")
	}
	for n := 0; n < 20; n++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for k := 0; k < 10; k++ {
				_, e := i.Transactions(context.Background(), PageRequest{})
				if e != nil && !errors.Is(e, ErrUnavailable) {
					t.Error(e)
				}
				_, e = i.Detail(context.Background(), 1)
				if e != nil && !errors.Is(e, ErrUnavailable) {
					t.Error(e)
				}
			}
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		if e := i.Close(); e != nil {
			t.Error(e)
		}
	}()
	wg.Wait()
}

// This generates incrementally: neither Build nor the synthetic source retains
// all 100k records. Opt-in keeps the default targeted test run small.
func TestSynthetic100K(t *testing.T) {
	if os.Getenv("READINDEX_SCALE") != "1" {
		t.Skip("set READINDEX_SCALE=1 for 100k synthetic stream")
	}
	reader, writer := io.Pipe()
	done := make(chan error, 1)
	go func() {
		hash := sha256.New()
		out := io.MultiWriter(writer, hash)
		_, err := fmt.Fprintln(out, testHeader)
		for n := 1; err == nil && n <= 100000; n++ {
			_, err = fmt.Fprintln(out, transaction(n, "2026-01-01", "synthetic"))
		}
		if err == nil {
			_, err = fmt.Fprintf(writer, `{"type":"footer","records":100001,"directives":100000,"postings":0,"sha256":"%s"}`+"\n", hex.EncodeToString(hash.Sum(nil)))
		}
		_ = writer.CloseWithError(err)
		done <- err
	}()
	path := destination(t)
	m, err := Build(context.Background(), reader, path)
	_ = reader.CloseWithError(err)
	writerErr := <-done
	if err != nil || writerErr != nil {
		t.Fatalf("scale build: %v, writer: %v", err, writerErr)
	}
	if m.Transactions != 100000 {
		t.Fatal("scale count")
	}
	i := openIndex(t, path, m)
	count := 0
	cursor := ""
	last := int64(100001)
	for {
		p, e := i.Transactions(context.Background(), PageRequest{Limit: 500, Cursor: cursor})
		if e != nil {
			t.Fatal(e)
		}
		for _, tx := range p.Transactions {
			if tx.ID != last-1 {
				t.Fatal("scale keyset gap")
			}
			last = tx.ID
			count++
		}
		cursor = p.NextCursor
		if cursor == "" {
			break
		}
	}
	if count != 100000 || last != 1 {
		t.Fatal("scale page count")
	}
	if _, err := i.Detail(context.Background(), 50000); err != nil {
		t.Fatal(err)
	}
}

func TestWhitespaceRetentionAndCursorOverhead(t *testing.T) {
	// Compaction must not turn a bounded response into 500MiB of retained raw
	// whitespace. Page earlier rather than keep unbounded exact source bytes.
	padded := func(raw string) string { return strings.TrimSuffix(raw, "}") + strings.Repeat(" ", 600000) + "}" }
	path, m := buildText(t, makeStream(testHeader, padded(transaction(1, "2026-01-01", "")), padded(transaction(2, "2026-01-01", ""))))
	i := openIndex(t, path, m)
	p, err := i.Transactions(context.Background(), PageRequest{})
	if err != nil || len(p.Transactions) != 1 || p.NextCursor == "" {
		t.Fatalf("retained page bound: %v", err)
	}
	path, m = buildText(t, makeStream(testHeader, padded(transaction(1, "2026-01-01", "")), padded(testMetadata)))
	i = openIndex(t, path, m)
	_, err = i.Detail(context.Background(), 1)
	wantError(t, err, ErrResourceLimit)

	// At the exact wire boundary, an otherwise fitting last item must reserve
	// its cursor if a later transaction exists.
	raw := transaction(2, "2026-01-01", "")
	probe := Page{Revision: strings.Repeat("0", 64), Transactions: []Transaction{{ID: 2, Date: "2026-01-01", Record: json.RawMessage(raw)}}}
	encoded, _ := json.Marshal(probe)
	raw = transaction(2, "2026-01-01", strings.Repeat("x", MaxResponseBytes-len(encoded)))
	path, m = buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", "small"), raw))
	i = openIndex(t, path, m)
	_, err = i.Transactions(context.Background(), PageRequest{Limit: 1})
	wantError(t, err, ErrResourceLimit)
	// Same record without a following item fits exactly (ID spelling same size).
	raw = strings.Replace(raw, `"id":2`, `"id":1`, 1)
	path, m = buildText(t, makeStream(testHeader, raw))
	i = openIndex(t, path, m)
	p, err = i.Transactions(context.Background(), PageRequest{Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ = json.Marshal(p)
	if len(encoded) != MaxResponseBytes || p.NextCursor != "" {
		t.Fatal("exact wire boundary not honored")
	}
}

func TestQueryPlansAvoidDiskSorts(t *testing.T) {
	path, m := buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", "")))
	i := openIndex(t, path, m)
	queries := []struct {
		sql  string
		args []any
	}{
		{"SELECT t.id,t.date,r.raw FROM transactions AS t INDEXED BY transactions_date_id JOIN records AS r ON r.seq=t.seq ORDER BY t.date DESC,t.id DESC LIMIT ?", []any{101}},
		{"SELECT t.id,t.date,r.raw FROM transactions AS t INDEXED BY transactions_date_id JOIN records AS r ON r.seq=t.seq WHERE (t.date,t.id) < (?,?) ORDER BY t.date DESC,t.id DESC LIMIT ?", []any{"2026-01-01", int64(1), 101}},
		{"SELECT raw FROM records INDEXED BY records_entry WHERE entry_id=? ORDER BY seq", []any{int64(1)}},
		{"SELECT r.seq,r.entry_id,r.raw,t.id,t.date,t.seq FROM records AS r LEFT JOIN transactions AS t INDEXED BY transactions_seq ON t.seq=r.seq ORDER BY r.seq", nil},
	}
	for _, q := range queries {
		rows, err := i.db.Query("EXPLAIN QUERY PLAN "+q.sql, q.args...)
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			if strings.Contains(strings.ToUpper(rows.Text(3)), "TEMP B-TREE") {
				t.Error("query requires disk sort")
			}
		}
		if err = rows.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestLargeManifestAndInvalidArguments(t *testing.T) {
	header := strings.Replace(testHeader, "main.bean", strings.Repeat("a", 5000)+".bean", 1)
	path, m := buildText(t, makeStream(header))
	_ = openIndex(t, path, m)
	// Source header fits but escaped manifest would exceed our explicit bound.
	header = strings.Replace(testHeader, "main.bean", strings.Repeat("<", 180000)+".bean", 1)
	path = destination(t)
	_, err := Build(context.Background(), strings.NewReader(makeStream(header)), path)
	wantError(t, err, ErrResourceLimit)
	if _, e := os.Stat(filepath.Dir(path)); !os.IsNotExist(e) {
		t.Fatal("resource failure leaked partial")
	}
	_, err = Build(nil, strings.NewReader(""), destination(t))
	wantError(t, err, ErrInvalidRequest)
	_, err = Build(context.Background(), nil, destination(t))
	wantError(t, err, ErrInvalidRequest)
	_, err = Open("", Manifest{})
	wantError(t, err, ErrUnavailable)
	var i *Index
	if err = i.Close(); err != nil {
		t.Fatal(err)
	}
	_, err = i.Detail(context.Background(), 1)
	wantError(t, err, ErrUnavailable)
	_, err = i.Transactions(context.Background(), PageRequest{})
	wantError(t, err, ErrUnavailable)
	path, m = buildText(t, makeStream(testHeader))
	i = openIndex(t, path, m)
	_, err = i.Detail(nil, 1)
	wantError(t, err, ErrInvalidRequest)
	_, err = i.Transactions(nil, PageRequest{})
	wantError(t, err, ErrInvalidRequest)
}

func TestOpenRejectsExpressionIndexBeforeIntegrity(t *testing.T) {
	path, m := buildText(t, makeStream(testHeader, transaction(1, "2026-01-01", "synthetic")))
	items := make([]string, 80)
	for n := range items {
		items[n] = fmt.Sprintf("printf('%%0000001d',%d)", n)
	}
	mutate(t, path, "CREATE INDEX crafted ON records(CAST(seq AS TEXT) IN ("+strings.Join(items, ",")+"))")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	b = bytes.ReplaceAll(b, []byte("%0000001d"), []byte("%0100000d"))
	if err := os.WriteFile(path, b, 0600); err != nil {
		t.Fatal(err)
	}
	// Evaluating this expression would require a denied scratch file. Reopen
	// must reject the unexpected schema without evaluating it.
	for pass := 0; pass < 3; pass++ {
		i, err := OpenContext(context.Background(), path, m)
		wantError(t, err, ErrCorrupt)
		if i != nil {
			i.Close()
			t.Fatal("unexpected schema accepted")
		}
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(b, after) {
		t.Fatal("rejected file was modified", err)
	}
	files, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(files) != 1 {
		t.Fatal("reopen leaked files", err)
	}
}

// Cancel at a deterministic context poll well into stream replay, not after a
// machine-dependent sleep or before OpenContext even acquires a connection.
type replayCancelContext struct {
	context.Context
	cancel context.CancelFunc
	polls  atomic.Int64
}

func (c *replayCancelContext) Err() error {
	if c.polls.Add(1) == 1000 {
		c.cancel()
	}
	return c.Context.Err()
}

func TestOpenContextCancelDuringReplayCleanup(t *testing.T) {
	records := []string{testHeader}
	for n := 1; n <= 2000; n++ {
		records = append(records, transaction(n, "2026-01-01", "synthetic"))
	}
	path, m := buildText(t, makeStream(records...))
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for pass := 0; pass < 5; pass++ {
		base, cancel := context.WithCancel(context.Background())
		ctx := &replayCancelContext{Context: base, cancel: cancel}
		i, err := OpenContext(ctx, path, m)
		cancel()
		wantError(t, err, context.Canceled)
		if i != nil {
			i.Close()
			t.Fatal("canceled reopen returned index")
		}
		if ctx.polls.Load() < 1000 {
			t.Fatal("did not reach replay")
		}
		// Failed reopen finalized its reader and joined its interrupt watcher;
		// no lingering read lock may block a fresh exclusive writer.
		db, err := sqlite.Open(path, true)
		if err != nil {
			t.Fatal(err)
		}
		if err := db.Exec("BEGIN EXCLUSIVE"); err != nil {
			t.Fatal(err)
		}
		if err := db.Exec("ROLLBACK"); err != nil {
			t.Fatal(err)
		}
		if err := db.Close(); err != nil {
			t.Fatal(err)
		}
		i, err = OpenContext(context.Background(), path, m)
		if err != nil {
			t.Fatal("cancellation poisoned reopen", err)
		}
		if err := i.Close(); err != nil {
			t.Fatal(err)
		}
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("cancellation modified index", err)
	}
	files, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(files) != 1 {
		t.Fatal("cancellation leaked files", err)
	}
	_, err = OpenContext(nil, path, m)
	wantError(t, err, ErrInvalidRequest)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = OpenContext(ctx, path, m)
	wantError(t, err, context.Canceled)
}

func TestBuildSyncsCreatedDirectoryParent(t *testing.T) {
	for _, existing := range []bool{false, true} {
		for _, failParent := range []bool{false, true} {
			t.Run(fmt.Sprintf("existing=%v/fail-parent=%v", existing, failParent), func(t *testing.T) {
				path := destination(t)
				dir := filepath.Dir(path)
				parent := filepath.Dir(dir)
				if existing {
					if err := os.Mkdir(dir, 0700); err != nil {
						t.Fatal(err)
					}
				}
				var calls []string
				m, err := build(context.Background(), strings.NewReader(makeStream(testHeader)), path, func(p string) error {
					calls = append(calls, p)
					if p == parent && failParent {
						return ErrUnavailable
					}
					return syncDir(p)
				})
				if !existing && failParent {
					wantError(t, err, ErrUnavailable)
					if m != (Manifest{}) {
						t.Fatal("failed sync returned manifest")
					}
					if _, err := os.Lstat(dir); !os.IsNotExist(err) {
						t.Fatal("failed parent sync leaked directory", err)
					}
					if len(calls) < 2 || calls[0] != dir || calls[1] != parent {
						t.Fatal("sync order", calls)
					}
					return
				}
				if err != nil {
					t.Fatal(err)
				}
				want := []string{dir}
				if !existing {
					want = append(want, parent)
				}
				if !reflect.DeepEqual(calls, want) {
					t.Fatal("sync order", calls)
				}
				openIndex(t, path, m)
			})
		}
	}
}
