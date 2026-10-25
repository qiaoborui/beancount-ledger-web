package app

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

// After a successful registration the cache holds a snapshot instead of the
// stream, so the next start skips stream parsing.
func TestRegistrationCachesSnapshot(t *testing.T) {
	input := localTestRequest(t)
	handle := registerHandleFixture(t, input)
	localModels.Lock()
	registered := committedLocalModel(handle)
	localModels.Unlock()
	if registered == nil {
		t.Fatal("registered model missing")
	}
	directory := filepath.Join(registered.cache.cfg.RuntimeDir, "canonical-stream")
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatalf("read cache dir: %v", err)
	}
	snapshots, streams := 0, 0
	for _, entry := range entries {
		name := entry.Name()
		if _, ok := localCanonicalStem(name); !ok {
			continue
		}
		if filepath.Ext(name) == "."+snapshotFormatTag {
			snapshots++
		} else if filepath.Ext(name) == ".records" {
			streams++
		}
	}
	if snapshots == 0 {
		t.Fatalf("registration did not cache a snapshot: %v", entries)
	}
	if streams != 0 {
		t.Fatalf("stream should be replaced by the snapshot, found %d", streams)
	}
}

// A snapshot written by registration must load back to the same model and pass
// the same source-version check, so the fast path cannot drift from the stream.
func TestCachedSnapshotLoadsBackToSameModel(t *testing.T) {
	input := localTestRequest(t)
	handle := registerHandleFixture(t, input)
	localModels.Lock()
	registered := committedLocalModel(handle)
	localModels.Unlock()
	if registered == nil {
		t.Fatal("registered model missing")
	}
	directory := filepath.Join(registered.cache.cfg.RuntimeDir, "canonical-stream")
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatalf("read cache dir: %v", err)
	}
	var snapshotPath string
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) == "."+snapshotFormatTag {
			snapshotPath = filepath.Join(directory, entry.Name())
			break
		}
	}
	if snapshotPath == "" {
		t.Fatal("no snapshot was written")
	}
	file, err := os.Open(snapshotPath)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := loadCanonicalModel(file, info, registered.version)
	if err != nil {
		t.Fatalf("load snapshot: %v", err)
	}
	if len(loaded.Entries) != len(registered.model.Entries) {
		t.Fatalf("entry count %d, want %d", len(loaded.Entries), len(registered.model.Entries))
	}
}

// A snapshot from another source tree is refused rather than silently used.
func TestLoadRejectsSnapshotForAnotherVersion(t *testing.T) {
	model := streamModel(t, snapshotFixtureStream)
	other := sha256.Sum256([]byte("other-tree"))
	encoded, err := EncodeCanonicalSnapshot(model, other, 1, "e", "r", 1)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	path := filepath.Join(t.TempDir(), "snapshot")
	if err := os.WriteFile(path, encoded, 0o600); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	info, _ := file.Stat()
	wrong := hex.EncodeToString(sha256.New().Sum(nil))
	if _, err := loadCanonicalModel(file, info, wrong); err == nil {
		t.Fatal("snapshot for another version was accepted")
	}
}

// A stream file still loads through the same entry point.
func TestLoadAcceptsPlainStream(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stream.records")
	if err := os.WriteFile(path, []byte(canonicalStreamFixture(t, 2)), 0o600); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	info, _ := file.Stat()
	model, err := loadCanonicalModel(file, info, "")
	if err != nil {
		t.Fatalf("load stream: %v", err)
	}
	if len(model.Entries) == 0 {
		t.Fatal("stream produced no entries")
	}
}
