package app

import (
	"context"
	"errors"
	"fmt"
	"time"
)

const (
	agentTimelineScope     = "ledger-agent-timelines"
	agentTimelinePageLimit = 80
)

// AgentTimelineItem is the durable, presentation-facing record for one Agent
// event. It is intentionally separate from the provider transcript: UI paging
// must never delete context, and context compaction must never hide history.
type AgentTimelineItem struct {
	ID       string             `json:"id"`
	Kind     string             `json:"kind"`
	Role     string             `json:"role,omitempty"`
	Content  string             `json:"content,omitempty"`
	Tool     *agentTimelineTool `json:"tool,omitempty"`
	Artifact *AgentArtifact     `json:"artifact,omitempty"`
	Approval *AgentApproval     `json:"approval,omitempty"`
	Resolved bool               `json:"resolved,omitempty"`
}

type agentTimelineTool struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Title  string `json:"title"`
	Status string `json:"status"`
	Input  any    `json:"input,omitempty"`
	Output any    `json:"output,omitempty"`
	Error  string `json:"error,omitempty"`
}

type agentTimelineStore struct {
	Version   int                 `json:"version"`
	UpdatedAt time.Time           `json:"updatedAt"`
	Items     []AgentTimelineItem `json:"items"`
}

type agentTimelinePage struct {
	Items      []AgentTimelineItem `json:"items"`
	NextBefore *int                `json:"nextBefore"`
}

func (s *Server) appendAgentTimelineItem(ctx context.Context, sessionID string, item AgentTimelineItem) error {
	if item.ID == "" || item.Kind == "" {
		return errors.New("agent timeline item requires id and kind")
	}
	return s.withAgentTimelineLock(ctx, sessionID, func(lockCtx context.Context) error {
		var store agentTimelineStore
		found, err := s.runtime().GetJSON(lockCtx, agentTimelineScope, s.agentSessionStoreKey(sessionID), &store)
		if err != nil {
			return err
		}
		if found && !store.UpdatedAt.IsZero() && time.Since(store.UpdatedAt) > agentSessionMaxAge {
			store = agentTimelineStore{}
		}
		if store.Version == 0 {
			store.Version = 1
		}
		for index := range store.Items {
			if store.Items[index].ID == item.ID {
				if item.Kind == "tool" && store.Items[index].Tool != nil && item.Tool != nil {
					if item.Tool.Input == nil {
						item.Tool.Input = store.Items[index].Tool.Input
					}
					if item.Tool.Output == nil {
						item.Tool.Output = store.Items[index].Tool.Output
					}
				}
				store.Items[index] = item
				if item.Kind == "tool" && item.Tool != nil {
					for approvalIndex := range store.Items {
						if store.Items[approvalIndex].Kind == "approval" && store.Items[approvalIndex].Approval != nil && store.Items[approvalIndex].Approval.ToolCallID == item.Tool.ID && item.Tool.Status != "running" {
							store.Items[approvalIndex].Resolved = true
						}
					}
				}
				store.UpdatedAt = time.Now().UTC()
				return s.runtime().PutJSON(lockCtx, agentTimelineScope, s.agentSessionStoreKey(sessionID), store)
			}
		}
		store.Items = append(store.Items, item)
		if item.Kind == "tool" && item.Tool != nil && item.Tool.Status != "running" {
			for approvalIndex := range store.Items {
				if store.Items[approvalIndex].Kind == "approval" && store.Items[approvalIndex].Approval != nil && store.Items[approvalIndex].Approval.ToolCallID == item.Tool.ID {
					store.Items[approvalIndex].Resolved = true
				}
			}
		}
		store.UpdatedAt = time.Now().UTC()
		return s.runtime().PutJSON(lockCtx, agentTimelineScope, s.agentSessionStoreKey(sessionID), store)
	})
}

func (s *Server) withAgentTimelineLock(ctx context.Context, sessionID string, fn func(context.Context) error) error {
	lockName := s.agentSessionLockName(sessionID)
	if held, _ := ctx.Value(agentSessionRunLockContextKey{}).(string); held == lockName {
		return fn(ctx)
	}
	return s.runtime().WithLock(ctx, lockName, fn)
}

func (s *Server) agentTimelinePage(ctx context.Context, sessionID string, before, limit int) (agentTimelinePage, error) {
	emptyPage := agentTimelinePage{Items: []AgentTimelineItem{}}
	var store agentTimelineStore
	found, err := s.runtime().GetJSON(ctx, agentTimelineScope, s.agentSessionStoreKey(sessionID), &store)
	if err != nil {
		return emptyPage, err
	}
	if !found {
		// Sessions created before timeline persistence still have their provider
		// transcript. Backfill readable user/assistant messages on first reload so
		// a deployment never makes an existing conversation look empty.
		messages, sessionFound, readErr := s.readAgentSession(ctx, sessionID)
		if readErr != nil || !sessionFound {
			return emptyPage, readErr
		}
		store = agentTimelineStore{Version: 1, UpdatedAt: time.Now().UTC()}
		for _, message := range messages {
			if (message.Role == "user" || message.Role == "assistant") && message.Content != "" {
				store.Items = append(store.Items, agentTimelineMessage(message.Role, message.Content))
			}
		}
		if err := s.runtime().PutJSON(ctx, agentTimelineScope, s.agentSessionStoreKey(sessionID), store); err != nil {
			return emptyPage, err
		}
	}
	if store.UpdatedAt.IsZero() || time.Since(store.UpdatedAt) > agentSessionMaxAge {
		_ = s.runtime().DeleteJSON(ctx, agentTimelineScope, s.agentSessionStoreKey(sessionID))
		return emptyPage, nil
	}
	if limit <= 0 || limit > agentTimelinePageLimit {
		limit = agentTimelinePageLimit
	}
	end := len(store.Items)
	if before > 0 && before < end {
		end = before
	}
	start := end - limit
	if start < 0 {
		start = 0
	}
	page := agentTimelinePage{Items: append(make([]AgentTimelineItem, 0, end-start), store.Items[start:end]...)}
	if start > 0 {
		page.NextBefore = &start
	}
	return page, nil
}

func agentTimelineMessage(role, content string) AgentTimelineItem {
	return AgentTimelineItem{ID: newAgentID("timeline"), Kind: "message", Role: role, Content: content}
}

func agentTimelineToolItem(payload any) (AgentTimelineItem, error) {
	value, ok := payload.(map[string]any)
	if !ok {
		return AgentTimelineItem{}, fmt.Errorf("unexpected agent tool payload %T", payload)
	}
	id, _ := value["id"].(string)
	name, _ := value["name"].(string)
	title, _ := value["title"].(string)
	status, _ := value["status"].(string)
	if id == "" || name == "" || title == "" || status == "" {
		return AgentTimelineItem{}, errors.New("incomplete agent tool payload")
	}
	errorText, _ := value["error"].(string)
	return AgentTimelineItem{ID: id, Kind: "tool", Tool: &agentTimelineTool{ID: id, Name: name, Title: title, Status: status, Input: value["input"], Output: value["output"], Error: errorText}}, nil
}

func (s *Server) recordAgentTimelineEvent(ctx context.Context, sessionID, event string, payload any) error {
	var item AgentTimelineItem
	switch event {
	case "tool_call", "tool_result":
		var err error
		item, err = agentTimelineToolItem(payload)
		if err != nil {
			return err
		}
	case "artifact":
		artifact, ok := payload.(AgentArtifact)
		if !ok {
			return fmt.Errorf("unexpected agent artifact payload %T", payload)
		}
		item = AgentTimelineItem{ID: artifact.ID, Kind: "artifact", Artifact: &artifact}
	case "approval_required":
		approval, ok := payload.(AgentApproval)
		if !ok {
			return fmt.Errorf("unexpected agent approval payload %T", payload)
		}
		item = AgentTimelineItem{ID: approval.ID, Kind: "approval", Approval: &approval}
	case "final":
		value, ok := payload.(map[string]any)
		if !ok {
			return fmt.Errorf("unexpected agent final payload %T", payload)
		}
		message, _ := value["message"].(string)
		if message == "" {
			return nil
		}
		item = agentTimelineMessage("assistant", message)
	default:
		return nil
	}
	return s.appendAgentTimelineItem(ctx, sessionID, item)
}
