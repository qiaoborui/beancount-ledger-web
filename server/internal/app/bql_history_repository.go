package app

import (
	"context"
	"strings"

	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/bqlhistoryrecord"
)

// bqlHistoryRepository is intentionally domain-shaped. It prevents the new
// relational model from being hidden behind another generic key/value store.
type bqlHistoryRepository interface {
	List(context.Context, string) ([]BQLHistoryRecord, error)
	Get(context.Context, string, string) (BQLHistoryRecord, error)
	Touch(context.Context, string, BQLHistoryRecord) (BQLHistoryRecord, bool, error)
	Backfill(context.Context, string, []BQLHistoryRecord) error
	SetGeneratedTitle(context.Context, string, string, string) (BQLHistoryRecord, error)
	Rename(context.Context, string, string, string) (BQLHistoryRecord, error)
	Delete(context.Context, string, string) error
}

type entBQLHistoryRepository struct {
	client *ent.Client
}

func newEntBQLHistoryRepository(client *ent.Client) bqlHistoryRepository {
	if client == nil {
		return nil
	}
	return &entBQLHistoryRepository{client: client}
}

func (r *entBQLHistoryRepository) List(ctx context.Context, clusterID string) ([]BQLHistoryRecord, error) {
	rows, err := r.client.BQLHistoryRecord.Query().
		Where(bqlhistoryrecord.ClusterIDEQ(clusterID)).
		Order(ent.Desc(bqlhistoryrecord.FieldLastRunAt)).
		All(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]BQLHistoryRecord, 0, len(rows))
	for _, row := range rows {
		out = append(out, bqlHistoryRecordFromEnt(row))
	}
	return out, nil
}

func (r *entBQLHistoryRepository) Get(ctx context.Context, clusterID, id string) (BQLHistoryRecord, error) {
	row, err := r.client.BQLHistoryRecord.Query().
		Where(bqlhistoryrecord.IDEQ(persistedBQLHistoryID(clusterID, id)), bqlhistoryrecord.ClusterIDEQ(clusterID)).
		Only(ctx)
	if ent.IsNotFound(err) {
		return BQLHistoryRecord{}, errBQLHistoryRecordNotFound
	}
	if err != nil {
		return BQLHistoryRecord{}, err
	}
	return bqlHistoryRecordFromEnt(row), nil
}

func (r *entBQLHistoryRepository) Touch(ctx context.Context, clusterID string, record BQLHistoryRecord) (BQLHistoryRecord, bool, error) {
	exists, err := r.client.BQLHistoryRecord.Query().
		Where(bqlhistoryrecord.ClusterIDEQ(clusterID), bqlhistoryrecord.QueryEQ(record.Query)).
		Exist(ctx)
	if err != nil {
		return BQLHistoryRecord{}, false, err
	}
	if err := r.client.BQLHistoryRecord.Create().
		SetID(persistedBQLHistoryID(clusterID, record.ID)).
		SetClusterID(clusterID).
		SetQuery(record.Query).
		SetTitle(record.Title).
		SetTitleSource(record.TitleSource).
		SetCreatedAt(record.CreatedAt).
		SetLastRunAt(record.LastRunAt).
		SetRunCount(record.RunCount).
		OnConflictColumns(bqlhistoryrecord.FieldClusterID, bqlhistoryrecord.FieldQuery).
		SetLastRunAt(record.LastRunAt).
		AddRunCount(1).
		Exec(ctx); err != nil {
		return BQLHistoryRecord{}, false, err
	}
	if err := r.prune(ctx, clusterID); err != nil {
		return BQLHistoryRecord{}, false, err
	}
	updated, err := r.Get(ctx, clusterID, record.ID)
	return updated, !exists, err
}

func (r *entBQLHistoryRepository) Backfill(ctx context.Context, clusterID string, records []BQLHistoryRecord) error {
	for _, record := range records {
		if err := r.client.BQLHistoryRecord.Create().
			SetID(persistedBQLHistoryID(clusterID, record.ID)).
			SetClusterID(clusterID).
			SetQuery(record.Query).
			SetTitle(record.Title).
			SetTitleSource(record.TitleSource).
			SetCreatedAt(record.CreatedAt).
			SetLastRunAt(record.LastRunAt).
			SetRunCount(record.RunCount).
			OnConflictColumns(bqlhistoryrecord.FieldClusterID, bqlhistoryrecord.FieldQuery).
			DoNothing().
			Exec(ctx); err != nil {
			return err
		}
	}
	return nil
}

func (r *entBQLHistoryRepository) SetGeneratedTitle(ctx context.Context, clusterID, id, title string) (BQLHistoryRecord, error) {
	record, err := r.Get(ctx, clusterID, id)
	if err != nil || record.TitleSource == "manual" {
		return record, err
	}
	if _, err := r.client.BQLHistoryRecord.Update().
		Where(bqlhistoryrecord.IDEQ(persistedBQLHistoryID(clusterID, id)), bqlhistoryrecord.ClusterIDEQ(clusterID)).
		SetTitle(title).
		SetTitleSource("ai").
		Save(ctx); err != nil {
		return BQLHistoryRecord{}, err
	}
	return r.Get(ctx, clusterID, id)
}

func (r *entBQLHistoryRepository) Rename(ctx context.Context, clusterID, id, title string) (BQLHistoryRecord, error) {
	affected, err := r.client.BQLHistoryRecord.Update().
		Where(bqlhistoryrecord.IDEQ(persistedBQLHistoryID(clusterID, id)), bqlhistoryrecord.ClusterIDEQ(clusterID)).
		SetTitle(title).
		SetTitleSource("manual").
		Save(ctx)
	if err != nil {
		return BQLHistoryRecord{}, err
	}
	if affected == 0 {
		return BQLHistoryRecord{}, errBQLHistoryRecordNotFound
	}
	return r.Get(ctx, clusterID, id)
}

func (r *entBQLHistoryRepository) Delete(ctx context.Context, clusterID, id string) error {
	affected, err := r.client.BQLHistoryRecord.Delete().
		Where(bqlhistoryrecord.IDEQ(persistedBQLHistoryID(clusterID, id)), bqlhistoryrecord.ClusterIDEQ(clusterID)).
		Exec(ctx)
	if err != nil {
		return err
	}
	if affected == 0 {
		return errBQLHistoryRecordNotFound
	}
	return nil
}

func (r *entBQLHistoryRepository) prune(ctx context.Context, clusterID string) error {
	rows, err := r.client.BQLHistoryRecord.Query().
		Where(bqlhistoryrecord.ClusterIDEQ(clusterID)).
		Order(ent.Desc(bqlhistoryrecord.FieldLastRunAt)).
		All(ctx)
	if err != nil || len(rows) <= bqlHistoryLimit {
		return err
	}
	ids := make([]string, 0, len(rows)-bqlHistoryLimit)
	for _, row := range rows[bqlHistoryLimit:] {
		ids = append(ids, row.ID)
	}
	_, err = r.client.BQLHistoryRecord.Delete().Where(bqlhistoryrecord.IDIn(ids...)).Exec(ctx)
	return err
}

func bqlHistoryRecordFromEnt(row *ent.BQLHistoryRecord) BQLHistoryRecord {
	if row == nil {
		return BQLHistoryRecord{}
	}
	return BQLHistoryRecord{ID: publicBQLHistoryID(row.ID), Query: row.Query, Title: row.Title, TitleSource: row.TitleSource, CreatedAt: row.CreatedAt, LastRunAt: row.LastRunAt, RunCount: row.RunCount}
}

// The legacy public record ID is derived from query text and therefore is not
// globally unique. Keep it stable at the HTTP boundary while namespacing the
// physical primary key by ledger cluster.
func persistedBQLHistoryID(clusterID, id string) string {
	return bqlHistoryScopeHash(clusterID) + ":" + id
}

func publicBQLHistoryID(id string) string {
	if separator := strings.IndexByte(id, ':'); separator >= 0 {
		return id[separator+1:]
	}
	return id
}

var _ bqlHistoryRepository = (*entBQLHistoryRepository)(nil)
