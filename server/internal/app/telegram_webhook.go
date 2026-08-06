package app

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

const (
	telegramWebhookMaxBodyBytes = 1 << 20
	telegramCompletedUpdateCap  = 1000
	telegramUpdatesLockName     = "telegram-updates"
	telegramUpdatesScope        = "telegram"
	telegramCompletedUpdatesKey = "completed-updates"
)

type telegramWebhookPayload struct {
	UpdateID int64 `json:"update_id"`
}

// telegramCompletedUpdates keeps the most recent completed update IDs. It is
// bounded so a duplicate delivery is only recognized while the ID is recent
// enough to matter for Telegram's retry window.
type telegramCompletedUpdates struct {
	Version int     `json:"version"`
	IDs     []int64 `json:"ids"`
}

type telegramAgentUpstreamError struct {
	status  int
	message string
}

func (e *telegramAgentUpstreamError) Error() string {
	return fmt.Sprintf("Agent service: %s (HTTP %d)", e.message, e.status)
}

// telegramWebhook accepts Telegram bot webhook deliveries, verifies the secret
// token, forwards the raw update to the private Agent, and acknowledges with
// 204 only after the whole Agent turn completed. Any failure returns a non-2xx
// response so Telegram retries the update later.
func (s *Server) telegramWebhook(c *gin.Context) {
	secret := strings.TrimSpace(s.cfg.TelegramWebhookSecret)
	got := strings.TrimSpace(c.GetHeader("X-Telegram-Bot-Api-Secret-Token"))
	if secret == "" || got == "" || len(got) != len(secret) || subtle.ConstantTimeCompare([]byte(got), []byte(secret)) != 1 {
		errorJSON(c, http.StatusUnauthorized, errors.New("invalid Telegram webhook secret"))
		return
	}
	raw, err := io.ReadAll(io.LimitReader(c.Request.Body, telegramWebhookMaxBodyBytes+1))
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if len(raw) > telegramWebhookMaxBodyBytes {
		errorJSON(c, http.StatusRequestEntityTooLarge, errors.New("Telegram update payload is too large"))
		return
	}
	var payload telegramWebhookPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		errorJSON(c, http.StatusBadRequest, errors.New("invalid Telegram update payload"))
		return
	}
	if payload.UpdateID <= 0 {
		errorJSON(c, http.StatusBadRequest, errors.New("Telegram update_id is required"))
		return
	}
	// WithoutCancel keeps the Agent turn running when Telegram drops the HTTP
	// connection; Cloud Run billing keeps the CPU available for the whole turn.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(c.Request.Context()), agentServiceRequestTimeout)
	defer cancel()
	err = s.runtime().WithLock(ctx, telegramUpdatesLockName, func(lockCtx context.Context) error {
		already, err := s.telegramUpdateCompleted(lockCtx, payload.UpdateID)
		if err != nil {
			return err
		}
		if already {
			c.Status(http.StatusNoContent)
			return nil
		}
		response, err := s.agentServiceRequest(lockCtx, http.MethodPost, "/v1/channels/telegram/updates", json.RawMessage(raw))
		if err != nil {
			return err
		}
		defer response.Body.Close()
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			return &telegramAgentUpstreamError{
				status:  response.StatusCode,
				message: agentServiceResponseError(response).Error(),
			}
		}
		if err := s.recordTelegramUpdateCompleted(lockCtx, payload.UpdateID); err != nil {
			return err
		}
		c.Status(http.StatusNoContent)
		return nil
	})
	if err != nil {
		status := http.StatusInternalServerError
		var upstream *telegramAgentUpstreamError
		if errors.As(err, &upstream) {
			status = http.StatusBadGateway
		}
		errorJSON(c, status, err)
		return
	}
}

func (s *Server) telegramUpdateCompleted(ctx context.Context, updateID int64) (bool, error) {
	var stored telegramCompletedUpdates
	found, err := s.runtime().GetJSON(ctx, telegramUpdatesScope, telegramCompletedUpdatesKey, &stored)
	if err != nil {
		return false, err
	}
	if !found {
		return false, nil
	}
	for _, id := range stored.IDs {
		if id == updateID {
			return true, nil
		}
	}
	return false, nil
}

func (s *Server) recordTelegramUpdateCompleted(ctx context.Context, updateID int64) error {
	var stored telegramCompletedUpdates
	found, err := s.runtime().GetJSON(ctx, telegramUpdatesScope, telegramCompletedUpdatesKey, &stored)
	if err != nil {
		return err
	}
	if !found {
		stored = telegramCompletedUpdates{Version: 1}
	}
	ids := make([]int64, 0, telegramCompletedUpdateCap)
	ids = append(ids, updateID)
	for _, id := range stored.IDs {
		if id == updateID {
			continue
		}
		ids = append(ids, id)
		if len(ids) >= telegramCompletedUpdateCap {
			break
		}
	}
	stored.IDs = ids
	return s.runtime().PutJSON(ctx, telegramUpdatesScope, telegramCompletedUpdatesKey, stored)
}
