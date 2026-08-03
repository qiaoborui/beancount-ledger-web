package app

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// WaitForLedgerIndexTrigger waits for a local writer's durable request or its
// PostgreSQL NOTIFY hint. It opens LISTEN before checking the table so a commit
// cannot be lost in the gap between the check and the wait.
func WaitForLedgerIndexTrigger(ctx context.Context, cfg Config, delay time.Duration) bool {
	if delay <= 0 {
		return true
	}
	if !cfg.LedgerIndexNotifyEnabled || cfg.DatabaseURL == "" {
		return waitForContext(ctx, delay)
	}
	conn, err := pgx.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		return waitForContext(ctx, delay)
	}
	defer conn.Close(context.Background())
	if _, err := conn.Exec(ctx, `LISTEN ledger_index_request`); err != nil {
		return waitForContext(ctx, delay)
	}
	store, err := NewLedgerIndexStore(cfg)
	if err == nil {
		defer store.Close()
		if pending, queryErr := store.HasPendingRequest(ctx); queryErr == nil && pending {
			return true
		}
	}
	waitCtx, cancel := context.WithTimeout(ctx, delay)
	defer cancel()
	_, err = conn.WaitForNotification(waitCtx)
	return err == nil
}

func PendingLedgerIndexRequestBoundary(ctx context.Context, cfg Config) (int64, error) {
	if !cfg.LedgerIndexNotifyEnabled {
		return 0, nil
	}
	store, err := NewLedgerIndexStore(cfg)
	if err != nil {
		return 0, err
	}
	defer store.Close()
	return store.PendingRequestBoundary(ctx)
}

func CompleteLedgerIndexRequests(ctx context.Context, cfg Config, boundary int64) error {
	if !cfg.LedgerIndexNotifyEnabled {
		return nil
	}
	store, err := NewLedgerIndexStore(cfg)
	if err != nil {
		return err
	}
	defer store.Close()
	return store.CompletePendingRequestsThrough(ctx, boundary)
}

func waitForContext(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
