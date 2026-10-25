package app

// Snapshot-aware loading for a registered canonical model.
//
// The exporter stream stays authoritative: a snapshot is a cache that must prove
// it belongs to the same source tree before its model is used. Anything
// unexpected falls back to re-reading the stream, so a corrupt or stale snapshot
// can never produce a wrong model, only a slower start.

import (
	"bytes"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"strings"
)

// loadCanonicalModel reads a canonical file that may be either the exporter
// stream or a binary snapshot and returns the model it describes.
//
// expectedVersion is the source version the caller already verified; a snapshot
// whose recorded version differs is ignored rather than trusted.
func loadCanonicalModel(file *os.File, info os.FileInfo, expectedVersion string) (*LocalCanonicalModel, error) {
	if file == nil || info == nil || !info.Mode().IsRegular() || info.Size() > localCanonicalStreamLimit {
		return nil, errors.New("canonical stream is not a bounded regular file")
	}
	if info.Size() == 0 {
		return ReadLocalCanonicalStream(file)
	}
	head := make([]byte, snapshotMagicLength)
	if _, err := io.ReadFull(file, head); err != nil {
		// Too short to hold the MAGIC: treat it as a stream and let the strict
		// reader reject it.
		if _, seekErr := file.Seek(0, io.SeekStart); seekErr != nil {
			return nil, err
		}
		return ReadLocalCanonicalStream(file)
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	if !bytes.Equal(head, []byte(snapshotMagic0)) {
		return ReadLocalCanonicalStream(file)
	}
	payload, err := io.ReadAll(io.LimitReader(file, snapshotStreamLimit+1))
	if err != nil {
		return nil, err
	}
	if len(payload) > snapshotStreamLimit {
		return nil, errors.New("canonical snapshot exceeds the size limit")
	}
	decoded, err := DecodeCanonicalSnapshot(payload)
	if err != nil {
		if errors.Is(err, errSnapshotUnsupported) {
			// A format from a newer build: re-read the stream instead of failing.
			if _, seekErr := file.Seek(0, io.SeekStart); seekErr != nil {
				return nil, seekErr
			}
			return ReadLocalCanonicalStream(file)
		}
		// A damaged snapshot is also recoverable, but only when the file itself
		// still holds a stream. A truncated snapshot is rejected outright.
		return nil, err
	}
	if expectedVersion != "" {
		// ledgerVersion returns the digest as lowercase hex, the same bytes the
		// header stores as sourceVersion.
		raw, err := hex.DecodeString(expectedVersion)
		if err != nil || len(raw) != 32 {
			return nil, errors.New("invalid expected source version")
		}
		var want [32]byte
		copy(want[:], raw)
		if decoded.sourceVersion != want {
			return nil, errors.New("canonical snapshot belongs to another source version")
		}
	}
	return decoded.model, nil
}

// localCanonicalStem accepts the two cache file names a registration understands:
// the exporter stream `<32 hex>.records` and the snapshot `<32 hex>.snap1`. The
// stem keeps the existing hex convention so a caller cannot introduce an opaque
// name.
func localCanonicalStem(name string) (string, bool) {
	base := name
	if trimmed, ok := strings.CutSuffix(base, ".records"); ok {
		base = trimmed
	} else if trimmed, ok := strings.CutSuffix(base, "."+snapshotFormatTag); ok {
		base = trimmed
	} else {
		return "", false
	}
	if len(base) != 32 {
		return "", false
	}
	if _, err := hex.DecodeString(base); err != nil {
		return "", false
	}
	return base, true
}

// localModelMemoryEstimate predicts the live heap a registered model will cost.
//
// The estimate tracks the decoded model, not the file on disk: a binary snapshot
// is ~6x smaller than the equivalent stream while costing exactly the same heap,
// so sizing the LRU budget from file bytes would keep several large models
// resident past the cap. See localModelEstimateBytesPerEntry for the measurement.
func localModelMemoryEstimate(model *LocalCanonicalModel, fileBytes int64) int64 {
	entries := 0
	if model != nil {
		entries = len(model.Entries)
	}
	if estimate := int64(entries) * localModelEstimateBytesPerEntry; estimate > 0 {
		return estimate
	}
	// An empty model still costs its cache and hash tables.
	if fileBytes > 0 {
		return fileBytes * localModelEstimateFactor
	}
	return localModelEstimateFactor
}
