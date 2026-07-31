package app

import (
	"context"
	"crypto/subtle"
	"errors"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/quickunlockdevice"
)

// quickUnlockRepository stores each browser credential independently. The
// token hash remains write-only: callers can verify it but never read it back
// through a public HTTP response.
type quickUnlockRepository interface {
	List(context.Context) ([]quickUnlockDevice, error)
	Save(context.Context, quickUnlockDevice) error
	Verify(context.Context, string, string, time.Time) error
	Revoke(context.Context, string, time.Time) error
	Backfill(context.Context, []quickUnlockDevice) error
}

type entQuickUnlockRepository struct {
	client *ent.Client
}

func newEntQuickUnlockRepository(client *ent.Client) quickUnlockRepository {
	if client == nil {
		return nil
	}
	return &entQuickUnlockRepository{client: client}
}

func (r *entQuickUnlockRepository) List(ctx context.Context) ([]quickUnlockDevice, error) {
	rows, err := r.client.QuickUnlockDevice.Query().Order(ent.Asc(quickunlockdevice.FieldCreatedAt), ent.Asc(quickunlockdevice.FieldID)).All(ctx)
	if err != nil {
		return nil, err
	}
	devices := make([]quickUnlockDevice, 0, len(rows))
	for _, row := range rows {
		devices = append(devices, quickUnlockDevice{
			ID: row.ID, Name: row.Name, Mode: row.Mode, CreatedAt: row.CreatedAt,
			LastUsedAt: row.LastUsedAt, RevokedAt: row.RevokedAt,
		})
	}
	return devices, nil
}

func (r *entQuickUnlockRepository) Save(ctx context.Context, device quickUnlockDevice) error {
	return r.client.QuickUnlockDevice.Create().
		SetID(device.ID).
		SetName(device.Name).
		SetMode(device.Mode).
		SetTokenHash(device.TokenHash).
		SetCreatedAt(device.CreatedAt).
		SetNillableLastUsedAt(device.LastUsedAt).
		SetNillableRevokedAt(device.RevokedAt).
		OnConflictColumns(quickunlockdevice.FieldID).
		UpdateNewValues().
		Exec(ctx)
}

func (r *entQuickUnlockRepository) Verify(ctx context.Context, deviceID, tokenHash string, usedAt time.Time) error {
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	row, err := tx.QuickUnlockDevice.Query().Where(quickunlockdevice.IDEQ(deviceID)).ForUpdate().Only(ctx)
	if ent.IsNotFound(err) || (err == nil && row.RevokedAt != nil) {
		return errors.New("quick unlock device not found")
	}
	if err != nil {
		return err
	}
	if !quickUnlockTokenHashesEqual(row.TokenHash, tokenHash) {
		return errors.New("quick unlock token mismatch")
	}
	if err := tx.QuickUnlockDevice.UpdateOneID(row.ID).SetLastUsedAt(usedAt).Exec(ctx); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *entQuickUnlockRepository) Revoke(ctx context.Context, deviceID string, revokedAt time.Time) error {
	affected, err := r.client.QuickUnlockDevice.Update().Where(quickunlockdevice.IDEQ(deviceID)).SetRevokedAt(revokedAt).Save(ctx)
	if err != nil {
		return err
	}
	if affected == 0 {
		return errors.New("quick unlock device not found")
	}
	return nil
}

// Backfill only inserts missing device IDs, so an old runtime document can
// never overwrite a credential changed after PostgreSQL became authoritative.
func (r *entQuickUnlockRepository) Backfill(ctx context.Context, devices []quickUnlockDevice) error {
	for _, device := range devices {
		if err := r.client.QuickUnlockDevice.Create().
			SetID(device.ID).
			SetName(device.Name).
			SetMode(device.Mode).
			SetTokenHash(device.TokenHash).
			SetCreatedAt(device.CreatedAt).
			SetNillableLastUsedAt(device.LastUsedAt).
			SetNillableRevokedAt(device.RevokedAt).
			OnConflictColumns(quickunlockdevice.FieldID).
			DoNothing().
			Exec(ctx); err != nil {
			return err
		}
	}
	return nil
}

func quickUnlockTokenHashesEqual(left, right string) bool {
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

var _ quickUnlockRepository = (*entQuickUnlockRepository)(nil)
