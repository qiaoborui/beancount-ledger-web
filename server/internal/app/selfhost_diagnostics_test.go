package app

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestFetchIndexerDiagnosticsPreservesActionableFailure(t *testing.T) {
	indexer := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/health" {
			t.Fatalf("path=%q", request.URL.Path)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"attempts":3,"firstIndexSucceeded":false,"lastError":"ledger checkout has uncommitted changes"}`))
	}))
	defer indexer.Close()

	got, err := fetchIndexerDiagnostics(context.Background(), indexer.URL+"/health", indexer.Client())
	if err != nil {
		t.Fatal(err)
	}
	if !got.Reachable || got.Attempts != 3 || got.FirstIndexSucceeded || !strings.Contains(got.LastError, "uncommitted changes") {
		t.Fatalf("diagnostics=%#v", got)
	}
}

func TestFetchIndexerDiagnosticsRejectsUnavailableEndpoint(t *testing.T) {
	indexer := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer indexer.Close()

	_, err := fetchIndexerDiagnostics(context.Background(), indexer.URL, indexer.Client())
	if err == nil || !strings.Contains(err.Error(), "HTTP 503") {
		t.Fatalf("error=%v", err)
	}
}

func TestSetupReadinessKeepsCurrentIndexerFailureVisibleAfterPreviousSuccess(t *testing.T) {
	indexer := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"attempts":4,"firstIndexSucceeded":true,"lastError":"fetch ledger checkout: authentication failed"}`))
	}))
	defer indexer.Close()

	server := &Server{
		cfg:        Config{IndexerHealthURL: indexer.URL},
		indexStore: testLedgerIndexPort{revision: LedgerIndexRevision{ID: 1}},
	}
	got := server.setupReadiness(context.Background())
	if got.State != "indexer_error" || !got.Active || !strings.Contains(got.Error, "read-only token") {
		t.Fatalf("readiness=%#v", got)
	}
}

func TestSetupReadinessPreservesFirstIndexAcrossIndexerRestart(t *testing.T) {
	indexer := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"attempts":1,"firstIndexSucceeded":false}`))
	}))
	defer indexer.Close()

	server := &Server{
		cfg:        Config{IndexerHealthURL: indexer.URL},
		indexStore: testLedgerIndexPort{revision: LedgerIndexRevision{ID: 1}},
	}
	got := server.setupReadiness(context.Background())
	if got.State != "ready" || got.Indexer == nil || !got.Indexer.FirstIndexSucceeded {
		t.Fatalf("readiness=%#v", got)
	}
}

func TestActionableIndexerErrorDoesNotExposeBeanCheckDetails(t *testing.T) {
	raw := "bean-check ledger revision: /data/ledger/transactions/private.bean:17 invalid account Assets:Secret"
	got := actionableIndexerError(raw)
	if !strings.Contains(got, "failed validation") || strings.Contains(got, "Assets:Secret") || strings.Contains(got, "private.bean") {
		t.Fatalf("public error=%q", got)
	}
}

func TestActionableIndexerErrorDirectsMissingMainBeanToOnboarding(t *testing.T) {
	raw := "bean-check ledger revision: /data/ledger/main.bean: no such file or directory"
	got := actionableIndexerError(raw)
	if !strings.Contains(got, "finish first-run onboarding") || strings.Contains(got, "/data/ledger") {
		t.Fatalf("public error=%q", got)
	}
}

func TestSetupReadinessDoesNotExposeDatabaseDetails(t *testing.T) {
	server := &Server{indexStoreErr: errors.New("connect postgres://ledger:secret@database/private: password authentication failed")}
	got := server.setupReadiness(context.Background())
	if got.State != "database_error" || got.Error != databaseReadinessError || strings.Contains(got.Error, "secret") {
		t.Fatalf("readiness=%#v", got)
	}
}
