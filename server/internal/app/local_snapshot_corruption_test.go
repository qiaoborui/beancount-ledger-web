package app

import (
	"crypto/sha256"
	"testing"
)

func corruptibleSnapshot(t *testing.T) []byte {
	t.Helper()
	model := streamModel(t, snapshotFixtureStream)
	encoded, err := EncodeCanonicalSnapshot(model, sha256.Sum256([]byte("source")), 1234,
		"beancount@3.2.3", "runtime-1", 99)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	return encoded
}

// A snapshot is a cache, so every structural violation must be rejected instead
// of yielding a partial model. The caller then re-reads the stream.
func TestSnapshotRejectsCorruption(t *testing.T) {
	good := corruptibleSnapshot(t)
	if _, err := DecodeCanonicalSnapshot(good); err != nil {
		t.Fatalf("baseline snapshot must decode: %v", err)
	}
	clone := func() []byte {
		out := make([]byte, len(good))
		copy(out, good)
		return out
	}
	cases := []struct {
		name   string
		mutate func([]byte) []byte
	}{
		{"truncated tail", func(b []byte) []byte { return b[:len(b)-1] }},
		{"truncated body", func(b []byte) []byte { return b[:len(b)/2] }},
		{"empty", func(b []byte) []byte { return nil }},
		{"bad magic", func(b []byte) []byte { c := clone(); c[0] = 'X'; return c }},
		{"unknown format", func(b []byte) []byte { c := clone(); c[8] = 9; return c }},
		{"unknown flags", func(b []byte) []byte { c := clone(); c[10] = 1; return c }},
		{"digest flipped", func(b []byte) []byte { c := clone(); c[len(c)-1] ^= 0xff; return c }},
		{"payload flipped", func(b []byte) []byte { c := clone(); c[len(c)/2] ^= 0xff; return c }},
		{"trailing garbage", func(b []byte) []byte { return append(append([]byte{}, b...), 0) }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			if _, err := DecodeCanonicalSnapshot(test.mutate(clone())); err == nil {
				t.Fatalf("%s was accepted", test.name)
			}
		})
	}
}

// A snapshot claiming a different source tree must never be used for this one.
func TestSnapshotVersionMismatchIsRejected(t *testing.T) {
	model := streamModel(t, snapshotFixtureStream)
	other := sha256.Sum256([]byte("another-tree"))
	encoded, err := EncodeCanonicalSnapshot(model, other, 1, "e", "r", 1)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	decoded, err := DecodeCanonicalSnapshot(encoded)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	current := sha256.Sum256([]byte("this-tree"))
	if decoded.sourceVersion == current {
		t.Fatal("fixture versions must differ for this test to mean anything")
	}
}

// The MAGIC discriminator decides which decoder runs; a stream must not be
// mistaken for a snapshot.
func TestSnapshotMagicDiscriminatesStreams(t *testing.T) {
	if IsCanonicalSnapshot([]byte(`{"type":"header","version":1}`)) {
		t.Fatal("a JSON stream was treated as a snapshot")
	}
	if !IsCanonicalSnapshot(corruptibleSnapshot(t)) {
		t.Fatal("a snapshot was not recognized")
	}
	if IsCanonicalSnapshot([]byte("BLWSNA")) {
		t.Fatal("a short buffer was treated as a snapshot")
	}
}

// A newer format must be reported as unsupported so the caller can fall back,
// distinct from a damaged file.
func TestSnapshotUnsupportedFormatIsDistinct(t *testing.T) {
	data := corruptibleSnapshot(t)
	data[9] = snapshotFormat + 1
	_, err := DecodeCanonicalSnapshot(data)
	if err == nil {
		t.Fatal("future format was accepted")
	}
	if err != errSnapshotUnsupported {
		t.Fatalf("future format error = %v, want errSnapshotUnsupported", err)
	}
}
