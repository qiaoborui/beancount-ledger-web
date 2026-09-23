package app

import (
	"errors"
	"os"
	"path/filepath"
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
	if err := os.WriteFile(filepath.Join(source, "receipt.json"), []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := copyLocalRuntime(source, destination); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(destination, "canonical-stream")); !os.IsNotExist(err) {
		t.Fatal("scratch copied")
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
