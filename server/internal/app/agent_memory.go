package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	agentMemoryScope        = "ledger-agent-memories"
	agentMemoryLimit        = 100
	agentMemoryContextLimit = 15
)

type AgentMemoryRecord struct {
	ID          string    `json:"id"`
	Kind        string    `json:"kind"`
	Title       string    `json:"title"`
	Instruction string    `json:"instruction"`
	CreatedAt   time.Time `json:"createdAt"`
	UpdatedAt   time.Time `json:"updatedAt"`
}

type agentMemoryStore struct {
	Version int                 `json:"version"`
	Records []AgentMemoryRecord `json:"records"`
}

type agentMemoryInput struct {
	ID          string `json:"id"`
	Kind        string `json:"kind"`
	Title       string `json:"title"`
	Instruction string `json:"instruction"`
}

func (input agentMemoryInput) Validate() error {
	input.Kind = strings.TrimSpace(input.Kind)
	input.Title = strings.TrimSpace(input.Title)
	input.Instruction = strings.TrimSpace(input.Instruction)
	if !isAgentMemoryKind(input.Kind) {
		return errors.New("memory kind must be preference, category_rule, account_alias, recurring, or response_style")
	}
	if input.Title == "" || len([]rune(input.Title)) > 80 {
		return errors.New("memory title must be 1-80 characters")
	}
	if input.Instruction == "" || len([]rune(input.Instruction)) > 400 {
		return errors.New("memory instruction must be 1-400 characters")
	}
	if containsSensitiveAgentContent(input.Title + "\n" + input.Instruction) {
		return errors.New("memory cannot contain passwords, verification codes, tokens, or full card numbers")
	}
	return nil
}

func isAgentMemoryKind(kind string) bool {
	switch kind {
	case "preference", "category_rule", "account_alias", "recurring", "response_style":
		return true
	default:
		return false
	}
}

var (
	agentSensitiveTermPattern   = regexp.MustCompile(`(?i)\b(password|passcode|pin|otp|token|secret|cvv)\b`)
	agentSensitiveNumberPattern = regexp.MustCompile(`(?:\d[ -]?){12,}`)
)

func containsSensitiveAgentContent(value string) bool {
	lower := strings.ToLower(value)
	for _, forbidden := range []string{"密码", "口令", "验证码", "密钥", "身份证"} {
		if strings.Contains(lower, forbidden) {
			return true
		}
	}
	return agentSensitiveTermPattern.MatchString(value) || agentSensitiveNumberPattern.MatchString(value)
}

func (s *Server) listAgentMemories(ctx context.Context) ([]AgentMemoryRecord, error) {
	store, err := s.readAgentMemoryStore(ctx)
	if err != nil {
		return nil, err
	}
	records := append([]AgentMemoryRecord(nil), store.Records...)
	sort.Slice(records, func(left, right int) bool { return records[left].UpdatedAt.After(records[right].UpdatedAt) })
	return records, nil
}

func (s *Server) searchAgentMemories(ctx context.Context, query string) ([]AgentMemoryRecord, error) {
	records, err := s.listAgentMemories(ctx)
	if err != nil {
		return nil, err
	}
	query = strings.ToLower(strings.TrimSpace(query))
	if query == "" {
		return records, nil
	}
	matched := make([]AgentMemoryRecord, 0, len(records))
	for _, record := range records {
		haystack := strings.ToLower(record.Kind + " " + record.Title + " " + record.Instruction)
		if strings.Contains(haystack, query) {
			matched = append(matched, record)
		}
	}
	return matched, nil
}

func (s *Server) upsertAgentMemory(ctx context.Context, input agentMemoryInput) (AgentMemoryRecord, error) {
	if err := input.Validate(); err != nil {
		return AgentMemoryRecord{}, err
	}
	input.ID = strings.TrimSpace(input.ID)
	input.Kind = strings.TrimSpace(input.Kind)
	input.Title = strings.TrimSpace(input.Title)
	input.Instruction = strings.TrimSpace(input.Instruction)
	var result AgentMemoryRecord
	err := s.runtime().WithLock(ctx, s.agentMemoryLockName(), func(lockCtx context.Context) error {
		store, err := s.readAgentMemoryStore(lockCtx)
		if err != nil {
			return err
		}
		for index, record := range store.Records {
			if (input.ID != "" && record.ID == input.ID) || (input.ID == "" && record.Kind == input.Kind && record.Title == input.Title) {
				record.Kind = input.Kind
				record.Title = input.Title
				record.Instruction = input.Instruction
				record.UpdatedAt = time.Now().UTC()
				store.Records[index] = record
				result = record
				return s.writeAgentMemoryStore(lockCtx, store)
			}
		}
		if len(store.Records) >= agentMemoryLimit {
			return errors.New("agent memory limit reached")
		}
		now := time.Now().UTC()
		result = AgentMemoryRecord{ID: newAgentID("memory"), Kind: input.Kind, Title: input.Title, Instruction: input.Instruction, CreatedAt: now, UpdatedAt: now}
		store.Records = append(store.Records, result)
		return s.writeAgentMemoryStore(lockCtx, store)
	})
	return result, err
}

func (s *Server) readAgentMemoryStore(ctx context.Context) (agentMemoryStore, error) {
	var store agentMemoryStore
	ok, err := s.runtime().GetJSON(ctx, agentMemoryScope, s.agentMemoryStoreKey(), &store)
	if err != nil {
		return agentMemoryStore{}, err
	}
	if !ok {
		return agentMemoryStore{Version: 1, Records: []AgentMemoryRecord{}}, nil
	}
	if store.Version == 0 {
		store.Version = 1
	}
	if store.Records == nil {
		store.Records = []AgentMemoryRecord{}
	}
	return store, nil
}

func (s *Server) writeAgentMemoryStore(ctx context.Context, store agentMemoryStore) error {
	store.Version = 1
	return s.runtime().PutJSON(ctx, agentMemoryScope, s.agentMemoryStoreKey(), store)
}

func (s *Server) agentMemoryStoreKey() string {
	sum := sha256.Sum256([]byte(ledgerClusterID(s.cfg)))
	return "memory:" + hex.EncodeToString(sum[:12])
}

func (s *Server) agentMemoryLockName() string {
	return "agent-memory:" + s.agentMemoryStoreKey()
}

func agentMemoryContext(records []AgentMemoryRecord) string {
	if len(records) == 0 {
		return ""
	}
	if len(records) > agentMemoryContextLimit {
		records = records[:agentMemoryContextLimit]
	}
	lines := make([]string, 0, len(records))
	for _, record := range records {
		lines = append(lines, "- ["+record.ID+"] "+record.Title+"："+record.Instruction)
	}
	return strings.Join(lines, "\n")
}
