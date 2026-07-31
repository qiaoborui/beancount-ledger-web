package app

import (
	"context"
	"errors"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/agentmemory"
)

type agentMemoryRepository interface {
	List(context.Context, string) ([]AgentMemoryRecord, error)
	Upsert(context.Context, string, agentMemoryInput) (AgentMemoryRecord, error)
	Backfill(context.Context, string, []AgentMemoryRecord) error
}

type entAgentMemoryRepository struct{ client *ent.Client }

func newEntAgentMemoryRepository(client *ent.Client) agentMemoryRepository {
	if client == nil {
		return nil
	}
	return &entAgentMemoryRepository{client: client}
}

func (r *entAgentMemoryRepository) List(ctx context.Context, clusterID string) ([]AgentMemoryRecord, error) {
	rows, err := r.client.AgentMemory.Query().Where(agentmemory.ClusterIDEQ(clusterID)).Order(ent.Desc(agentmemory.FieldUpdatedAt)).All(ctx)
	if err != nil {
		return nil, err
	}
	records := make([]AgentMemoryRecord, 0, len(rows))
	for _, row := range rows {
		records = append(records, agentMemoryFromEnt(row))
	}
	return records, nil
}

func (r *entAgentMemoryRepository) Upsert(ctx context.Context, clusterID string, input agentMemoryInput) (AgentMemoryRecord, error) {
	if input.ID != "" {
		existing, err := r.client.AgentMemory.Query().Where(agentmemory.IDEQ(input.ID), agentmemory.ClusterIDEQ(clusterID)).Only(ctx)
		if err == nil {
			row, err := r.client.AgentMemory.UpdateOneID(existing.ID).SetKind(input.Kind).SetTitle(input.Title).SetInstruction(input.Instruction).SetUpdatedAt(time.Now().UTC()).Save(ctx)
			if err != nil {
				return AgentMemoryRecord{}, err
			}
			return agentMemoryFromEnt(row), nil
		}
		if !ent.IsNotFound(err) {
			return AgentMemoryRecord{}, err
		}
	}
	// An absent ID is an upsert by the domain's natural key.
	existing, err := r.client.AgentMemory.Query().Where(agentmemory.ClusterIDEQ(clusterID), agentmemory.KindEQ(input.Kind), agentmemory.TitleEQ(input.Title)).Only(ctx)
	if err == nil {
		row, err := r.client.AgentMemory.UpdateOneID(existing.ID).SetInstruction(input.Instruction).SetUpdatedAt(time.Now().UTC()).Save(ctx)
		if err != nil {
			return AgentMemoryRecord{}, err
		}
		return agentMemoryFromEnt(row), nil
	}
	if !ent.IsNotFound(err) {
		return AgentMemoryRecord{}, err
	}
	count, err := r.client.AgentMemory.Query().Where(agentmemory.ClusterIDEQ(clusterID)).Count(ctx)
	if err != nil {
		return AgentMemoryRecord{}, err
	}
	if count >= agentMemoryLimit {
		return AgentMemoryRecord{}, errors.New("agent memory limit reached")
	}
	now := time.Now().UTC()
	row, err := r.client.AgentMemory.Create().SetID(newAgentID("memory")).SetClusterID(clusterID).SetKind(input.Kind).SetTitle(input.Title).SetInstruction(input.Instruction).SetCreatedAt(now).SetUpdatedAt(now).Save(ctx)
	if err != nil {
		return AgentMemoryRecord{}, err
	}
	return agentMemoryFromEnt(row), nil
}

func (r *entAgentMemoryRepository) Backfill(ctx context.Context, clusterID string, records []AgentMemoryRecord) error {
	for _, record := range records {
		if err := r.client.AgentMemory.Create().SetID(record.ID).SetClusterID(clusterID).SetKind(record.Kind).SetTitle(record.Title).SetInstruction(record.Instruction).SetCreatedAt(record.CreatedAt).SetUpdatedAt(record.UpdatedAt).OnConflictColumns(agentmemory.FieldClusterID, agentmemory.FieldKind, agentmemory.FieldTitle).DoNothing().Exec(ctx); err != nil {
			return err
		}
	}
	return nil
}

func agentMemoryFromEnt(row *ent.AgentMemory) AgentMemoryRecord {
	return AgentMemoryRecord{ID: row.ID, Kind: row.Kind, Title: row.Title, Instruction: row.Instruction, CreatedAt: row.CreatedAt, UpdatedAt: row.UpdatedAt}
}

var _ agentMemoryRepository = (*entAgentMemoryRepository)(nil)
