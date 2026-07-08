package app

import (
	"net/http"
	"os"
	"strings"

	"github.com/gin-gonic/gin"
)

func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		origin := strings.TrimSpace(c.GetHeader("Origin"))
		if !strings.HasPrefix(c.Request.URL.Path, "/api/") || origin == "" {
			c.Next()
			return
		}
		if crossOriginAllowed(c, origin) {
			c.Header("Access-Control-Allow-Origin", normalizeWebOrigin(origin))
			c.Header("Access-Control-Allow-Credentials", "true")
			c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization")
			c.Header("Access-Control-Allow-Methods", "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS")
			c.Header("Vary", appendVary(c.Writer.Header().Get("Vary"), "Origin"))
			if c.Request.Method == http.MethodOptions {
				c.AbortWithStatus(http.StatusNoContent)
				return
			}
		}
		c.Next()
	}
}

func crossOriginAllowed(c *gin.Context, origin string) bool {
	normalized := normalizeWebOrigin(origin)
	if normalized == "" {
		return false
	}
	if sameOriginAllowed(c, normalized) {
		return true
	}
	for _, allowed := range configuredCORSOrigins() {
		if normalized == allowed {
			return true
		}
	}
	return false
}

func requestUsesConfiguredCrossOrigin(c *gin.Context) bool {
	origin := normalizeWebOrigin(c.GetHeader("Origin"))
	return origin != "" && origin != normalizeWebOrigin(requestOrigin(c)) && crossOriginAllowed(c, origin)
}

func configuredCORSOrigins() []string {
	origins := []string{}
	origins = appendConfiguredWebAuthnOrigins(origins, os.Getenv("LEDGER_CORS_ORIGINS"))
	origins = appendConfiguredWebAuthnOrigins(origins, os.Getenv("CORS_ALLOWED_ORIGINS"))
	origins = appendConfiguredWebAuthnOrigins(origins, os.Getenv("PUBLIC_ORIGINS"))
	return origins
}

func appendVary(current string, value string) string {
	for _, item := range strings.Split(current, ",") {
		if strings.EqualFold(strings.TrimSpace(item), value) {
			return current
		}
	}
	if strings.TrimSpace(current) == "" {
		return value
	}
	return current + ", " + value
}
