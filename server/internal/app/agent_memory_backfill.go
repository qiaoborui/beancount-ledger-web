package app

import (
	"context"
	"fmt"

	"github.com/borui/beancount-ledger-web/server/internal/persistence"
)

func backfillAgentMemoryRuntime(ctx context.Context, store *persistence.Store, runtime RuntimeStore, cfg Config, memories agentMemoryRepository) error {
	if store == nil || runtime == nil || memories == nil {
		return nil
	}
	return store.RunBackfillOnce(ctx, "relational-agent-memories-v1", func(ctx context.Context) error {
		var legacy agentMemoryStore
		clusterID := ledgerClusterID(cfg)
		ok, err := runtime.GetJSON(ctx, agentMemoryScope, agentMemoryStoreKeyForCluster(clusterID), &legacy)
		if err != nil {
			return fmt.Errorf("read agent memories: %w", err)
		}
		if !ok || len(legacy.Records) == 0 {
			return nil
		}
		if err := memories.Backfill(ctx, clusterID, legacy.Records); err != nil {
			return fmt.Errorf("import agent memories: %w", err)
		}
		return nil
	})
}
