package app

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
)

func (s *Server) login(c *gin.Context) {
	if !s.limiter.Check(c, "auth.login", 10, time.Minute) {
		return
	}
	if authDisabled() {
		c.JSON(http.StatusOK, gin.H{"ok": true})
		return
	}
	var input LoginRequest
	if !bindJSON(c, &input) {
		return
	}
	ok, err := verifyPassword(input.Password)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid password"})
		return
	}
	token, err := createSessionToken()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	setSessionCookie(c, token)
	setSensitiveCookie(c)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) logout(c *gin.Context) {
	clearAuthCookies(c)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) lockSensitive(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	clearSensitiveCookie(c)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) me(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"authenticated": isAuthenticated(c), "sensitiveUnlocked": isSensitiveUnlocked(c), "authDisabled": authDisabled()})
}
