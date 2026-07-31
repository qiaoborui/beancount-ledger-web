package app

import (
	"context"
	"fmt"

	"github.com/borui/beancount-ledger-web/server/internal/persistence"
)

func backfillPasskeyRuntime(ctx context.Context, store *persistence.Store, runtime RuntimeStore, passkeys passkeyRepository) error {
	if store == nil || runtime == nil || passkeys == nil {
		return nil
	}
	return store.RunBackfillOnce(ctx, "relational-webauthn-v1", func(ctx context.Context) error {
		var legacy passkeyStore
		ok, err := runtime.GetJSON(ctx, "auth", "passkeys", &legacy)
		if err != nil {
			return fmt.Errorf("read passkeys: %w", err)
		}
		if !ok {
			return nil
		}
		if err := passkeys.Backfill(ctx, legacy); err != nil {
			return fmt.Errorf("import passkeys: %w", err)
		}
		return nil
	})
}
