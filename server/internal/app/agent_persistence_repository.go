package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/agentapproval"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/agentsession"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/agentsessionmessage"
)

type agentSessionRepository interface {
	Read(context.Context, string, string) ([]agentModelMessage, bool, error)
	Write(context.Context, string, string, []agentModelMessage) error
	Append(context.Context, string, string, agentModelMessage) (bool, error)
	Delete(context.Context, string, string) error
}

type agentApprovalRepository interface {
	Save(context.Context, string, AgentApproval) error
	Take(context.Context, string, string, string) (AgentApproval, bool, bool, error)
	DeleteSession(context.Context, string, string) error
}

type entAgentSessionRepository struct{ client *ent.Client }
type entAgentApprovalRepository struct{ client *ent.Client }

func newEntAgentSessionRepository(client *ent.Client) agentSessionRepository {
	if client == nil {
		return nil
	}
	return &entAgentSessionRepository{client: client}
}

func newEntAgentApprovalRepository(client *ent.Client) agentApprovalRepository {
	if client == nil {
		return nil
	}
	return &entAgentApprovalRepository{client: client}
}

func (r *entAgentSessionRepository) Read(ctx context.Context, clusterID, sessionID string) ([]agentModelMessage, bool, error) {
	key := relationalAgentSessionKey(clusterID, sessionID)
	if _, err := r.client.AgentSession.Delete().Where(agentsession.UpdatedAtLT(time.Now().UTC().Add(-agentSessionMaxAge))).Exec(ctx); err != nil {
		return nil, false, err
	}
	_, err := r.client.AgentSession.Query().Where(agentsession.IDEQ(key), agentsession.ClusterIDEQ(clusterID)).Only(ctx)
	if ent.IsNotFound(err) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	rows, err := r.client.AgentSessionMessage.Query().Where(agentsessionmessage.SessionKeyEQ(key)).Order(ent.Asc(agentsessionmessage.FieldOrdinal)).All(ctx)
	if err != nil {
		return nil, false, err
	}
	messages := make([]agentModelMessage, 0, len(rows))
	for _, row := range rows {
		message, err := agentMessageFromEnt(row)
		if err != nil {
			return nil, false, err
		}
		messages = append(messages, message)
	}
	return messages, true, nil
}

func (r *entAgentSessionRepository) Write(ctx context.Context, clusterID, sessionID string, messages []agentModelMessage) error {
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := replaceAgentSessionMessages(ctx, tx, clusterID, sessionID, trimAgentSessionMessages(messages), false); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *entAgentSessionRepository) Append(ctx context.Context, clusterID, sessionID string, message agentModelMessage) (bool, error) {
	key := relationalAgentSessionKey(clusterID, sessionID)
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	session, err := tx.AgentSession.Query().Where(agentsession.IDEQ(key), agentsession.ClusterIDEQ(clusterID)).ForUpdate().Only(ctx)
	if ent.IsNotFound(err) {
		return false, tx.Commit()
	}
	if err != nil {
		return false, err
	}
	if session.UpdatedAt.Before(time.Now().UTC().Add(-agentSessionMaxAge)) {
		if err := tx.AgentSession.DeleteOne(session).Exec(ctx); err != nil {
			return false, err
		}
		return false, tx.Commit()
	}
	rows, err := tx.AgentSessionMessage.Query().Where(agentsessionmessage.SessionKeyEQ(key)).Order(ent.Asc(agentsessionmessage.FieldOrdinal)).All(ctx)
	if err != nil {
		return false, err
	}
	messages := make([]agentModelMessage, 0, len(rows)+1)
	for _, row := range rows {
		item, err := agentMessageFromEnt(row)
		if err != nil {
			return false, err
		}
		messages = append(messages, item)
	}
	messages = append(messages, message)
	if err := replaceAgentSessionMessages(ctx, tx, clusterID, sessionID, trimAgentSessionMessages(messages), true); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

func (r *entAgentSessionRepository) Delete(ctx context.Context, clusterID, sessionID string) error {
	key := relationalAgentSessionKey(clusterID, sessionID)
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.AgentSessionMessage.Delete().Where(agentsessionmessage.SessionKeyEQ(key)).Exec(ctx); err != nil {
		return err
	}
	if _, err := tx.AgentSession.Delete().Where(agentsession.IDEQ(key), agentsession.ClusterIDEQ(clusterID)).Exec(ctx); err != nil {
		return err
	}
	return tx.Commit()
}

func replaceAgentSessionMessages(ctx context.Context, tx *ent.Tx, clusterID, sessionID string, messages []agentModelMessage, locked bool) error {
	key := relationalAgentSessionKey(clusterID, sessionID)
	if !locked {
		// The unique cluster/session constraint makes concurrent first writes safe.
		existing, err := tx.AgentSession.Query().Where(agentsession.IDEQ(key)).Only(ctx)
		if ent.IsNotFound(err) {
			if _, err := tx.AgentSession.Create().SetID(key).SetClusterID(clusterID).SetSessionID(sessionID).SetUpdatedAt(time.Now().UTC()).Save(ctx); err != nil {
				return err
			}
		} else if err != nil {
			return err
		} else if _, err := tx.AgentSession.UpdateOneID(existing.ID).SetUpdatedAt(time.Now().UTC()).Save(ctx); err != nil {
			return err
		}
	} else if _, err := tx.AgentSession.UpdateOneID(key).SetUpdatedAt(time.Now().UTC()).Save(ctx); err != nil {
		return err
	}
	if _, err := tx.AgentSessionMessage.Delete().Where(agentsessionmessage.SessionKeyEQ(key)).Exec(ctx); err != nil {
		return err
	}
	for ordinal, message := range messages {
		create := tx.AgentSessionMessage.Create().SetID(fmt.Sprintf("%s:%d", key, ordinal)).SetSessionKey(key).SetOrdinal(ordinal).SetRole(message.Role).SetContent(message.Content).SetToolCallID(message.ToolCallID)
		if len(message.ToolCalls) > 0 {
			raw, err := json.Marshal(message.ToolCalls)
			if err != nil {
				return err
			}
			create.SetToolCalls(raw)
		}
		if err := create.Exec(ctx); err != nil {
			return err
		}
	}
	return nil
}

func (r *entAgentApprovalRepository) Save(ctx context.Context, clusterID string, approval AgentApproval) error {
	if !json.Valid(approval.Arguments) {
		return errors.New("agent approval arguments must be valid JSON")
	}
	return r.client.AgentApproval.Create().SetID(approval.ID).SetClusterID(clusterID).SetSessionID(approval.SessionID).SetToolCallID(approval.ToolCallID).SetToolName(approval.ToolName).SetToolTitle(approval.ToolTitle).SetArguments(append(json.RawMessage(nil), approval.Arguments...)).SetSummary(approval.Summary).SetPage(approval.PageContext.Page).SetPath(approval.PageContext.Path).SetRangeStart(approval.PageContext.Start).SetRangeEnd(approval.PageContext.End).SetValuationCurrency(approval.PageContext.ValuationCurrency).SetBqlQuery(approval.PageContext.BQLQuery).SetCreatedAt(approval.CreatedAt).SetExpiresAt(approval.ExpiresAt).OnConflictColumns(agentapproval.FieldID).UpdateNewValues().Exec(ctx)
}

func (r *entAgentApprovalRepository) Take(ctx context.Context, clusterID, sessionID, id string) (AgentApproval, bool, bool, error) {
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return AgentApproval{}, false, false, err
	}
	defer tx.Rollback()
	row, err := tx.AgentApproval.Query().Where(agentapproval.IDEQ(id), agentapproval.ClusterIDEQ(clusterID), agentapproval.SessionIDEQ(sessionID)).ForUpdate().Only(ctx)
	if ent.IsNotFound(err) {
		return AgentApproval{}, false, false, tx.Commit()
	}
	if err != nil {
		return AgentApproval{}, false, false, err
	}
	if err := tx.AgentApproval.DeleteOne(row).Exec(ctx); err != nil {
		return AgentApproval{}, false, false, err
	}
	if err := tx.Commit(); err != nil {
		return AgentApproval{}, false, false, err
	}
	if !row.ExpiresAt.After(time.Now().UTC()) {
		return AgentApproval{}, false, true, nil
	}
	return agentApprovalFromEnt(row), true, false, nil
}

func (r *entAgentApprovalRepository) DeleteSession(ctx context.Context, clusterID, sessionID string) error {
	_, err := r.client.AgentApproval.Delete().Where(agentapproval.ClusterIDEQ(clusterID), agentapproval.SessionIDEQ(sessionID)).Exec(ctx)
	return err
}

func agentMessageFromEnt(row *ent.AgentSessionMessage) (agentModelMessage, error) {
	message := agentModelMessage{Role: row.Role, Content: row.Content, ToolCallID: row.ToolCallID}
	if len(row.ToolCalls) > 0 {
		if err := json.Unmarshal(row.ToolCalls, &message.ToolCalls); err != nil {
			return agentModelMessage{}, err
		}
	}
	return message, nil
}

func agentApprovalFromEnt(row *ent.AgentApproval) AgentApproval {
	return AgentApproval{ID: row.ID, SessionID: row.SessionID, ToolCallID: row.ToolCallID, ToolName: row.ToolName, ToolTitle: row.ToolTitle, Arguments: append(json.RawMessage(nil), row.Arguments...), Summary: row.Summary, CreatedAt: row.CreatedAt, ExpiresAt: row.ExpiresAt, PageContext: AgentPageContext{Page: row.Page, Path: row.Path, Start: row.RangeStart, End: row.RangeEnd, ValuationCurrency: row.ValuationCurrency, BQLQuery: row.BqlQuery}}
}

func relationalAgentSessionKey(clusterID, sessionID string) string {
	sum := sha256.Sum256([]byte(clusterID))
	return sessionID + ":" + hex.EncodeToString(sum[:12])
}

var _ agentSessionRepository = (*entAgentSessionRepository)(nil)
var _ agentApprovalRepository = (*entAgentApprovalRepository)(nil)
