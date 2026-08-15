package app

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"
)

// gmailPollWorker owns the local-only Gmail polling loop. It deliberately runs
// one attempt at a time: the durable Gmail sync lease still protects against a
// manual sync or another process, while this worker never creates overlapping
// in-process work when an API call is slow.
type gmailPollWorker struct {
	interval time.Duration
	timeout  time.Duration
	run      func(context.Context) error
	logger   *slog.Logger

	mu     sync.Mutex
	cancel context.CancelFunc
	done   chan struct{}
}

func newGmailPollWorker(interval, timeout time.Duration, logger *slog.Logger, run func(context.Context) error) *gmailPollWorker {
	return &gmailPollWorker{interval: interval, timeout: timeout, logger: logger, run: run}
}

func (w *gmailPollWorker) Start(parent context.Context) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.done != nil {
		return
	}
	ctx, cancel := context.WithCancel(parent)
	w.cancel = cancel
	w.done = make(chan struct{})
	go w.loop(ctx, w.done)
}

func (w *gmailPollWorker) Close() error {
	w.mu.Lock()
	cancel, done := w.cancel, w.done
	w.mu.Unlock()
	if cancel == nil || done == nil {
		return nil
	}
	cancel()
	<-done
	return nil
}

func (w *gmailPollWorker) loop(ctx context.Context, done chan struct{}) {
	defer close(done)
	for {
		w.runOnce(ctx)
		if ctx.Err() != nil {
			return
		}
		// A timer is created after the attempt completes. Unlike time.Ticker,
		// it cannot accumulate a pending tick while Gmail is slow and trigger an
		// immediate retry when the attempt returns.
		timer := time.NewTimer(w.interval)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			return
		case <-timer.C:
		}
	}
}

func (w *gmailPollWorker) runOnce(parent context.Context) {
	ctx, cancel := context.WithTimeout(parent, w.timeout)
	defer cancel()
	defer func() {
		if recovered := recover(); recovered != nil {
			w.loggerOr().Error("gmail poll worker recovered panic")
		}
	}()
	if err := w.run(ctx); err != nil && !errors.Is(parent.Err(), context.Canceled) {
		w.loggerOr().Warn("gmail poll attempt failed", "error", err)
	}
}

func (w *gmailPollWorker) loggerOr() *slog.Logger {
	if w.logger != nil {
		return w.logger
	}
	return slog.Default()
}

func (s *Server) newGmailPollWorker() *gmailPollWorker {
	s.cfgMu.RLock()
	interval, timeout := s.cfg.GmailPollInterval, s.cfg.GmailPollTimeout
	s.cfgMu.RUnlock()
	return newGmailPollWorker(interval, timeout, s.loggerOr(), s.pollGmail)
}

func (s *Server) pollGmail(ctx context.Context) error {
	// Match the HTTP middleware's request-lifetime read lock. Every helper
	// below reads s.cfg directly, so a partial snapshot would still race a
	// runtime configuration refresh.
	s.cfgMu.RLock()
	defer s.cfgMu.RUnlock()
	connection, connected, err := s.gmailConnection(ctx)
	if err != nil || !connected {
		return err
	}
	// Drain any already persisted events first. This makes a webhook-to-poll
	// migration finish queued retries without making the local deployment accept
	// incoming Pub/Sub requests.
	if _, err := s.drainGmailPushEvents(ctx, 5); err != nil && !gmailErrorTransient(err) {
		return err
	}
	err = s.syncGmail(ctx, connection.HistoryID)
	if err != nil && errors.Is(ctx.Err(), context.DeadlineExceeded) {
		// syncGmail records normal Gmail failures itself. A deadline means its
		// write may use an already-expired context, so retain a visible error
		// through a short independent persistence attempt.
		statusCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = s.updateGmailConnectionError(statusCtx, err)
	}
	return err
}
