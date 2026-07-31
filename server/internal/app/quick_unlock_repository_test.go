package app

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestQuickUnlockUsesRepositoryWhenAvailable(t *testing.T) {
	usedAt := time.Date(2026, time.July, 31, 12, 0, 0, 0, time.UTC)
	repository := &recordingQuickUnlockRepository{
		devices: []quickUnlockDevice{{ID: "device-1", Name: "Phone", Mode: "numeric", CreatedAt: usedAt}},
	}
	server := &Server{quickUnlocks: repository}

	store := server.readQuickUnlockStore(context.Background())
	if len(store.Devices) != 1 || store.Devices[0].TokenHash != "" {
		t.Fatalf("read store = %#v", store)
	}
	device := quickUnlockDevice{ID: "device-2", Name: "Laptop", Mode: "biometric", TokenHash: "token-hash", CreatedAt: usedAt}
	if err := server.saveQuickUnlockDevice(device); err != nil {
		t.Fatal(err)
	}
	if err := server.verifyQuickUnlockDevice("device-2", "raw-token"); err != nil {
		t.Fatal(err)
	}
	if err := server.revokeQuickUnlockDevice("device-2"); err != nil {
		t.Fatal(err)
	}

	if repository.saved.ID != "device-2" || repository.verifiedID != "device-2" || repository.revokedID != "device-2" {
		t.Fatalf("unexpected repository calls: %#v", repository)
	}
	if repository.verifiedHash != quickUnlockTokenHash("raw-token") || repository.verifiedAt.IsZero() || repository.revokedAt.IsZero() {
		t.Fatalf("quick unlock timestamps/hash were not supplied: %#v", repository)
	}
}

func TestQuickUnlockFilesystemFallbackLifecycle(t *testing.T) {
	server := &Server{cfg: Config{RuntimeDir: t.TempDir()}, runtimeStore: newFilesystemRuntimeStore(t.TempDir())}
	createdAt := time.Date(2026, time.July, 31, 12, 0, 0, 0, time.UTC)
	device := quickUnlockDevice{ID: "device-1", Name: "Phone", Mode: "numeric", TokenHash: quickUnlockTokenHash("raw-token"), CreatedAt: createdAt}
	if err := server.saveQuickUnlockDevice(device); err != nil {
		t.Fatal(err)
	}
	if err := server.verifyQuickUnlockDevice(device.ID, "raw-token"); err != nil {
		t.Fatal(err)
	}
	if got := server.readQuickUnlockStore(context.Background()); len(got.Devices) != 1 || got.Devices[0].LastUsedAt == nil {
		t.Fatalf("quick unlock verify did not persist usage: %#v", got)
	}
	if err := server.revokeQuickUnlockDevice(device.ID); err != nil {
		t.Fatal(err)
	}
	if err := server.verifyQuickUnlockDevice(device.ID, "raw-token"); err == nil {
		t.Fatal("verify succeeded after revoke")
	}
}

type recordingQuickUnlockRepository struct {
	devices      []quickUnlockDevice
	saved        quickUnlockDevice
	verifiedID   string
	verifiedHash string
	verifiedAt   time.Time
	revokedID    string
	revokedAt    time.Time
}

func (r *recordingQuickUnlockRepository) List(context.Context) ([]quickUnlockDevice, error) {
	return r.devices, nil
}

func (r *recordingQuickUnlockRepository) Save(_ context.Context, device quickUnlockDevice) error {
	r.saved = device
	return nil
}

func (r *recordingQuickUnlockRepository) Verify(_ context.Context, id, tokenHash string, usedAt time.Time) error {
	if id == "" || tokenHash == "" {
		return errors.New("quick unlock verification input is required")
	}
	r.verifiedID, r.verifiedHash, r.verifiedAt = id, tokenHash, usedAt
	return nil
}

func (r *recordingQuickUnlockRepository) Revoke(_ context.Context, id string, revokedAt time.Time) error {
	r.revokedID, r.revokedAt = id, revokedAt
	return nil
}

func (r *recordingQuickUnlockRepository) Backfill(context.Context, []quickUnlockDevice) error {
	return nil
}

var _ quickUnlockRepository = (*recordingQuickUnlockRepository)(nil)
