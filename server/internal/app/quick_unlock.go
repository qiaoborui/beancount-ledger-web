package app

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

const quickUnlockTokenBytes = 32

type quickUnlockStore struct {
	Version int                 `json:"version"`
	Devices []quickUnlockDevice `json:"devices"`
}

type quickUnlockDevice struct {
	ID         string     `json:"id"`
	Name       string     `json:"name,omitempty"`
	Mode       string     `json:"mode"`
	TokenHash  string     `json:"tokenHash"`
	CreatedAt  time.Time  `json:"createdAt"`
	LastUsedAt *time.Time `json:"lastUsedAt,omitempty"`
	RevokedAt  *time.Time `json:"revokedAt,omitempty"`
}

type quickUnlockPublicDevice struct {
	ID         string     `json:"id"`
	Name       string     `json:"name,omitempty"`
	Mode       string     `json:"mode"`
	CreatedAt  time.Time  `json:"createdAt"`
	LastUsedAt *time.Time `json:"lastUsedAt,omitempty"`
	RevokedAt  *time.Time `json:"revokedAt,omitempty"`
}

func (s *Server) quickUnlockStatus(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	store := s.readQuickUnlockStore()
	devices := make([]quickUnlockPublicDevice, 0, len(store.Devices))
	for _, device := range store.Devices {
		devices = append(devices, quickUnlockPublicDevice{
			ID: device.ID, Name: device.Name, Mode: device.Mode,
			CreatedAt: device.CreatedAt, LastUsedAt: device.LastUsedAt, RevokedAt: device.RevokedAt,
		})
	}
	c.JSON(http.StatusOK, gin.H{"devices": devices})
}

func (s *Server) quickUnlockRegister(c *gin.Context) {
	if !s.limiter.Check(c, "quick-unlock.register", 10, time.Minute) {
		return
	}
	if !requireSensitive(c) {
		return
	}
	var input QuickUnlockRegisterRequest
	if !bindJSON(c, &input) {
		return
	}
	deviceID := input.DeviceID
	if deviceID == "" {
		generated, err := randomURLToken(18)
		if err != nil {
			errorJSON(c, http.StatusBadRequest, err)
			return
		}
		deviceID = generated
	}
	token, err := randomURLToken(quickUnlockTokenBytes)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	now := time.Now()
	device := quickUnlockDevice{
		ID: deviceID, Name: strings.TrimSpace(input.Name), Mode: input.Mode,
		TokenHash: quickUnlockTokenHash(token), CreatedAt: now,
	}
	if device.Name == "" {
		device.Name = "This browser"
	}
	if err := s.saveQuickUnlockDevice(device); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"deviceId": device.ID, "token": token})
}

func (s *Server) quickUnlockVerify(c *gin.Context) {
	if !s.limiter.Check(c, "quick-unlock.verify", 20, time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input QuickUnlockVerifyRequest
	if !bindJSON(c, &input) {
		return
	}
	if err := s.verifyQuickUnlockDevice(input.DeviceID, input.Token); err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Quick unlock failed"})
		return
	}
	setSensitiveCookie(c)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) quickUnlockRevoke(c *gin.Context) {
	if !s.limiter.Check(c, "quick-unlock.revoke", 20, time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input QuickUnlockRevokeRequest
	if !bindJSON(c, &input) {
		return
	}
	if err := s.revokeQuickUnlockDevice(input.DeviceID); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) readQuickUnlockStore() quickUnlockStore {
	var store quickUnlockStore
	ok, err := s.runtime().GetJSON(context.Background(), "auth", "quick-unlock", &store)
	if err != nil || !ok {
		return quickUnlockStore{Version: 1, Devices: []quickUnlockDevice{}}
	}
	if store.Version == 0 {
		store.Version = 1
	}
	if store.Devices == nil {
		store.Devices = []quickUnlockDevice{}
	}
	return store
}

func (s *Server) writeQuickUnlockStore(store quickUnlockStore) error {
	store.Version = 1
	return s.runtime().PutJSON(context.Background(), "auth", "quick-unlock", store)
}

func (s *Server) saveQuickUnlockDevice(device quickUnlockDevice) error {
	return s.runtime().WithLock(context.Background(), "auth/quick-unlock", func() error {
		store := s.readQuickUnlockStore()
		next := make([]quickUnlockDevice, 0, len(store.Devices)+1)
		for _, existing := range store.Devices {
			if existing.ID == device.ID {
				continue
			}
			next = append(next, existing)
		}
		next = append(next, device)
		store.Devices = next
		return s.writeQuickUnlockStore(store)
	})
}

func (s *Server) verifyQuickUnlockDevice(deviceID string, token string) error {
	tokenHash := quickUnlockTokenHash(token)
	return s.runtime().WithLock(context.Background(), "auth/quick-unlock", func() error {
		store := s.readQuickUnlockStore()
		now := time.Now()
		for index := range store.Devices {
			device := &store.Devices[index]
			if device.ID != deviceID || device.RevokedAt != nil {
				continue
			}
			if subtle.ConstantTimeCompare([]byte(device.TokenHash), []byte(tokenHash)) != 1 {
				return errors.New("quick unlock token mismatch")
			}
			device.LastUsedAt = &now
			return s.writeQuickUnlockStore(store)
		}
		return errors.New("quick unlock device not found")
	})
}

func (s *Server) revokeQuickUnlockDevice(deviceID string) error {
	return s.runtime().WithLock(context.Background(), "auth/quick-unlock", func() error {
		store := s.readQuickUnlockStore()
		now := time.Now()
		found := false
		for index := range store.Devices {
			if store.Devices[index].ID == deviceID {
				store.Devices[index].RevokedAt = &now
				found = true
			}
		}
		if !found {
			return errors.New("quick unlock device not found")
		}
		return s.writeQuickUnlockStore(store)
	})
}

func quickUnlockTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func randomURLToken(length int) (string, error) {
	bytes := make([]byte, length)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(bytes), nil
}
