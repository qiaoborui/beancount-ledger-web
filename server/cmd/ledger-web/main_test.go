package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
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

func TestMetricsHTTPServerExposesOnlyMetrics(t *testing.T) {
	metricsServer := newMetricsHTTPServer("127.0.0.1:9091", http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusNoContent)
	}))

	metrics := httptest.NewRecorder()
	metricsServer.Handler.ServeHTTP(metrics, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if metrics.Code != http.StatusNoContent {
		t.Fatalf("metrics status=%d, want %d", metrics.Code, http.StatusNoContent)
	}
	other := httptest.NewRecorder()
	metricsServer.Handler.ServeHTTP(other, httptest.NewRequest(http.MethodGet, "/api/health", nil))
	if other.Code != http.StatusNotFound {
		t.Fatalf("other status=%d, want %d", other.Code, http.StatusNotFound)
	}
	post := httptest.NewRecorder()
	metricsServer.Handler.ServeHTTP(post, httptest.NewRequest(http.MethodPost, "/metrics", nil))
	if post.Code != http.StatusMethodNotAllowed {
		t.Fatalf("post status=%d, want %d", post.Code, http.StatusMethodNotAllowed)
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

func TestServeHTTPServicesShutsDownApplicationAndMetrics(t *testing.T) {
	applicationListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	metricsListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		_ = applicationListener.Close()
		t.Fatal(err)
	}
	applicationServer := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusNoContent)
	})}
	metricsServer := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusOK)
	})}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- serveHTTPServices(ctx,
			httpService{Server: applicationServer, Listener: applicationListener},
			httpService{Server: metricsServer, Listener: metricsListener},
		)
	}()
	client := &http.Client{Timeout: 2 * time.Second}
	for _, addr := range []string{applicationListener.Addr().String(), metricsListener.Addr().String()} {
		response, err := client.Get("http://" + addr)
		if err != nil {
			t.Fatal(err)
		}
		_ = response.Body.Close()
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("servers did not shut down")
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
