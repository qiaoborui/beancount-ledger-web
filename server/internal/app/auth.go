package app

import (
	"errors"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

const (
	sessionCookieName   = "ledger_session"
	sensitiveCookieName = "ledger_sensitive_until"
)

func authDisabled() bool {
	return truthyEnv("LEDGER_AUTH_DISABLED")
}

func authSecret() ([]byte, error) {
	raw := os.Getenv("AUTH_SECRET")
	if raw == "" {
		return nil, errors.New("AUTH_SECRET is required")
	}
	return []byte(raw), nil
}

func verifyPassword(password string) (bool, error) {
	configured := os.Getenv("APP_PASSWORD")
	if configured == "" {
		return false, errors.New("APP_PASSWORD is required")
	}
	if strings.HasPrefix(configured, "$2a$") || strings.HasPrefix(configured, "$2b$") || strings.HasPrefix(configured, "$2y$") {
		return bcrypt.CompareHashAndPassword([]byte(configured), []byte(password)) == nil, nil
	}
	return password == configured, nil
}

func createSessionToken() (string, error) {
	secret, err := authSecret()
	if err != nil {
		return "", err
	}
	claims := jwt.MapClaims{
		"typ": "session",
		"sub": "owner",
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(30 * 24 * time.Hour).Unix(),
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(secret)
}

func createSensitiveToken() (string, error) {
	secret, err := authSecret()
	if err != nil {
		return "", err
	}
	now := time.Now()
	claims := jwt.MapClaims{
		"typ": "sensitive",
		"sub": "owner",
		"iat": now.Unix(),
		"exp": now.Add(15 * time.Minute).Unix(),
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(secret)
}

func isAuthenticated(c *gin.Context) bool {
	if authDisabled() {
		return true
	}
	token, err := c.Cookie(sessionCookieName)
	if err != nil || token == "" {
		return false
	}
	secret, err := authSecret()
	if err != nil {
		return false
	}
	parsed, err := jwt.Parse(token, func(token *jwt.Token) (any, error) {
		if token.Method != jwt.SigningMethodHS256 {
			return nil, errors.New("unexpected signing method")
		}
		return secret, nil
	})
	if err != nil || !parsed.Valid {
		return false
	}
	claims, ok := parsed.Claims.(jwt.MapClaims)
	return ok && claims["typ"] == "session" && claims["sub"] == "owner"
}

func isSensitiveUnlocked(c *gin.Context) bool {
	if authDisabled() {
		return true
	}
	token, err := c.Cookie(sensitiveCookieName)
	if err != nil {
		return false
	}
	secret, err := authSecret()
	if err != nil {
		return false
	}
	parsed, err := jwt.Parse(token, func(token *jwt.Token) (any, error) {
		if token.Method != jwt.SigningMethodHS256 {
			return nil, errors.New("unexpected signing method")
		}
		return secret, nil
	})
	if err != nil || !parsed.Valid {
		return false
	}
	claims, ok := parsed.Claims.(jwt.MapClaims)
	return ok && claims["typ"] == "sensitive" && claims["sub"] == "owner"
}

func requireAuth(c *gin.Context) bool {
	if isAuthenticated(c) {
		return true
	}
	c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "Unauthorized"})
	return false
}

func requireSensitive(c *gin.Context) bool {
	if !requireAuth(c) {
		return false
	}
	if isSensitiveUnlocked(c) {
		return true
	}
	c.AbortWithStatusJSON(423, gin.H{"error": "Sensitive data is locked"})
	return false
}

func setSessionCookie(c *gin.Context, token string) {
	setAuthCookie(c, sessionCookieName, token, 60*60*24*30)
}

func setSensitiveCookie(c *gin.Context) {
	token, err := createSensitiveToken()
	if err != nil {
		return
	}
	setAuthCookie(c, sensitiveCookieName, token, 15*60)
}

func clearAuthCookies(c *gin.Context) {
	clearAuthCookie(c, sessionCookieName)
	clearSensitiveCookie(c)
}

func clearSensitiveCookie(c *gin.Context) {
	clearAuthCookie(c, sensitiveCookieName)
}

func setAuthCookie(c *gin.Context, name, value string, maxAge int) {
	sameSite := http.SameSiteLaxMode
	secure := gin.Mode() == gin.ReleaseMode
	if requestUsesConfiguredCrossOrigin(c) {
		sameSite = http.SameSiteNoneMode
		secure = true
	}
	http.SetCookie(c.Writer, &http.Cookie{
		Name:     name,
		Value:    value,
		Path:     "/",
		MaxAge:   maxAge,
		Secure:   secure,
		HttpOnly: true,
		SameSite: sameSite,
	})
}

func clearAuthCookie(c *gin.Context, name string) {
	sameSite := http.SameSiteLaxMode
	secure := gin.Mode() == gin.ReleaseMode
	if requestUsesConfiguredCrossOrigin(c) {
		sameSite = http.SameSiteNoneMode
		secure = true
	}
	http.SetCookie(c.Writer, &http.Cookie{
		Name:     name,
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		Secure:   secure,
		HttpOnly: true,
		SameSite: sameSite,
	})
}

func sameOriginMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if !strings.HasPrefix(c.Request.URL.Path, "/api/") || !unsafeHTTPMethod(c.Request.Method) {
			c.Next()
			return
		}
		origin := strings.TrimSpace(c.GetHeader("Origin"))
		if site := strings.ToLower(strings.TrimSpace(c.GetHeader("Sec-Fetch-Site"))); site == "cross-site" && !crossOriginAllowed(c, origin) {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "Cross-site requests are not allowed"})
			return
		}
		if origin == "" {
			c.Next()
			return
		}
		if !sameOriginAllowed(c, origin) && !crossOriginAllowed(c, origin) {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "Cross-site requests are not allowed"})
			return
		}
		c.Next()
	}
}

func unsafeHTTPMethod(method string) bool {
	switch method {
	case http.MethodGet, http.MethodHead, http.MethodOptions:
		return false
	default:
		return true
	}
}

func sameOriginAllowed(c *gin.Context, origin string) bool {
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return false
	}
	for _, allowed := range allowedOrigins(c) {
		if strings.EqualFold(strings.TrimRight(origin, "/"), strings.TrimRight(allowed, "/")) {
			return true
		}
	}
	return false
}

func allowedOrigins(c *gin.Context) []string {
	origins := []string{requestOrigin(c)}
	if configured := configuredPublicOrigin(); configured != "" {
		origins = append(origins, configured)
	}
	return origins
}
