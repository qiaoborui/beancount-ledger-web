package app

import (
	"context"
	"fmt"

	"github.com/borui/beancount-ledger-web/server/internal/persistence"
)

// backfillGmailRuntime copies the legacy Gmail documents into typed tables.
// It intentionally leaves runtime_json in place for rollback compatibility.
func backfillGmailRuntime(ctx context.Context, store *persistence.Store, runtime RuntimeStore, repository gmailStateRepository) error {
	if store == nil || runtime == nil || repository == nil {
		return nil
	}
	return store.RunBackfillOnce(ctx, "relational-gmail-state-v1", func(ctx context.Context) error {
		state := gmailLegacyState{}
		var connection gmailConnection
		ok, err := runtime.GetJSON(ctx, "gmail", gmailConnectionKey, &connection)
		if err != nil {
			return fmt.Errorf("read gmail connection: %w", err)
		}
		if ok {
			state.Connection = &connection
		}
		var oauth gmailOAuthState
		ok, err = runtime.GetJSON(ctx, "gmail", gmailOAuthStateKey, &oauth)
		if err != nil {
			return fmt.Errorf("read gmail OAuth state: %w", err)
		}
		if ok {
			state.OAuthState = &oauth
		}
		var pushes gmailPushEventStore
		ok, err = runtime.GetJSON(ctx, "gmail", gmailPushEventsKey, &pushes)
		if err != nil {
			return fmt.Errorf("read gmail push events: %w", err)
		}
		if ok {
			state.PushEvents = pushes.Items
		}
		var pending gmailPendingStore
		ok, err = runtime.GetJSON(ctx, "gmail", gmailPendingKey, &pending)
		if err != nil {
			return fmt.Errorf("read gmail pending imports: %w", err)
		}
		if ok {
			state.Pending = pending.Items
		}
		var lease gmailSyncLease
		ok, err = runtime.GetJSON(ctx, "gmail", gmailSyncLeaseKey, &lease)
		if err != nil {
			return fmt.Errorf("read gmail sync lease: %w", err)
		}
		if ok {
			state.SyncLease = &lease
		}
		return repository.Backfill(ctx, state)
	})
}
