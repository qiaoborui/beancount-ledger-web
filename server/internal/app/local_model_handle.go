package app

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

var ErrLocalModelUnavailable = errors.New("local model unavailable; reload required")

type localRegisteredModel struct {
	handle     string
	root       string
	entrypoint string
	version    string
	model      *LocalCanonicalModel
	cache      *LedgerCache
	staging    bool
}

// Bounded registry, not unbounded per-ledger retention. In-flight requests own
// their pointers; evicting a handle cannot free a model underneath a reader.
var localModels struct {
	sync.Mutex
	committed *localRegisteredModel
	staged    *localRegisteredModel
}

func LocalModelSourceVersion(input LocalRequest) (string, error) {
	cfg, err := localConfig(input)
	if err != nil {
		return "", err
	}
	version, err := ledgerVersion(cfg)
	return version.Version, err
}

// Registration requires a source token obtained before canonical export and
// rechecks it after ingestion. Caller owns an immutable pinned source/stage.
func RegisterLocalModel(input LocalRequest, streamName, expectedVersion string) (string, error) {
	if input.Canonical != nil || input.ModelHandle != "" || expectedVersion == "" {
		return "", errors.New("invalid model registration")
	}
	cfg, err := localConfig(input)
	if err != nil {
		return "", err
	}
	if (filepath.Base(filepath.Dir(filepath.Dir(cfg.LedgerRoot))) == "staging") != input.Staging {
		return "", errors.New("model scope must match workspace generation/stage")
	}
	if len(streamName) != 40 || !strings.HasSuffix(streamName, ".records") {
		return "", errors.New("invalid canonical stream name")
	}
	if _, err := hex.DecodeString(strings.TrimSuffix(streamName, ".records")); err != nil {
		return "", errors.New("invalid canonical stream name")
	}
	directory := filepath.Join(cfg.RuntimeDir, "canonical-stream")
	if err := validateLocalDirectory(directory, false); err != nil {
		return "", err
	}
	path := filepath.Join(directory, streamName)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Size() > localCanonicalStreamLimit {
		return "", errors.New("canonical stream is not a bounded regular file")
	}
	before, err := ledgerVersion(cfg)
	if err != nil {
		return "", err
	}
	if before.Version != expectedVersion {
		return "", errors.New("source changed before canonical registration")
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return "", errors.New("canonical stream identity changed")
	}
	model, err := ReadLocalCanonicalStream(file)
	if err != nil {
		return "", err
	}
	after, err := ledgerVersion(cfg)
	if err != nil {
		return "", err
	}
	if after.Version != expectedVersion {
		return "", errors.New("source changed during canonical registration")
	}
	token := make([]byte, 24)
	if _, err := rand.Read(token); err != nil {
		return "", err
	}
	handle := hex.EncodeToString(token)
	cfg.localCanonical = model
	// ReadLocalCanonicalStream created this model exclusively for this cache.
	// Unlike caller-supplied legacy JSON, its arrays may become the primary
	// normalized semantic entries without retaining another rich copy.
	cfg.localCanonicalOwned = true
	cfg.localCanonicalVersion = expectedVersion
	registered := &localRegisteredModel{handle: handle, root: cfg.LedgerRoot, entrypoint: cfg.localEntrypoint, version: expectedVersion, model: model, cache: NewLedgerCache(cfg), staging: input.Staging}
	localModels.Lock()
	defer localModels.Unlock()
	if input.Staging {
		localModels.staged = registered
	} else {
		localModels.committed = registered
	}
	return handle, nil
}

func resolveLocalModel(cfg Config, handle string, staging bool) (Config, error) {
	localModels.Lock()
	model := localModels.committed
	if staging {
		model = localModels.staged
	}
	// A stage-scoped handle is one-shot: no subsequent mutation may reuse it.
	if staging && model != nil && model.handle == handle {
		localModels.staged = nil
	}
	localModels.Unlock()
	if model == nil || model.handle != handle || model.root != cfg.LedgerRoot || model.entrypoint != cfg.localEntrypoint || model.staging != staging {
		return cfg, ErrLocalModelUnavailable
	}
	version, err := ledgerVersion(cfg)
	if err != nil {
		return cfg, err
	}
	if version.Version != model.version {
		ReleaseLocalModel(handle)
		return cfg, ErrLocalModelUnavailable
	}
	cfg.localCanonical = model.model
	cfg.localRegisteredCache = model.cache
	return cfg, nil
}

func ReleaseLocalModel(handle string) {
	localModels.Lock()
	defer localModels.Unlock()
	if localModels.committed != nil && localModels.committed.handle == handle {
		localModels.committed = nil
	}
	if localModels.staged != nil && localModels.staged.handle == handle {
		localModels.staged = nil
	}
}
