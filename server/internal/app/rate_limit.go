package app

import (
	"context"
	"database/sql"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

type RateLimiter interface {
	Check(c *gin.Context, name string, limit int, window time.Duration) bool
}

type rateBucket struct {
	count   int
	resetAt time.Time
}

type memoryRateLimiter struct {
	mu      sync.Mutex
	buckets map[string]rateBucket
}

func NewRateLimiter() RateLimiter {
	return &memoryRateLimiter{buckets: map[string]rateBucket{}}
}

func (r *memoryRateLimiter) Check(c *gin.Context, name string, limit int, window time.Duration) bool {
	if truthyEnv("LEDGER_RATE_LIMIT_DISABLED") || limit <= 0 || window <= 0 {
		return true
	}
	now := time.Now()
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.buckets) > 1000 {
		for key, bucket := range r.buckets {
			if !bucket.resetAt.After(now) {
				delete(r.buckets, key)
			}
		}
	}
	key := name + ":" + clientAddress(c)
	bucket := r.buckets[key]
	if !bucket.resetAt.After(now) {
		bucket = rateBucket{resetAt: now.Add(window)}
	}
	bucket.count++
	r.buckets[key] = bucket
	if bucket.count <= limit {
		return true
	}
	retryAfter := int(time.Until(bucket.resetAt).Seconds())
	if retryAfter < 1 {
		retryAfter = 1
	}
	c.Header("Retry-After", formatInt(retryAfter))
	c.Header("X-RateLimit-Limit", formatInt(limit))
	c.Header("X-RateLimit-Remaining", "0")
	c.Header("X-RateLimit-Reset", formatInt64(bucket.resetAt.Unix()))
	c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "Too many requests"})
	return false
}

type postgresRateLimiter struct {
	db *sql.DB
}

func NewPostgresRateLimiter(db *sql.DB) (RateLimiter, error) {
	limiter := &postgresRateLimiter{db: db}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err := db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS runtime_rate_limits (
  bucket_key TEXT PRIMARY KEY,
  count INTEGER NOT NULL,
  reset_at TIMESTAMPTZ NOT NULL
)`)
	if err != nil {
		return nil, err
	}
	return limiter, nil
}

func (r *postgresRateLimiter) Check(c *gin.Context, name string, limit int, window time.Duration) bool {
	if truthyEnv("LEDGER_RATE_LIMIT_DISABLED") || limit <= 0 || window <= 0 {
		return true
	}
	now := time.Now().UTC()
	resetAt := now.Add(window)
	bucketKey := name + ":" + clientAddress(c)
	var count int
	err := r.db.QueryRowContext(c.Request.Context(), `
INSERT INTO runtime_rate_limits (bucket_key, count, reset_at)
VALUES ($1, 1, $2)
ON CONFLICT (bucket_key)
DO UPDATE SET
  count = CASE WHEN runtime_rate_limits.reset_at <= $3 THEN 1 ELSE runtime_rate_limits.count + 1 END,
  reset_at = CASE WHEN runtime_rate_limits.reset_at <= $3 THEN $2 ELSE runtime_rate_limits.reset_at END
RETURNING count, reset_at`, bucketKey, resetAt, now).Scan(&count, &resetAt)
	if err != nil {
		c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"error": "Rate limiter unavailable"})
		return false
	}
	if count <= limit {
		return true
	}
	retryAfter := int(time.Until(resetAt).Seconds())
	if retryAfter < 1 {
		retryAfter = 1
	}
	c.Header("Retry-After", formatInt(retryAfter))
	c.Header("X-RateLimit-Limit", formatInt(limit))
	c.Header("X-RateLimit-Remaining", "0")
	c.Header("X-RateLimit-Reset", formatInt64(resetAt.Unix()))
	c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "Too many requests"})
	return false
}

func clientAddress(c *gin.Context) string {
	if truthyEnv("TRUST_PROXY_HEADERS") {
		if forwarded := strings.TrimSpace(strings.Split(c.GetHeader("X-Forwarded-For"), ",")[0]); forwarded != "" {
			return forwarded
		}
		if realIP := strings.TrimSpace(c.GetHeader("X-Real-IP")); realIP != "" {
			return realIP
		}
	}
	if host, _, err := net.SplitHostPort(c.Request.RemoteAddr); err == nil && host != "" {
		return host
	}
	return c.Request.RemoteAddr
}
