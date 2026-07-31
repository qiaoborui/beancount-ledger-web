package app

import (
	"context"
	"sort"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/notification"
)

// notificationRepository persists notification state as independently mutable
// rows. A refresh therefore cannot overwrite read/dismiss actions for another
// month as the previous JSON document implementation could.
type notificationRepository interface {
	MergeMonth(context.Context, string, []Insight) ([]StoredNotification, []StoredNotification, error)
	Backfill(context.Context, []StoredNotification) error
	UpdateStatus(context.Context, []string, string) ([]StoredNotification, error)
}

type entNotificationRepository struct {
	client *ent.Client
}

func newEntNotificationRepository(client *ent.Client) notificationRepository {
	if client == nil {
		return nil
	}
	return &entNotificationRepository{client: client}
}

func (r *entNotificationRepository) MergeMonth(ctx context.Context, month string, insights []Insight) ([]StoredNotification, []StoredNotification, error) {
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer tx.Rollback()
	rows, err := tx.Notification.Query().Where(notification.MonthEQ(month)).All(ctx)
	if err != nil {
		return nil, nil, err
	}
	byID := make(map[string]*ent.Notification, len(rows))
	for _, row := range rows {
		byID[row.ID] = row
	}
	now := time.Now().UTC()
	currentIDs := make(map[string]bool, len(insights))
	created := []StoredNotification{}
	for _, insight := range insights {
		id := notificationID(month, insight)
		currentIDs[id] = true
		detailHash := notificationDetailHash(insight)
		existing, found := byID[id]
		if !found {
			create := tx.Notification.Create().
				SetID(id).
				SetInsightID(insight.ID).
				SetMonth(month).
				SetSeverity(insight.Severity).
				SetTitle(insight.Title).
				SetDetail(insight.Detail).
				SetDetailHash(detailHash).
				SetAccount(insight.Account).
				SetOccurredOn(insight.Date).
				SetStatus("unread").
				SetCreatedAt(now).
				SetUpdatedAt(now)
			if insight.Amount != nil {
				create.SetAmount(*insight.Amount)
			}
			row, err := create.Save(ctx)
			if err != nil {
				return nil, nil, err
			}
			byID[id] = row
			created = append(created, storedNotificationFromEnt(row))
			continue
		}
		if existing.DetailHash == detailHash && existing.Severity == insight.Severity && existing.Title == insight.Title {
			continue
		}
		update := tx.Notification.UpdateOneID(existing.ID).
			SetSeverity(insight.Severity).
			SetTitle(insight.Title).
			SetDetail(insight.Detail).
			SetDetailHash(detailHash).
			SetAccount(insight.Account).
			SetOccurredOn(insight.Date).
			SetUpdatedAt(now)
		if insight.Amount == nil {
			update.ClearAmount()
		} else {
			update.SetAmount(*insight.Amount)
		}
		if existing.Status == "resolved" {
			update.SetStatus("unread").ClearResolvedAt().ClearReadAt()
		}
		row, err := update.Save(ctx)
		if err != nil {
			return nil, nil, err
		}
		byID[id] = row
	}
	for id, row := range byID {
		if currentIDs[id] || row.Status == "resolved" {
			continue
		}
		updated, err := tx.Notification.UpdateOneID(row.ID).SetStatus("resolved").SetResolvedAt(now).SetUpdatedAt(now).Save(ctx)
		if err != nil {
			return nil, nil, err
		}
		byID[id] = updated
	}
	if err := tx.Commit(); err != nil {
		return nil, nil, err
	}
	all, err := r.listMonth(ctx, month)
	if err != nil {
		return nil, nil, err
	}
	return created, all, nil
}

func (r *entNotificationRepository) Backfill(ctx context.Context, notifications []StoredNotification) error {
	for _, stored := range notifications {
		createdAt, err := time.Parse(time.RFC3339Nano, stored.CreatedAt)
		if err != nil {
			return err
		}
		updatedAt, err := time.Parse(time.RFC3339Nano, stored.UpdatedAt)
		if err != nil {
			return err
		}
		create := r.client.Notification.Create().
			SetID(stored.ID).
			SetInsightID(stored.InsightID).
			SetMonth(stored.Month).
			SetSeverity(stored.Severity).
			SetTitle(stored.Title).
			SetDetail(stored.Detail).
			SetDetailHash(stored.DetailHash).
			SetAccount(stored.Account).
			SetOccurredOn(stored.Date).
			SetStatus(stored.Status).
			SetCreatedAt(createdAt).
			SetUpdatedAt(updatedAt)
		if stored.Amount != nil {
			create.SetAmount(*stored.Amount)
		}
		if stored.ReadAt != nil {
			value, err := time.Parse(time.RFC3339Nano, *stored.ReadAt)
			if err != nil {
				return err
			}
			create.SetReadAt(value)
		}
		if stored.DismissedAt != nil {
			value, err := time.Parse(time.RFC3339Nano, *stored.DismissedAt)
			if err != nil {
				return err
			}
			create.SetDismissedAt(value)
		}
		if stored.ResolvedAt != nil {
			value, err := time.Parse(time.RFC3339Nano, *stored.ResolvedAt)
			if err != nil {
				return err
			}
			create.SetResolvedAt(value)
		}
		if err := create.OnConflictColumns(notification.FieldID).DoNothing().Exec(ctx); err != nil {
			return err
		}
	}
	return nil
}

func (r *entNotificationRepository) UpdateStatus(ctx context.Context, ids []string, status string) ([]StoredNotification, error) {
	rows, err := r.client.Notification.Query().Where(notification.IDIn(ids...)).All(ctx)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	updated := make([]StoredNotification, 0, len(rows))
	for _, row := range rows {
		change := r.client.Notification.UpdateOneID(row.ID).SetStatus(status).SetUpdatedAt(now)
		switch status {
		case "read":
			change.SetReadAt(now)
		case "unread":
			change.ClearReadAt().ClearDismissedAt().ClearResolvedAt()
		case "dismissed":
			change.SetDismissedAt(now)
		case "resolved":
			change.SetResolvedAt(now)
		}
		result, err := change.Save(ctx)
		if err != nil {
			return nil, err
		}
		updated = append(updated, storedNotificationFromEnt(result))
	}
	return updated, nil
}

func (r *entNotificationRepository) listMonth(ctx context.Context, month string) ([]StoredNotification, error) {
	rows, err := r.client.Notification.Query().Where(notification.MonthEQ(month)).All(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]StoredNotification, 0, len(rows))
	for _, row := range rows {
		out = append(out, storedNotificationFromEnt(row))
	}
	sort.Slice(out, func(i, j int) bool {
		if statusRank(out[i].Status) != statusRank(out[j].Status) {
			return statusRank(out[i].Status) < statusRank(out[j].Status)
		}
		if severityRank(out[i].Severity) != severityRank(out[j].Severity) {
			return severityRank(out[i].Severity) < severityRank(out[j].Severity)
		}
		return out[i].UpdatedAt > out[j].UpdatedAt
	})
	return out, nil
}

func storedNotificationFromEnt(row *ent.Notification) StoredNotification {
	if row == nil {
		return StoredNotification{}
	}
	stored := StoredNotification{
		ID: row.ID, InsightID: row.InsightID, Month: row.Month, Severity: row.Severity,
		Title: row.Title, Detail: row.Detail, DetailHash: row.DetailHash, Amount: row.Amount,
		Account: row.Account, Date: row.OccurredOn, Status: row.Status,
		CreatedAt: row.CreatedAt.UTC().Format(time.RFC3339Nano), UpdatedAt: row.UpdatedAt.UTC().Format(time.RFC3339Nano),
	}
	if row.ReadAt != nil {
		value := row.ReadAt.UTC().Format(time.RFC3339Nano)
		stored.ReadAt = &value
	}
	if row.DismissedAt != nil {
		value := row.DismissedAt.UTC().Format(time.RFC3339Nano)
		stored.DismissedAt = &value
	}
	if row.ResolvedAt != nil {
		value := row.ResolvedAt.UTC().Format(time.RFC3339Nano)
		stored.ResolvedAt = &value
	}
	return stored
}

var _ notificationRepository = (*entNotificationRepository)(nil)
