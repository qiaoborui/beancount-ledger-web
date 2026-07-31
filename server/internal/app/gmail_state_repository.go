package app

import (
	"context"
	"fmt"
	"strconv"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/gmailconnection"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/gmailoauthstate"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/gmailpendingimport"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/gmailpushevent"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/gmailsynclease"
)

const (
	gmailStateSingletonID = "default"
	gmailStateLockID      = "__gmail_state_lock__"
)

// gmailStateRepository owns the durable, business-shaped Gmail state. The
// filesystem implementation preserves the established RuntimeStore layout;
// PostgreSQL keeps every connection, OAuth state, event, lease and review item
// in independently mutable typed Ent rows.
type gmailStateRepository interface {
	WithLock(context.Context, string, func(context.Context) error) error
	Connection(context.Context) (gmailConnection, bool, error)
	SaveConnection(context.Context, gmailConnection) error
	DeleteConnection(context.Context) error
	OAuthState(context.Context) (gmailOAuthState, bool, error)
	SaveOAuthState(context.Context, gmailOAuthState) error
	DeleteOAuthState(context.Context) error
	PushEvents(context.Context) (gmailPushEventStore, error)
	SavePushEvents(context.Context, gmailPushEventStore) error
	Pending(context.Context) (gmailPendingStore, error)
	SavePending(context.Context, gmailPendingStore) error
	SyncLease(context.Context) (gmailSyncLease, bool, error)
	SaveSyncLease(context.Context, gmailSyncLease) error
	DeleteSyncLease(context.Context) error
	Backfill(context.Context, gmailLegacyState) error
}

type gmailLegacyState struct {
	Connection *gmailConnection
	OAuthState *gmailOAuthState
	PushEvents []gmailPushEvent
	Pending    []GmailPendingImport
	SyncLease  *gmailSyncLease
}

type runtimeGmailStateRepository struct{ runtime RuntimeStore }

func newRuntimeGmailStateRepository(runtime RuntimeStore) gmailStateRepository {
	return &runtimeGmailStateRepository{runtime: runtime}
}
func (r *runtimeGmailStateRepository) WithLock(ctx context.Context, name string, fn func(context.Context) error) error {
	return r.runtime.WithLock(ctx, name, fn)
}
func (r *runtimeGmailStateRepository) Connection(ctx context.Context) (gmailConnection, bool, error) {
	var value gmailConnection
	ok, err := r.runtime.GetJSON(ctx, "gmail", gmailConnectionKey, &value)
	return value, ok, err
}
func (r *runtimeGmailStateRepository) SaveConnection(ctx context.Context, value gmailConnection) error {
	return r.runtime.PutJSON(ctx, "gmail", gmailConnectionKey, value)
}
func (r *runtimeGmailStateRepository) DeleteConnection(ctx context.Context) error {
	return r.runtime.DeleteJSON(ctx, "gmail", gmailConnectionKey)
}
func (r *runtimeGmailStateRepository) OAuthState(ctx context.Context) (gmailOAuthState, bool, error) {
	var value gmailOAuthState
	ok, err := r.runtime.GetJSON(ctx, "gmail", gmailOAuthStateKey, &value)
	return value, ok, err
}
func (r *runtimeGmailStateRepository) SaveOAuthState(ctx context.Context, value gmailOAuthState) error {
	return r.runtime.PutJSON(ctx, "gmail", gmailOAuthStateKey, value)
}
func (r *runtimeGmailStateRepository) DeleteOAuthState(ctx context.Context) error {
	return r.runtime.DeleteJSON(ctx, "gmail", gmailOAuthStateKey)
}
func (r *runtimeGmailStateRepository) PushEvents(ctx context.Context) (gmailPushEventStore, error) {
	var value gmailPushEventStore
	ok, err := r.runtime.GetJSON(ctx, "gmail", gmailPushEventsKey, &value)
	if err != nil || ok {
		return value, err
	}
	return gmailPushEventStore{Version: 1, Items: []gmailPushEvent{}}, nil
}
func (r *runtimeGmailStateRepository) SavePushEvents(ctx context.Context, value gmailPushEventStore) error {
	return r.runtime.PutJSON(ctx, "gmail", gmailPushEventsKey, value)
}
func (r *runtimeGmailStateRepository) Pending(ctx context.Context) (gmailPendingStore, error) {
	var value gmailPendingStore
	ok, err := r.runtime.GetJSON(ctx, "gmail", gmailPendingKey, &value)
	if err != nil || ok {
		return value, err
	}
	return gmailPendingStore{Version: 1, Items: []GmailPendingImport{}}, nil
}
func (r *runtimeGmailStateRepository) SavePending(ctx context.Context, value gmailPendingStore) error {
	return r.runtime.PutJSON(ctx, "gmail", gmailPendingKey, value)
}
func (r *runtimeGmailStateRepository) SyncLease(ctx context.Context) (gmailSyncLease, bool, error) {
	var value gmailSyncLease
	ok, err := r.runtime.GetJSON(ctx, "gmail", gmailSyncLeaseKey, &value)
	return value, ok, err
}
func (r *runtimeGmailStateRepository) SaveSyncLease(ctx context.Context, value gmailSyncLease) error {
	return r.runtime.PutJSON(ctx, "gmail", gmailSyncLeaseKey, value)
}
func (r *runtimeGmailStateRepository) DeleteSyncLease(ctx context.Context) error {
	return r.runtime.DeleteJSON(ctx, "gmail", gmailSyncLeaseKey)
}
func (r *runtimeGmailStateRepository) Backfill(context.Context, gmailLegacyState) error { return nil }

type gmailEntClientKey struct{}
type entGmailStateRepository struct{ client *ent.Client }

func newEntGmailStateRepository(client *ent.Client) gmailStateRepository {
	if client == nil {
		return nil
	}
	return &entGmailStateRepository{client: client}
}
func (r *entGmailStateRepository) clientFor(ctx context.Context) *ent.Client {
	if client, ok := ctx.Value(gmailEntClientKey{}).(*ent.Client); ok && client != nil {
		return client
	}
	return r.client
}
func (r *entGmailStateRepository) WithLock(ctx context.Context, _ string, fn func(context.Context) error) error {
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// The fixed row is created by the migration and serializes all of the
	// legacy RuntimeStore critical sections without returning to JSON storage.
	if _, err := tx.GmailSyncLease.Query().Where(gmailsynclease.IDEQ(gmailStateLockID)).ForUpdate().Only(ctx); err != nil {
		return err
	}
	if err := fn(context.WithValue(ctx, gmailEntClientKey{}, tx.Client())); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *entGmailStateRepository) Connection(ctx context.Context) (gmailConnection, bool, error) {
	row, err := r.clientFor(ctx).GmailConnection.Query().Where(gmailconnection.IDEQ(gmailStateSingletonID)).Only(ctx)
	if ent.IsNotFound(err) {
		return gmailConnection{}, false, nil
	}
	if err != nil {
		return gmailConnection{}, false, err
	}
	history, err := strconv.ParseUint(row.HistoryID, 10, 64)
	if err != nil {
		return gmailConnection{}, false, fmt.Errorf("read gmail history ID: %w", err)
	}
	value := gmailConnection{Version: 1, Email: row.Email, EncryptedRefreshToken: row.EncryptedRefreshToken, LabelID: row.LabelID, LabelName: row.LabelName, HistoryID: history, WatchExpiration: row.WatchExpiration, ConnectedAt: row.ConnectedAt.UTC().Format(time.RFC3339Nano), UpdatedAt: row.UpdatedAt.UTC().Format(time.RFC3339Nano), LastError: row.LastError}
	if row.LastSyncAt != nil {
		value.LastSyncAt = row.LastSyncAt.UTC().Format(time.RFC3339Nano)
	}
	return value, true, nil
}
func (r *entGmailStateRepository) SaveConnection(ctx context.Context, value gmailConnection) error {
	connected, err := gmailRequiredTime(value.ConnectedAt)
	if err != nil {
		return fmt.Errorf("gmail connection connectedAt: %w", err)
	}
	updated, err := gmailRequiredTime(value.UpdatedAt)
	if err != nil {
		return fmt.Errorf("gmail connection updatedAt: %w", err)
	}
	lastSync, err := gmailOptionalTime(value.LastSyncAt)
	if err != nil {
		return fmt.Errorf("gmail connection lastSyncAt: %w", err)
	}
	return r.clientFor(ctx).GmailConnection.Create().SetID(gmailStateSingletonID).SetEmail(value.Email).SetEncryptedRefreshToken(value.EncryptedRefreshToken).SetLabelID(value.LabelID).SetLabelName(value.LabelName).SetHistoryID(strconv.FormatUint(value.HistoryID, 10)).SetWatchExpiration(value.WatchExpiration).SetConnectedAt(connected).SetUpdatedAt(updated).SetNillableLastSyncAt(lastSync).SetLastError(value.LastError).OnConflictColumns(gmailconnection.FieldID).UpdateNewValues().Exec(ctx)
}
func (r *entGmailStateRepository) DeleteConnection(ctx context.Context) error {
	_, err := r.clientFor(ctx).GmailConnection.Delete().Where(gmailconnection.IDEQ(gmailStateSingletonID)).Exec(ctx)
	return err
}

func (r *entGmailStateRepository) OAuthState(ctx context.Context) (gmailOAuthState, bool, error) {
	row, err := r.clientFor(ctx).GmailOAuthState.Query().Where(gmailoauthstate.IDEQ(gmailStateSingletonID)).Only(ctx)
	if ent.IsNotFound(err) {
		return gmailOAuthState{}, false, nil
	}
	if err != nil {
		return gmailOAuthState{}, false, err
	}
	return gmailOAuthState{Value: row.Value, ExpiresAt: row.ExpiresAt.UTC().Format(time.RFC3339Nano)}, true, nil
}
func (r *entGmailStateRepository) SaveOAuthState(ctx context.Context, value gmailOAuthState) error {
	expires, err := gmailRequiredTime(value.ExpiresAt)
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	return r.clientFor(ctx).GmailOAuthState.Create().SetID(gmailStateSingletonID).SetValue(value.Value).SetCreatedAt(now).SetExpiresAt(expires).OnConflictColumns(gmailoauthstate.FieldID).UpdateNewValues().Exec(ctx)
}
func (r *entGmailStateRepository) DeleteOAuthState(ctx context.Context) error {
	_, err := r.clientFor(ctx).GmailOAuthState.Delete().Where(gmailoauthstate.IDEQ(gmailStateSingletonID)).Exec(ctx)
	return err
}

func (r *entGmailStateRepository) PushEvents(ctx context.Context) (gmailPushEventStore, error) {
	rows, err := r.clientFor(ctx).GmailPushEvent.Query().Order(ent.Asc(gmailpushevent.FieldCreatedAt), ent.Asc(gmailpushevent.FieldID)).All(ctx)
	if err != nil {
		return gmailPushEventStore{}, err
	}
	store := gmailPushEventStore{Version: 1, Items: make([]gmailPushEvent, 0, len(rows))}
	for _, row := range rows {
		item, err := gmailPushEventFromEnt(row)
		if err != nil {
			return gmailPushEventStore{}, err
		}
		store.Items = append(store.Items, item)
	}
	return store, nil
}
func (r *entGmailStateRepository) SavePushEvents(ctx context.Context, store gmailPushEventStore) error {
	client := r.clientFor(ctx)
	keep := make([]string, 0, len(store.Items))
	for _, item := range store.Items {
		keep = append(keep, item.ID)
		if err := saveEntGmailPushEvent(ctx, client, item); err != nil {
			return err
		}
	}
	query := client.GmailPushEvent.Delete()
	if len(keep) == 0 {
		_, err := query.Exec(ctx)
		return err
	}
	_, err := query.Where(gmailpushevent.IDNotIn(keep...)).Exec(ctx)
	return err
}
func saveEntGmailPushEvent(ctx context.Context, client *ent.Client, item gmailPushEvent) error {
	available, err := gmailRequiredTime(item.AvailableAt)
	if err != nil {
		return fmt.Errorf("gmail push %s availableAt: %w", item.ID, err)
	}
	lease, err := gmailOptionalTime(item.LeaseUntil)
	if err != nil {
		return err
	}
	created, err := gmailRequiredTime(item.CreatedAt)
	if err != nil {
		return err
	}
	updated, err := gmailRequiredTime(item.UpdatedAt)
	if err != nil {
		return err
	}
	return client.GmailPushEvent.Create().SetID(item.ID).SetEmail(item.Email).SetHistoryID(strconv.FormatUint(item.HistoryID, 10)).SetStatus(item.Status).SetAttempts(item.Attempts).SetAvailableAt(available).SetNillableLeaseUntil(lease).SetLastError(item.LastError).SetCreatedAt(created).SetUpdatedAt(updated).OnConflictColumns(gmailpushevent.FieldID).UpdateNewValues().Exec(ctx)
}
func gmailPushEventFromEnt(row *ent.GmailPushEvent) (gmailPushEvent, error) {
	history, err := strconv.ParseUint(row.HistoryID, 10, 64)
	if err != nil {
		return gmailPushEvent{}, fmt.Errorf("read gmail push history ID: %w", err)
	}
	item := gmailPushEvent{ID: row.ID, Email: row.Email, HistoryID: history, Status: row.Status, Attempts: row.Attempts, AvailableAt: row.AvailableAt.UTC().Format(time.RFC3339Nano), LastError: row.LastError, CreatedAt: row.CreatedAt.UTC().Format(time.RFC3339Nano), UpdatedAt: row.UpdatedAt.UTC().Format(time.RFC3339Nano)}
	if row.LeaseUntil != nil {
		item.LeaseUntil = row.LeaseUntil.UTC().Format(time.RFC3339Nano)
	}
	return item, nil
}

func (r *entGmailStateRepository) Pending(ctx context.Context) (gmailPendingStore, error) {
	rows, err := r.clientFor(ctx).GmailPendingImport.Query().Order(ent.Asc(gmailpendingimport.FieldCreatedAt), ent.Asc(gmailpendingimport.FieldID)).All(ctx)
	if err != nil {
		return gmailPendingStore{}, err
	}
	store := gmailPendingStore{Version: 1, Items: make([]GmailPendingImport, 0, len(rows))}
	for _, row := range rows {
		store.Items = append(store.Items, gmailPendingFromEnt(row))
	}
	return store, nil
}
func (r *entGmailStateRepository) SavePending(ctx context.Context, store gmailPendingStore) error {
	client := r.clientFor(ctx)
	keep := make([]string, 0, len(store.Items))
	for _, item := range store.Items {
		keep = append(keep, item.ID)
		if err := saveEntGmailPending(ctx, client, item); err != nil {
			return err
		}
	}
	query := client.GmailPendingImport.Delete()
	if len(keep) == 0 {
		_, err := query.Exec(ctx)
		return err
	}
	_, err := query.Where(gmailpendingimport.IDNotIn(keep...)).Exec(ctx)
	return err
}
func saveEntGmailPending(ctx context.Context, client *ent.Client, item GmailPendingImport) error {
	received, err := gmailOptionalTime(item.ReceivedAt)
	if err != nil {
		return fmt.Errorf("gmail pending %s receivedAt: %w", item.ID, err)
	}
	created, err := gmailRequiredTime(item.CreatedAt)
	if err != nil {
		return err
	}
	updated, err := gmailRequiredTime(item.UpdatedAt)
	if err != nil {
		return err
	}
	return client.GmailPendingImport.Create().SetID(item.ID).SetImportID(item.ImportID).SetSourceKey(item.SourceKey).SetMessageID(item.MessageID).SetThreadID(item.ThreadID).SetSender(item.Sender).SetSubject(item.Subject).SetNillableReceivedAt(received).SetFilename(item.Filename).SetProvider(item.Provider).SetCandidateCount(item.CandidateCount).SetStatus(item.Status).SetError(item.Error).SetCreatedAt(created).SetUpdatedAt(updated).SetStoredBytes(item.StoredBytes).SetOutputFile(item.OutputFile).OnConflictColumns(gmailpendingimport.FieldID).UpdateNewValues().Exec(ctx)
}
func gmailPendingFromEnt(row *ent.GmailPendingImport) GmailPendingImport {
	item := GmailPendingImport{ID: row.ID, ImportID: row.ImportID, SourceKey: row.SourceKey, MessageID: row.MessageID, ThreadID: row.ThreadID, Sender: row.Sender, Subject: row.Subject, Filename: row.Filename, Provider: row.Provider, CandidateCount: row.CandidateCount, Status: row.Status, Error: row.Error, CreatedAt: row.CreatedAt.UTC().Format(time.RFC3339Nano), UpdatedAt: row.UpdatedAt.UTC().Format(time.RFC3339Nano), StoredBytes: row.StoredBytes, OutputFile: row.OutputFile}
	if row.ReceivedAt != nil {
		item.ReceivedAt = row.ReceivedAt.UTC().Format(time.RFC3339Nano)
	}
	return item
}

func (r *entGmailStateRepository) SyncLease(ctx context.Context) (gmailSyncLease, bool, error) {
	row, err := r.clientFor(ctx).GmailSyncLease.Query().Where(gmailsynclease.IDEQ(gmailStateSingletonID)).Only(ctx)
	if ent.IsNotFound(err) {
		return gmailSyncLease{}, false, nil
	}
	if err != nil {
		return gmailSyncLease{}, false, err
	}
	return gmailSyncLease{Owner: row.Owner, ExpiresAt: row.ExpiresAt.UTC().Format(time.RFC3339Nano)}, true, nil
}
func (r *entGmailStateRepository) SaveSyncLease(ctx context.Context, lease gmailSyncLease) error {
	expires, err := gmailRequiredTime(lease.ExpiresAt)
	if err != nil {
		return err
	}
	return r.clientFor(ctx).GmailSyncLease.Create().SetID(gmailStateSingletonID).SetOwner(lease.Owner).SetExpiresAt(expires).OnConflictColumns(gmailsynclease.FieldID).UpdateNewValues().Exec(ctx)
}
func (r *entGmailStateRepository) DeleteSyncLease(ctx context.Context) error {
	_, err := r.clientFor(ctx).GmailSyncLease.Delete().Where(gmailsynclease.IDEQ(gmailStateSingletonID)).Exec(ctx)
	return err
}

// Backfill inserts legacy state once without overwriting a row that may have
// been created by a newer server during a rolling deploy.
func (r *entGmailStateRepository) Backfill(ctx context.Context, legacy gmailLegacyState) error {
	client := r.clientFor(ctx)
	if legacy.Connection != nil {
		value := *legacy.Connection
		connected, err := gmailRequiredTime(value.ConnectedAt)
		if err != nil {
			return fmt.Errorf("backfill gmail connection connectedAt: %w", err)
		}
		updated, err := gmailRequiredTime(value.UpdatedAt)
		if err != nil {
			return fmt.Errorf("backfill gmail connection updatedAt: %w", err)
		}
		lastSync, err := gmailOptionalTime(value.LastSyncAt)
		if err != nil {
			return fmt.Errorf("backfill gmail connection lastSyncAt: %w", err)
		}
		if err := client.GmailConnection.Create().SetID(gmailStateSingletonID).SetEmail(value.Email).SetEncryptedRefreshToken(value.EncryptedRefreshToken).SetLabelID(value.LabelID).SetLabelName(value.LabelName).SetHistoryID(strconv.FormatUint(value.HistoryID, 10)).SetWatchExpiration(value.WatchExpiration).SetConnectedAt(connected).SetUpdatedAt(updated).SetNillableLastSyncAt(lastSync).SetLastError(value.LastError).OnConflictColumns(gmailconnection.FieldID).DoNothing().Exec(ctx); err != nil {
			return err
		}
	}
	if legacy.OAuthState != nil && legacy.OAuthState.Value != "" {
		expires, err := gmailRequiredTime(legacy.OAuthState.ExpiresAt)
		if err != nil {
			return fmt.Errorf("backfill gmail OAuth state: %w", err)
		}
		if err := client.GmailOAuthState.Create().SetID(gmailStateSingletonID).SetValue(legacy.OAuthState.Value).SetCreatedAt(time.Now().UTC()).SetExpiresAt(expires).OnConflictColumns(gmailoauthstate.FieldID).DoNothing().Exec(ctx); err != nil {
			return err
		}
	}
	for _, item := range legacy.PushEvents {
		available, err := gmailRequiredTime(item.AvailableAt)
		if err != nil {
			return fmt.Errorf("backfill gmail push %s availableAt: %w", item.ID, err)
		}
		lease, err := gmailOptionalTime(item.LeaseUntil)
		if err != nil {
			return err
		}
		created, err := gmailRequiredTime(item.CreatedAt)
		if err != nil {
			return err
		}
		updated, err := gmailRequiredTime(item.UpdatedAt)
		if err != nil {
			return err
		}
		if err := client.GmailPushEvent.Create().SetID(item.ID).SetEmail(item.Email).SetHistoryID(strconv.FormatUint(item.HistoryID, 10)).SetStatus(item.Status).SetAttempts(item.Attempts).SetAvailableAt(available).SetNillableLeaseUntil(lease).SetLastError(item.LastError).SetCreatedAt(created).SetUpdatedAt(updated).OnConflictColumns(gmailpushevent.FieldID).DoNothing().Exec(ctx); err != nil {
			return err
		}
	}
	for _, item := range legacy.Pending {
		received, err := gmailOptionalTime(item.ReceivedAt)
		if err != nil {
			return fmt.Errorf("backfill gmail pending %s receivedAt: %w", item.ID, err)
		}
		created, err := gmailRequiredTime(item.CreatedAt)
		if err != nil {
			return err
		}
		updated, err := gmailRequiredTime(item.UpdatedAt)
		if err != nil {
			return err
		}
		if err := client.GmailPendingImport.Create().SetID(item.ID).SetImportID(item.ImportID).SetSourceKey(item.SourceKey).SetMessageID(item.MessageID).SetThreadID(item.ThreadID).SetSender(item.Sender).SetSubject(item.Subject).SetNillableReceivedAt(received).SetFilename(item.Filename).SetProvider(item.Provider).SetCandidateCount(item.CandidateCount).SetStatus(item.Status).SetError(item.Error).SetCreatedAt(created).SetUpdatedAt(updated).SetStoredBytes(item.StoredBytes).SetOutputFile(item.OutputFile).OnConflict().DoNothing().Exec(ctx); err != nil {
			return err
		}
	}
	if legacy.SyncLease != nil && legacy.SyncLease.Owner != "" {
		expires, err := gmailRequiredTime(legacy.SyncLease.ExpiresAt)
		if err != nil {
			return fmt.Errorf("backfill gmail sync lease: %w", err)
		}
		if err := client.GmailSyncLease.Create().SetID(gmailStateSingletonID).SetOwner(legacy.SyncLease.Owner).SetExpiresAt(expires).OnConflictColumns(gmailsynclease.FieldID).DoNothing().Exec(ctx); err != nil {
			return err
		}
	}
	return nil
}

func gmailRequiredTime(value string) (time.Time, error) {
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}, err
	}
	return parsed.UTC(), nil
}
func gmailOptionalTime(value string) (*time.Time, error) {
	if value == "" {
		return nil, nil
	}
	parsed, err := gmailRequiredTime(value)
	if err != nil {
		return nil, err
	}
	return &parsed, nil
}
