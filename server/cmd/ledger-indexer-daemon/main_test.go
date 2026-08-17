package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestNewHealthServerTimeoutFields(t *testing.T) {
	server := newHealthServer(":0", http.NotFoundHandler())

	if server.ReadHeaderTimeout <= 0 {
		t.Fatalf("ReadHeaderTimeout = %v, want > 0", server.ReadHeaderTimeout)
	}
	if server.ReadTimeout <= 0 {
		t.Fatalf("ReadTimeout = %v, want > 0", server.ReadTimeout)
	}
	if server.WriteTimeout <= 0 {
		t.Fatalf("WriteTimeout = %v, want > 0", server.WriteTimeout)
	}
	if server.IdleTimeout <= 0 {
		t.Fatalf("IdleTimeout = %v, want > 0", server.IdleTimeout)
	}
	if server.MaxHeaderBytes <= 0 {
		t.Fatalf("MaxHeaderBytes = %d, want > 0", server.MaxHeaderBytes)
	}
}

func TestIndexerReadyFailsWhenLatestAttemptHasAnError(t *testing.T) {
	status := &indexerStatus{
		attempts:    2,
		lastSuccess: time.Now().UTC().Add(-time.Minute),
		lastAttempt: time.Now().UTC(),
		lastError:   "runtime configuration is invalid",
	}
	recorder := httptest.NewRecorder()

	status.ready(recorder, httptest.NewRequest(http.MethodGet, "/ready", nil))

	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if !strings.Contains(recorder.Body.String(), `"firstIndexSucceeded":true`) || !strings.Contains(recorder.Body.String(), status.lastError) {
		t.Fatalf("body=%s", recorder.Body.String())
	}
}

func TestIndexerStandbyDoesNotStartAndRemainsUnready(t *testing.T) {
	t.Setenv("LEDGER_INDEXER_STANDBY", "true")
	if indexerShouldRun() {
		t.Fatal("indexerShouldRun=true in standby mode")
	}

	status := &indexerStatus{}
	health := httptest.NewRecorder()
	status.health(health, httptest.NewRequest(http.MethodGet, "/health", nil))
	if health.Code != http.StatusOK {
		t.Fatalf("health status=%d body=%s", health.Code, health.Body.String())
	}
	ready := httptest.NewRecorder()
	status.ready(ready, httptest.NewRequest(http.MethodGet, "/ready", nil))
	if ready.Code != http.StatusServiceUnavailable {
		t.Fatalf("ready status=%d body=%s", ready.Code, ready.Body.String())
	}
}
