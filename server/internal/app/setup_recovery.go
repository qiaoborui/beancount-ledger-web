package app

import (
	"context"
	"log/slog"

	"github.com/borui/beancount-ledger-web/server/internal/persistence"
)

// RecoverSelfHostedInstallCode is intentionally a host-side operation, not an
// HTTP endpoint. Access requires the deployment's database and AUTH_SECRET,
// and every successful rotation is audited by RuntimeConfigStore.
func RecoverSelfHostedInstallCode(ctx context.Context, cfg Config, logger *slog.Logger) (string, error) {
	db, err := openPostgres(cfg.DatabaseURL)
	if err != nil {
		return "", err
	}
	defer db.Close()
	if err := persistence.ApplyMigrations(ctx, db); err != nil {
		return "", err
	}
	store, err := NewRuntimeConfigStore(db, logger)
	if err != nil {
		return "", err
	}
	return store.RegenerateInstallCode(ctx)
}
