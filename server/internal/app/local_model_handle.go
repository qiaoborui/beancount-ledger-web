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

// localModelLedgerRoot maps both managed layouts to the ledger that owns them:
// <ledger>/generations/<id>/workspace and <ledger>/staging/<id>/workspace both
// belong to <ledger>. Promotion/adoption cross from one layout to the other, so
// they must agree on the ledger even though the roots differ.
func localModelLedgerRoot(root string) string {
	if container := filepath.Dir(filepath.Dir(root)); filepath.Base(container) == "generations" ||
		filepath.Base(container) == "staging" {
		return filepath.Dir(container)
	}
	return root
}

func newLocalModelHandle() (string, error) {
	token := make([]byte, 24)
	if _, err := rand.Read(token); err != nil {
		return "", err
	}
	return hex.EncodeToString(token), nil
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
	handle, err := newLocalModelHandle()
	if err != nil {
		return "", err
	}
	// ReadLocalCanonicalStream created this model exclusively for this cache.
	// Unlike caller-supplied legacy JSON, its arrays may become the primary
	// normalized semantic entries without retaining another rich copy.
	registered := bindLocalRegisteredModel(cfg, model, handle, expectedVersion, stamps, after,
		input.Staging, opened.Size()*localModelEstimateFactor)
	localModels.Lock()
	defer localModels.Unlock()
	if input.Staging {
		localModels.staged = registered
	} else {
		insertCommittedLocalModel(registered)
	}
	return handle, nil
}

// bindLocalRegisteredModel builds the per-root cache and registry entry for a
// canonical model that is already known to match `version` at cfg.LedgerRoot.
// The model must be exclusively owned by the returned registration.
func bindLocalRegisteredModel(cfg Config, model *LocalCanonicalModel, handle, version string,
	stamps *localSourceStamps, stampVersion LedgerVersion, staging bool, estimate int64) *localRegisteredModel {
	cfg.localCanonical = model
	cfg.localCanonicalOwned = true
	cfg.localCanonicalVersion = version
	cache := NewLedgerCache(cfg)
	cache.stamps, cache.stampVersion = stamps, stampVersion
	return &localRegisteredModel{handle: handle, root: cfg.LedgerRoot, entrypoint: cfg.localEntrypoint, version: version,
		model: model, cache: cache, stamps: stamps, staging: staging, estimate: estimate}
}

// PromoteLocalModel turns a retained stage registration into the committed
// model for a just-published generation. Stage and generation must hold
// byte-identical sources (the same sourceVersion); generation layout, ledger,
// entrypoint and handle lifetime are rechecked here, and every mismatch fails
// closed so the caller can fall back to a full registration.
func PromoteLocalModel(input LocalRequest, handle, expectedVersion string) (string, error) {
	if input.Canonical != nil || input.ModelHandle != "" || handle == "" || expectedVersion == "" {
		return "", errors.New("invalid model promotion")
	}
	cfg, err := localConfig(input)
	if err != nil {
		return "", err
	}
	if input.Staging || filepath.Base(filepath.Dir(filepath.Dir(cfg.LedgerRoot))) != "generations" {
		return "", errors.New("model promotion target must be a committed generation")
	}
	stamps := &localSourceStamps{}
	version, err := ledgerVersionStamped(cfg, stamps)
	if err != nil {
		return "", err
	}
	if version.Version != expectedVersion {
		return "", errors.New("promoted model source does not match the generation")
	}
	localModels.Lock()
	defer localModels.Unlock()
	stage := localModels.staged
	if stage == nil || stage.handle != handle {
		return "", errors.New("stage model is no longer registered")
	}
	if !stage.staging || stage.version != expectedVersion || stage.entrypoint != cfg.localEntrypoint ||
		stage.root == cfg.LedgerRoot || localModelLedgerRoot(stage.root) != localModelLedgerRoot(cfg.LedgerRoot) {
		return "", errors.New("stage model does not belong to this generation")
	}
	// The version above is a full content hash of the target; the stamps prove
	// the same bytes are still in place unless glob includes make that
	// unprovable, in which case registration relies on the hash alone.
	if !stamps.unusable && !stamps.matches() {
		return "", errors.New("generation source changed during promotion")
	}
	if err := rebindLocalCanonicalModelRoot(stage.model, stage.root, cfg.LedgerRoot); err != nil {
		return "", err
	}
	promotedHandle, err := newLocalModelHandle()
	if err != nil {
		return "", err
	}
	promoted := bindLocalRegisteredModel(cfg, stage.model, promotedHandle, expectedVersion, stamps, version,
		false, stage.estimate)
	localModels.staged = nil
	insertCommittedLocalModel(promoted)
	return promotedHandle, nil
}

// AdoptLocalModel creates the one-shot stage registration for a staging request
// from an equivalent committed model. Both roots must belong to the same ledger
// and hold byte-identical sources, and the committed model must still be
// registered. The returned registration owns a fresh cache and its own copy of
// the canonical entry and posting arrays, so no mutable state is shared with the
// committed model; releasing or mutating it cannot affect that model.
func AdoptLocalModel(input LocalRequest, sourceHandle, expectedVersion string) (string, error) {
	if input.Canonical != nil || input.ModelHandle != "" || sourceHandle == "" || expectedVersion == "" {
		return "", errors.New("invalid model adoption")
	}
	if !input.Staging {
		return "", errors.New("model adoption requires a staging workspace")
	}
	cfg, err := localConfig(input)
	if err != nil {
		return "", err
	}
	if filepath.Base(filepath.Dir(filepath.Dir(cfg.LedgerRoot))) != "staging" {
		return "", errors.New("model adoption target must be a staging workspace")
	}
	stamps := &localSourceStamps{}
	version, err := ledgerVersionStamped(cfg, stamps)
	if err != nil {
		return "", err
	}
	if version.Version != expectedVersion {
		return "", errors.New("staging source does not match the committed model")
	}
	localModels.Lock()
	source := committedLocalModel(sourceHandle)
	usable := source != nil && !source.staging && source.version == expectedVersion &&
		source.entrypoint == cfg.localEntrypoint &&
		localModelLedgerRoot(source.root) == localModelLedgerRoot(cfg.LedgerRoot)
	localModels.Unlock()
	if !usable {
		return "", errors.New("committed model does not match the staging workspace")
	}
	// Snapshot builds normalize the committed model's owned entry arrays under
	// its cache mutex. Copy under that mutex so a concurrent first read can never
	// observe a half-normalized model.
	source.cache.mu.Lock()
	clone, err := cloneLocalCanonicalModelForWorkspace(source.model)
	source.cache.mu.Unlock()
	if err != nil {
		return "", err
	}
	handle, err := newLocalModelHandle()
	if err != nil {
		return "", err
	}
	localModels.Lock()
	defer localModels.Unlock()
	// Recheck the source after the copy: it must still be the registered model.
	if current := committedLocalModel(sourceHandle); current != source || current.version != expectedVersion {
		return "", errors.New("committed model changed during adoption")
	}
	if !stamps.unusable && !stamps.matches() {
		return "", errors.New("staging source changed during adoption")
	}
	adopted := bindLocalRegisteredModel(cfg, clone, handle, expectedVersion, stamps, version, true, source.estimate)
	localModels.staged = adopted
	return handle, nil
}

// cloneLocalCanonicalModelForWorkspace copies an owned canonical model so it can
// be normalized against another workspace root. Entry structs, posting arrays
// and source path strings are copied; the immutable option/commodity catalogs
// and metadata values are shared. Callers must hold the source cache mutex.
func cloneLocalCanonicalModelForWorkspace(model *LocalCanonicalModel) (*LocalCanonicalModel, error) {
	if model == nil {
		return nil, errors.New("canonical model is missing")
	}
	root := model.normalizedRoot
	entries := make([]BeanEntry, len(model.Entries))
	for index, entry := range model.Entries {
		clone := entry
		file := entry.File
		switch {
		case file == "":
		case root == "" && filepath.IsAbs(file):
			return nil, errors.New("canonical ledger source must be relative")
		case root != "":
			relative, err := filepath.Rel(root, file)
			if err != nil || filepath.IsAbs(relative) || relative == ".." ||
				strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
				return nil, errors.New("canonical ledger source escapes its workspace")
			}
			file = relative
		}
		clone.File = filepath.ToSlash(file)
		if len(entry.Postings) > 0 {
			clone.Postings = append([]parsedPosting(nil), entry.Postings...)
		}
		entries[index] = clone
	}
	return &LocalCanonicalModel{Version: model.Version, Entries: entries,
		Options: model.Options, Commodities: model.Commodities}, nil
}

// rebindLocalCanonicalModelRoot rewrites a normalized model's absolute source
// paths from the workspace it was normalized for onto a workspace holding the
// same bytes. A model that was never normalized keeps relative paths and needs
// no rewrite; anything unexpected fails closed.
func rebindLocalCanonicalModelRoot(model *LocalCanonicalModel, oldRoot, newRoot string) error {
	if model == nil {
		return errors.New("canonical model is missing")
	}
	if model.normalizedRoot == "" {
		for _, entry := range model.Entries {
			if entry.File != "" && filepath.IsAbs(entry.File) {
				return errors.New("canonical ledger source must be relative")
			}
		}
		return nil
	}
	if model.normalizedRoot != oldRoot {
		return errors.New("canonical model belongs to another workspace")
	}
	prefix := oldRoot + string(filepath.Separator)
	for index := range model.Entries {
		file := model.Entries[index].File
		if file == "" {
			continue
		}
		if !filepath.IsAbs(file) {
			return errors.New("canonical ledger source must be absolute once normalized")
		}
		if !strings.HasPrefix(file, prefix) {
			return errors.New("canonical ledger source escapes its workspace")
		}
		model.Entries[index].File = filepath.Join(newRoot, strings.TrimPrefix(file, prefix))
	}
	model.normalizedRoot = newRoot
	return nil
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
