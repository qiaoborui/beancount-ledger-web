package app

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

// exampleCanonicalModel books the example ledger the way the iOS loader would:
// relative sources, no raw text and explicit units on every posting.
func exampleCanonicalModel(t testing.TB, root string) *LocalCanonicalModel {
	t.Helper()
	lines, err := ReadLedgerLines(filepath.Join(root, "main.bean"), map[string]bool{})
	if err != nil {
		t.Fatal(err)
	}
	parsed := ParseBeanLines(lines)
	if len(parsed.Errors) != 0 {
		t.Fatal(parsed.Errors)
	}
	model := &LocalCanonicalModel{Version: 1, Options: OptionsMapFromBeanEntries(parsed.Entries)}
	for _, entry := range parsed.Entries {
		switch entry.Kind {
		case "transaction", "open", "close", "commodity", "balance", "price", "pad", "note", "event", "custom":
		default:
			continue
		}
		entry.File, _ = filepath.Rel(root, entry.File)
		entry.RawLines = nil
		entry.Postings = append([]parsedPosting(nil), entry.Postings...)
		blank, total, currency := -1, 0, ""
		for i, posting := range entry.Postings {
			if posting.Blank {
				blank = i
				continue
			}
			total += posting.Quantity.Cents()
			currency = posting.Quantity.Currency
		}
		if blank >= 0 {
			cents := -total
			sign := ""
			if cents < 0 {
				sign, cents = "-", -cents
			}
			entry.Postings[blank].Quantity = BeanAmount{Number: fmt.Sprintf("%s%d.%02d", sign, cents/100, cents%100), Currency: currency}
		}
		model.Entries = append(model.Entries, entry)
	}
	return model
}

func exampleLocalRequest(t *testing.T, example string) LocalRequest {
	t.Helper()
	ledger := t.TempDir()
	root := filepath.Join(ledger, "generations", "initial", "workspace")
	if err := os.CopyFS(root, os.DirFS(example)); err != nil {
		t.Fatal(err)
	}
	return LocalRequest{WorkspaceRoot: root, RuntimeRoot: filepath.Join(ledger, "runtime"), Method: "GET",
		Canonical: exampleCanonicalModel(t, root)}
}

// dispatchWithDeferral runs one request on a fresh snapshot, so the deferred
// and eager parses never share the process-wide page cache.
func dispatchWithDeferral(t *testing.T, input LocalRequest, deferred bool) json.RawMessage {
	t.Helper()
	previous := localDeferRawParse
	localDeferRawParse = deferred
	defer func() { localDeferRawParse = previous }()
	localPageCache.Lock()
	localPageCache.cache = nil
	localPageCache.Unlock()
	return localTestDispatch(t, input)
}

var (
	localSnapshotSequenceSuffix = regexp.MustCompile(`:[0-9]+"`)
	localPageCursor             = regexp.MustCompile(`"nextCursor":"[^"]*"`)
)

// normalizeSnapshotIdentity masks values derived from the process-wide
// snapshot sequence, which differs between any two fresh snapshots by design:
// revision suffixes and the signed cursors whose scope includes them.
func normalizeSnapshotIdentity(body []byte) []byte {
	body = localPageCursor.ReplaceAll(body, []byte(`"nextCursor":"C"`))
	return localSnapshotSequenceSuffix.ReplaceAll(body, []byte(`:N"`))
}

func TestLocalDeferredRawParseMatchesEagerParseOnExamples(t *testing.T) {
	examples, _ := filepath.Glob(filepath.Join("..", "..", "..", "examples", "*", "main.bean"))
	if len(examples) == 0 {
		t.Fatal("no example ledgers found")
	}
	for _, main := range examples {
		example := filepath.Dir(main)
		t.Run(filepath.Base(example), func(t *testing.T) {
			input := exampleLocalRequest(t, example)
			var all TransactionQueryResult
			input.Path = "/api/ledger/transactions"
			input.Query = map[string]string{"start": "0001-01-01", "end": "9999-12-31"}
			if err := json.Unmarshal(dispatchWithDeferral(t, input, false), &all); err != nil {
				t.Fatal(err)
			}
			if len(all.Transactions) == 0 {
				t.Fatal("example has no transactions")
			}
			first := all.Transactions[0]
			start, end := "0001-01-01", "9999-12-31"
			wide := map[string]string{"start": start, "end": end}
			cases := []struct {
				path  string
				query map[string]string
			}{
				{"/api/ledger/bootstrap", map[string]string{}},
				{"/api/ledger/bootstrap/page", map[string]string{"start": start, "end": end, "today": first.Date}},
				{"/api/ledger/transactions", wide},
				{"/api/ledger/transactions/page", map[string]string{"start": start, "end": end, "limit": "500"}},
				{"/api/ledger/transactions/page", map[string]string{"dialect": localNativePendingCandidatesDialect, "start": start, "end": end}},
				{"/api/ledger/transactions/history-page", map[string]string{"start": start, "end": end}},
				{"/api/ledger/transactions/detail", map[string]string{"file": first.Source.File, "line": fmt.Sprint(first.Source.Line), "hash": first.Source.Hash}},
				{"/api/ledger/entries", wide},
				{"/api/ledger/dashboard", wide},
				{"/api/ledger/summary", wide},
				{"/api/ledger/accounts", map[string]string{}},
			}
			for _, posting := range first.Postings {
				cases = append(cases,
					struct {
						path  string
						query map[string]string
					}{"/api/ledger/accounts/detail", map[string]string{"account": posting.Account, "currency": posting.Currency, "start": start, "end": end}},
					struct {
						path  string
						query map[string]string
					}{"/api/ledger/accounts/detail/page", map[string]string{"account": posting.Account, "currency": posting.Currency}},
				)
			}
			for _, c := range cases {
				input.Path, input.Query = c.path, c.query
				eager := normalizeSnapshotIdentity(dispatchWithDeferral(t, input, false))
				deferred := normalizeSnapshotIdentity(dispatchWithDeferral(t, input, true))
				if !bytes.Equal(eager, deferred) {
					at := 0
					for at < len(eager) && at < len(deferred) && eager[at] == deferred[at] {
						at++
					}
					from := max(0, at-200)
					t.Errorf("%s %v differs at byte %d\n eager: %.400s\n deferred: %.400s", c.path, c.query, at, eager[from:], deferred[from:])
				}
			}
		})
	}
}

// Measures the first request after a model change: a fresh snapshot plus one
// query, with the raw transaction parse eager or deferred.
func BenchmarkLocalColdSnapshotRequest(b *testing.B) {
	gin.SetMode(gin.ReleaseMode)
	root := filepath.Join(b.TempDir(), "generations", "benchmark", "workspace")
	if err := os.MkdirAll(root, 0700); err != nil {
		b.Fatal(err)
	}
	var source strings.Builder
	source.WriteString("option \"operating_currency\" \"CNY\"\n2020-01-01 open Assets:Cash CNY\n2020-01-01 open Expenses:Food CNY\n")
	for i := 0; i < 10000; i++ {
		fmt.Fprintf(&source, "2026-%02d-%02d * \"Shop\" \"Expense %d\" #food\n  memo: \"row %d\"\n  Expenses:Food  10.00 CNY\n  Assets:Cash  -10.00 CNY\n", i%9+1, i%28+1, i, i)
	}
	if err := os.WriteFile(filepath.Join(root, "main.bean"), []byte(source.String()), 0600); err != nil {
		b.Fatal(err)
	}
	model := exampleCanonicalModel(b, root)
	start, end := "2026-01-01", "2026-10-01"
	for _, request := range []struct {
		name, path string
		query      map[string]string
	}{
		{"bootstrap", "/api/ledger/bootstrap", map[string]string{"start": start, "end": end, "today": "2026-09-16"}},
		{"transactions-page", "/api/ledger/transactions/page", map[string]string{"start": start, "end": end, "limit": "100"}},
		{"transactions", "/api/ledger/transactions", map[string]string{"start": start, "end": end}},
	} {
		for _, deferred := range []bool{false, true} {
			b.Run(fmt.Sprintf("%s/deferred=%t", request.name, deferred), func(b *testing.B) {
				previous := localDeferRawParse
				localDeferRawParse = deferred
				defer func() { localDeferRawParse = previous }()
				input := LocalRequest{WorkspaceRoot: root, Canonical: model, Method: "GET", Path: request.path, Query: request.query}
				b.ReportAllocs()
				b.ResetTimer()
				for range b.N {
					localPageCache.Lock()
					localPageCache.cache = nil
					localPageCache.Unlock()
					status, _, err := DispatchLocalRequest(input)
					if status != http.StatusOK || err != nil {
						b.Fatalf("status=%d err=%v", status, err)
					}
				}
			})
		}
	}
}
