package app

import (
	"context"
	"errors"
	"fmt"
	"os"
)

// importStateRepository owns the short-lived, structured state of an import.
// The generated and deduplicated Bean documents remain runtime files: they are
// the canonical, lossless representation of preview postings and can be
// parsed again when a preview is read.  This prevents a transient API response
// from becoming another opaque JSON document in PostgreSQL.
type importStateRepository interface {
	SaveJob(context.Context, string, importMeta) error
	Job(context.Context, string) (importMeta, error)
	SavePreview(context.Context, string, importPreviewState, ginH) error
	Preview(context.Context, string) (importPreviewState, ginH, error)
	Delete(context.Context, string) error
	Backfill(context.Context, string, importMeta, *importPreviewState) error
}

// importPreviewState contains only fields that are intrinsic to a preview.
// Preview entries are rebuilt from the deduplicated Bean runtime file and
// account options are rebuilt from the ledger snapshot.
type importPreviewState struct {
	DedupReport           string
	CandidateCount        int
	RawRowCount           int
	FilteredRowCount      int
	GeneratedCount        int
	ExcludedRowCount      int
	SkippedDuplicateCount int
	DateStart             string
	DateEnd               string
	Warnings              []string
}

var errImportPreviewMalformed = errors.New("导入预览数据损坏，请重新上传账单")

// runtimeImportStateRepository keeps the legacy JSON representation for
// filesystem deployments. PostgreSQL deployments receive an Ent-backed
// implementation through application wiring instead.
type runtimeImportStateRepository struct {
	runtime RuntimeStore
}

func newRuntimeImportStateRepository(runtime RuntimeStore) importStateRepository {
	if runtime == nil {
		return nil
	}
	return &runtimeImportStateRepository{runtime: runtime}
}

// newFallbackImportStateRepository lets a PostgreSQL deployment resume an
// import that was created before its relational upgrade. The primary store is
// always read first, so a legacy JSON document can never overwrite newer
// relational state.
func newFallbackImportStateRepository(primary, legacy importStateRepository) importStateRepository {
	if primary == nil {
		return legacy
	}
	if legacy == nil {
		return primary
	}
	return &fallbackImportStateRepository{primary: primary, legacy: legacy}
}

type fallbackImportStateRepository struct {
	primary importStateRepository
	legacy  importStateRepository
}

func (r *fallbackImportStateRepository) SaveJob(ctx context.Context, importID string, meta importMeta) error {
	return r.primary.SaveJob(ctx, importID, meta)
}

func (r *fallbackImportStateRepository) Job(ctx context.Context, importID string) (importMeta, error) {
	meta, err := r.primary.Job(ctx, importID)
	if !errors.Is(err, os.ErrNotExist) {
		return meta, err
	}
	meta, err = r.legacy.Job(ctx, importID)
	if err != nil {
		return importMeta{}, err
	}
	if err := r.primary.Backfill(ctx, importID, meta, nil); err != nil {
		return importMeta{}, err
	}
	return meta, nil
}

func (r *fallbackImportStateRepository) SavePreview(ctx context.Context, importID string, state importPreviewState, legacy ginH) error {
	return r.primary.SavePreview(ctx, importID, state, legacy)
}

func (r *fallbackImportStateRepository) Preview(ctx context.Context, importID string) (importPreviewState, ginH, error) {
	state, response, err := r.primary.Preview(ctx, importID)
	if !errors.Is(err, os.ErrNotExist) {
		return state, response, err
	}
	meta, err := r.legacy.Job(ctx, importID)
	if err != nil {
		return importPreviewState{}, nil, err
	}
	state, response, err = r.legacy.Preview(ctx, importID)
	if err != nil {
		return importPreviewState{}, nil, err
	}
	if err := r.primary.Backfill(ctx, importID, meta, &state); err != nil {
		return importPreviewState{}, nil, err
	}
	// A relational preview is intentionally rebuilt, so do not leak its legacy
	// JSON response back into the normal PostgreSQL path.
	return state, nil, nil
}

func (r *fallbackImportStateRepository) Delete(ctx context.Context, importID string) error {
	return errors.Join(r.primary.Delete(ctx, importID), r.legacy.Delete(ctx, importID))
}

func (r *fallbackImportStateRepository) Backfill(ctx context.Context, importID string, meta importMeta, state *importPreviewState) error {
	return r.primary.Backfill(ctx, importID, meta, state)
}

func (r *runtimeImportStateRepository) SaveJob(ctx context.Context, importID string, meta importMeta) error {
	return r.runtime.PutJSON(ctx, "imports", importFileKey(importID, "meta"), meta)
}

func (r *runtimeImportStateRepository) Job(ctx context.Context, importID string) (importMeta, error) {
	var meta importMeta
	ok, err := r.runtime.GetJSON(ctx, "imports", importFileKey(importID, "meta"), &meta)
	if err != nil {
		return importMeta{}, err
	}
	if !ok {
		return importMeta{}, os.ErrNotExist
	}
	return meta, nil
}

func (r *runtimeImportStateRepository) SavePreview(ctx context.Context, importID string, state importPreviewState, legacy ginH) error {
	if legacy == nil {
		legacy = importPreviewResponseFromState(importID, importMeta{}, state, nil, nil)
	}
	return r.runtime.PutJSON(ctx, "imports", importFileKey(importID, "preview"), legacy)
}

func (r *runtimeImportStateRepository) Preview(ctx context.Context, importID string) (importPreviewState, ginH, error) {
	var preview ginH
	ok, err := r.runtime.GetJSON(ctx, "imports", importFileKey(importID, "preview"), &preview)
	if err != nil {
		return importPreviewState{}, nil, fmt.Errorf("%w: %v", errImportPreviewMalformed, err)
	}
	if !ok {
		return importPreviewState{}, nil, os.ErrNotExist
	}
	state, err := importPreviewStateFromResponse(preview)
	if err != nil {
		return importPreviewState{}, nil, err
	}
	return state, preview, nil
}

func (r *runtimeImportStateRepository) Delete(ctx context.Context, importID string) error {
	return errors.Join(
		r.runtime.DeleteJSON(ctx, "imports", importFileKey(importID, "meta")),
		r.runtime.DeleteJSON(ctx, "imports", importFileKey(importID, "preview")),
	)
}

func (r *runtimeImportStateRepository) Backfill(context.Context, string, importMeta, *importPreviewState) error {
	// The legacy store is already the source being imported from.
	return nil
}

func importPreviewStateFromResponse(preview ginH) (importPreviewState, error) {
	state := importPreviewState{}
	var err error
	if state.DedupReport, err = previewString(preview, "dedupReport", false); err != nil {
		return importPreviewState{}, err
	}
	if state.CandidateCount, err = previewInt(preview, "candidateCount"); err != nil {
		return importPreviewState{}, err
	}
	if state.RawRowCount, err = previewInt(preview, "rawRowCount"); err != nil {
		return importPreviewState{}, err
	}
	if state.FilteredRowCount, err = previewInt(preview, "filteredRowCount"); err != nil {
		return importPreviewState{}, err
	}
	if state.GeneratedCount, err = previewInt(preview, "generatedCount"); err != nil {
		return importPreviewState{}, err
	}
	if state.ExcludedRowCount, err = previewInt(preview, "excludedRowCount"); err != nil {
		return importPreviewState{}, err
	}
	if state.SkippedDuplicateCount, err = previewInt(preview, "skippedDuplicateCount"); err != nil {
		return importPreviewState{}, err
	}
	if state.DateStart, err = previewString(preview, "dateStart", true); err != nil {
		return importPreviewState{}, err
	}
	if state.DateEnd, err = previewString(preview, "dateEnd", true); err != nil {
		return importPreviewState{}, err
	}
	if state.Warnings, err = previewStrings(preview, "warnings"); err != nil {
		return importPreviewState{}, err
	}
	return state, nil
}

func previewString(preview ginH, key string, nullable bool) (string, error) {
	value, ok := preview[key]
	if !ok || (nullable && value == nil) {
		return "", nil
	}
	text, ok := value.(string)
	if !ok {
		return "", fmt.Errorf("%w: %s 不是字符串", errImportPreviewMalformed, key)
	}
	return text, nil
}

func previewInt(preview ginH, key string) (int, error) {
	value, ok := preview[key]
	if !ok {
		return 0, fmt.Errorf("%w: 缺少 %s", errImportPreviewMalformed, key)
	}
	switch value := value.(type) {
	case int:
		return value, nil
	case int32:
		return int(value), nil
	case int64:
		return int(value), nil
	case float64:
		if value == float64(int(value)) {
			return int(value), nil
		}
	}
	return 0, fmt.Errorf("%w: %s 不是整数", errImportPreviewMalformed, key)
}

func previewStrings(preview ginH, key string) ([]string, error) {
	value, ok := preview[key]
	if !ok || value == nil {
		return nil, nil
	}
	switch values := value.(type) {
	case []string:
		return append([]string(nil), values...), nil
	case []any:
		out := make([]string, 0, len(values))
		for _, value := range values {
			text, ok := value.(string)
			if !ok {
				return nil, fmt.Errorf("%w: %s 包含非字符串项", errImportPreviewMalformed, key)
			}
			out = append(out, text)
		}
		return out, nil
	default:
		return nil, fmt.Errorf("%w: %s 不是字符串数组", errImportPreviewMalformed, key)
	}
}

var _ importStateRepository = (*runtimeImportStateRepository)(nil)
var _ importStateRepository = (*fallbackImportStateRepository)(nil)
