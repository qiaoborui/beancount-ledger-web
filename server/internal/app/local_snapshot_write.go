package app

// Writing a binary snapshot back to the cache after a successful registration.
//
// This is an optimization on the read path, so every failure here is ignored:
// the model is already registered and usable, and the next registration simply
// re-reads the stream. Nothing about correctness may depend on this succeeding.

import (
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// writeCanonicalSnapshot replaces the registered stream file with an equivalent
// snapshot next to it and reports whether it did so.
//
// streamName is the file the model was read from. When it is already a snapshot
// this is a no-op. The stream is removed only after the snapshot is durable, so
// an interrupted write leaves the stream in place.
func writeCanonicalSnapshot(cfg Config, model *LocalCanonicalModel, streamName, version,
	exporterID, appRuntimeFP string) (bool, error) {
	if model == nil || cfg.RuntimeDir == "" {
		return false, nil
	}
	stem, ok := localCanonicalStem(streamName)
	if !ok || strings.HasSuffix(streamName, "."+snapshotFormatTag) {
		return false, nil
	}
	raw, err := hex.DecodeString(version)
	if err != nil || len(raw) != 32 {
		return false, nil
	}
	var sourceVersion [32]byte
	copy(sourceVersion[:], raw)

	encoded, err := EncodeCanonicalSnapshot(model, sourceVersion, 0, exporterID, appRuntimeFP, 0)
	if err != nil {
		return false, nil
	}
	directory := filepath.Join(cfg.RuntimeDir, "canonical-stream")
	if err := validateLocalDirectory(directory, false); err != nil {
		return false, nil
	}
	target := filepath.Join(directory, stem+"."+snapshotFormatTag)
	if err := writeLocalFileAtomic(directory, target, encoded); err != nil {
		return false, nil
	}
	// The snapshot supersedes the stream for this source version; keeping both
	// would double the cache footprint for no benefit. Removal is best effort.
	streamPath := filepath.Join(directory, streamName)
	if streamPath != target {
		_ = os.Remove(streamPath)
	}
	return true, nil
}

// writeLocalFileAtomic creates the file through a temporary sibling and renames
// it into place, so a reader never observes a partially written snapshot.
func writeLocalFileAtomic(directory, target string, payload []byte) error {
	temp, err := os.CreateTemp(directory, ".snapshot-")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer func() {
		if name != "" {
			_ = os.Remove(name)
		}
	}()
	if _, err := temp.Write(payload); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(name, 0o600); err != nil {
		return err
	}
	if err := os.Rename(name, target); err != nil {
		return err
	}
	name = ""
	return nil
}

// snapshotExporterID identifies what produced a snapshot, so a future format
// change can tell old caches apart in diagnostics.
func snapshotExporterID() string {
	return fmt.Sprintf("beancount-ledger-web/%s", snapshotFormatTag)
}
