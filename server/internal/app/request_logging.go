package app

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
)

// requestIDHeader is the HTTP header used to carry the request ID between
// clients and the server, and to echo it back in responses.
const requestIDHeader = "X-Request-Id"

type requestIDContextKey struct{}

// requestIDFromContext returns the request ID carried by a request context, or
// an empty string when no middleware has assigned one yet.
func requestIDFromContext(ctx context.Context) string {
	if id, ok := ctx.Value(requestIDContextKey{}).(string); ok {
		return id
	}
	return ""
}

// requestLoggingMiddleware generates (or passes through) a request ID, echoes
// it on the response, makes it available to handlers through the request
// context, and records a structured access log line when the request finishes.
func requestLoggingMiddleware(logger *slog.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		requestID := c.GetHeader(requestIDHeader)
		if requestID == "" {
			requestID = newRequestID()
		}
		c.Header(requestIDHeader, requestID)
		c.Request = c.Request.WithContext(context.WithValue(c.Request.Context(), requestIDContextKey{}, requestID))

		c.Next()

		logger.Info("http request",
			slog.String("request_id", requestID),
			slog.String("method", c.Request.Method),
			slog.String("path", c.Request.URL.Path),
			slog.Int("status", c.Writer.Status()),
			slog.Int64("duration_ms", time.Since(start).Milliseconds()),
			slog.String("client_ip", c.ClientIP()),
			slog.String("user_agent", c.Request.UserAgent()),
		)
	}
}

// recoveryMiddleware catches handler panics, logs them through slog with the
// request ID from the request context, and returns a 500 response. It replaces
// gin.Recovery() so panic output joins the structured log stream.
func recoveryMiddleware(logger *slog.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		defer func() {
			if recovered := recover(); recovered != nil {
				logger.Error("panic recovered",
					slog.String("request_id", requestIDFromContext(c.Request.Context())),
					slog.String("method", c.Request.Method),
					slog.String("path", c.Request.URL.Path),
					slog.Any("error", recovered),
					slog.String("stack", string(debug.Stack())),
				)
				if !c.Writer.Written() {
					c.AbortWithStatus(http.StatusInternalServerError)
				} else {
					c.Abort()
				}
			}
		}()
		c.Next()
	}
}

// newRequestID returns a random hex request ID. The timestamp fallback keeps
// logging alive even if the system entropy source is unavailable.
func newRequestID() string {
	var buffer [16]byte
	if _, err := rand.Read(buffer[:]); err != nil {
		return "req-" + strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(buffer[:])
}
