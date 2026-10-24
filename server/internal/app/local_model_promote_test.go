package app

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// stageClone copies a committed generation into <ledger>/staging/<id>/workspace,
// which is exactly what a preview/commit stage starts from.
func stageClone(t *testing.T, generation LocalRequest) LocalRequest {
	t.Helper()
	ledger := filepath.Dir(filepath.Dir(filepath.Dir(generation.WorkspaceRoot)))
	staging := filepath.Join(ledger, "staging")
	if err := os.MkdirAll(staging, 0700); err != nil {
		t.Fatal(err)
	}
	proposal, err := os.MkdirTemp(staging, "proposal")
	if err != nil {
		t.Fatal(err)
	}
	stage := filepath.Join(proposal, "workspace")
	if err := os.CopyFS(stage, os.DirFS(generation.WorkspaceRoot)); err != nil {
		t.Fatal(err)
	}
	stageInput := generation
	stageInput.WorkspaceRoot = stage
	stageInput.Staging = true
	return stageInput
}

// canonicalStreamForLedgerFixture books the two real fixture transactions at
// their real source locators, so promoted/dopted models expose real editor
// drafts and source hashes rather than generated ones.
func canonicalStreamForLedgerFixture(t *testing.T) []byte {
	t.Helper()
	var body strings.Builder
	write := func(v any) {
		encoded, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		body.Write(encoded)
		body.WriteByte('\n')
	}
	write(map[string]any{"type": "header", "version": 1})
	write(map[string]any{"type": "option", "key": "operating_currency", "value": "CNY"})
	write(map[string]any{"type": "commodity", "value": "CNY"})
	for _, transaction := range []struct {
		date, payee, narration string
		line                   int
		postings               [][2]string
	}{
		{"2026-05-01", "Cafe", "Lunch", 1, [][2]string{{"Expenses:Food", "12.00"}, {"Assets:Cash", "-12.00"}}},
		{"2026-05-31", "Employer", "Salary", 6, [][2]string{{"Assets:Cash", "1000.00"}, {"Income:Salary", "-1000.00"}}},
	} {
		write(map[string]any{"type": "entry", "entry": map[string]any{"Kind": "transaction", "Date": transaction.date,
			"File": "transactions/2026/05.bean", "Line": transaction.line,
			"Payee": transaction.payee, "Narration": transaction.narration}})
		for _, posting := range transaction.postings {
			write(map[string]any{"type": "posting", "posting": map[string]any{
				"account": posting[0], "Quantity": map[string]string{"Number": posting[1], "Currency": "CNY"}}})
		}
		write(map[string]any{"type": "end_entry"})
	}
	digest := sha256.Sum256([]byte(body.String()))
	write(map[string]any{"type": "footer", "entries": 2, "sha256": hex.EncodeToString(digest[:])})
	return []byte(body.String())
}

// registerStreamHandleFixture registers one model from an explicit canonical
// stream for the exact source version of input.
func registerStreamHandleFixture(t *testing.T, input LocalRequest, stream []byte) (string, string) {
	t.Helper()
	version, err := LocalModelSourceVersion(input)
	if err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(input.WorkspaceRoot))), "runtime", "canonical-stream")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	name := strings.Repeat("d", 32) + ".records"
	if err := os.WriteFile(filepath.Join(directory, name), stream, 0600); err != nil {
		t.Fatal(err)
	}
	handle, err := RegisterLocalModel(input, name, version)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ReleaseLocalModel(handle) })
	return handle, version
}

func TestLocalModelPromoteBindsRetainedStageToItsGeneration(t *testing.T) {
	generation := localTestRequest(t)
	stage := stageClone(t, generation)
	stream := canonicalStreamForLedgerFixture(t)
	handle, version := registerStreamHandleFixture(t, stage, stream)
	generationVersion, err := LocalModelSourceVersion(generation)
	if err != nil {
		t.Fatal(err)
	}
	if generationVersion != version {
		t.Fatal("stage clone source version differs from its generation")
	}

	promoted, err := PromoteLocalModel(generation, handle, version)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ReleaseLocalModel(promoted) })
	// Promotion consumes the stage registration.
	if _, err := PromoteLocalModel(generation, handle, version); err == nil {
		t.Fatal("promoted stage handle reused")
	}
	if localModels.staged != nil {
		t.Fatal("stage registration survived promotion")
	}

	// The preview stage is removed by publication; the committed model must not
	// depend on it in any way.
	if err := os.RemoveAll(filepath.Dir(filepath.Dir(stage.WorkspaceRoot))); err != nil {
		t.Fatal(err)
	}
	cfg, err := localConfig(generation)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := resolveLocalModel(cfg, promoted, false)
	if err != nil || resolved.localCanonical == nil || resolved.localRegisteredCache == nil {
		t.Fatal("promoted handle did not resolve", err)
	}

	generation.WorkspaceRoot = filepath.Clean(generation.WorkspaceRoot)
	generation.ModelHandle = promoted
	generation.Path = "/api/ledger/transactions/page"
	generation.Query = candidatePageQuery(nil)
	status, raw, err := DispatchLocalRequest(generation)
	if status != 200 || err != nil {
		t.Fatalf("promoted generation page: status=%d err=%v", status, err)
	}
	if strings.Contains(string(raw), "/staging/") || strings.Contains(string(raw), generation.WorkspaceRoot) {
		t.Fatalf("page leaked an absolute or stale source path: %s", raw)
	}
	var page localTransactionPage
	if err := json.Unmarshal(raw, &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Transactions) != 2 {
		t.Fatalf("promoted model transactions = %d", len(page.Transactions))
	}
	detailSource := page.Transactions[0].Source
	if filepath.IsAbs(detailSource.File) || detailSource.File != "transactions/2026/05.bean" || detailSource.Hash == "" {
		t.Fatalf("promoted model source locator = %+v", detailSource)
	}

	// Details resolve by the generation root and return the exact editor draft.
	generation.Path = "/api/ledger/transactions/detail"
	generation.Query = map[string]string{"file": detailSource.File,
		"line": jsonInt(detailSource.Line), "hash": detailSource.Hash}
	status, raw, err = DispatchLocalRequest(generation)
	if status != 200 || err != nil {
		t.Fatalf("promoted generation detail: status=%d err=%v raw=%s", status, err, raw)
	}
	var detail Transaction
	if err := json.Unmarshal(raw, &detail); err != nil {
		t.Fatal(err)
	}
	if detail.Entry == nil || detail.Source.File != "transactions/2026/05.bean" {
		t.Fatalf("detail lost its source draft or locator: %+v", detail)
	}
	if detail.Entry == nil || detail.Entry.Narration != detail.Narration || detail.Source.Line == 0 {
		t.Fatalf("detail draft = %+v", detail.Entry)
	}

	// Once the snapshot exists the promoted model's entries belong to the new
	// root, and re-resolving still yields the same committed registration.
	resolved, err = resolveLocalModel(cfg, promoted, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range resolved.localCanonical.Entries {
		if entry.File == "" {
			continue
		}
		if !filepath.IsAbs(entry.File) || !strings.HasPrefix(entry.File, cfg.LedgerRoot+string(filepath.Separator)) {
			t.Fatalf("promoted model kept a stale source path: %s", entry.File)
		}
	}
}

func jsonInt(value int) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}

func TestLocalModelPromoteFailsClosedOnMismatchAndBadLifetime(t *testing.T) {
	generation := localTestRequest(t)
	stream := canonicalStreamForLedgerFixture(t)

	t.Run("digest-mismatch", func(t *testing.T) {
		stage := stageClone(t, generation)
		handle, version := registerStreamHandleFixture(t, stage, stream)
		mainBean := filepath.Join(generation.WorkspaceRoot, "commodities.bean")
		if err := os.WriteFile(mainBean, []byte("2026-01-01 commodity CNY\n; changed\n"), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := PromoteLocalModel(generation, handle, version); err == nil {
			t.Fatal("changed generation source promoted")
		}
		// A rejected promotion leaves the retained stage registration intact.
		localModels.Lock()
		retained := localModels.staged != nil && localModels.staged.handle == handle
		localModels.Unlock()
		if !retained {
			t.Fatal("rejected promotion consumed the stage model")
		}
	})
	t.Run("wrong-version-token", func(t *testing.T) {
		stage := stageClone(t, generation)
		handle, version := registerStreamHandleFixture(t, stage, stream)
		if _, err := PromoteLocalModel(generation, handle, version+"0"); err == nil {
			t.Fatal("wrong expected version promoted")
		}
	})
	t.Run("wrong-entrypoint", func(t *testing.T) {
		stage := stageClone(t, generation)
		handle, version := registerStreamHandleFixture(t, stage, stream)
		wrong := generation
		wrong.Entrypoint = "other.bean"
		if _, err := PromoteLocalModel(wrong, handle, version); err == nil {
			t.Fatal("entrypoint mismatch promoted")
		}
	})
	t.Run("staging-target", func(t *testing.T) {
		stage := stageClone(t, generation)
		handle, version := registerStreamHandleFixture(t, stage, stream)
		if _, err := PromoteLocalModel(stage, handle, version); err == nil {
			t.Fatal("staging root accepted as a promotion target")
		}
	})
	t.Run("unmanaged-target", func(t *testing.T) {
		stage := stageClone(t, generation)
		handle, version := registerStreamHandleFixture(t, stage, stream)
		unmanaged := generation
		unmanaged.WorkspaceRoot = filepath.Join(t.TempDir(), "workspace")
		if err := os.MkdirAll(unmanaged.WorkspaceRoot, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(unmanaged.WorkspaceRoot, "main.bean"), []byte("option \"title\" \"x\"\n"), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := PromoteLocalModel(unmanaged, handle, version); err == nil {
			t.Fatal("unmanaged root promoted")
		}
	})
	t.Run("replaced-by-newer-stage", func(t *testing.T) {
		first := stageClone(t, generation)
		handle, version := registerStreamHandleFixture(t, first, stream)
		// A second staging request (another preview) registers its own stage and
		// displaces this one; the old handle must never be promoted afterwards.
		second := stageClone(t, generation)
		registerStreamHandleFixture(t, second, stream)
		if _, err := PromoteLocalModel(generation, handle, version); err == nil {
			t.Fatal("displaced stage handle promoted")
		}
	})
	t.Run("released-handle", func(t *testing.T) {
		stage := stageClone(t, generation)
		handle, version := registerStreamHandleFixture(t, stage, stream)
		ReleaseLocalModel(handle)
		if _, err := PromoteLocalModel(generation, handle, version); err == nil {
			t.Fatal("released stage handle promoted")
		}
	})
	t.Run("one-shot-stage-handle", func(t *testing.T) {
		stage := stageClone(t, generation)
		handle, version := registerStreamHandleFixture(t, stage, stream)
		stageCfg, err := localConfig(stage)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := resolveLocalModel(stageCfg, handle, true); err != nil {
			t.Fatal(err)
		}
		if _, err := PromoteLocalModel(generation, handle, version); err == nil {
			t.Fatal("consumed one-shot stage handle promoted")
		}
	})
}

func TestLocalModelAdoptCopiesCommittedModelWithoutSharingIt(t *testing.T) {
	generation := localTestRequest(t)
	stream := canonicalStreamForLedgerFixture(t)
	committed, version := registerStreamHandleFixture(t, generation, stream)
	stage := stageClone(t, generation)

	adopted, err := AdoptLocalModel(stage, committed, version)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ReleaseLocalModel(adopted) })
	if adopted == committed {
		t.Fatal("adoption reused the committed handle")
	}
	stageCfg, err := localConfig(stage)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := resolveLocalModel(stageCfg, adopted, true)
	if err != nil {
		t.Fatal(err)
	}
	// The adopted stage registration is one-shot.
	if _, err := resolveLocalModel(stageCfg, adopted, true); err == nil {
		t.Fatal("adopted stage handle reused")
	}
	snapshot, err := resolved.localRegisteredCache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Transactions) != 2 {
		t.Fatalf("adopted snapshot transactions = %d", len(snapshot.Transactions))
	}
	for _, transaction := range snapshot.Transactions {
		if !filepath.IsAbs(transaction.Source.File) ||
			!strings.HasPrefix(transaction.Source.File, stageCfg.LedgerRoot+string(filepath.Separator)) {
			t.Fatalf("adopted snapshot kept the committed root: %s", transaction.Source.File)
		}
	}
	// Releasing the stage cannot disturb the committed model or its snapshot.
	ReleaseLocalModel(adopted)
	generationCfg, err := localConfig(generation)
	if err != nil {
		t.Fatal(err)
	}
	committedResolved, err := resolveLocalModel(generationCfg, committed, false)
	if err != nil {
		t.Fatal(err)
	}
	committedSnapshot, err := committedResolved.localRegisteredCache.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(committedSnapshot.Transactions) != 2 {
		t.Fatalf("committed snapshot transactions = %d", len(committedSnapshot.Transactions))
	}
	status, page, err := localTransactionPageProjection(generationCfg, committedSnapshot, candidatePageQuery(nil), false)
	if status != 200 || err != nil {
		t.Fatalf("committed page after adoption: status=%d err=%v", status, err)
	}
	var decoded localTransactionPage
	if err := json.Unmarshal(page, &decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Transactions) != 2 || decoded.Transactions[0].Source.File != "transactions/2026/05.bean" {
		t.Fatalf("committed page after adoption = %+v", decoded.Transactions)
	}
}

func TestLocalModelAdoptFailsClosed(t *testing.T) {
	generation := localTestRequest(t)
	stream := canonicalStreamForLedgerFixture(t)
	committed, version := registerStreamHandleFixture(t, generation, stream)

	t.Run("changed-stage-source", func(t *testing.T) {
		stage := stageClone(t, generation)
		if err := os.WriteFile(filepath.Join(stage.WorkspaceRoot, "commodities.bean"),
			[]byte("2026-01-01 commodity CNY\n; changed\n"), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := AdoptLocalModel(stage, committed, version); err == nil {
			t.Fatal("changed staging source adopted")
		}
	})
	t.Run("unknown-committed-model", func(t *testing.T) {
		stage := stageClone(t, generation)
		if _, err := AdoptLocalModel(stage, strings.Repeat("e", 48), version); err == nil {
			t.Fatal("unknown committed handle adopted")
		}
	})
	t.Run("generation-target", func(t *testing.T) {
		if _, err := AdoptLocalModel(generation, committed, version); err == nil {
			t.Fatal("generation root accepted as an adoption target")
		}
	})
	t.Run("wrong-version-token", func(t *testing.T) {
		stage := stageClone(t, generation)
		if _, err := AdoptLocalModel(stage, committed, version+"0"); err == nil {
			t.Fatal("wrong expected version adopted")
		}
	})
	t.Run("other-ledger", func(t *testing.T) {
		other := localTestRequest(t)
		stage := stageClone(t, other)
		if _, err := AdoptLocalModel(stage, committed, version); err == nil {
			t.Fatal("committed model adopted across ledgers")
		}
	})
}

// The adoption copy is the only new per-request cost of keeping a single Go
// registration; it replaces a full canonical import of the same content.
func BenchmarkLocalModelAdoptClone100k(b *testing.B) {
	entries := make([]BeanEntry, 100000)
	for i := range entries {
		entries[i] = BeanEntry{Kind: "transaction", Date: "2026-09-01", File: "transactions/2026/09.bean", Line: i + 1,
			Postings: []parsedPosting{
				{Posting: Posting{Account: "Assets:Cash"}, Quantity: BeanAmount{Number: "-10", Currency: "CNY"}},
				{Posting: Posting{Account: "Expenses:Food"}, Quantity: BeanAmount{Number: "10", Currency: "CNY"}},
			}}
	}
	model := &LocalCanonicalModel{Version: 1, Entries: entries,
		Options: map[string]string{"operating_currency": "CNY"}}
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		if _, err := cloneLocalCanonicalModelForWorkspace(model); err != nil {
			b.Fatal(err)
		}
	}
}
