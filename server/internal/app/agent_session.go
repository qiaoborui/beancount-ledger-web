package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"time"
)

const (
	agentSessionScope        = "ledger-agent-sessions"
	agentSessionMaxAge       = 24 * time.Hour
	agentSessionMessageLimit = 80
)

type agentSessionStore struct {
	Version   int                 `json:"version"`
	UpdatedAt time.Time           `json:"updatedAt"`
	Messages  []agentModelMessage `json:"messages"`
}

func (s *Server) readAgentSession(ctx context.Context, sessionID string) ([]agentModelMessage, bool, error) {
	if s.agentSessions != nil {
		messages, found, err := s.agentSessions.Read(ctx, ledgerClusterID(s.cfg), sessionID)
		if err != nil || found {
			return messages, found, err
		}
	}
	var store agentSessionStore
	found, err := s.runtime().GetJSON(ctx, agentSessionScope, s.agentSessionStoreKey(sessionID), &store)
	if err != nil || !found {
		return nil, found, err
	}
	if store.UpdatedAt.IsZero() || time.Since(store.UpdatedAt) > agentSessionMaxAge {
		_ = s.runtime().DeleteJSON(ctx, agentSessionScope, s.agentSessionStoreKey(sessionID))
		return nil, false, nil
	}
	messages := append([]agentModelMessage(nil), store.Messages...)
	if s.agentSessions != nil {
		if err := s.agentSessions.Write(ctx, ledgerClusterID(s.cfg), sessionID, messages); err != nil {
			return nil, false, err
		}
	}
	return messages, true, nil
}

func (s *Server) writeAgentSession(ctx context.Context, sessionID string, messages []agentModelMessage) error {
	if s.agentSessions != nil {
		return s.agentSessions.Write(ctx, ledgerClusterID(s.cfg), sessionID, messages)
	}
	return s.runtime().WithLock(ctx, s.agentSessionLockName(sessionID), func(lockCtx context.Context) error {
		trimmed := trimAgentSessionMessages(messages)
		return s.runtime().PutJSON(lockCtx, agentSessionScope, s.agentSessionStoreKey(sessionID), agentSessionStore{Version: 1, UpdatedAt: time.Now().UTC(), Messages: trimmed})
	})
}

func (s *Server) appendAgentSessionMessage(ctx context.Context, sessionID string, message agentModelMessage) error {
	if s.agentSessions != nil {
		appended, err := s.agentSessions.Append(ctx, ledgerClusterID(s.cfg), sessionID, message)
		if err != nil || appended {
			return err
		}
		// A pre-migration session is lazily copied on its first continuation.
		var legacy agentSessionStore
		found, err := s.runtime().GetJSON(ctx, agentSessionScope, s.agentSessionStoreKey(sessionID), &legacy)
		if err != nil || !found || legacy.UpdatedAt.IsZero() || time.Since(legacy.UpdatedAt) > agentSessionMaxAge {
			return err
		}
		messages := append(append([]agentModelMessage(nil), legacy.Messages...), message)
		return s.agentSessions.Write(ctx, ledgerClusterID(s.cfg), sessionID, messages)
	}
	return s.runtime().WithLock(ctx, s.agentSessionLockName(sessionID), func(lockCtx context.Context) error {
		messages, found, err := s.readAgentSession(lockCtx, sessionID)
		if err != nil {
			return err
		}
		if !found {
			return nil
		}
		messages = append(messages, message)
		return s.runtime().PutJSON(lockCtx, agentSessionScope, s.agentSessionStoreKey(sessionID), agentSessionStore{Version: 1, UpdatedAt: time.Now().UTC(), Messages: trimAgentSessionMessages(messages)})
	})
}

func trimAgentSessionMessages(messages []agentModelMessage) []agentModelMessage {
	if len(messages) <= agentSessionMessageLimit {
		return append([]agentModelMessage(nil), messages...)
	}
	start := len(messages) - agentSessionMessageLimit
	for start < len(messages) && messages[start].Role == "tool" {
		start++
	}
	return append([]agentModelMessage(nil), messages[start:]...)
}

func (s *Server) agentSessionStoreKey(sessionID string) string {
	sum := sha256.Sum256([]byte(ledgerClusterID(s.cfg)))
	return sessionID + ":" + hex.EncodeToString(sum[:12])
}

func (s *Server) agentSessionLockName(sessionID string) string {
	return "agent-session:" + s.agentSessionStoreKey(sessionID)
}
