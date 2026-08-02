package app

import (
	"context"
	"encoding/base64"
	"errors"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/passkeycredential"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/passkeysession"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/passkeytransport"
	"github.com/go-webauthn/webauthn/webauthn"
)

// passkeyRepository keeps credentials, transport hints, and single-use
// challenges in their own tables. SessionData is the sole JSONB value because
// it is a third-party WebAuthn protocol envelope.
type passkeyRepository interface {
	Credentials(context.Context) ([]StoredPasskey, error)
	SaveSession(context.Context, *webauthn.SessionData) error
	ConsumeSession(context.Context, string) (*webauthn.SessionData, error)
	HasSession(context.Context) (bool, error)
	SaveCredential(context.Context, StoredPasskey) error
	UpdateCredential(context.Context, string, uint32, bool, bool) error
	RenameCredential(context.Context, string, string) error
	DeleteCredential(context.Context, string) (int, error)
	Backfill(context.Context, passkeyStore) error
}

type entPasskeyRepository struct {
	client *ent.Client
}

func newEntPasskeyRepository(client *ent.Client) passkeyRepository {
	if client == nil {
		return nil
	}
	return &entPasskeyRepository{client: client}
}

func (r *entPasskeyRepository) Credentials(ctx context.Context) ([]StoredPasskey, error) {
	credentials, err := r.client.PasskeyCredential.Query().Order(ent.Asc(passkeycredential.FieldID)).All(ctx)
	if err != nil {
		return nil, err
	}
	transports, err := r.client.PasskeyTransport.Query().All(ctx)
	if err != nil {
		return nil, err
	}
	byCredential := map[string][]string{}
	for _, transport := range transports {
		byCredential[transport.CredentialID] = append(byCredential[transport.CredentialID], transport.Transport)
	}
	out := make([]StoredPasskey, 0, len(credentials))
	for _, credential := range credentials {
		out = append(out, StoredPasskey{
			ID:             credential.ID,
			PublicKey:      base64.RawURLEncoding.EncodeToString(credential.PublicKey),
			Counter:        uint32(credential.SignCount),
			Name:           credential.Name,
			Transports:     byCredential[credential.ID],
			BackupEligible: credential.BackupEligible,
			BackupState:    credential.BackupState,
			CreatedAt:      credential.CreatedAt,
			UpdatedAt:      credential.UpdatedAt,
			LastUsedAt:     credential.LastUsedAt,
		})
	}
	return out, nil
}

func (r *entPasskeyRepository) SaveSession(ctx context.Context, session *webauthn.SessionData) error {
	return r.saveSession(ctx, session, time.Now().UTC())
}

func (r *entPasskeyRepository) saveSession(ctx context.Context, session *webauthn.SessionData, createdAt time.Time) error {
	if session == nil || session.Challenge == "" {
		return errors.New("No active passkey challenge")
	}
	expiresAt := createdAt.Add(passkeySessionTTL)
	if !session.Expires.IsZero() && session.Expires.Before(expiresAt) {
		expiresAt = session.Expires
	}
	return r.client.PasskeySession.Create().
		SetID(session.Challenge).
		SetData(*session).
		SetCreatedAt(createdAt).
		SetExpiresAt(expiresAt).
		OnConflictColumns(passkeysession.FieldID).
		SetData(*session).
		SetExpiresAt(expiresAt).
		Exec(ctx)
}

func (r *entPasskeyRepository) ConsumeSession(ctx context.Context, challenge string) (*webauthn.SessionData, error) {
	if challenge == "" {
		return nil, errors.New("No active passkey challenge")
	}
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	row, err := tx.PasskeySession.Query().Where(passkeysession.IDEQ(challenge)).ForUpdate().Only(ctx)
	if ent.IsNotFound(err) {
		return nil, errors.New("No active passkey challenge")
	}
	if err != nil {
		return nil, err
	}
	if !row.ExpiresAt.After(time.Now()) {
		if err := tx.PasskeySession.DeleteOne(row).Exec(ctx); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return nil, errors.New("No active passkey challenge")
	}
	if err := tx.PasskeySession.DeleteOne(row).Exec(ctx); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	data := row.Data
	return &data, nil
}

func (r *entPasskeyRepository) HasSession(ctx context.Context) (bool, error) {
	now := time.Now().UTC()
	if _, err := r.client.PasskeySession.Delete().Where(passkeysession.ExpiresAtLTE(now)).Exec(ctx); err != nil {
		return false, err
	}
	return r.client.PasskeySession.Query().Where(passkeysession.ExpiresAtGT(now)).Exist(ctx)
}

func (r *entPasskeyRepository) SaveCredential(ctx context.Context, stored StoredPasskey) error {
	publicKey, err := decodeBase64URL(stored.PublicKey)
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	existing, err := tx.PasskeyCredential.Query().Where(passkeycredential.IDEQ(stored.ID)).Only(ctx)
	if ent.IsNotFound(err) {
		createdAt := stored.CreatedAt
		if createdAt.IsZero() {
			createdAt = now
		}
		if _, err := tx.PasskeyCredential.Create().SetID(stored.ID).SetPublicKey(publicKey).SetSignCount(uint64(stored.Counter)).SetName(stored.Name).SetNillableBackupEligible(stored.BackupEligible).SetNillableBackupState(stored.BackupState).SetCreatedAt(createdAt).SetUpdatedAt(now).SetNillableLastUsedAt(stored.LastUsedAt).Save(ctx); err != nil {
			return err
		}
	} else if err != nil {
		return err
	} else {
		update := tx.PasskeyCredential.UpdateOneID(existing.ID).SetPublicKey(publicKey).SetSignCount(uint64(stored.Counter)).SetUpdatedAt(now)
		if stored.BackupEligible == nil {
			update.ClearBackupEligible()
		} else {
			update.SetBackupEligible(*stored.BackupEligible)
		}
		if stored.BackupState == nil {
			update.ClearBackupState()
		} else {
			update.SetBackupState(*stored.BackupState)
		}
		if err := update.Exec(ctx); err != nil {
			return err
		}
	}
	if _, err := tx.PasskeyTransport.Delete().Where(passkeytransport.CredentialIDEQ(stored.ID)).Exec(ctx); err != nil {
		return err
	}
	for _, transport := range stored.Transports {
		if err := tx.PasskeyTransport.Create().SetID(stored.ID+":"+transport).SetCredentialID(stored.ID).SetTransport(transport).OnConflictColumns(passkeytransport.FieldCredentialID, passkeytransport.FieldTransport).DoNothing().Exec(ctx); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (r *entPasskeyRepository) UpdateCredential(ctx context.Context, id string, counter uint32, backupEligible bool, backupState bool) error {
	now := time.Now().UTC()
	updated, err := r.client.PasskeyCredential.Update().Where(passkeycredential.IDEQ(id)).SetSignCount(uint64(counter)).SetBackupEligible(backupEligible).SetBackupState(backupState).SetUpdatedAt(now).SetLastUsedAt(now).Save(ctx)
	if err != nil {
		return err
	}
	if updated == 0 {
		return errPasskeyNotFound
	}
	return nil
}

func (r *entPasskeyRepository) RenameCredential(ctx context.Context, id string, name string) error {
	updated, err := r.client.PasskeyCredential.Update().Where(passkeycredential.IDEQ(id)).SetName(name).SetUpdatedAt(time.Now().UTC()).Save(ctx)
	if err != nil {
		return err
	}
	if updated == 0 {
		return errPasskeyNotFound
	}
	return nil
}

func (r *entPasskeyRepository) DeleteCredential(ctx context.Context, id string) (int, error) {
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	credential, err := tx.PasskeyCredential.Query().Where(passkeycredential.IDEQ(id)).Only(ctx)
	if ent.IsNotFound(err) {
		return 0, errPasskeyNotFound
	}
	if err != nil {
		return 0, err
	}
	if _, err := tx.PasskeyTransport.Delete().Where(passkeytransport.CredentialIDEQ(id)).Exec(ctx); err != nil {
		return 0, err
	}
	if err := tx.PasskeyCredential.DeleteOne(credential).Exec(ctx); err != nil {
		return 0, err
	}
	remaining, err := tx.PasskeyCredential.Query().Count(ctx)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return remaining, nil
}

func (r *entPasskeyRepository) Backfill(ctx context.Context, legacy passkeyStore) error {
	legacy.normalizePasskeySessions(time.Now().UTC())
	for _, credential := range legacy.Credentials {
		if err := r.SaveCredential(ctx, credential); err != nil {
			return err
		}
	}
	for _, stored := range legacy.Sessions {
		if stored.Session == nil {
			continue
		}
		if err := r.saveSession(ctx, stored.Session, stored.CreatedAt); err != nil {
			return err
		}
	}
	return nil
}

var _ passkeyRepository = (*entPasskeyRepository)(nil)
