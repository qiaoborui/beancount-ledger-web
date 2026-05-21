package app

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

type rateBucket struct {
	count   int
	resetAt time.Time
}

type RateLimiter struct {
	mu      sync.Mutex
	buckets map[string]rateBucket
}

func NewRateLimiter() *RateLimiter {
	return &RateLimiter{buckets: map[string]rateBucket{}}
}

func (r *RateLimiter) Check(c *gin.Context, name string, limit int, window time.Duration) bool {
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
