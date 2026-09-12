package app

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/gin-gonic/gin"
)

func appendIdempotencyFixture(t *testing.T) (*Server, *fakeGitHubLedgerAPI) {
	t.Helper()
	t.Setenv("LEDGER_AUTH_DISABLED", "true")
	fake := newFakeGitHubLedgerAPI(t, map[string]string{
		"main.bean":                 "include \"commodities.bean\"\ninclude \"accounts.bean\"\ninclude \"transactions/2026/05.bean\"\n",
		"commodities.bean":          "2026-01-01 commodity CNY\n",
		"accounts.bean":             "2026-01-01 open Assets:Cash CNY\n2026-01-01 open Expenses:Food CNY\n",
		"transactions/2026/05.bean": "; May\n",
	})
	t.Cleanup(fake.server.Close)
	cfg := githubAPITestConfig(t, fake)
	return &Server{cfg: cfg, writer: NewLedgerWriter(cfg, nil)}, fake
}

func TestAppendGitHubRetryAfterCommitResponseFailureWritesOnce(t *testing.T) {
	s, fake := appendIdempotencyFixture(t)
	fake.failNextRefResponse = true
	response := appendIdempotencyRequest(t, s.appendEntry, appendIdempotencyEntry(), "server-retry")
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if count := strings.Count(fake.files["transactions/2026/05.bean"], `"Cafe"`); count != 1 || fake.commitCount != 1 {
		t.Fatalf("ambiguous commit retry: entries=%d commits=%d", count, fake.commitCount)
	}
}

func TestAppendFailedValidationRollsBackReceipt(t *testing.T) {
	cfg := testLedger(t)
	checker := filepath.Join(t.TempDir(), "bean-check")
	if err := os.WriteFile(checker, []byte("#!/bin/sh\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", checker)
	writer := NewLedgerWriter(cfg, nil)
	entry := appendIdempotencyEntry()
	entry.Payee = "Rollback probe"
	_, err := writer.AppendEntriesWithOperationIDs("test", []LedgerEntry{entry}, []string{"rollback-key"})
	if err == nil {
		t.Fatal("expected validation failure")
	}
	if _, err := os.Stat(writer.appendReceiptPath("rollback-key")); !os.IsNotExist(err) {
		t.Fatalf("receipt survived rollback: %v", err)
	}
	if err := os.WriteFile(checker, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if _, err := writer.AppendEntriesWithOperationIDs("test", []LedgerEntry{entry}, []string{"rollback-key"}); err != nil {
			t.Fatal(err)
		}
	}
	text := string(mustRead(t, transactionFileForDate(cfg, entry.Date)))
	if count := strings.Count(text, `"Rollback probe"`); count != 1 {
		t.Fatalf("after rollback/retry, copies=%d", count)
	}
}

func TestAppendOperationIDsRejectInvalidRequests(t *testing.T) {
	s, fake := appendIdempotencyFixture(t)
	for _, ids := range [][]string{{""}, {"../escape"}, {strings.Repeat("x", 129)}, {"one", "two"}} {
		response := appendIdempotencyRequest(t, s.appendBatch, map[string]any{"entries": []LedgerEntry{appendIdempotencyEntry()}, "operationIds": ids}, "")
		if response.Code != http.StatusBadRequest {
			t.Fatalf("ids=%v status=%d", ids, response.Code)
		}
	}
	if fake.commitCount != 0 {
		t.Fatal("invalid operation IDs reached commit")
	}
}

func TestAppendIdempotencyHeaderAllowedAcrossConfiguredOrigins(t *testing.T) {
	t.Setenv("LEDGER_CORS_ORIGINS", "https://frontend.example.com")
	router := gin.New()
	router.Use(corsMiddleware())
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodOptions, "/api/ledger/append", nil)
	request.Header.Set("Origin", "https://frontend.example.com")
	request.Header.Set("Access-Control-Request-Headers", "content-type,idempotency-key")
	router.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNoContent || !strings.Contains(recorder.Header().Get("Access-Control-Allow-Headers"), "Idempotency-Key") {
		t.Fatalf("preflight: %d %v", recorder.Code, recorder.Header())
	}
}

func appendIdempotencyEntry() LedgerEntry {
	return LedgerEntry{Kind: "transaction", Date: "2026-05-03", Payee: "Cafe", Currency: "CNY", Postings: []EntryPosting{
		{Account: "Expenses:Food", Amount: "12.00", Currency: "CNY"},
		{Account: "Assets:Cash", Amount: "-12.00", Currency: "CNY"},
	}}
}

func appendIdempotencyRequest(t *testing.T, handler gin.HandlerFunc, payload any, key string) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(recorder)
	c.Request = httptest.NewRequest(http.MethodPost, "/", bytes.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")
	if key != "" {
		c.Request.Header.Set("Idempotency-Key", key)
	}
	handler(c)
	return recorder
}

func TestAppendRetryAfterLostResponseWritesOnce(t *testing.T) {
	s, fake := appendIdempotencyFixture(t)
	entry := appendIdempotencyEntry()
	for i := 0; i < 2; i++ {
		// A fresh writer models a restart after the first response was lost.
		s.writer = NewLedgerWriter(s.cfg, nil)
		response := appendIdempotencyRequest(t, s.appendEntry, entry, "operation-one")
		if response.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
		}
	}
	if count := strings.Count(fake.files["transactions/2026/05.bean"], `"Cafe"`); count != 1 {
		t.Fatalf("retry wrote %d copies", count)
	}
	if fake.commitCount != 1 {
		t.Fatalf("commits=%d, want 1", fake.commitCount)
	}
}

func TestAppendBatchRetryAsIndividualOperationsWritesOnce(t *testing.T) {
	s, fake := appendIdempotencyFixture(t)
	first, second := appendIdempotencyEntry(), appendIdempotencyEntry()
	second.Payee = "Bakery"
	response := appendIdempotencyRequest(t, s.appendBatch, map[string]any{
		"entries": []LedgerEntry{first, second}, "operationIds": []string{"batch-one", "batch-two"},
	}, "")
	if response.Code != http.StatusOK {
		t.Fatalf("batch: %d %s", response.Code, response.Body.String())
	}
	for i, entry := range []LedgerEntry{first, second} {
		response = appendIdempotencyRequest(t, s.appendEntry, entry, []string{"batch-one", "batch-two"}[i])
		if response.Code != http.StatusOK {
			t.Fatalf("replay: %d %s", response.Code, response.Body.String())
		}
	}
	if count := strings.Count(fake.files["transactions/2026/05.bean"], "2026-05-03 *"); count != 2 {
		t.Fatalf("batch retry wrote %d entries", count)
	}
}

func TestAppendIdempotencyKeyRejectsChangedPayload(t *testing.T) {
	s, fake := appendIdempotencyFixture(t)
	entry := appendIdempotencyEntry()
	response := appendIdempotencyRequest(t, s.appendEntry, entry, "same-key")
	if response.Code != http.StatusOK {
		t.Fatal(response.Body.String())
	}
	entry.Date = "2026-06-03"
	response = appendIdempotencyRequest(t, s.appendEntry, entry, "same-key")
	if response.Code != http.StatusConflict {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if fake.commitCount != 1 {
		t.Fatalf("changed payload created %d commits", fake.commitCount)
	}
}

func TestAppendConcurrentOperationIDsWriteOnce(t *testing.T) {
	for _, conflicting := range []bool{false, true} {
		t.Run(map[bool]string{false: "same-content", true: "conflicting-content"}[conflicting], func(t *testing.T) {
			s, fake := appendIdempotencyFixture(t)
			const workers = 12
			start := make(chan struct{})
			results := make(chan error, workers)
			var group sync.WaitGroup
			for index := 0; index < workers; index++ {
				group.Add(1)
				go func(index int) {
					defer group.Done()
					entry := appendIdempotencyEntry()
					if conflicting && index%2 == 1 {
						entry.Payee = "Bakery"
					}
					<-start
					_, err := s.writer.AppendEntriesWithOperationIDs("test", []LedgerEntry{entry}, []string{"concurrent-operation"})
					results <- err
				}(index)
			}
			close(start)
			group.Wait()
			close(results)
			conflicts := 0
			for err := range results {
				if errors.Is(err, errAppendIdempotencyConflict) {
					conflicts++
					continue
				}
				if err != nil {
					t.Fatal(err)
				}
			}
			wantedConflicts := 0
			if conflicting {
				wantedConflicts = workers / 2
			}
			if conflicts != wantedConflicts {
				t.Fatalf("conflicts=%d want=%d", conflicts, wantedConflicts)
			}
			if count := strings.Count(fake.files["transactions/2026/05.bean"], "2026-05-03 *"); count != 1 || fake.commitCount != 1 {
				t.Fatalf("concurrent writes: entries=%d commits=%d", count, fake.commitCount)
			}
		})
	}
}

func TestAppendLocalCompletedReplaySkipsValidation(t *testing.T) {
	cfg := testLedger(t)
	checker := filepath.Join(t.TempDir(), "bean-check")
	if err := os.WriteFile(checker, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", checker)
	writer := NewLedgerWriter(cfg, nil)
	entry := appendIdempotencyEntry()
	if _, err := writer.AppendEntriesWithOperationIDs("test", []LedgerEntry{entry}, []string{"completed-local"}); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(checker); err != nil {
		t.Fatal(err)
	}
	// A replay verifies durable provenance and makes no candidate ledger write.
	writer = NewLedgerWriter(cfg, nil)
	if _, err := writer.AppendEntriesWithOperationIDs("test", []LedgerEntry{entry}, []string{"completed-local"}); err != nil {
		t.Fatalf("completed replay revalidated the ledger: %v", err)
	}
}

func TestAppendLocalIndependentWritersShareReceiptLock(t *testing.T) {
	cfg := testLedger(t)
	cfg.LedgerFilesystemLockEnabled = true
	checker := filepath.Join(t.TempDir(), "bean-check")
	if err := os.WriteFile(checker, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", checker)
	const workers = 6
	start := make(chan struct{})
	results := make(chan error, workers)
	entry := appendIdempotencyEntry()
	entry.Payee = "Independent writers"
	for index := 0; index < workers; index++ {
		writer := NewLedgerWriter(cfg, nil)
		go func() {
			<-start
			_, err := writer.AppendEntriesWithOperationIDs("test", []LedgerEntry{entry}, []string{"shared-lock-operation"})
			results <- err
		}()
	}
	close(start)
	for index := 0; index < workers; index++ {
		if err := <-results; err != nil {
			t.Error(err)
		}
	}
	text := string(mustRead(t, transactionFileForDate(cfg, entry.Date)))
	if count := strings.Count(text, `"Independent writers"`); count != 1 {
		t.Fatalf("independent writers appended %d copies", count)
	}
}

func TestAppendLocalPartialBatchFailureRollsBackEntriesAndReceipts(t *testing.T) {
	cfg := testLedger(t)
	writer := NewLedgerWriter(cfg, nil)
	first, second := appendIdempotencyEntry(), appendIdempotencyEntry()
	first.Payee = "Partial rollback probe"
	second.Date = "2026-06-03"
	blockedPath := transactionFileForDate(cfg, second.Date)
	if err := os.MkdirAll(blockedPath, 0o700); err != nil {
		t.Fatal(err)
	}
	before := string(mustRead(t, transactionFileForDate(cfg, first.Date)))
	_, err := writer.AppendEntriesWithOperationIDs("test", []LedgerEntry{first, second}, []string{"partial-first", "partial-second"})
	if err == nil {
		t.Fatal("expected second file write failure")
	}
	if after := string(mustRead(t, transactionFileForDate(cfg, first.Date))); before != after {
		t.Fatal("earlier batch entry survived rollback")
	}
	for _, id := range []string{"partial-first", "partial-second"} {
		if _, err := os.Stat(writer.appendReceiptPath(id)); !os.IsNotExist(err) {
			t.Fatalf("receipt %s survived rollback: %v", id, err)
		}
	}
}
