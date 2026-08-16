package app

import (
	"context"
	"encoding/base64"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestGmailPollWorkerDoesNotOverlapAndStops(t *testing.T) {
	started := make(chan struct{})
	var calls atomic.Int32
	worker := newGmailPollWorker(5*time.Millisecond, time.Second, nil, func(ctx context.Context) error {
		if calls.Add(1) == 1 {
			close(started)
		}
		<-ctx.Done()
		return ctx.Err()
	})
	worker.Start(context.Background())
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("poll worker did not start")
	}
	time.Sleep(25 * time.Millisecond)
	if got := calls.Load(); got != 1 {
		t.Fatalf("overlapping poll attempts=%d, want 1", got)
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("poll calls after close=%d, want 1", got)
	}
}

func TestGmailPollWorkerWaitsAnIntervalAfterSlowAttempt(t *testing.T) {
	starts := make(chan time.Time, 2)
	release := make(chan struct{})
	var calls atomic.Int32
	interval := 25 * time.Millisecond
	worker := newGmailPollWorker(interval, time.Second, nil, func(context.Context) error {
		call := calls.Add(1)
		starts <- time.Now()
		if call == 1 {
			<-release
		}
		return nil
	})
	worker.Start(context.Background())
	select {
	case <-starts:
	case <-time.After(time.Second):
		t.Fatal("first poll attempt did not start")
	}
	time.Sleep(2 * interval)
	releasedAt := time.Now()
	close(release)
	var second time.Time
	select {
	case second = <-starts:
	case <-time.After(time.Second):
		t.Fatal("second poll attempt did not start")
	}
	if got := second.Sub(releasedAt); got < interval-5*time.Millisecond {
		t.Fatalf("second attempt started after %v, want at least %v", got, interval)
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestPollGmailSynchronizesWithConfigWriters(t *testing.T) {
	cfg := testLedger(t)
	cfg.GmailTokenEncryptionKey = base64.RawStdEncoding.EncodeToString(make([]byte, 32))
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	if err := server.writeGmailConnection(context.Background(), gmailConnection{Email: "owner@example.com", EncryptedRefreshToken: "invalid", LabelID: "label"}); err != nil {
		t.Fatal(err)
	}

	server.cfgMu.Lock()
	done := make(chan struct{})
	go func() {
		_ = server.pollGmail(context.Background())
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("poll completed while configuration writer held the lock")
	case <-time.After(25 * time.Millisecond):
	}
	server.cfgMu.Unlock()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("poll did not resume after configuration writer released the lock")
	}
}

func TestPollGmailAndConfigurationUpdatesAreRaceSafe(t *testing.T) {
	cfg := testLedger(t)
	cfg.GmailTokenEncryptionKey = base64.RawStdEncoding.EncodeToString(make([]byte, 32))
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	if err := server.writeGmailConnection(context.Background(), gmailConnection{Email: "owner@example.com", EncryptedRefreshToken: "invalid", LabelID: "label"}); err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	var wait sync.WaitGroup
	wait.Add(2)
	go func() {
		defer wait.Done()
		<-start
		for range 100 {
			_ = server.pollGmail(context.Background())
		}
	}()
	go func() {
		defer wait.Done()
		<-start
		for index := range 100 {
			server.cfgMu.Lock()
			if index%2 == 0 {
				server.cfg.GmailTokenEncryptionKey = base64.RawStdEncoding.EncodeToString(make([]byte, 32))
			} else {
				server.cfg.GmailTokenEncryptionKey = base64.RawStdEncoding.EncodeToString([]byte("01234567890123456789012345678901"))
			}
			server.cfgMu.Unlock()
		}
	}()
	close(start)
	wait.Wait()
}

func TestNewGmailPollWorkerAndConfigurationUpdatesAreRaceSafe(t *testing.T) {
	server := &Server{cfg: Config{GmailPollInterval: time.Minute, GmailPollTimeout: time.Minute}}
	start := make(chan struct{})
	var wait sync.WaitGroup
	wait.Add(2)
	go func() {
		defer wait.Done()
		<-start
		for range 100 {
			worker := server.newGmailPollWorker()
			if worker.interval != time.Minute && worker.interval != 2*time.Minute {
				t.Fatalf("unexpected poll interval %v", worker.interval)
			}
			if worker.timeout != time.Minute && worker.timeout != 2*time.Minute {
				t.Fatalf("unexpected poll timeout %v", worker.timeout)
			}
		}
	}()
	go func() {
		defer wait.Done()
		<-start
		for index := range 100 {
			server.cfgMu.Lock()
			if index%2 == 0 {
				server.cfg.GmailPollInterval = time.Minute
				server.cfg.GmailPollTimeout = time.Minute
			} else {
				server.cfg.GmailPollInterval = 2 * time.Minute
				server.cfg.GmailPollTimeout = 2 * time.Minute
			}
			server.cfgMu.Unlock()
		}
	}()
	close(start)
	wait.Wait()
}

func TestGmailPollWorkerRecoversPanicAndRetries(t *testing.T) {
	completed := make(chan struct{})
	var calls atomic.Int32
	worker := newGmailPollWorker(5*time.Millisecond, time.Second, nil, func(context.Context) error {
		call := calls.Add(1)
		if call == 1 {
			panic("test panic")
		}
		if call == 2 {
			close(completed)
		}
		return nil
	})
	worker.Start(context.Background())
	select {
	case <-completed:
	case <-time.After(time.Second):
		t.Fatal("poll worker did not retry after panic")
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}
