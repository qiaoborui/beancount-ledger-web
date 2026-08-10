package main

import (
	"net/http"
	"testing"
	"time"
)

func TestNewHTTPServerTimeoutFields(t *testing.T) {
	server := newHTTPServer(":0", http.NotFoundHandler())

	if server.ReadHeaderTimeout <= 0 {
		t.Fatalf("ReadHeaderTimeout = %v, want > 0", server.ReadHeaderTimeout)
	}
	if server.ReadTimeout <= 0 {
		t.Fatalf("ReadTimeout = %v, want > 0", server.ReadTimeout)
	}
	if server.IdleTimeout <= 0 {
		t.Fatalf("IdleTimeout = %v, want > 0", server.IdleTimeout)
	}
	if server.MaxHeaderBytes <= 0 {
		t.Fatalf("MaxHeaderBytes = %d, want > 0", server.MaxHeaderBytes)
	}
	// WriteTimeout must cover the longest supported response: the SSE agent
	// turn and telegram webhook both hold the connection open for up to
	// agentServiceRequestTimeout (14 minutes).
	if server.WriteTimeout < 14*time.Minute {
		t.Fatalf("WriteTimeout = %v, want >= 14m", server.WriteTimeout)
	}
}
