package app

import (
	"context"
	"fmt"

	"github.com/borui/beancount-ledger-web/server/internal/persistence"
)

// backfillRelationalRuntime is the one-time bridge from the legacy JSON
// runtime bucket. New request paths use only Ent repositories after this runs.
func backfillRelationalRuntime(ctx context.Context, store *persistence.Store, runtime RuntimeStore, cfg Config, bql bqlHistoryRepository, push pushSubscriptionRepository, notifications notificationRepository) error {
	if store == nil || runtime == nil {
		return nil
	}
	return store.RunBackfillOnce(ctx, "relational-runtime-v1", func(ctx context.Context) error {
		if bql != nil {
			var legacy bqlHistoryStore
			key := bqlHistoryKey + ":" + bqlHistoryScopeHash(ledgerClusterID(cfg))
			ok, err := runtime.GetJSON(ctx, bqlHistoryScope, key, &legacy)
			if err != nil {
				return fmt.Errorf("read BQL history: %w", err)
			}
			if ok && len(legacy.Records) > 0 {
				if err := bql.Backfill(ctx, ledgerClusterID(cfg), legacy.Records); err != nil {
					return fmt.Errorf("import BQL history: %w", err)
				}
			}
		}
		if push != nil {
			var legacy pushStore
			ok, err := runtime.GetJSON(ctx, "push", "subscriptions", &legacy)
			if err != nil {
				return fmt.Errorf("read push subscriptions: %w", err)
			}
			if ok && len(legacy.Subscriptions) > 0 {
				if err := push.Backfill(ctx, legacy.Subscriptions); err != nil {
					return fmt.Errorf("import push subscriptions: %w", err)
				}
			}
		}
		if notifications != nil {
			var legacy notificationStore
			ok, err := runtime.GetJSON(ctx, "notifications", "store", &legacy)
			if err != nil {
				return fmt.Errorf("read notifications: %w", err)
			}
			if ok && len(legacy.Notifications) > 0 {
				if err := notifications.Backfill(ctx, legacy.Notifications); err != nil {
					return fmt.Errorf("import notifications: %w", err)
				}
			}
		}
		return nil
	})
}
