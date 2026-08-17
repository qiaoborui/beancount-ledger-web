package app

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestWaitForLedgerIndexNotification(t *testing.T) {
	t.Run("notification continues immediately", func(t *testing.T) {
		if !waitForLedgerIndexNotification(context.Background(), time.Hour, func(context.Context) error {
			return nil
		}) {
			t.Fatal("notification should continue the indexer loop")
		}
	})

	t.Run("poll timeout continues", func(t *testing.T) {
		if !waitForLedgerIndexNotification(context.Background(), time.Millisecond, func(ctx context.Context) error {
			<-ctx.Done()
			return ctx.Err()
		}) {
			t.Fatal("poll timeout should continue the indexer loop")
		}
	})

	t.Run("parent cancellation stops", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()

		if waitForLedgerIndexNotification(ctx, time.Hour, func(context.Context) error {
			cancel()
			return nil
		}) {
			t.Fatal("parent cancellation should stop the indexer loop")
		}
	})

	t.Run("notification errors keep fallback polling", func(t *testing.T) {
		if !waitForLedgerIndexNotification(context.Background(), time.Millisecond, func(context.Context) error {
			return errors.New("connection lost")
		}) {
			t.Fatal("notification errors should retain fallback polling")
		}
	})
}
