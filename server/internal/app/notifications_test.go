package app

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

type failingNotificationSnapshotPort struct {
	calls atomic.Int32
}

func (p *failingNotificationSnapshotPort) Snapshot(context.Context) (*LedgerSnapshot, error) {
	p.calls.Add(1)
	return nil, errors.New("snapshot unavailable")
}

func (p *failingNotificationSnapshotPort) SnapshotLite(context.Context) (*LedgerSnapshot, error) {
	return nil, errors.New("snapshot unavailable")
}

func TestNotificationRefreshInterval(t *testing.T) {
	for _, test := range []struct {
		raw  string
		want time.Duration
		ok   bool
	}{
		{raw: "off", want: 0, ok: true},
		{raw: "", want: 0, ok: true},
		{raw: "15m", want: 15 * time.Minute, ok: true},
		{raw: "0s", ok: false},
		{raw: "later", ok: false},
	} {
		got, err := notificationRefreshInterval(test.raw)
		if (err == nil) != test.ok || got != test.want {
			t.Fatalf("notificationRefreshInterval(%q) = (%v, %v)", test.raw, got, err)
		}
	}
}

func TestNotificationServiceSchedulerStopsWithLifecycle(t *testing.T) {
	port := &failingNotificationSnapshotPort{}
	service, err := newNotificationService(NotificationServiceDependencies{
		Config:       Config{NotificationRefreshInterval: "1ms"},
		RuntimeStore: newFilesystemRuntimeStore(t.TempDir()),
		SnapshotPort: port,
	}, newNotificationChannelRegistry())
	if err != nil {
		t.Fatal(err)
	}
	if err := service.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for port.calls.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if port.calls.Load() == 0 {
		t.Fatal("scheduler did not refresh notifications")
	}
	if err := service.Close(); err != nil {
		t.Fatal(err)
	}
	calls := port.calls.Load()
	time.Sleep(5 * time.Millisecond)
	if got := port.calls.Load(); got != calls {
		t.Fatalf("scheduler ran after close: got %d calls, want %d", got, calls)
	}
}
