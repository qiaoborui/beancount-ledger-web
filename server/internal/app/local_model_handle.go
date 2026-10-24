package app

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"runtime/debug"
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
	// A decoded model plus its LedgerCache costs several times the stream bytes.
	// Measured on the repository's 100,591-entry synthetic ledger (47MB canonical
	// stream): 237-365MB of live Go heap, i.e. 5-8x. Six is the conservative
	// midpoint until real-device numbers calibrate it. The budget below stays the
	// cap: at this factor one such model costs ~282MB of the 384MiB budget, so
	// large ledgers keep only the current model resident instead of silently
	// assuming a third of the real cost.
	localModelEstimateFactor = 6
)

var localModelBudget int64 = 384 << 20

// The Go heap shares the iOS process's single jetsam budget with the Python
// loader, the canonical stream buffers and Swift, so it may target at most half
// of the memory os_proc_available_memory reports, within bounds:
//
//   - Floor: the measured 100k ledger keeps 237-365MB of live heap. A soft limit
//     below that peak makes the runtime collect continuously around the working
//     set, so never target less than 512MiB (~1.4x the measured peak). A device
//     that reports less than twice the floor is already close to its jetsam
//     limit; the floor still bounds the default 2x growth without adding thrash.
//   - Ceiling: the 200k projection is roughly twice the 100k heap, and a single
//     app heap beyond 1GiB is a jetsam risk on every supported phone, so cap
//     there even when the device reports more memory.
const (
	localMemoryLimitFloor   = 512 << 20
	localMemoryLimitCeiling = 1 << 30
)

// localMemoryLimitFor maps an available-memory reading to the Go soft heap
// limit. Zero means the reading is unknown and the runtime default is kept.
func localMemoryLimitFor(availableBytes int64) int64 {
	if availableBytes <= 0 {
		return 0
	}
	limit := availableBytes / 2
	if limit < localMemoryLimitFloor {
		return localMemoryLimitFloor
	}
	if limit > localMemoryLimitCeiling {
		return localMemoryLimitCeiling
	}
	return limit
}

// ConfigureLocalMemoryLimit applies the soft Go heap limit (GOMEMLIMIT) derived
// from the process's available memory. The mobile shell calls it once at launch,
// before the first model registration; an unknown reading (zero) keeps the
// runtime default. It returns the applied limit in bytes, or zero when the
// default was kept. A soft limit targets the heap rather than capping it, so it
// cannot turn a transient allocation into a failed request.
func ConfigureLocalMemoryLimit(availableBytes int64) int64 {
	limit := localMemoryLimitFor(availableBytes)
	if limit > 0 {
		debug.SetMemoryLimit(limit)
	}
	return limit
}

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

// ReleaseIdleLocalModels drops every committed model except the current ledger
// so an iOS memory warning can reclaim idle ledgers before the process is killed.
// The current ledger is keepHandle when it is still registered; otherwise the
// most recently resolved model is kept, because a stale or missing shell handle
// must not drop the ledger the visible view is reading. Requests already in
// flight own their pointers, so dropping a registry reference cannot free a
// model underneath a reader. Stages are left alone: they belong to the request
// publishing them. It returns how many models were dropped.
func ReleaseIdleLocalModels(keepHandle string) int {
	localModels.Lock()
	defer localModels.Unlock()
	keep := -1
	for index, model := range localModels.committed {
		if model.handle == keepHandle {
			keep = index
			break
		}
	}
	if keep < 0 && len(localModels.committed) > 0 {
		keep = 0
	}
	if keep < 0 {
		released := len(localModels.committed)
		clear(localModels.committed)
		localModels.committed = nil
		return released
	}
	released := len(localModels.committed) - 1
	kept := localModels.committed[keep]
	clear(localModels.committed)
	localModels.committed = []*localRegisteredModel{kept}
	return released
}
