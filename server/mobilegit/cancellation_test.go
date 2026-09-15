package mobilegit

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
)

func TestPendingCancellationsAreBoundedAndExpire(t *testing.T) {
	registry := &cancellationRegistry{}
	t.Cleanup(func() {
		registry.mu.Lock()
		defer registry.mu.Unlock()
		for _, pending := range registry.pending {
			pending.timer.Stop()
		}
	})
	for index := 0; index < maxPendingCancellations; index++ {
		if err := registry.cancel(fmt.Sprint(index)); err != nil {
			t.Fatal(err)
		}
	}
	assertCode(t, registry.cancel("overflow"), "git.limit_exceeded")
	registry.mu.Lock()
	expires := registry.pending["0"].expires
	registry.mu.Unlock()
	registry.expire("0", expires)
	if err := registry.cancel("overflow"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := registry.register("0", cancel); err != nil {
		t.Fatal(err)
	}
	if err := ctx.Err(); err != nil {
		t.Fatalf("expired cancellation affected new request: %v", err)
	}
	registry.finish("0")
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if len(registry.active) != 0 || len(registry.pending) != maxPendingCancellations {
		t.Fatalf("registry limits active=%d pending=%d", len(registry.active), len(registry.pending))
	}
}

func TestCancellationAndRegistrationSerializeWithoutLostSignal(t *testing.T) {
	registry := &cancellationRegistry{}
	for index := 0; index < 100; index++ {
		id := fmt.Sprint(index)
		ctx, cancel := context.WithCancel(context.Background())
		var registration, cancellation error
		var workers sync.WaitGroup
		workers.Add(2)
		go func() { defer workers.Done(); registration = registry.register(id, cancel) }()
		go func() { defer workers.Done(); cancellation = registry.cancel(id) }()
		workers.Wait()
		if cancellation != nil || (registration != nil && !errors.Is(registration, context.Canceled)) || !errors.Is(ctx.Err(), context.Canceled) {
			t.Fatalf("lost cancellation: register=%v cancel=%v context=%v", registration, cancellation, ctx.Err())
		}
		registry.finish(id)
		cancel()
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if len(registry.active) != 0 || len(registry.pending) != 0 {
		t.Fatal("completed requests retained registry state")
	}
}
