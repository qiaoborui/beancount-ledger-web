package app

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestLocalResponseSourceSchemaPreservesOpaqueFileValues(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "receipt.pdf")
	for _, path := range []string{"/api/ledger/bootstrap", "/api/ledger/transactions", "/api/ledger/accounts/detail"} {
		t.Run(path, func(t *testing.T) {
			source := map[string]any{"file": filepath.Join(root, "main.bean"), "line": float64(1)}
			metadata := map[string]any{"file": file, "source": map[string]any{"file": file, "line": float64(1)}}
			transaction := map[string]any{"source": source, "metadata": metadata, "entry": map[string]any{"metadata": metadata}}
			payload := map[string]any{"transactions": []any{transaction}, "future": map[string]any{"file": file}}
			if path == "/api/ledger/accounts/detail" {
				payload["rows"] = []any{map[string]any{"txn": transaction}}
			}
			normalizeLocalSourcePaths(payload, localResponseModel(path), root, false)
			if source["file"] != "main.bean" {
				t.Error("known source did not become relative")
			}
			if metadata["file"] != file || metadata["source"].(map[string]any)["file"] != file {
				t.Error("opaque metadata changed")
			}
			if payload["future"].(map[string]any)["file"] != file {
				t.Error("unknown field changed")
			}
		})
	}
	cell := map[string]any{"source": map[string]any{"file": file, "line": float64(1)}, "file": file}
	payload := map[string]any{"rows": []any{[]any{cell, nil}}, "columns": []any{"file", "empty"}}
	before, _ := json.Marshal(payload)
	normalizeLocalSourcePaths(payload, localResponseModel("/api/ledger/bql"), root, false)
	after, _ := json.Marshal(payload)
	if string(before) != string(after) {
		t.Error("BQL cells must remain opaque")
	}
	diagnostic := map[string]any{"file": filepath.Join(root, "main.bean"), "message": file}
	normalizeLocalSourcePaths(diagnostic, reflect.TypeOf(BeanParseError{}), root, false)
	if diagnostic["file"] != "main.bean" || diagnostic["message"] != file {
		t.Error("diagnostic conversion changed")
	}
}

func TestLocalRequestPreservesMetadataFileAndConvertsOnlyTransactionSources(t *testing.T) {
	root := t.TempDir()
	for _, test := range []struct{ method, path string }{
		{http.MethodPost, "/api/ledger/append"},
		{http.MethodPost, "/api/ledger/append-batch"},
		{http.MethodPost, "/api/ledger/imports/commit"},
		{http.MethodPost, "/api/ledger/bql-history"},
		{http.MethodPut, "/api/ledger/transactions"},
		{http.MethodDelete, "/api/ledger/transactions"},
		{http.MethodPost, "/api/ledger/transactions"},
		{http.MethodPost, "/api/ledger/transactions/tags"},
	} {
		t.Run(test.method+test.path, func(t *testing.T) {
			input := LocalRequest{Method: test.method, Path: test.path, Body: json.RawMessage(`{
				"source":{"file":"main.bean","line":1,"hash":"abc"},
				"sources":[{"file":"main.bean","line":1,"hash":"abc"}],
				"metadata":{"file":"receipt.pdf","source":{"file":"metadata.bean","line":1}},
				"entry":{"metadata":{"file":"receipt.pdf"}},
				"entries":[{"metadata":{"file":"receipt.pdf"}}],
				"file":"literal.txt"
			}`)}
			encoded, _, err := localRequestBody(input, root)
			if err != nil {
				t.Fatal(err)
			}
			var body map[string]any
			if err := json.Unmarshal(encoded, &body); err != nil {
				t.Fatal(err)
			}
			metadata := body["metadata"].(map[string]any)
			if metadata["file"] != "receipt.pdf" || metadata["source"].(map[string]any)["file"] != "metadata.bean" {
				t.Errorf("custom metadata was rewritten: %v", metadata)
			}
			for _, entry := range []any{body["entry"], body["entries"].([]any)[0]} {
				if entry.(map[string]any)["metadata"].(map[string]any)["file"] != "receipt.pdf" {
					t.Error("entry metadata was rewritten")
				}
			}
			if body["file"] != "literal.txt" {
				t.Error("unknown file field was rewritten")
			}
			expectedSource, expectedSources := "main.bean", "main.bean"
			if test.path == "/api/ledger/transactions" {
				expectedSource = filepath.Join(root, "main.bean")
			}
			if test.path == "/api/ledger/transactions/tags" {
				expectedSources = filepath.Join(root, "main.bean")
			}
			if body["source"].(map[string]any)["file"] != expectedSource {
				t.Error("incorrect singular source conversion")
			}
			if body["sources"].([]any)[0].(map[string]any)["file"] != expectedSources {
				t.Error("incorrect bulk source conversion")
			}
		})
	}
}

func TestLocalMetadataFileSurvivesAppendReadEditTagsAndDelete(t *testing.T) {
	for _, absolute := range []bool{false, true} {
		t.Run(map[bool]string{false: "relative", true: "absolute"}[absolute], func(t *testing.T) {
			input := localTestRequest(t)
			generation := input.WorkspaceRoot
			stage := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(generation))), "staging", "metadata", "workspace")
			if err := os.CopyFS(stage, os.DirFS(generation)); err != nil {
				t.Fatal(err)
			}
			input.WorkspaceRoot, input.Staging = stage, true
			fileValue := "receipt.pdf"
			if absolute {
				fileValue = filepath.Join(stage, "receipt.pdf")
			}
			entry := LedgerEntry{Kind: "transaction", Date: "2026-05-15", Payee: "Metadata fixture", Narration: "Keep file literal",
				Metadata: map[string]MetadataValue{"file": fileValue},
				Postings: []EntryPosting{{Account: "Expenses:Food", Amount: "3.00", Currency: "CNY"}, {Account: "Assets:Cash", Amount: "-3.00", Currency: "CNY"}}}
			input.Method, input.Path = http.MethodPost, "/api/ledger/append"
			input.Body, _ = json.Marshal(entry)
			localTestDispatch(t, input)
			beanFile := filepath.Join(stage, "transactions/2026/05.bean")
			assertPersisted := func() {
				t.Helper()
				if !strings.Contains(string(mustRead(t, beanFile)), `file: "`+fileValue+`"`) {
					t.Fatalf("persisted file metadata differs from input %q", fileValue)
				}
			}
			assertPersisted()
			readTransaction := func() Transaction {
				t.Helper()
				read := input
				read.Method, read.Path, read.Body = http.MethodGet, "/api/ledger/transactions", nil
				var result TransactionQueryResult
				if err := json.Unmarshal(localTestDispatch(t, read), &result); err != nil {
					t.Fatal(err)
				}
				for _, transaction := range result.Transactions {
					if transaction.Payee == entry.Payee {
						if transaction.Metadata["file"] != fileValue || transaction.Entry == nil || transaction.Entry.Metadata["file"] != fileValue {
							t.Fatalf("readback changed metadata: %+v", transaction)
						}
						if filepath.IsAbs(transaction.Source.File) {
							t.Fatal("source must remain generation-relative")
						}
						return transaction
					}
				}
				t.Fatal("fixture transaction missing")
				return Transaction{}
			}
			transaction := readTransaction()
			entry.Narration = "Edited without changing metadata"
			input.Method = http.MethodPut
			input.Path = "/api/ledger/transactions"
			input.Body, _ = json.Marshal(UpdateTransactionRequest{Source: transaction.Source, Entry: entry})
			localTestDispatch(t, input)
			assertPersisted()
			transaction = readTransaction()
			input.Method, input.Path = http.MethodPost, "/api/ledger/transactions/tags"
			input.Body, _ = json.Marshal(AddTransactionTagsRequest{Sources: []TransactionSource{transaction.Source}, Tags: []string{"checked"}})
			localTestDispatch(t, input)
			assertPersisted()
			transaction = readTransaction()
			input.Method, input.Path = http.MethodDelete, "/api/ledger/transactions"
			input.Body, _ = json.Marshal(DeleteTransactionRequest{Source: transaction.Source, Reason: "Regression fixture"})
			localTestDispatch(t, input)
			assertPersisted() // Recoverable deletion retains the original metadata in comments.
			if strings.Contains(string(mustRead(t, filepath.Join(generation, "transactions/2026/05.bean"))), entry.Payee) {
				t.Fatal("immutable generation changed")
			}
		})
	}
}
