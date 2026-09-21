package boundedstream

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const header = `{"type":"header","version":1,"source_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","entry_file":"main.bean","runtime":"beancount/3.2.3 python/3.13.2","exporter":"bounded-v1"}`
const tx = `{"type":"directive","id":1,"value":{"Kind":"transaction","Date":"2026-01-01","File":"main.bean","Line":1,"Flag":"*","Narration":"synthetic","Tags":[],"Links":[]}}`
const post = `{"type":"posting","entry_id":1,"ordinal":0,"value":{"account":"Assets:Cash","Quantity":{"Number":"-1.25000000000000000000000001E+2","Currency":"USD"}}}`
const meta = `{"type":"metadata","entry_id":1,"posting":-1,"key":"a","value":{"type":"decimal","value":"1E-99999999"}}`

func stream(records ...string) string {
	var b strings.Builder
	var directives, postings int
	for _, r := range records {
		b.WriteString(r)
		b.WriteByte('\n')
		var obj map[string]any
		_ = json.Unmarshal([]byte(r), &obj)
		if obj["type"] == "directive" {
			directives++
		}
		if obj["type"] == "posting" {
			postings++
		}
	}
	h := sha256.Sum256([]byte(b.String()))
	fmt.Fprintf(&b, `{"type":"footer","records":%d,"directives":%d,"postings":%d,"sha256":"%s"}`+"\n", len(records), directives, postings, hex.EncodeToString(h[:]))
	return b.String()
}

func verifyText(s string) (Summary, error) {
	return Verify(context.Background(), strings.NewReader(s), nil)
}
func requireInvalid(t *testing.T, s string) {
	t.Helper()
	summary, err := verifyText(s)
	if !errors.Is(err, ErrInvalid) {
		t.Fatalf("expected invalid, got %v", err)
	}
	if summary != (Summary{}) {
		t.Fatal("partial summary escaped")
	}
}

func TestVerifySummaryAndVisitorOwnership(t *testing.T) {
	option := `{"type":"option","key":"title","value":"Example"}`
	commodity := `{"type":"commodity","value":"USD"}`
	postingMeta := strings.Replace(meta, `"posting":-1`, `"posting":0`, 1)
	raw := stream(header, option, commodity, tx, meta, post, postingMeta)
	var retained []Record
	s, err := Verify(context.Background(), strings.NewReader(raw), func(r Record) error {
		retained = append(retained, r)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if s.Version != 1 || s.Records != 7 || s.Directives != 1 || s.Postings != 1 || s.Metadata != 2 || s.Options != 1 || s.Commodities != 1 || s.Bytes != int64(len(raw)) {
		t.Fatalf("bad summary: %+v", s)
	}
	if len(retained) != 8 || string(retained[0].Raw) != header || retained[7].Type != "footer" {
		t.Fatal("visitor records overwritten or missing")
	}
	max := 0
	for _, line := range strings.SplitAfter(raw, "\n") {
		if len(line) > max {
			max = len(line)
		}
	}
	if s.MaxRecordBytes != max || s.SourceDigest != strings.Repeat("a", 64) {
		t.Fatal("bad bounds/digest summary")
	}
	// Mutation in a visitor cannot change the verifier's digest/state.
	_, err = Verify(context.Background(), strings.NewReader(raw), func(r Record) error { clear(r.Raw); return nil })
	if err != nil {
		t.Fatal(err)
	}
	if _, err := verifyText(stream(header)); err != nil {
		t.Fatal(err)
	}
}

func TestHeaderAndRecordSchema(t *testing.T) {
	cases := map[string]string{
		"missing header":          stream(tx),
		"second header":           stream(header, header),
		"version":                 stream(strings.Replace(header, `"version":1`, `"version":2`, 1)),
		"float version":           stream(strings.Replace(header, `"version":1`, `"version":1.0`, 1)),
		"null version":            stream(strings.Replace(header, `"version":1`, `"version":null`, 1)),
		"digest":                  stream(strings.Replace(header, strings.Repeat("a", 64), strings.Repeat("A", 64), 1)),
		"runtime":                 stream(strings.Replace(header, "beancount/3.2.3 python/3.13.2", "secret-runtime", 1)),
		"exporter":                stream(strings.Replace(header, "bounded-v1", "bounded-v2", 1)),
		"unknown header field":    stream(strings.TrimSuffix(header, "}") + `,"secret":1}`),
		"unknown record":          stream(header, `{"type":"secret-type"}`),
		"null object":             stream(header, `null`),
		"multiple objects":        stream(header + ` {}`),
		"array":                   stream(header, `[]`),
		"blank":                   stream(header, ``),
		"option number":           stream(header, `{"type":"option","key":"title","value":1}`),
		"commodity null":          stream(header, `{"type":"commodity","value":null}`),
		"duplicate":               stream(strings.TrimSuffix(header, "}") + `,"version":1}`),
		"escaped duplicate":       stream(strings.TrimSuffix(header, "}") + `,"ver\u0073ion":1}`),
		"nested duplicate":        stream(header, tx, strings.Replace(post, `"Number":`, `"Currency":"USD","Number":`, 1)),
		"unpaired high surrogate": stream(header, `{"type":"option","key":"title","value":"\ud800"}`),
		"unpaired low surrogate":  stream(header, `{"type":"option","key":"title","value":"\udc00"}`),
		"invalid utf8":            stream(header, "{\"type\":\"option\",\"key\":\"title\",\"value\":\"\xff\"}"),
		"BOM":                     "\xef\xbb\xbf" + stream(header),
	}
	for name, input := range cases {
		t.Run(name, func(t *testing.T) { requireInvalid(t, input) })
	}
	for _, value := range []string{`"\ud83d\ude00"`, `"\\uD800"`, `"中文😀"`} {
		if _, err := verifyText(stream(header, `{"type":"option","key":"title","value":`+value+`}`)); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSafePaths(t *testing.T) {
	for _, path := range []string{"", "/private/main.bean", "../main.bean", "a/../b", "a//b", "./main.bean", "a/", `C:\main.bean`, `a\b`, "a\x00b", "a\nb"} {
		t.Run(fmt.Sprintf("path-%q", path), func(t *testing.T) {
			encoded, _ := json.Marshal(path)
			requireInvalid(t, stream(strings.Replace(header, `"main.bean"`, string(encoded), 1)))
			if path != "" {
				requireInvalid(t, stream(header, `{"type":"option","key":"include","value":`+string(encoded)+`}`))
			}
		})
	}
	if _, err := verifyText(stream(strings.Replace(header, "main.bean", "账本/main.bean", 1))); err != nil {
		t.Fatal(err)
	}
}

func TestOrdering(t *testing.T) {
	closeDirective := `{"type":"directive","id":1,"value":{"Kind":"close","Date":"2026-01-01","File":"","Line":0,"Account":"Assets:Cash"}}`
	option := `{"type":"option","key":"title","value":"Example"}`
	commodity := `{"type":"commodity","value":"USD"}`
	cases := map[string][]string{
		"id starts one":                    {header, strings.Replace(tx, `"id":1`, `"id":2`, 1)},
		"id repeated":                      {header, tx, tx},
		"id skipped":                       {header, tx, strings.Replace(tx, `"id":1`, `"id":3`, 1)},
		"id string":                        {header, strings.Replace(tx, `"id":1`, `"id":"1"`, 1)},
		"id overflow":                      {header, strings.Replace(tx, `"id":1`, `"id":9223372036854775808`, 1)},
		"posting before directive":         {header, post},
		"posting after close":              {header, closeDirective, post},
		"posting wrong id":                 {header, tx, strings.Replace(post, `"entry_id":1`, `"entry_id":2`, 1)},
		"posting gap":                      {header, tx, strings.Replace(post, `"ordinal":0`, `"ordinal":1`, 1)},
		"posting repeated":                 {header, tx, post, post},
		"metadata before directive":        {header, meta},
		"metadata wrong directive":         {header, tx, strings.Replace(meta, `"entry_id":1`, `"entry_id":2`, 1)},
		"metadata previous directive":      {header, tx, strings.Replace(tx, `"id":1`, `"id":2`, 1), meta},
		"metadata future posting":          {header, tx, strings.Replace(meta, `"posting":-1`, `"posting":0`, 1)},
		"metadata directive after posting": {header, tx, post, meta},
		"metadata old posting":             {header, tx, post, strings.Replace(post, `"ordinal":0`, `"ordinal":1`, 1), strings.Replace(meta, `"posting":-1`, `"posting":0`, 1)},
		"duplicate metadata":               {header, tx, meta, meta},
		"unsorted metadata":                {header, tx, strings.Replace(meta, `"key":"a"`, `"key":"z"`, 1), meta},
		"internal metadata":                {header, tx, strings.Replace(meta, `"key":"a"`, `"key":"__secret"`, 1)},
		"source metadata":                  {header, tx, strings.Replace(meta, `"key":"a"`, `"key":"filename"`, 1)},
		"late option":                      {header, tx, option},
		"option after commodity":           {header, commodity, option},
		"late commodity":                   {header, tx, commodity},
		"duplicate commodity":              {header, commodity, commodity},
		"unsorted commodities":             {header, commodity, strings.Replace(commodity, "USD", "CNY", 1)},
	}
	for name, records := range cases {
		t.Run(name, func(t *testing.T) { requireInvalid(t, stream(records...)) })
	}
	if _, err := verifyText(stream(header, tx, meta, strings.Replace(meta, `"key":"a"`, `"key":"b"`, 1), post, strings.Replace(post, `"ordinal":0`, `"ordinal":1`, 1), strings.Replace(tx, `"id":1`, `"id":2`, 1), postFor(2))); err != nil {
		t.Fatal(err)
	}
}
func postFor(id int) string {
	return strings.Replace(post, `"entry_id":1`, fmt.Sprintf(`"entry_id":%d`, id), 1)
}

func TestDirectiveAndPostingTypes(t *testing.T) {
	base := `"Kind":%q,"Date":"2026-01-01","File":"main.bean","Line":1`
	kinds := map[string]string{
		"open":        `,"Account":"Assets:Cash","Currencies":["USD"],"Booking":"FIFO"`,
		"close":       `,"Account":"Assets:Cash"`,
		"commodity":   `,"Currency":"USD"`,
		"pad":         `,"Account":"Assets:Cash","Account2":"Equity:Opening"`,
		"balance":     `,"Account":"Assets:Cash","Currency":"USD","AmountValue":{"Number":"1.000000000000000001","Currency":"USD"},"Tolerance":"1E-18","DiffAmount":{"Number":"0","Currency":"USD"}`,
		"transaction": `,"Flag":"*","Payee":"Example","Narration":"Example","Tags":["a","b"],"Links":[]`,
		"note":        `,"Account":"Assets:Cash","Narration":"Example","Tags":[],"Links":[]`,
		"event":       `,"Name":"location","Value":"Example"`,
		"query":       `,"Name":"example","Value":"SELECT account"`,
		"price":       `,"Currency":"HOOL","QuoteCurrency":"USD","AmountValue":{"Number":"1","Currency":"USD"}`,
		"document":    `,"Account":"Assets:Cash","Filename":"docs/example.pdf","Tags":[],"Links":[]`,
		"custom":      `,"CustomType":"budget","CustomValues":[{"type":"account","value":"Expenses:Food"}]`,
	}
	for kind, extra := range kinds {
		t.Run(kind, func(t *testing.T) {
			r := `{"type":"directive","id":1,"value":{` + fmt.Sprintf(base, kind) + extra + `}}`
			if _, err := verifyText(stream(header, r)); err != nil {
				t.Fatal(err)
			}
			for _, fragment := range []string{`"Kind":"` + kind + `",`, `"Date":"2026-01-01",`, `"File":"main.bean",`, `,"Line":1`} {
				requireInvalid(t, stream(header, strings.Replace(r, fragment, "", 1)))
			}
			for _, field := range []string{`"Postings":[]`, `"Metadata":{}`, `"secret":true`} {
				requireInvalid(t, stream(header, strings.TrimSuffix(r, "}}")+","+field+"}}"))
			}
		})
	}
	mutations := [][2]string{
		{`"Line":1`, `"Line":-1`}, {`"Line":1`, `"Line":1e0`}, {`"File":"main.bean"`, `"File":"../secret"`},
		{`"Date":"2026-01-01"`, `"Date":"2026-02-30"`}, {`"Date":"2026-01-01"`, `"Date":"0000-01-01"`},
		{`"Kind":"transaction"`, `"Kind":"unknown"`}, {`"Tags":[]`, `"Tags":["z","a"]`},
		{`"Tags":[]`, `"Tags":["a","a"]`}, {`"Tags":[]`, `"Tags":[1]`}, {`"Narration":"synthetic"`, `"Narration":null`},
	}
	for i, m := range mutations {
		t.Run(fmt.Sprintf("directive-%d", i), func(t *testing.T) { requireInvalid(t, stream(header, strings.Replace(tx, m[0], m[1], 1))) })
	}
	for _, number := range []string{`1`, `null`, `true`, `"NaN"`, `"Infinity"`, `"1/2"`, `"1_000"`, `" 1"`, `""`, `"1e"`, `"--1"`} {
		r := strings.Replace(post, `"-1.25000000000000000000000001E+2"`, number, 1)
		requireInvalid(t, stream(header, tx, r))
	}
	for _, number := range []string{"0", "-0.00", "+1.2", "1E-999999999999999999999", ".5", "1.", "9.999999999999999999999999999999999999"} {
		r := strings.Replace(post, "-1.25000000000000000000000001E+2", number, 1)
		if _, err := verifyText(stream(header, tx, r)); err != nil {
			t.Fatal(err)
		}
	}
	for _, extra := range []string{`,"CostDate":"2026-01-01"`, `,"CostLabel":"Example"`, `,"Metadata":{}`, `,"Price":{"Number":"1","Currency":null}`, `,"Cost":{"Number":"1","Currency":"USD","secret":1}`} {
		requireInvalid(t, stream(header, tx, strings.TrimSuffix(post, "}}")+extra+"}}"))
	}
	fullPost := strings.TrimSuffix(post, "}}") + `,"flag":"!","Cost":{"Number":"1","Currency":"USD"},"CostDate":"2026-01-01","CostLabel":"Example","Price":{"Number":"1E+2","Currency":"USD"}}}`
	if _, err := verifyText(stream(header, tx, fullPost)); err != nil {
		t.Fatal(err)
	}
}

func metadataValue(v string) string {
	return `{"type":"metadata","entry_id":1,"posting":-1,"key":"a","value":` + v + `}`
}
func nested(depth int) string {
	v := `{"type":"none","value":null}`
	for i := 0; i < depth; i++ {
		v = `{"type":"list","value":[` + v + `]}`
	}
	return v
}
func TestTypedValues(t *testing.T) {
	valid := []string{`{"type":"none","value":null}`, `{"type":"bool","value":false}`, `{"type":"int","value":1234567890123456789012345678901234567890}`, `{"type":"str","value":"中文"}`, `{"type":"decimal","value":"1.00000000000000000001E-18"}`, `{"type":"date","value":"2024-02-29"}`, `{"type":"amount","value":{"Number":"1E+2","Currency":"USD"}}`, nested(16)}
	for _, v := range valid {
		if _, err := verifyText(stream(header, tx, metadataValue(v))); err != nil {
			t.Fatal(err)
		}
	}
	invalid := []string{`null`, `[]`, `{}`, `{"type":"bool","value":1}`, `{"type":"int","value":"1"}`, `{"type":"int","value":1.0}`, `{"type":"int","value":1e0}`, `{"type":"none","value":"null"}`, `{"type":"str","value":false}`, `{"type":"decimal","value":0.1}`, `{"type":"date","value":"2025-02-29"}`, `{"type":"list","value":{}}`, `{"type":"str","value":"x","secret":0}`, `{"type":"account","value":"Assets:Cash"}`, `{"type":"secret","value":null}`, `{"type":"amount","value":{"Number":"1"}}`, nested(17), nested(100)}
	for i, v := range invalid {
		t.Run(fmt.Sprintf("invalid-%d", i), func(t *testing.T) { requireInvalid(t, stream(header, tx, metadataValue(v))) })
	}
}

func TestFooterAndTruncation(t *testing.T) {
	good := stream(header, tx, post)
	for i := 0; i < len(good); i++ {
		requireInvalid(t, good[:i])
	}
	for _, suffix := range []string{"\n", " ", "{}\n", "\x00", good} {
		requireInvalid(t, good+suffix)
	}
	for _, change := range [][2]string{{`"records":3`, `"records":2`}, {`"directives":1`, `"directives":2`}, {`"postings":1`, `"postings":0`}, {`"records":3`, `"records":3.0`}, {`"sha256":"`, `"sha256":"0`}, {`"type":"footer"`, `"type":"footer","secret":1`}} {
		requireInvalid(t, strings.Replace(good, change[0], change[1], 1))
	}
	// Valid JSON but a change to preceding raw bytes invalidates the digest.
	requireInvalid(t, strings.Replace(good, "synthetic", "Synthetic", 1))
	requireInvalid(t, strings.Replace(good, `"version":1`, `"version": 1`, 1))
	// Conversely the hash must be over original bytes, not remarshal output.
	if _, err := verifyText(stream(strings.Replace(header, `"version":1`, `"version": 1`, 1))); err != nil {
		t.Fatal(err)
	}
}

func TestRecordByteLimit(t *testing.T) {
	prefix := `{"type":"option","key":"title","value":"`
	suffix := `"}`
	for _, delta := range []int{-1, 0, 1} {
		line := prefix + strings.Repeat("x", MaxRecordBytes-len(prefix)-len(suffix)-1+delta) + suffix
		_, err := verifyText(stream(header, line))
		if delta <= 0 && err != nil {
			t.Fatal(err)
		}
		if delta > 0 && !errors.Is(err, ErrInvalid) {
			t.Fatal("oversize accepted")
		}
	}
	// Infinite input without LF must stop after the bounded read, not at EOF.
	r := &endlessReader{}
	_, err := Verify(context.Background(), r, nil)
	if !errors.Is(err, ErrInvalid) || r.read > MaxRecordBytes {
		t.Fatalf("unbounded read: %d %v", r.read, err)
	}
}

type endlessReader struct{ read int }

func (r *endlessReader) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = ' '
	}
	r.read += len(p)
	return len(p), nil
}

type errorReader struct{}

func (errorReader) Read([]byte) (int, error) { return 0, errors.New("SECRET /private/path") }

type countReader struct{ reads int }

func (r *countReader) Read([]byte) (int, error) { r.reads++; return 0, io.EOF }

func TestCancellationCallbackAndSanitizedErrors(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := &countReader{}
	_, err := Verify(ctx, r, nil)
	if !errors.Is(err, context.Canceled) || r.reads != 0 {
		t.Fatal("must cancel before reading")
	}
	ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	_, err = Verify(ctx, strings.NewReader(stream(header, tx, post)), func(Record) error { calls++; cancel(); return nil })
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatal("must cancel before next callback")
	}
	_, err = Verify(context.Background(), strings.NewReader(stream(header)), func(Record) error { return errors.New("SECRET /private/path") })
	if !errors.Is(err, ErrVisitor) || strings.Contains(err.Error(), "SECRET") || strings.Contains(err.Error(), "/private") {
		t.Fatal("unsafe callback error")
	}
	_, err = Verify(context.Background(), errorReader{}, nil)
	if !errors.Is(err, ErrRead) || strings.Contains(err.Error(), "SECRET") {
		t.Fatal("unsafe reader error")
	}
	_, err = verifyText(stream(header, `{"type":"SECRET /private/path"}`))
	if err == nil || strings.Contains(err.Error(), "SECRET") || strings.Contains(err.Error(), "/private") {
		t.Fatal("unsafe schema error")
	}
	ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	_, err = Verify(ctx, strings.NewReader(stream(header)), func(r Record) error {
		if r.Type == "footer" {
			cancel()
		}
		return nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatal("footer cancellation ignored")
	}
	// The callback may have seen records, but no success is possible until the
	// footer AND EOF have been validated. Future builders must not publish yet.
	calls = 0
	s, err := Verify(context.Background(), strings.NewReader(stream(header)+"x"), func(Record) error { calls++; return nil })
	if err == nil || s != (Summary{}) || calls != 2 {
		t.Fatal("provisional footer semantics")
	}
}

func TestStreamingManyRecords(t *testing.T) {
	// Generate on a pipe instead of allocating the test stream or all directives.
	r, w := io.Pipe()
	done := make(chan error, 1)
	const count = 10000
	go func() {
		h := sha256.New()
		out := io.MultiWriter(w, h)
		_, err := fmt.Fprintln(out, header)
		for i := 1; i <= count && err == nil; i++ {
			_, err = fmt.Fprintln(out, strings.Replace(tx, `"id":1`, fmt.Sprintf(`"id":%d`, i), 1))
		}
		if err == nil {
			_, err = fmt.Fprintf(w, `{"type":"footer","records":%d,"directives":%d,"postings":0,"sha256":"%x"}`+"\n", count+1, count, h.Sum(nil))
		}
		w.CloseWithError(err)
		done <- err
	}()
	s, err := Verify(context.Background(), r, nil)
	r.Close()
	if err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if s.Directives != count || s.Records != count+1 {
		t.Fatal("bad streaming counts")
	}
}

func pythonRuntime(t *testing.T) (string, string) {
	t.Helper()
	_, source, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(source), "../../.."))
	python := os.Getenv("LEDGER_STREAM_PYTHON")
	if python == "" {
		python = "/tmp/ledger-stream-phase1-venv/bin/python"
		if _, err := os.Stat(python); err != nil {
			python = "python3"
		}
	}
	cmd := exec.Command(python, "-c", "import beancount")
	if err := cmd.Run(); err != nil {
		if os.Getenv("LEDGER_STREAM_PYTHON") != "" {
			t.Fatal("configured Python cannot import beancount")
		}
		t.Skip("Python with beancount unavailable; set LEDGER_STREAM_PYTHON")
	}
	return python, filepath.Join(root, "App/LedgerMobile/Runtime")
}

func TestPythonInteroperability(t *testing.T) {
	python, runtimeDir := pythonRuntime(t)
	base := t.TempDir()
	ledger := filepath.Join(base, "ledger")
	output := filepath.Join(base, "output")
	for _, dir := range []string{ledger, output} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	// Sorted public metadata is deliberate: the contract requires strict key
	// order to prevent duplicate metadata without a per-directive seen-key set.
	fixture := `option "operating_currency" "USD"
2000-01-01 open Assets:Cash USD
2000-01-01 open Assets:Stock HOOL "FIFO"
2000-01-01 open Equity:Opening USD
2000-01-01 commodity HOOL
2000-01-02 pad Assets:Cash Equity:Opening
2000-01-03 balance Assets:Cash 100 ~ 0.001 USD
2026-01-01 * "Example buy" #example ^receipt
  approved: TRUE
  due: 2026-02-03
  exact: 0.123456789123456789
  memo: "中文"
  Assets:Stock 2 HOOL {10 USD, 2025-12-31, "example"} @ 10 USD
    broker: "Example"
    exact: 0.123456789123456789
  Assets:Cash -20 USD
2026-01-02 price HOOL 12 USD
2026-01-03 custom "budget" Assets:Cash "monthly" 100.000000000000000001 USD 0.123456789123456789 TRUE 2026-02-01
2026-01-04 note Assets:Cash "Example" #tag ^link
2026-01-05 event "location" "Example"
2026-01-06 query "example" "SELECT account"
2026-01-07 document Assets:Cash "example.pdf"
2026-01-08 close Equity:Opening
`
	if err := os.WriteFile(filepath.Join(ledger, "main.bean"), []byte(fixture), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ledger, "example.pdf"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(output, "stream.jsonl")
	cmd := exec.Command(python, "-c", `import sys; sys.path.insert(0,sys.argv[1]); import ledger_stream; ledger_stream.export_stream(sys.argv[2],sys.argv[3])`, runtimeDir, ledger, destination)
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("synthetic Python export failed: %v\n%s", err, b)
	}
	f, err := os.Open(destination)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	seen := map[string]bool{}
	s, err := Verify(context.Background(), f, func(r Record) error {
		if r.Type == "directive" {
			var obj struct{ Value struct{ Kind string } }
			if err := json.Unmarshal(r.Raw, &obj); err != nil {
				return err
			}
			seen[obj.Value.Kind] = true
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(seen) != 12 || s.Postings < 4 || s.Metadata < 6 {
		t.Fatalf("incomplete interoperability coverage: kinds=%d summary=%+v", len(seen), s)
	}
	// Source digest interoperability, independently recomputed for the only
	// parsed source. Documents are not parsed ledger source files.
	data, err := os.ReadFile(filepath.Join(ledger, "main.bean"))
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.New()
	for _, part := range [][]byte{[]byte("main.bean"), data} {
		n := uint64(len(part))
		for shift := 56; shift >= 0; shift -= 8 {
			h.Write([]byte{byte(n >> uint(shift))})
		}
		h.Write(part)
	}
	if s.SourceDigest != fmt.Sprintf("%x", h.Sum(nil)) {
		t.Fatal("source digest interoperability mismatch")
	}
}

func TestPythonMetadataOrderingContract(t *testing.T) {
	python, runtimeDir := pythonRuntime(t)
	// Detect the exact exporter contract rather than quietly accepting an
	// unbounded metadata-key set. No exporter monkey patch is used here.
	cmd := exec.Command(python, "-c", `import sys,io; sys.path.insert(0,sys.argv[1]); import ledger_stream; b=io.BytesIO(); w=ledger_stream._Writer(b); w.metadata(1,-1,{"z":"last","a":"first"}); sys.stdout.buffer.write(b.getvalue())`, runtimeDir)
	b, err := cmd.Output()
	if err != nil {
		t.Fatal("synthetic Python metadata probe failed")
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) != 2 {
		t.Fatal("metadata probe record count")
	}
	for i, want := range []string{"a", "z"} {
		var record struct{ Key string }
		if err := json.Unmarshal([]byte(lines[i]), &record); err != nil {
			t.Fatal(err)
		}
		if record.Key != want {
			t.Fatalf("metadata key %d = %q, want %q", i, record.Key, want)
		}
	}
	if _, err := verifyText(stream(header, tx, lines[0], lines[1])); err != nil {
		t.Fatal(err)
	}
}

func FuzzVerify(f *testing.F) {
	for _, seed := range []string{stream(header), stream(header, tx, meta, post), stream(header, tx, metadataValue(nested(16))), "{}\n", "\xff\n"} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		s, err := Verify(context.Background(), bytes.NewReader(b), nil)
		if err != nil && s != (Summary{}) {
			t.Fatal("partial summary")
		}
		if err == nil && (s.Bytes != int64(len(b)) || s.MaxRecordBytes > MaxRecordBytes) {
			t.Fatal("bad bounds")
		}
	})
}

func TestReaderErrorsAndReusedBuffer(t *testing.T) {
	for _, ctx := range []context.Context{nil, context.Background()} {
		if s, err := Verify(ctx, nil, nil); !errors.Is(err, ErrInvalid) || s != (Summary{}) {
			t.Fatal("nil argument accepted")
		}
	}
	// A caller may have an arbitrarily large bufio.Reader. Verification must
	// not reuse it as its own line buffer and consume an arbitrarily long line.
	r := bufio.NewReaderSize(strings.NewReader(strings.Repeat("x", 4*MaxRecordBytes)), 4*MaxRecordBytes)
	if _, err := Verify(context.Background(), r, nil); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	if r.Buffered() != 3*MaxRecordBytes {
		t.Fatal("caller buffer used for unbounded ReadSlice")
	}
	for _, prefix := range []string{header + "\n", stream(header)} {
		_, err := Verify(context.Background(), io.MultiReader(strings.NewReader(prefix), errorReader{}), nil)
		if !errors.Is(err, ErrRead) || strings.Contains(err.Error(), "SECRET") {
			t.Fatal("reader error was swallowed or disclosed")
		}
	}
	_, err := Verify(context.Background(), strings.NewReader(stream(header)), func(r Record) error {
		if r.Type == "footer" {
			return errors.New("SECRET")
		}
		return nil
	})
	if !errors.Is(err, ErrVisitor) || strings.Contains(err.Error(), "SECRET") {
		t.Fatal("footer callback failure ignored")
	}
}

func TestCLI(t *testing.T) {
	_, source, _, _ := runtime.Caller(0)
	serverRoot := filepath.Clean(filepath.Join(filepath.Dir(source), "../.."))
	binary := filepath.Join(t.TempDir(), "ledger-stream-check")
	build := exec.Command("go", "build", "-o", binary, "./cmd/ledger-stream-check")
	build.Dir = serverRoot
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build CLI: %v %s", err, output)
	}
	path := filepath.Join(t.TempDir(), "SECRET-input.jsonl")
	if err := os.WriteFile(path, []byte(stream(header, tx, post)), 0600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(binary, path)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatal("valid CLI failed")
	}
	var summary Summary
	if err := json.Unmarshal(output, &summary); err != nil || summary.Directives != 1 || summary.Postings != 1 {
		t.Fatal("invalid CLI summary")
	}
	for _, secret := range []string{"SECRET", "Assets:Cash", "synthetic", "main.bean"} {
		if bytes.Contains(output, []byte(secret)) {
			t.Fatal("CLI leaked financial/source values")
		}
	}
	cases := [][]string{nil, {path, path}, {path + "-missing"}, {filepath.Dir(path)}, {"--help"}}
	for _, args := range cases {
		out, err := exec.Command(binary, args...).CombinedOutput()
		if err == nil || bytes.Contains(out, []byte("SECRET")) || bytes.Contains(out, []byte(filepath.Dir(path))) {
			t.Fatal("CLI failure missing or unsafe")
		}
	}
	if err := os.WriteFile(path, []byte(stream(header, `{"type":"SECRET"}`)), 0600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(binary, path).CombinedOutput()
	if err == nil || bytes.Contains(out, []byte("SECRET")) {
		t.Fatal("CLI invalid record leaked data or succeeded")
	}
}
