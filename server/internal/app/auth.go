package app

import (
	"errors"
	"net/http"
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
		raw = os.Getenv("APP_PASSWORD")
	}
	if raw == "" {
		return nil, errors.New("AUTH_SECRET or APP_PASSWORD is required")
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
		"sub": "owner",
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(30 * 24 * time.Hour).Unix(),
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
	return err == nil && parsed.Valid
}

func isSensitiveUnlocked(c *gin.Context) bool {
	if authDisabled() {
		return true
	}
	raw, err := c.Cookie(sensitiveCookieName)
	if err != nil {
		return false
	}
	until, err := parseInt64(raw)
	return err == nil && until > time.Now().UnixMilli()
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
	c.SetCookie(sessionCookieName, token, 60*60*24*30, "/", "", gin.Mode() == gin.ReleaseMode, true)
}

func setSensitiveCookie(c *gin.Context) {
	until := time.Now().Add(15 * time.Minute).UnixMilli()
	c.SetCookie(sensitiveCookieName, formatInt64(until), 15*60, "/", "", gin.Mode() == gin.ReleaseMode, true)
}

func clearAuthCookies(c *gin.Context) {
	c.SetCookie(sessionCookieName, "", -1, "/", "", gin.Mode() == gin.ReleaseMode, true)
	c.SetCookie(sensitiveCookieName, "", -1, "/", "", gin.Mode() == gin.ReleaseMode, true)
}
