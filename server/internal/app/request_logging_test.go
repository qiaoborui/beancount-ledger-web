package app

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestRequestLoggingMiddlewareEchoesClientRequestID(t *testing.T) {
	router := gin.New()
	router.Use(requestLoggingMiddleware(discardLogger()))
	router.GET("/ping", func(c *gin.Context) {
		c.String(http.StatusOK, "pong")
	})

	request := httptest.NewRequest(http.MethodGet, "/ping", nil)
	request.Header.Set(requestIDHeader, "client-request-id")
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, request)

	if got := recorder.Header().Get(requestIDHeader); got != "client-request-id" {
		t.Errorf("X-Request-Id = %q, want %q", got, "client-request-id")
	}
}

func TestRequestLoggingMiddlewareGeneratesRequestID(t *testing.T) {
	router := gin.New()
	router.Use(requestLoggingMiddleware(discardLogger()))
	router.GET("/ping", func(c *gin.Context) {
		got := requestIDFromContext(c.Request.Context())
		if got == "" {
			t.Error("request context carries no request id")
		}
		if echoed := c.Writer.Header().Get(requestIDHeader); echoed != got {
			t.Errorf("response X-Request-Id = %q, want %q", echoed, got)
		}
		c.String(http.StatusOK, "pong")
	})

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/ping", nil))

	if got := recorder.Header().Get(requestIDHeader); got == "" {
		t.Error("response carries no X-Request-Id")
	}
}

func TestRecoveryMiddlewareReturns500(t *testing.T) {
	router := gin.New()
	router.Use(requestLoggingMiddleware(discardLogger()), recoveryMiddleware(discardLogger()))
	router.GET("/panic", func(c *gin.Context) {
		panic("boom")
	})

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/panic", nil))

	if recorder.Code != http.StatusInternalServerError {
		t.Errorf("status = %d, want %d", recorder.Code, http.StatusInternalServerError)
	}
}
