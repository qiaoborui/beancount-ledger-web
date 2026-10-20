package app

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"slices"
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
	stamps     *localSourceStamps
	staging    bool
	// Estimated resident cost, derived from the canonical stream size.
	estimate int64
}

// Committed models are kept in a small LRU so switching between ledgers in
// the app does not force a full canonical re-register each time. It is bounded
// by count and by an estimated memory budget; the most recent model is always
// kept even when it alone exceeds the budget. Stages stay single and one-shot.
// In-flight requests own their pointers; evicting a handle only drops the
// registry's reference and cannot free a model underneath a reader.
const (
	localModelLRULimit = 4
	// A decoded model plus its LedgerCache costs a few times the stream bytes.
	localModelEstimateFactor = 3
)

var localModelBudget int64 = 384 << 20

var localModels struct {
	sync.Mutex
	committed []*localRegisteredModel // most recently used first
	staged    *localRegisteredModel
}

// localModelLedgerKey identifies one ledger across its immutable generations
// (<ledger>/generations/<id>/workspace), so registering a newer generation
// replaces the older one instead of keeping both resident. Roots outside that
// layout are keyed by themselves.
func localModelLedgerKey(root string) string {
	if generations := filepath.Dir(filepath.Dir(root)); filepath.Base(generations) == "generations" {
		return generations
	}
	return root
}

// Caller holds localModels.
func insertCommittedLocalModel(registered *localRegisteredModel) {
	ledger := localModelLedgerKey(registered.root)
	kept := []*localRegisteredModel{registered}
	total := registered.estimate
	for _, model := range localModels.committed {
		if model.entrypoint == registered.entrypoint && localModelLedgerKey(model.root) == ledger {
			continue
		}
		if len(kept) >= localModelLRULimit || total+model.estimate > localModelBudget {
			continue
		}
		kept = append(kept, model)
		total += model.estimate
	}
	clear(localModels.committed)
	localModels.committed = kept
}

// Caller holds localModels.
func committedLocalModel(handle string) *localRegisteredModel {
	for _, model := range localModels.committed {
		if model.handle == handle {
			return model
		}
	}
	return nil
}

// touchLocalModel marks a successfully resolved model most recently used. A
// model evicted or replaced meanwhile is not resurrected.
func touchLocalModel(model *localRegisteredModel) {
	localModels.Lock()
	defer localModels.Unlock()
	if i := slices.Index(localModels.committed, model); i > 0 {
		copy(localModels.committed[1:i+1], localModels.committed[:i])
		localModels.committed[0] = model
	}
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
	stamps := &localSourceStamps{}
	after, err := ledgerVersionStamped(cfg, stamps)
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
	cache := NewLedgerCache(cfg)
	cache.stamps, cache.stampVersion = stamps, after
	registered := &localRegisteredModel{handle: handle, root: cfg.LedgerRoot, entrypoint: cfg.localEntrypoint, version: expectedVersion,
		model: model, cache: cache, stamps: stamps, staging: input.Staging, estimate: opened.Size() * localModelEstimateFactor}
	localModels.Lock()
	defer localModels.Unlock()
	if input.Staging {
		localModels.staged = registered
	} else {
		insertCommittedLocalModel(registered)
	}
	return handle, nil
}

func resolveLocalModel(cfg Config, handle string, staging bool) (Config, error) {
	localModels.Lock()
	var model *localRegisteredModel
	if staging {
		model = localModels.staged
		// A stage-scoped handle is one-shot: no subsequent mutation may reuse it.
		if model != nil && model.handle == handle {
			localModels.staged = nil
		}
	} else {
		model = committedLocalModel(handle)
	}
	localModels.Unlock()
	if model == nil || model.handle != handle || model.root != cfg.LedgerRoot || model.entrypoint != cfg.localEntrypoint || model.staging != staging {
		return cfg, ErrLocalModelUnavailable
	}
	// Unchanged stat identities prove the immutable source is still the one
	// registered; anything else falls back to the full content-hash check.
	if !model.stamps.matches() {
		version, err := ledgerVersion(cfg)
		if err != nil {
			return cfg, err
		}
		if version.Version != model.version {
			ReleaseLocalModel(handle)
			return cfg, ErrLocalModelUnavailable
		}
	}
	if !staging {
		touchLocalModel(model)
	}
	cfg.localCanonical = model.model
	cfg.localRegisteredCache = model.cache
	return cfg, nil
}

func ReleaseLocalModel(handle string) {
	localModels.Lock()
	defer localModels.Unlock()
	localModels.committed = slices.DeleteFunc(localModels.committed, func(model *localRegisteredModel) bool {
		return model.handle == handle
	})
	if localModels.staged != nil && localModels.staged.handle == handle {
		localModels.staged = nil
	}
}
