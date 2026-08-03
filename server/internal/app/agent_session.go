package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strconv"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	agentSessionScope         = "ledger-agent-sessions"
	agentSessionDeletionScope = "ledger-agent-session-deletions"
	agentSessionMaxAge        = 24 * time.Hour
	// Keep a small reserve for the system prompt, tool definitions, and the
	// provider's completion. The history itself is bounded by estimated tokens,
	// never by a message count.
	agentSessionDefaultHistoryTokenBudget = 48_000
	agentSessionMinHistoryTokenBudget     = 4_096
	agentSessionMaxHistoryTokenBudget     = 1_000_000
)

type agentSessionStore struct {
	Version   int                 `json:"version"`
	UpdatedAt time.Time           `json:"updatedAt"`
	Messages  []agentModelMessage `json:"messages"`
}

// agentSessionDeletion prevents a stale request from reviving a deleted
// session, including a pending approval receipt that predates its timeline.
// Session IDs are random and never intentionally reused, so the tombstone may
// safely outlive the short-lived transcript and approval records.
type agentSessionDeletion struct {
	DeletedAt time.Time `json:"deletedAt"`
}

type agentSessionRunLockContextKey struct{}

var agentSessionRunLocks sync.Map // map[string]*sync.Mutex

// withAgentSessionRunLock serializes the whole durable lifecycle for one
// session, including model sampling and approval continuation. The runtime
// store uses a process lock for files and a PostgreSQL advisory lock in hosted
// deployments. Nested session writes reuse the held lock/transaction.
func (s *Server) withAgentSessionRunLock(ctx context.Context, sessionID string, fn func(context.Context) error) error {
	lockName := s.agentSessionLockName(sessionID)
	if held, _ := ctx.Value(agentSessionRunLockContextKey{}).(string); held == lockName {
		return fn(ctx)
	}
	if runtimeBackend(s.cfg) != "postgres" {
		entry, _ := agentSessionRunLocks.LoadOrStore(lockName, &sync.Mutex{})
		lock := entry.(*sync.Mutex)
		lock.Lock()
		defer lock.Unlock()
		return fn(ctx)
	}
	return s.runtime().WithLock(ctx, lockName, func(lockCtx context.Context) error {
		return fn(context.WithValue(lockCtx, agentSessionRunLockContextKey{}, lockName))
	})
}

func (s *Server) agentSessionWasDeleted(ctx context.Context, sessionID string) (bool, error) {
	var deletion agentSessionDeletion
	found, err := s.runtime().GetJSON(ctx, agentSessionDeletionScope, s.agentSessionStoreKey(sessionID), &deletion)
	return found, err
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
	if held, _ := ctx.Value(agentSessionRunLockContextKey{}).(string); held == s.agentSessionLockName(sessionID) {
		return s.runtime().PutJSON(ctx, agentSessionScope, s.agentSessionStoreKey(sessionID), agentSessionStore{Version: 1, UpdatedAt: time.Now().UTC(), Messages: trimAgentSessionMessages(messages)})
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
	if held, _ := ctx.Value(agentSessionRunLockContextKey{}).(string); held == s.agentSessionLockName(sessionID) {
		messages, found, err := s.readAgentSession(ctx, sessionID)
		if err != nil || !found {
			return err
		}
		messages = append(messages, message)
		return s.runtime().PutJSON(ctx, agentSessionScope, s.agentSessionStoreKey(sessionID), agentSessionStore{Version: 1, UpdatedAt: time.Now().UTC(), Messages: trimAgentSessionMessages(messages)})
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
	if agentSessionMessagesTokenEstimate(messages) <= agentSessionHistoryTokenBudget() {
		return append([]agentModelMessage(nil), messages...)
	}
	target := agentSessionHistoryTokenBudget() * 3 / 4
	start := len(messages)
	retainedTokens := 0
	for start > 0 && retainedTokens < target {
		start--
		retainedTokens += agentModelMessageTokenEstimate(messages[start])
	}
	// A tool result must never be retained without the assistant call that
	// requested it. Move the tail boundary back to that call; this preserves a
	// valid provider transcript after compaction.
	for start > 0 && messages[start].Role != "assistant" {
		start--
	}
	if start == 0 {
		return append([]agentModelMessage(nil), messages...)
	}
	compacted := agentModelMessage{Role: "system", Content: agentSessionCompactionNotice(messages[:start])}
	trimmed := make([]agentModelMessage, 0, len(messages)-start+1)
	trimmed = append(trimmed, compacted)
	trimmed = append(trimmed, messages[start:]...)
	return trimmed
}

func agentSessionHistoryTokenBudget() int {
	value, err := strconv.Atoi(os.Getenv("LEDGER_AI_HISTORY_TOKEN_BUDGET"))
	if err != nil || value == 0 {
		return agentSessionDefaultHistoryTokenBudget
	}
	if value < agentSessionMinHistoryTokenBudget {
		return agentSessionMinHistoryTokenBudget
	}
	if value > agentSessionMaxHistoryTokenBudget {
		return agentSessionMaxHistoryTokenBudget
	}
	return value
}

func agentSessionMessagesTokenEstimate(messages []agentModelMessage) int {
	total := 0
	for _, message := range messages {
		total += agentModelMessageTokenEstimate(message)
	}
	return total
}

// agentModelMessageTokenEstimate deliberately overestimates CJK and JSON
// payloads. Providers use different tokenizers, so this is a portable guard
// around the configured context budget rather than a model-specific tokenizer.
func agentModelMessageTokenEstimate(message agentModelMessage) int {
	raw, err := json.Marshal(message)
	if err != nil {
		return 4 + utf8.RuneCountInString(message.Content)
	}
	ascii, nonASCII := 0, 0
	for _, byteValue := range raw {
		if byteValue < utf8.RuneSelf {
			ascii++
		} else {
			nonASCII++
		}
	}
	return 4 + (ascii+3)/4 + (nonASCII+2)/3
}

func agentSessionCompactionNotice(discarded []agentModelMessage) string {
	toolResults := 0
	for _, message := range discarded {
		if message.Role == "tool" {
			toolResults++
		}
	}
	return "较早的 Agent 历史已在持久会话中压缩（" + strconv.Itoa(len(discarded)) + " 条消息，其中 " + strconv.Itoa(toolResults) + " 条工具结果）。不要假设这些历史中的未展示事实；如需数据请重新调用只读工具。保留的最近消息和所有待确认操作仍是当前任务事实。"
}

func (s *Server) agentSessionStoreKey(sessionID string) string {
	sum := sha256.Sum256([]byte(ledgerClusterID(s.cfg)))
	return sessionID + ":" + hex.EncodeToString(sum[:12])
}

func (s *Server) agentSessionLockName(sessionID string) string {
	return "agent-session:" + s.agentSessionStoreKey(sessionID)
}
