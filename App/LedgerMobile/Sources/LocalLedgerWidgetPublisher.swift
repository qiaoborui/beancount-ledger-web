import Foundation

/// Builds widget data through the device repository. Callers own the active-ledger
/// and explicit privacy authorization, including background authorization.
enum LocalLedgerWidgetPublisher {
    struct PreparedSnapshot: Sendable {
        let ledgerID: UUID
        let revisionID: UUID
        let snapshot: LedgerWidgetSnapshot
        let attemptedAt: Date
    }

    enum PublicationError: Error, Equatable {
        case revisionChanged
    }

    static func prepare(
        repository: LocalLedgerRepository,
        valuationCurrency: String,
        now: Date = Date()
    ) async throws -> PreparedSnapshot {
        try Task.checkCancellation()
        guard let revision = try await repository.workspace.currentRevision() else {
            throw LocalLedgerWorkspace.WorkspaceError.missingRevision
        }
        let month = LedgerDateRange.current(.month, now: now)
        let today = LedgerDateRange.today(now: now)
        let weekStart = LedgerWidgetDates.weekStart(today)
        let year = Int(today.prefix(4)) ?? 2026
        let ledger = try await repository.bootstrap(start: month.start, end: month.queryEndExclusive,
            today: today, valuationCurrency: valuationCurrency)
        try Task.checkCancellation()
        let report = try await repository.homeReport(start: month.start, end: month.queryEndExclusive,
            valuationCurrency: valuationCurrency)
        try Task.checkCancellation()
        let week = try await repository.homeReport(start: weekStart,
            end: LedgerWidgetDates.adding(7, to: weekStart), valuationCurrency: valuationCurrency)
        try Task.checkCancellation()
        let annual = try await repository.homeReport(start: "\(year)-01-01", end: "\(year + 1)-01-01",
            valuationCurrency: valuationCurrency)
        try Task.checkCancellation()
        let history = try await repository.homeReport(start: LedgerWidgetDates.adding(-77, to: weekStart),
            end: LedgerWidgetDates.adding(1, to: today), valuationCurrency: valuationCurrency)
        try Task.checkCancellation()
        let imports = try await repository.importDocuments()
        try Task.checkCancellation()
        // Every repository read pins an immutable generation. Unique revision IDs
        // let this final check reject any collection spanning a concurrent commit.
        guard try await repository.workspace.currentRevision()?.id == revision.id else {
            throw PublicationError.revisionChanged
        }
        var snapshot = LedgerWidgetSnapshotBuilder.make(report: report, ledger: ledger,
            importDocuments: imports, importsUpdatedAt: now, fallbackDate: now)
        snapshot.insights = LedgerWidgetExpenseInsights(
            updatedAt: ISO8601DateFormatter().string(from: now),
            week: LedgerWidgetSnapshotBuilder.make(report: week, ledger: ledger, fallbackDate: now).expense,
            year: LedgerWidgetSnapshotBuilder.make(report: annual, ledger: ledger, fallbackDate: now).expense,
            history: LedgerWidgetSnapshotBuilder.make(report: history, ledger: ledger, fallbackDate: now).expense
        )
        return PreparedSnapshot(ledgerID: repository.descriptor.id, revisionID: revision.id,
            snapshot: snapshot, attemptedAt: now)
    }

    /// The caller's authorization and save share one MainActor turn. A ledger
    /// switch or explicit lock on that actor therefore cannot repopulate its cache.
    @MainActor
    @discardableResult
    static func publish(
        _ prepared: PreparedSnapshot,
        repository: LocalLedgerRepository,
        store: LedgerWidgetSnapshotStore = .shared,
        isAuthorized: @MainActor () -> Bool
    ) async throws -> Bool {
        guard prepared.ledgerID == repository.descriptor.id, isAuthorized() else { return false }
        let revision = try await repository.workspace.currentRevision()
        try Task.checkCancellation()
        guard revision?.id == prepared.revisionID, isAuthorized() else { return false }
        return try store.saveIfNewer(prepared.snapshot, attemptedAt: prepared.attemptedAt)
    }

    @MainActor
    @discardableResult
    static func refresh(
        repository: LocalLedgerRepository,
        valuationCurrency: String,
        store: LedgerWidgetSnapshotStore = .shared,
        now: Date = Date(),
        isAuthorized: @MainActor () -> Bool
    ) async throws -> Bool {
        guard isAuthorized() else { return false }
        let prepared = try await prepare(repository: repository, valuationCurrency: valuationCurrency, now: now)
        return try await publish(prepared, repository: repository, store: store, isAuthorized: isAuthorized)
    }
}
