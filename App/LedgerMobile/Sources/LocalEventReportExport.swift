import Foundation

/// Caller-owned protected full event Markdown. The first pass completes all
/// aggregates; the second emits every tagged transaction. No partial UI window
/// can supply the export count or replace the complete second pass.
@MainActor
final class LocalEventReportExport: Identifiable {
    let id = UUID()
    let url: URL
    let count: Int
    let revisionID: UUID
    private let file: TransactionShareFile

    private init(url: URL, count: Int, revisionID: UUID, file: TransactionShareFile) {
        self.url = url; self.count = count; self.revisionID = revisionID; self.file = file
    }
    func discard() { file.discard() }

    static func prepare(repository: LocalLedgerRepository, tag: String, start: String, end: String,
                        expectedRevisionID: UUID, accountLabels: [String: String], parentDirectory: URL,
                        adopt: @MainActor (LocalEventReportExport) -> Void = { _ in },
                        validate: @MainActor () throws -> Void) async throws -> LocalEventReportExport {
        try validate(); try Task.checkCancellation()
        let report = try await repository.eventTagReport(tag: tag, start: start, end: end,
            accountLabels: accountLabels, expectedRevisionID: expectedRevisionID)
        try validate(); try Task.checkCancellation()
        var sink: TransactionShareFile?
        var reader: LocalTransactionWindow?
        do {
            let file = try TransactionShareFile(parentDirectory: parentDirectory)
            sink = file
            var formatter = try EventReportMarkdownStream(summary: report.summary, categories: report.categoryBreakdown)
            let windowReader = try await repository.makeTransactionWindow(start: start, end: end,
                filter: .init(tags: [tag]), expectedRevisionID: expectedRevisionID, limits: .init(maxRows: 100))
            reader = windowReader
            while true {
                try validate(); try Task.checkCancellation()
                let window = try await windowReader.nextWindow()
                try validate(); try Task.checkCancellation()
                guard window.revision == report.revision else { throw LocalLedgerError.staleTransactionCursor }
                for transaction in window.transactions {
                    try Task.checkCancellation()
                    try formatter.append(transaction, write: file.append)
                }
                if window.isComplete { break }
            }
            await windowReader.invalidate()
            try formatter.finish(write: file.append)
            let current = try await repository.workspace.currentRevision()
            try validate(); try Task.checkCancellation()
            guard current?.id == expectedRevisionID else { throw LocalLedgerWorkspace.WorkspaceError.staleRevision }
            let export = LocalEventReportExport(url: try file.finish(), count: report.summary.transactionCount,
                revisionID: expectedRevisionID, file: file)
            // Adopt before any async caller can resume, closing the completed-file
            // ownership gap on lock/revision/dismissal.
            adopt(export)
            return export
        } catch {
            sink?.discard()
            await reader?.invalidate()
            throw error
        }
    }
}
