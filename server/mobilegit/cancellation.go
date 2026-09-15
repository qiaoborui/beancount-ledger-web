package mobilegit

import (
	"context"
	"sync"
	"time"
)

const cancellationRetention = 3 * time.Minute
const maxPendingCancellations = 256

type pendingCancellation struct {
	expires time.Time
	timer   *time.Timer
}

// A cancellation can arrive before the detached Swift worker enters Go.
// Registration and cancellation share a lock; short-lived, bounded tombstones
// bridge that scheduling gap without retaining arbitrary request IDs forever.
type cancellationRegistry struct {
	mu      sync.Mutex
	active  map[string]context.CancelFunc
	pending map[string]pendingCancellation
}

func (r *cancellationRegistry) register(id string, cancel context.CancelFunc) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.active[id] != nil {
		return fail("invalid_request", "requestID is already in use")
	}
	if pending, ok := r.pending[id]; ok {
		delete(r.pending, id)
		pending.timer.Stop()
		if time.Now().Before(pending.expires) {
			cancel()
			return context.Canceled
		}
	}
	if r.active == nil {
		r.active = make(map[string]context.CancelFunc)
	}
	r.active[id] = cancel
	return nil
}

func (r *cancellationRegistry) finish(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.active, id)
}

func (r *cancellationRegistry) cancel(id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if cancel := r.active[id]; cancel != nil {
		cancel()
		return nil
	}
	if _, ok := r.pending[id]; ok {
		return nil
	}
	if len(r.pending) >= maxPendingCancellations {
		return fail("limit_exceeded", "Too many pending Git cancellation requests")
	}
	if r.pending == nil {
		r.pending = make(map[string]pendingCancellation)
	}
	expires := time.Now().Add(cancellationRetention)
	timer := time.AfterFunc(cancellationRetention, func() { r.expire(id, expires) })
	r.pending[id] = pendingCancellation{expires: expires, timer: timer}
	return nil
}

func (r *cancellationRegistry) expire(id string, expires time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if pending, ok := r.pending[id]; ok && pending.expires.Equal(expires) {
		pending.timer.Stop()
		delete(r.pending, id)
	}
}

func (r *cancellationRegistry) isActive(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.active[id] != nil
}
