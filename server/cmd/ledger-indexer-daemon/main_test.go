package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

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
