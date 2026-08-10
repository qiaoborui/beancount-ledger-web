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
