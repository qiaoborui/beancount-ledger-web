package main

import (
	"bytes"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestSelfHostCommandContract(t *testing.T) {
	for _, test := range []struct {
		args []string
		want string
	}{
		{want: "serve"},
		{args: []string{"recover-install-code"}, want: "recover-install-code"},
		{args: []string{"--help"}, want: "help"},
	} {
		got, err := selfHostCommand(test.args)
		if err != nil || got != test.want {
			t.Fatalf("selfHostCommand(%q)=(%q, %v), want %q", test.args, got, err, test.want)
		}
	}
	if _, err := selfHostCommand([]string{"recover-install-code", "extra"}); err == nil {
		t.Fatal("expected extra command arguments to be rejected")
	}
}

func TestWriteUsageDocumentsRecoveryCommand(t *testing.T) {
	var output bytes.Buffer
	writeUsage(&output)
	if !strings.Contains(output.String(), "recover-install-code") || !strings.Contains(output.String(), "setup is incomplete") {
		t.Fatalf("usage=%q", output.String())
	}
}

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
