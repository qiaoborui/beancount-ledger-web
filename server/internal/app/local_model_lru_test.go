package app

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type lruLedger struct {
	input  LocalRequest
	cfg    Config
	handle string
}

func registerLRULedger(t *testing.T, input LocalRequest) lruLedger {
	t.Helper()
	handle := registerHandleFixture(t, input)
	cfg, err := localConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	return lruLedger{input: input, cfg: cfg, handle: handle}
}

func (l lruLedger) resolves(t *testing.T) bool {
	t.Helper()
	_, err := resolveLocalModel(l.cfg, l.handle, l.input.Staging)
	if err != nil && !errors.Is(err, ErrLocalModelUnavailable) {
		t.Fatal(err)
	}
	return err == nil
}

func committedLocalModelCount() int {
	localModels.Lock()
	defer localModels.Unlock()
	return len(localModels.committed)
}

func TestLocalModelLRUKeepsSeveralLedgersAndEvictsByCount(t *testing.T) {
	var ledgers []lruLedger
	for range localModelLRULimit {
		ledgers = append(ledgers, registerLRULedger(t, localTestRequest(t)))
	}
	for _, ledger := range ledgers {
		if !ledger.resolves(t) {
			t.Fatal("switching between registered ledgers required re-registration")
		}
	}
	// Touch the oldest so the second-oldest becomes least recently used.
	if !ledgers[0].resolves(t) {
		t.Fatal("oldest ledger unavailable")
	}
	extra := registerLRULedger(t, localTestRequest(t))
	if ledgers[1].resolves(t) {
		t.Fatal("least recently used model survived count eviction")
	}
	for _, ledger := range []lruLedger{ledgers[0], ledgers[2], ledgers[3], extra} {
		if !ledger.resolves(t) {
			t.Fatal("recently used model evicted")
		}
	}
	if got := committedLocalModelCount(); got > localModelLRULimit {
		t.Fatalf("registry holds %d models", got)
	}
}

func TestLocalModelLRUEvictsByBudget(t *testing.T) {
	first := registerLRULedger(t, localTestRequest(t))
	localModels.Lock()
	estimate := committedLocalModel(first.handle).estimate
	localModels.Unlock()
	if estimate <= 0 {
		t.Fatal("registration recorded no size estimate")
	}
	previous := localModelBudget
	localModelBudget = 2*estimate + estimate/2
	t.Cleanup(func() { localModelBudget = previous })
	second := registerLRULedger(t, localTestRequest(t))
	// Touch second, then first: second becomes least recently used.
	if !second.resolves(t) || !first.resolves(t) {
		t.Fatal("models within budget evicted")
	}
	third := registerLRULedger(t, localTestRequest(t))
	if second.resolves(t) {
		t.Fatal("least recently used model survived budget eviction")
	}
	if !first.resolves(t) || !third.resolves(t) {
		t.Fatal("recent models evicted")
	}
	// The newest model is kept even when it alone exceeds the budget.
	localModelBudget = estimate / 2
	fourth := registerLRULedger(t, localTestRequest(t))
	if !fourth.resolves(t) || first.resolves(t) || third.resolves(t) {
		t.Fatal("over-budget registration did not keep only the newest model")
	}
}

func TestLocalModelLRUReplacesSameLedgerAndGeneration(t *testing.T) {
	input := localTestRequest(t)
	first := registerLRULedger(t, input)
	other := registerLRULedger(t, localTestRequest(t))
	same := registerLRULedger(t, input)
	if first.resolves(t) || !same.resolves(t) || !other.resolves(t) {
		t.Fatal("re-registering the same root did not replace only its old handle")
	}
	next := filepath.Join(filepath.Dir(filepath.Dir(input.WorkspaceRoot)), "next", "workspace")
	if err := os.CopyFS(next, os.DirFS(input.WorkspaceRoot)); err != nil {
		t.Fatal(err)
	}
	moved := input
	moved.WorkspaceRoot = next
	generation := registerLRULedger(t, moved)
	if same.resolves(t) || !generation.resolves(t) || !other.resolves(t) {
		t.Fatal("a newer generation did not replace the older one of the same ledger")
	}
	if got := committedLocalModelCount(); got != 2 {
		t.Fatalf("registry holds %d models, want 2", got)
	}
}

func TestLocalModelLRUReleaseAndStaleVersion(t *testing.T) {
	released := registerLRULedger(t, localTestRequest(t))
	stale := registerLRULedger(t, localTestRequest(t))
	kept := registerLRULedger(t, localTestRequest(t))
	ReleaseLocalModel(released.handle)
	if released.resolves(t) || !kept.resolves(t) {
		t.Fatal("release did not remove only its handle")
	}
	main := filepath.Join(stale.input.WorkspaceRoot, "main.bean")
	content, err := os.ReadFile(main)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(main, append(content, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	if stale.resolves(t) {
		t.Fatal("stale model accepted")
	}
	localModels.Lock()
	leftover := committedLocalModel(stale.handle)
	localModels.Unlock()
	if leftover != nil {
		t.Fatal("stale model not released from the registry")
	}
	if !kept.resolves(t) {
		t.Fatal("stale release affected another ledger")
	}
}

func TestLocalModelLRULeavesStageSingleAndOneShot(t *testing.T) {
	input := localTestRequest(t)
	stage := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(input.WorkspaceRoot))), "staging", "proposal", "workspace")
	if err := os.CopyFS(stage, os.DirFS(input.WorkspaceRoot)); err != nil {
		t.Fatal(err)
	}
	input.WorkspaceRoot, input.Staging = stage, true
	staged := registerLRULedger(t, input)
	for range localModelLRULimit + 1 {
		registerLRULedger(t, localTestRequest(t))
	}
	localModels.Lock()
	inLRU := committedLocalModel(staged.handle)
	localModels.Unlock()
	if inLRU != nil {
		t.Fatal("staged model entered the committed LRU")
	}
	if !staged.resolves(t) {
		t.Fatal("committed registrations evicted the stage")
	}
	if staged.resolves(t) {
		t.Fatal("stage handle reused")
	}
}

func TestLocalModelReleaseIdleKeepsCurrentLedgerAndStage(t *testing.T) {
	current := registerLRULedger(t, localTestRequest(t))
	older := registerLRULedger(t, localTestRequest(t))
	oldest := registerLRULedger(t, localTestRequest(t))
	// A staged model belongs to the request publishing it and must survive a
	// memory warning; only idle committed ledgers are reclaimable.
	input := localTestRequest(t)
	stage := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(input.WorkspaceRoot))), "staging", "proposal", "workspace")
	if err := os.CopyFS(stage, os.DirFS(input.WorkspaceRoot)); err != nil {
		t.Fatal(err)
	}
	input.WorkspaceRoot, input.Staging = stage, true
	staged := registerLRULedger(t, input)

	if released := ReleaseIdleLocalModels(current.handle); released != 2 {
		t.Fatalf("released %d idle models, want 2", released)
	}
	if !current.resolves(t) {
		t.Fatal("memory pressure released the current ledger")
	}
	for _, idle := range []lruLedger{older, oldest} {
		if idle.resolves(t) {
			t.Fatal("idle ledger survived memory pressure")
		}
	}
	if !staged.resolves(t) {
		t.Fatal("memory pressure released the staged model")
	}
	// A missing/stale shell handle must keep the most recently used ledger: it is
	// the one the visible view is reading when the shell's own bookkeeping is
	// out of date.
	if released := ReleaseIdleLocalModels(""); released != 0 {
		t.Fatalf("released %d models for a missing keep handle, want 0", released)
	}
	if !current.resolves(t) {
		t.Fatal("missing keep handle dropped the most recently used ledger")
	}
	recent := registerLRULedger(t, localTestRequest(t))
	idle := registerLRULedger(t, localTestRequest(t))
	// Resolving marks the recent ledger most recently used.
	if !recent.resolves(t) {
		t.Fatal("recent ledger did not resolve")
	}
	if released := ReleaseIdleLocalModels("stale-handle"); released != 2 {
		t.Fatalf("released %d models for a stale keep handle, want 2", released)
	}
	if !recent.resolves(t) {
		t.Fatal("stale keep handle dropped the most recently used ledger")
	}
	for _, idleLedger := range []lruLedger{idle, current} {
		if idleLedger.resolves(t) {
			t.Fatal("stale keep handle retained an idle ledger")
		}
	}
}
