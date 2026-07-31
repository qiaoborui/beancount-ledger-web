package app

import (
	"context"
	"fmt"

	"github.com/borui/beancount-ledger-web/server/internal/persistence"
)

// backfillQuickUnlockRuntime makes the existing PostgreSQL runtime document a
// one-time import source. The legacy key intentionally remains untouched so
// filesystem deployments retain their JSON-compatible state.
func backfillQuickUnlockRuntime(ctx context.Context, store *persistence.Store, runtime RuntimeStore, quickUnlocks quickUnlockRepository) error {
	if store == nil || runtime == nil || quickUnlocks == nil {
		return nil
	}
	return store.RunBackfillOnce(ctx, "relational-quick-unlock-v1", func(ctx context.Context) error {
		var legacy quickUnlockStore
		ok, err := runtime.GetJSON(ctx, "auth", "quick-unlock", &legacy)
		if err != nil {
			return fmt.Errorf("read quick unlock devices: %w", err)
		}
		if !ok || len(legacy.Devices) == 0 {
			return nil
		}
		if err := quickUnlocks.Backfill(ctx, legacy.Devices); err != nil {
			return fmt.Errorf("import quick unlock devices: %w", err)
		}
		return nil
	})
}
