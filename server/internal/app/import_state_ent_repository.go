package app

import (
	"context"
	"os"
	"strconv"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/importjob"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/importpreviewstate"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/importpreviewwarning"
)

// entImportStateRepository keeps import metadata and preview scalars in
// relational rows. It never stores temporary filesystem paths or the dynamic
// preview response envelope.
type entImportStateRepository struct{ client *ent.Client }

func newEntImportStateRepository(client *ent.Client) importStateRepository {
	if client == nil {
		return nil
	}
	return &entImportStateRepository{client: client}
}

func (r *entImportStateRepository) SaveJob(ctx context.Context, importID string, meta importMeta) error {
	now := time.Now().UTC()
	upsert := r.client.ImportJob.Create().
		SetID(importID).
		SetProvider(meta.Provider).
		SetOriginalFilename(meta.OriginalFilename).
		SetInputFilename(meta.InputFilename).
		SetInputFileKey(meta.InputFileKey).
		SetDocumentFileKey(meta.DocumentFileKey).
		SetGeneratedFileKey(meta.GeneratedFileKey).
		SetDedupedFileKey(meta.DedupedFileKey).
		SetDetectionProvider(meta.ProviderDetection.Provider).
		SetDetectionReason(meta.ProviderDetection.Reason).
		SetDetectionConfidence(meta.ProviderDetection.Confidence).
		SetStatementHash(meta.StatementHash).
		SetDateStart(meta.DateStart).
		SetDateEnd(meta.DateEnd).
		SetNillableExpectedEntryCount(meta.ExpectedEntryCount).
		SetCreatedAt(now).
		SetUpdatedAt(now).
		OnConflictColumns(importjob.FieldID).
		SetProvider(meta.Provider).
		SetOriginalFilename(meta.OriginalFilename).
		SetInputFilename(meta.InputFilename).
		SetInputFileKey(meta.InputFileKey).
		SetDocumentFileKey(meta.DocumentFileKey).
		SetGeneratedFileKey(meta.GeneratedFileKey).
		SetDedupedFileKey(meta.DedupedFileKey).
		SetDetectionProvider(meta.ProviderDetection.Provider).
		SetDetectionReason(meta.ProviderDetection.Reason).
		SetDetectionConfidence(meta.ProviderDetection.Confidence).
		SetStatementHash(meta.StatementHash).
		SetDateStart(meta.DateStart).
		SetDateEnd(meta.DateEnd).
		SetUpdatedAt(now)
	if meta.ExpectedEntryCount == nil {
		upsert.ClearExpectedEntryCount()
	} else {
		upsert.SetExpectedEntryCount(*meta.ExpectedEntryCount)
	}
	return upsert.Exec(ctx)
}

func (r *entImportStateRepository) Job(ctx context.Context, importID string) (importMeta, error) {
	row, err := r.client.ImportJob.Query().Where(importjob.IDEQ(importID)).Only(ctx)
	if ent.IsNotFound(err) {
		return importMeta{}, os.ErrNotExist
	}
	if err != nil {
		return importMeta{}, err
	}
	return importMetaFromEnt(row), nil
}

func (r *entImportStateRepository) SavePreview(ctx context.Context, importID string, state importPreviewState, _ ginH) error {
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := saveImportPreviewState(ctx, tx, importID, state, false); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *entImportStateRepository) Preview(ctx context.Context, importID string) (importPreviewState, ginH, error) {
	row, err := r.client.ImportPreviewState.Query().Where(importpreviewstate.IDEQ(importID)).Only(ctx)
	if ent.IsNotFound(err) {
		return importPreviewState{}, nil, os.ErrNotExist
	}
	if err != nil {
		return importPreviewState{}, nil, err
	}
	warnings, err := r.client.ImportPreviewWarning.Query().Where(importpreviewwarning.ImportIDEQ(importID)).Order(ent.Asc(importpreviewwarning.FieldPosition)).All(ctx)
	if err != nil {
		return importPreviewState{}, nil, err
	}
	state := importPreviewStateFromEnt(row)
	state.Warnings = make([]string, 0, len(warnings))
	for _, warning := range warnings {
		state.Warnings = append(state.Warnings, warning.Message)
	}
	return state, nil, nil
}

func (r *entImportStateRepository) Delete(ctx context.Context, importID string) error {
	_, err := r.client.ImportJob.Delete().Where(importjob.IDEQ(importID)).Exec(ctx)
	return err
}

// Backfill only creates an entirely absent job. It deliberately does not
// update an existing row, so historical runtime JSON never overwrites a job
// that has already become authoritative in PostgreSQL.
func (r *entImportStateRepository) Backfill(ctx context.Context, importID string, meta importMeta, state *importPreviewState) error {
	jobExists, err := r.client.ImportJob.Query().Where(importjob.IDEQ(importID)).Exist(ctx)
	if err != nil {
		return err
	}
	if jobExists {
		if state == nil {
			return nil
		}
		previewExists, err := r.client.ImportPreviewState.Query().Where(importpreviewstate.IDEQ(importID)).Exist(ctx)
		if err != nil || previewExists {
			return err
		}
		tx, err := r.client.Tx(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if err := saveImportPreviewState(ctx, tx, importID, *state, true); err != nil {
			return err
		}
		return tx.Commit()
	}
	tx, err := r.client.Tx(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	now := time.Now().UTC()
	if err := tx.ImportJob.Create().
		SetID(importID).SetProvider(meta.Provider).SetOriginalFilename(meta.OriginalFilename).
		SetInputFilename(meta.InputFilename).SetInputFileKey(meta.InputFileKey).
		SetDocumentFileKey(meta.DocumentFileKey).SetGeneratedFileKey(meta.GeneratedFileKey).
		SetDedupedFileKey(meta.DedupedFileKey).SetDetectionProvider(meta.ProviderDetection.Provider).
		SetDetectionReason(meta.ProviderDetection.Reason).SetDetectionConfidence(meta.ProviderDetection.Confidence).
		SetStatementHash(meta.StatementHash).SetDateStart(meta.DateStart).SetDateEnd(meta.DateEnd).
		SetNillableExpectedEntryCount(meta.ExpectedEntryCount).SetCreatedAt(now).SetUpdatedAt(now).Exec(ctx); err != nil {
		return err
	}
	if state != nil {
		if err := saveImportPreviewState(ctx, tx, importID, *state, true); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func saveImportPreviewState(ctx context.Context, tx *ent.Tx, importID string, state importPreviewState, insertOnly bool) error {
	now := time.Now().UTC()
	create := tx.ImportPreviewState.Create().
		SetID(importID).SetDedupReport(state.DedupReport).SetCandidateCount(state.CandidateCount).
		SetRawRowCount(state.RawRowCount).SetFilteredRowCount(state.FilteredRowCount).
		SetGeneratedCount(state.GeneratedCount).SetExcludedRowCount(state.ExcludedRowCount).
		SetSkippedDuplicateCount(state.SkippedDuplicateCount).SetDateStart(state.DateStart).SetDateEnd(state.DateEnd).
		SetCreatedAt(now).SetUpdatedAt(now)
	if insertOnly {
		if err := create.Exec(ctx); err != nil {
			return err
		}
	} else if err := create.OnConflictColumns(importpreviewstate.FieldID).
		SetDedupReport(state.DedupReport).SetCandidateCount(state.CandidateCount).
		SetRawRowCount(state.RawRowCount).SetFilteredRowCount(state.FilteredRowCount).
		SetGeneratedCount(state.GeneratedCount).SetExcludedRowCount(state.ExcludedRowCount).
		SetSkippedDuplicateCount(state.SkippedDuplicateCount).SetDateStart(state.DateStart).SetDateEnd(state.DateEnd).
		SetUpdatedAt(now).Exec(ctx); err != nil {
		return err
	}
	if _, err := tx.ImportPreviewWarning.Delete().Where(importpreviewwarning.ImportIDEQ(importID)).Exec(ctx); err != nil {
		return err
	}
	for position, message := range state.Warnings {
		if err := tx.ImportPreviewWarning.Create().SetID(importPreviewWarningID(importID, position)).SetImportID(importID).SetPosition(position).SetMessage(message).Exec(ctx); err != nil {
			return err
		}
	}
	return nil
}

func importMetaFromEnt(row *ent.ImportJob) importMeta {
	return importMeta{
		Provider: row.Provider, OriginalFilename: row.OriginalFilename, InputFilename: row.InputFilename,
		InputFileKey: row.InputFileKey, DocumentFileKey: row.DocumentFileKey, GeneratedFileKey: row.GeneratedFileKey,
		DedupedFileKey: row.DedupedFileKey, StatementHash: row.StatementHash, DateStart: row.DateStart, DateEnd: row.DateEnd,
		ExpectedEntryCount: row.ExpectedEntryCount,
		ProviderDetection:  providerDetection{Provider: row.DetectionProvider, Reason: row.DetectionReason, Confidence: row.DetectionConfidence},
	}
}

func importPreviewStateFromEnt(row *ent.ImportPreviewState) importPreviewState {
	return importPreviewState{DedupReport: row.DedupReport, CandidateCount: row.CandidateCount, RawRowCount: row.RawRowCount,
		FilteredRowCount: row.FilteredRowCount, GeneratedCount: row.GeneratedCount, ExcludedRowCount: row.ExcludedRowCount,
		SkippedDuplicateCount: row.SkippedDuplicateCount, DateStart: row.DateStart, DateEnd: row.DateEnd}
}

func importPreviewWarningID(importID string, position int) string {
	return importID + ":" + strconv.Itoa(position)
}

var _ importStateRepository = (*entImportStateRepository)(nil)
