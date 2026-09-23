import Foundation

/// Caller-owned export, not a session cache. The lifecycle owner must discard
/// this value on lock/revision change/dismissal, including after publication.
@MainActor
final class LocalTransactionShareExport {
    let url: URL
    let count: Int
    let revisionID: UUID
    private let file: TransactionShareFile

    private init(url: URL, count: Int, revisionID: UUID, file: TransactionShareFile) {
        self.url = url
        self.count = count
        self.revisionID = revisionID
        self.file = file
    }

    func discard() { file.discard() }

    /// Two passes preserve the exact legacy count/date header without retaining
    /// selected rows. `selectedIDs == nil` means the entire filtered range; an
    /// empty set means none. IDs are caller-owned existing selection state, not
    /// gathered from a visible window. This adapter does not cap or truncate it.
    static func prepare(repository: LocalLedgerRepository, start: String, end: String,
                        filter: LedgerTransactionFilter, selectedIDs: Set<String>?,
                        expectedRevisionID: UUID, currency: String, accountLabels: [String: String],
                        parentDirectory: URL, adopt: @MainActor (LocalTransactionShareExport) -> Void = { _ in },
                        validate: @MainActor () throws -> Void) async throws -> LocalTransactionShareExport {
        try validate()
        try Task.checkCancellation()
        let first = try await repository.makeTransactionWindow(start: start, end: end,
            filter: filter, expectedRevisionID: expectedRevisionID, limits: .init(maxRows: 100))
        var second: LocalTransactionWindow?
        var file: TransactionShareFile?
        do {
            try validate()
            var count = 0
            var firstDate: String?, lastDate: String?, nativeRevision: String?
            while true {
                try Task.checkCancellation()
                let window = try await first.nextWindow()
                try validate()
                nativeRevision = window.revision
                for row in window.transactions where selectedIDs?.contains(row.id) ?? true {
                    if count == 0 { firstDate = row.date }
                    guard lastDate == nil || row.date <= lastDate! else {
                        throw TransactionShareTextStream.StreamError.invalidOrder
                    }
                    lastDate = row.date
                    let (total, overflow) = count.addingReportingOverflow(1)
                    guard !overflow else { throw TransactionShareTextStream.StreamError.countMismatch }
                    count = total
                }
                if window.isComplete { break }
            }
            await first.invalidate()
            try validate()
            try Task.checkCancellation()
            let sink = try TransactionShareFile(parentDirectory: parentDirectory)
            file = sink
            var formatter = try TransactionShareTextStream(summary: .init(count: count,
                firstDate: firstDate, lastDate: lastDate), currency: currency, accountLabels: accountLabels)
            let reader = try await repository.makeTransactionWindow(start: start, end: end,
                filter: filter, expectedRevisionID: expectedRevisionID, limits: .init(maxRows: 100))
            second = reader
            try validate()
            while true {
                try Task.checkCancellation()
                let window = try await reader.nextWindow()
                try validate()
                guard window.revision == nativeRevision else { throw LocalLedgerError.staleTransactionCursor }
                for row in window.transactions where selectedIDs?.contains(row.id) ?? true {
                    try Task.checkCancellation()
                    try formatter.append(row, write: sink.append)
                }
                if window.isComplete { break }
            }
            await reader.invalidate()
            try formatter.finish(write: sink.append)
            let revision = try await repository.workspace.currentRevision()
            try validate()
            try Task.checkCancellation()
            guard revision?.id == expectedRevisionID else { throw LocalLedgerWorkspace.WorkspaceError.staleRevision }
            // No await between final owner checks and publishing the complete file.
            let url = try sink.finish()
            let export = LocalTransactionShareExport(url: url, count: count, revisionID: expectedRevisionID, file: sink)
            // Transfer revocation ownership synchronously before an async caller
            // can suspend receiving this completed result.
            adopt(export)
            return export
        } catch {
            file?.discard()
            await first.invalidate()
            await second?.invalidate()
            throw error
        }
    }
}
