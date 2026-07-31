package app

import (
	"context"
	"errors"
	"os"
	"testing"
)

func TestRuntimeImportStateRepositoryKeepsFilesystemJSONCompatibility(t *testing.T) {
	ctx := context.Background()
	repository := newRuntimeImportStateRepository(newFilesystemRuntimeStore(t.TempDir()))
	meta := importMeta{Provider: "alipay", OriginalFilename: "bill.csv", InputFile: "/tmp/private.csv", InputFileKey: "preview/original"}
	preview := validImportPreview()

	if err := repository.SaveJob(ctx, "preview", meta); err != nil {
		t.Fatal(err)
	}
	if err := repository.SavePreview(ctx, "preview", mustPreviewState(t, preview), preview); err != nil {
		t.Fatal(err)
	}
	gotMeta, err := repository.Job(ctx, "preview")
	if err != nil {
		t.Fatal(err)
	}
	if gotMeta.InputFile != meta.InputFile || gotMeta.InputFileKey != meta.InputFileKey {
		t.Fatalf("meta = %#v", gotMeta)
	}
	_, gotPreview, err := repository.Preview(ctx, "preview")
	if err != nil {
		t.Fatal(err)
	}
	if gotPreview["generatedBean"] != "generated" || gotPreview["provider"] != "alipay" {
		t.Fatalf("preview = %#v", gotPreview)
	}
	if err := repository.Delete(ctx, "preview"); err != nil {
		t.Fatal(err)
	}
	if _, err := repository.Job(ctx, "preview"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("job err = %v", err)
	}
}

func TestRuntimeImportStateRepositoryRejectsMalformedLegacyPreview(t *testing.T) {
	ctx := context.Background()
	runtime := newFilesystemRuntimeStore(t.TempDir())
	repository := newRuntimeImportStateRepository(runtime)
	preview := validImportPreview()
	preview["candidateCount"] = "not-an-int"
	if err := runtime.PutJSON(ctx, "imports", importFileKey("preview", "preview"), preview); err != nil {
		t.Fatal(err)
	}
	if _, _, err := repository.Preview(ctx, "preview"); !errors.Is(err, errImportPreviewMalformed) {
		t.Fatalf("err = %v, want malformed preview error", err)
	}
}

func TestFallbackImportStateRepositoryBackfillsWithoutReturningLegacyResponse(t *testing.T) {
	ctx := context.Background()
	state := mustPreviewState(t, validImportPreview())
	legacy := &fakeImportStateRepository{meta: importMeta{Provider: "alipay", OriginalFilename: "bill.csv"}, preview: state, response: validImportPreview()}
	primary := &fakeImportStateRepository{jobErr: os.ErrNotExist, previewErr: os.ErrNotExist}
	repository := newFallbackImportStateRepository(primary, legacy)

	got, response, err := repository.Preview(ctx, "preview")
	if err != nil {
		t.Fatal(err)
	}
	if response != nil || got.CandidateCount != state.CandidateCount {
		t.Fatalf("preview=%#v response=%#v", got, response)
	}
	if primary.backfilledMeta.Provider != "alipay" || primary.backfilledPreview == nil {
		t.Fatalf("backfill meta=%#v preview=%#v", primary.backfilledMeta, primary.backfilledPreview)
	}
}

func validImportPreview() ginH {
	return ginH{
		"importId": "preview", "provider": "alipay", "generatedBean": "generated", "dedupReport": "kept",
		"candidateCount": 1, "rawRowCount": 2, "filteredRowCount": 2, "generatedCount": 2,
		"excludedRowCount": 0, "skippedDuplicateCount": 1, "dateStart": "2026-01-01", "dateEnd": "2026-01-02",
		"warnings": []string{"review"},
	}
}

func mustPreviewState(t *testing.T, preview ginH) importPreviewState {
	t.Helper()
	state, err := importPreviewStateFromResponse(preview)
	if err != nil {
		t.Fatal(err)
	}
	return state
}

type fakeImportStateRepository struct {
	meta              importMeta
	preview           importPreviewState
	response          ginH
	jobErr            error
	previewErr        error
	backfilledMeta    importMeta
	backfilledPreview *importPreviewState
}

func (r *fakeImportStateRepository) SaveJob(_ context.Context, _ string, meta importMeta) error {
	r.meta = meta
	return nil
}
func (r *fakeImportStateRepository) Job(context.Context, string) (importMeta, error) {
	return r.meta, r.jobErr
}
func (r *fakeImportStateRepository) SavePreview(_ context.Context, _ string, preview importPreviewState, response ginH) error {
	r.preview, r.response = preview, response
	return nil
}
func (r *fakeImportStateRepository) Preview(context.Context, string) (importPreviewState, ginH, error) {
	return r.preview, r.response, r.previewErr
}
func (r *fakeImportStateRepository) Delete(context.Context, string) error { return nil }
func (r *fakeImportStateRepository) Backfill(_ context.Context, _ string, meta importMeta, preview *importPreviewState) error {
	r.backfilledMeta, r.backfilledPreview = meta, preview
	return nil
}

var _ importStateRepository = (*fakeImportStateRepository)(nil)
