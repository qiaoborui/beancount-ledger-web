package main

import (
	"context"
	"errors"
	"net"
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

func TestServeHTTPShutsDownWhenContextIsCancelled(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	requestHandled := make(chan struct{}, 1)
	server := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		requestHandled <- struct{}{}
		writer.WriteHeader(http.StatusNoContent)
	})}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- serveHTTP(ctx, server, listener)
	}()

	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Get("http://" + listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusNoContent)
	}
	select {
	case <-requestHandled:
	case <-time.After(2 * time.Second):
		t.Fatal("server did not handle request")
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("server did not shut down")
	}
}

func TestServeHTTPReturnsListenerError(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(http.ResponseWriter, *http.Request) {})}

	err = serveHTTP(context.Background(), server, listener)
	if err == nil || errors.Is(err, http.ErrServerClosed) {
		t.Fatalf("serveHTTP error = %v, want listener error", err)
	}
}
