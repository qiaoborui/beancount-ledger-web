package app

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"testing"
)

func registerHandleFixture(t *testing.T, input LocalRequest) string {
	t.Helper()
	version, err := LocalModelSourceVersion(input)
	if err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(input.WorkspaceRoot))), "runtime", "canonical-stream")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	name := strings.Repeat("a", 32) + ".records"
	if err := os.WriteFile(filepath.Join(directory, name), canonicalStreamFixture(t, 2), 0600); err != nil {
		t.Fatal(err)
	}
	handle, err := RegisterLocalModel(input, name, version)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ReleaseLocalModel(handle) })
	return handle
}

func TestLocalModelHandleScopeFreshnessEvictionAndOneShotStage(t *testing.T) {
	input := localTestRequest(t)
	first := registerHandleFixture(t, input)
	cfg, err := localConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := resolveLocalModel(cfg, first, false)
	if err != nil || resolved.localCanonical == nil || resolved.localRegisteredCache == nil {
		t.Fatal("handle did not resolve", err)
	}
	other := localTestRequest(t)
	otherCfg, err := localConfig(other)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = resolveLocalModel(otherCfg, first, false); !errors.Is(err, ErrLocalModelUnavailable) {
		t.Fatal("cross-workspace handle accepted")
	}
	second := registerHandleFixture(t, input)
	if _, err = resolveLocalModel(cfg, first, false); !errors.Is(err, ErrLocalModelUnavailable) {
		t.Fatal("evicted handle accepted")
	}
	main := filepath.Join(input.WorkspaceRoot, "main.bean")
	info, err := os.Stat(main)
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(main)
	if err != nil {
		t.Fatal(err)
	}
	// Same-size same-mtime edit must invalidate the full source digest.
	for i := range content {
		if content[i] == ' ' {
			content[i] = '\t'
			break
		}
	}
	if err := os.WriteFile(main, content, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(main, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	if _, err = resolveLocalModel(cfg, second, false); !errors.Is(err, ErrLocalModelUnavailable) {
		t.Fatal("same-size/mtime edit accepted", err)
	}
	stage := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(other.WorkspaceRoot))), "staging", "proposal", "workspace")
	if err := os.CopyFS(stage, os.DirFS(other.WorkspaceRoot)); err != nil {
		t.Fatal(err)
	}
	other.WorkspaceRoot = stage
	other.Staging = true
	staged := registerHandleFixture(t, other)
	stagedCfg, err := localConfig(other)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := resolveLocalModel(stagedCfg, staged, true); err != nil {
		t.Fatal(err)
	}
	if _, err := resolveLocalModel(stagedCfg, staged, true); !errors.Is(err, ErrLocalModelUnavailable) {
		t.Fatal("stage handle reused")
	}
}

func TestLocalModelRegistrationRejectsPathsMismatchAndMalformedStream(t *testing.T) {
	input := localTestRequest(t)
	version, err := LocalModelSourceVersion(input)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"../canonical.records", strings.Repeat("g", 32) + ".records", "/tmp/model"} {
		if _, err := RegisterLocalModel(input, name, version); err == nil {
			t.Fatal("bad path accepted")
		}
	}
	handle := registerHandleFixture(t, input)
	if _, err := RegisterLocalModel(input, strings.Repeat("a", 32)+".records", "wrong-version"); err == nil {
		t.Fatal("wrong source token accepted")
	}
	ReleaseLocalModel(handle)
	cfg, _ := localConfig(input)
	if _, err := resolveLocalModel(cfg, handle, false); !errors.Is(err, ErrLocalModelUnavailable) {
		t.Fatal("released handle accepted")
	}
}

func TestLocalRuntimeCopyExcludesCanonicalScratch(t *testing.T) {
	source, destination := t.TempDir(), filepath.Join(t.TempDir(), "copied")
	if err := os.MkdirAll(filepath.Join(source, "canonical-stream"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "canonical-stream", "orphan.records"), []byte("scratch"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(source, "canonical-cache", "build"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "canonical-cache", "build", "cached.records"), []byte("cache"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "receipt.json"), []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := copyLocalRuntime(source, destination); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(destination, "canonical-stream")); !os.IsNotExist(err) {
		t.Fatal("scratch copied")
	}
	if _, err := os.Stat(filepath.Join(destination, "canonical-cache")); !os.IsNotExist(err) {
		t.Fatal("canonical cache copied into a stage")
	}
	if _, err := os.Stat(filepath.Join(destination, "receipt.json")); err != nil {
		t.Fatal("receipt not copied", err)
	}
}

func TestLocalModelRegistrationRejectsMalformedArtifact(t *testing.T) {
	input := localTestRequest(t)
	version, err := LocalModelSourceVersion(input)
	if err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(input.WorkspaceRoot))), "runtime", "canonical-stream")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	name := strings.Repeat("b", 32) + ".records"
	if err := os.WriteFile(filepath.Join(directory, name), []byte("not a stream"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := RegisterLocalModel(input, name, version); err == nil {
		t.Fatal("malformed stream registered")
	}
}

// Exercise both content freshness and include-graph failures without changing
// file size or relying on a timestamp advancing.
func mutateRegisteredModelSource(t *testing.T, input LocalRequest, mutation string) {
	t.Helper()
	path := filepath.Join(input.WorkspaceRoot, "accounts.bean")
	if mutation == "missing-include" {
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
		return
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	changed := strings.Replace(string(content), "Assets:Cash", "Assets:Bank", 1)
	if changed == string(content) || len(changed) != len(content) {
		t.Fatal("tamper fixture must change content without changing size")
	}
	if err := os.WriteFile(path, []byte(changed), info.Mode()); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if after.Size() != info.Size() || !after.ModTime().Equal(info.ModTime()) {
		t.Fatal("tamper changed size or mtime")
	}
}

func warmRegisteredCandidatePage(t *testing.T, input LocalRequest) {
	t.Helper()
	raw := localTestDispatch(t, input)
	var page localTransactionPage
	if err := json.Unmarshal(raw, &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Transactions) != 2 || page.Revision == "" {
		t.Fatal("registered candidate page did not warm the snapshot")
	}
}

func TestLocalModelHandleCandidatePageRejectsSourceChangesAfterWarm(t *testing.T) {
	for _, mutation := range []string{"same-size-same-mtime", "missing-include"} {
		t.Run(mutation, func(t *testing.T) {
			input := localTestRequest(t)
			input.ModelHandle = registerHandleFixture(t, input)
			input.Path = "/api/ledger/transactions/page"
			input.Query = candidatePageQuery(nil)
			warmRegisteredCandidatePage(t, input)
			mutateRegisteredModelSource(t, input, mutation)

			status, raw, err := DispatchLocalRequest(input)
			if status != http.StatusConflict || raw != nil || err == nil {
				t.Fatalf("changed registered source accepted: status=%d payload=%t err=%v", status, raw != nil, err)
			}
			if mutation == "same-size-same-mtime" && !errors.Is(err, ErrLocalModelUnavailable) {
				t.Fatalf("expected stale-model sentinel, got %v", err)
			}
		})
	}
}

func TestLocalModelHandleSnapshotRejectsSourceChangesAfterResolve(t *testing.T) {
	for _, mutation := range []string{"same-size-same-mtime", "missing-include"} {
		t.Run(mutation, func(t *testing.T) {
			input := localTestRequest(t)
			input.ModelHandle = registerHandleFixture(t, input)
			input.Path = "/api/ledger/transactions/page"
			input.Query = candidatePageQuery(nil)
			warmRegisteredCandidatePage(t, input)
			cfg, err := localConfig(input)
			if err != nil {
				t.Fatal(err)
			}
			cfg, err = resolveLocalModel(cfg, input.ModelHandle, false)
			if err != nil {
				t.Fatal(err)
			}
			// Deterministic adversarial interleaving: mutate after resolve has
			// checked the digest, but before the warm snapshot can be returned.
			mutateRegisteredModelSource(t, input, mutation)
			cache, err := localRequestCache(cfg, false)
			if err != nil || cache == nil || cache != cfg.localRegisteredCache {
				t.Fatalf("registered cache was not returned directly: %v", err)
			}
			snapshot, err := cache.Snapshot()
			if err == nil || snapshot != nil {
				t.Fatal("changed source returned a stale registered snapshot")
			}
			if mutation == "same-size-same-mtime" && !errors.Is(err, ErrLocalModelUnavailable) {
				t.Fatalf("expected stale-model sentinel, got %v", err)
			}
		})
	}
}

func TestLocalModelStampsDetectEditAfterResolve(t *testing.T) {
	input := localTestRequest(t)
	handle := registerHandleFixture(t, input)
	cfg, err := localConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := resolveLocalModel(cfg, handle, false)
	if err != nil {
		t.Fatal(err)
	}
	cache := resolved.localRegisteredCache
	if !cache.stamps.matches() {
		t.Fatal("registered fixture should be verifiable by stat stamps")
	}
	if _, err := cache.Snapshot(); err != nil {
		t.Fatal(err)
	}
	main := filepath.Join(input.WorkspaceRoot, "main.bean")
	file, err := os.OpenFile(main, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("\n; edited\n"); err != nil {
		t.Fatal(err)
	}
	file.Close()
	if _, err := cache.Snapshot(); !errors.Is(err, ErrLocalModelUnavailable) {
		t.Fatalf("edit after resolve accepted: %v", err)
	}
}

// The estimate must track the decoded model, not the file that carried it: a
// binary snapshot is ~6x smaller than the equivalent stream while costing the
// same heap, so a file-size estimate would let several large models stay
// resident past the budget.
func TestLocalModelEstimateUsesResidentModelCost(t *testing.T) {
	input := localTestRequest(t)
	handle := registerHandleFixture(t, input)
	localModels.Lock()
	registered := committedLocalModel(handle)
	localModels.Unlock()
	if registered == nil {
		t.Fatal("registered model missing from the committed LRU")
	}
	want := int64(len(registered.model.Entries)) * localModelEstimateBytesPerEntry
	if registered.estimate != want {
		t.Fatalf("estimate = %d, want %d (entries x bytes per entry)", registered.estimate, want)
	}
	// A snapshot does not make the model cheaper, so the estimate must not shrink
	// with the cache file.
	smallerFile := localModelMemoryEstimate(registered.model, 1<<10)
	if smallerFile != want {
		t.Fatalf("estimate depends on file size: %d for a small file, want %d", smallerFile, want)
	}
	if localModelEstimateBytesPerEntry < 2151 {
		t.Fatalf("estimate %d bytes/entry undercounts the measured 2,151 on the 100k tier",
			localModelEstimateBytesPerEntry)
	}
	// One 100k ledger (110,563 entries) fits the budget alone; two do not. The
	// budget, not a lucky estimate, decides residency.
	measured100k := int64(110_563) * localModelEstimateBytesPerEntry
	if measured100k > localModelBudget {
		t.Fatalf("one 100k estimate %d exceeds the %d budget, so it could never stay resident",
			measured100k, localModelBudget)
	}
	if two := 2 * measured100k; two <= localModelBudget {
		t.Fatalf("two 100k ledgers fit the %d budget at %d bytes/entry",
			localModelBudget, localModelEstimateBytesPerEntry)
	}
}

func TestLocalMemoryLimitLeavesHeadroomAndDefaults(t *testing.T) {
	for _, test := range []struct {
		name      string
		available int64
		want      int64
	}{
		{"unknown reading keeps the runtime default", 0, 0},
		{"invalid reading keeps the runtime default", -1, 0},
		{"tight device keeps the measured-heap floor", 600 << 20, localMemoryLimitFloor},
		{"half of available memory", 1536 << 20, 768 << 20},
		{"large device is capped for jetsam", 8 << 30, localMemoryLimitCeiling},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := localMemoryLimitFor(test.available); got != test.want {
				t.Fatalf("localMemoryLimitFor(%d) = %d, want %d", test.available, got, test.want)
			}
		})
	}
	// The floor must stay above the measured 365MB peak live heap; a soft limit
	// below the working set makes the runtime collect continuously.
	if localMemoryLimitFloor <= 365<<20 {
		t.Fatalf("memory limit floor %d does not exceed the measured 365MB live heap", localMemoryLimitFloor)
	}
}

func TestConfigureLocalMemoryLimitAppliesSoftLimit(t *testing.T) {
	previous := debug.SetMemoryLimit(-1)
	t.Cleanup(func() { debug.SetMemoryLimit(previous) })
	if applied := ConfigureLocalMemoryLimit(1536 << 20); applied != 768<<20 {
		t.Fatalf("applied limit = %d, want %d", applied, 768<<20)
	}
	if current := debug.SetMemoryLimit(-1); current != 768<<20 {
		t.Fatalf("runtime limit = %d, want %d", current, 768<<20)
	}
	// An unknown reading must not silently change the configured limit.
	if applied := ConfigureLocalMemoryLimit(0); applied != 0 {
		t.Fatalf("unknown reading applied %d", applied)
	}
	if current := debug.SetMemoryLimit(-1); current != 768<<20 {
		t.Fatalf("unknown reading changed the runtime limit to %d", current)
	}
}
