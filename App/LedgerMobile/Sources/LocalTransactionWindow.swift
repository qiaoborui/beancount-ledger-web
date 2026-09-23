import Foundation

/// Forward-only, exact-Swift matching windows. The provider must capture the workspace
/// UUID and date range, request unfiltered candidates, enforce the bridge's 1 MiB
/// wire limit before decoding, and honour `expectedRevision` on every request.
/// No transaction IDs or cumulative visible array are retained. The owner must call
/// `invalidate()` on lock/workspace/revision changes, including while a candidate
/// page is cached; a pure reader cannot observe external authentication changes.
///
/// Bounds are independent: <=1,000 / 4 MiB visible rows PLUS one <=500 / 8 MiB
/// accounted candidate page (<=1,500 rows / 12 MiB combined), <=10,000 / 4 MiB
/// cursor state, and the scan's separately bounded summary state. Accounting uses
/// LocalTransactionScan, not JSON copies, and is not an allocator/RSS guarantee.
actor LocalTransactionWindow {
    struct Request: Sendable {
        let workspaceID: UUID
        let cursor: String?
        let expectedRevision: String?
        let limit = 500
    }

    typealias Provider = @Sendable (Request) async throws -> LedgerTransactionPage

    struct Limits: Equatable, Sendable {
        var maxRows = 1_000
        var maxBytes = 4 * 1_024 * 1_024
        var maxPages = 10_000
        var maxCursorBytes = 4 * 1_024 * 1_024
    }

    enum WindowError: Error, Equatable {
        case invalidConfiguration, failed, busy, locked, revisionMismatch
        case pageRows, candidateBytes, rowBytes, pages, cursorBytes, repeatedCursor, emptyCursor
        case checkpointBytes, invalidCheckpoint
    }

    /// Owner-side navigation cache. Explicit LRU insertion keeps both anchor
    /// count and accounted bytes bounded; no transaction rows are stored here.
    struct Anchors: Sendable {
        private var values: [(id: Int, checkpoint: Checkpoint)] = []
        private(set) var accountedBytes = 0
        var count: Int { values.count }

        mutating func insert(_ checkpoint: Checkpoint, for id: Int) {
            if let index = values.firstIndex(where: { $0.id == id }) {
                accountedBytes -= values.remove(at: index).checkpoint.accountedBytes
            }
            while values.count >= 32 || accountedBytes + checkpoint.accountedBytes > 64 * 1_024 {
                guard !values.isEmpty else { return }
                accountedBytes -= values.removeFirst().checkpoint.accountedBytes
            }
            values.append((id, checkpoint))
            accountedBytes += checkpoint.accountedBytes
        }

        mutating func checkpoint(for id: Int) -> Checkpoint? {
            guard let index = values.firstIndex(where: { $0.id == id }) else { return nil }
            let value = values.remove(at: index)
            values.append(value)
            return value.checkpoint
        }

        mutating func removeAll() { values = []; accountedBytes = 0 }
    }

    /// Immutable, <=64 KiB, with no candidate rows or cursor-history snapshot.
    /// A caller retaining navigation anchors MUST evict to <=32 anchors / 64 KiB
    /// total `accountedBytes`. The reader itself retains no anchor history.
    /// Resume reconstructs cycle checks by replaying from the start (O(prefix));
    /// it does not ingest replay into the original forward owner's full summary.
    struct Checkpoint: Sendable {
        fileprivate let workspaceID: UUID
        fileprivate let scope: String
        fileprivate let revision: String
        fileprivate let filter: LedgerTransactionFilter
        fileprivate let limits: Limits
        fileprivate let cursor: String?
        fileprivate let offset: Int
        fileprivate let consumed: Int
        let accountedBytes: Int
    }

    struct Window: Sendable {
        let transactions: [LedgerTransaction]
        let accountedBytes: Int
        /// nil means there are no further *matching* rows, including all-empty scans.
        let continuation: Checkpoint?
        let revision: String
        /// Full-range summary only from the original forward owner, only at EOF.
        /// Replay readers deliberately return nil here.
        let summary: LocalTransactionScan.Result?
        var isComplete: Bool { continuation == nil }
    }

    private let workspaceID: UUID
    private let scope: String
    private let filter: LedgerTransactionFilter
    private let limits: Limits
    private let provider: Provider
    private var revision: String?
    private var candidate: LedgerTransactionPage?
    private var sizes: [Int] = []
    private var cursor: String?
    private var offset = 0
    private var consumed = 0
    private var pageCount = 0
    private var cursors: Set<String> = []
    private var cursorBytes = 0
    private var eof = false
    private var failed = false
    private var busy = false
    private var replayTarget: Checkpoint?
    private let ownsSummary: Bool
    private var scan: LocalTransactionScan?
    private var summary: LocalTransactionScan.Result?

    init(workspaceID: UUID, scope: String = "", filter: LedgerTransactionFilter = .init(),
         limits: Limits = .init(), checkpoint: Checkpoint? = nil,
         provider: @escaping Provider) throws {
        guard (1...1_000).contains(limits.maxRows), (1...4 * 1_024 * 1_024).contains(limits.maxBytes),
              (1...10_000).contains(limits.maxPages),
              (1...4 * 1_024 * 1_024).contains(limits.maxCursorBytes) else {
            throw WindowError.invalidConfiguration
        }
        guard scope.utf8.count <= 4_096 else { throw WindowError.invalidConfiguration }
        if let checkpoint {
            guard checkpoint.workspaceID == workspaceID, checkpoint.scope == scope, checkpoint.filter == filter,
                  checkpoint.limits == limits else { throw WindowError.invalidCheckpoint }
        }
        self.workspaceID = workspaceID
        self.scope = scope
        self.filter = filter
        self.limits = limits
        self.provider = provider
        revision = checkpoint?.revision
        replayTarget = checkpoint
        ownsSummary = checkpoint == nil
        // Validate and bound retained filter configuration using the same scan rules.
        var scanLimits = LocalTransactionScan.Limits()
        scanLimits.maxVisibleCount = 0
        _ = try LocalTransactionScan(expectedRevision: "pending", filter: filter, limits: scanLimits)
    }

    /// Revoke cached sensitive rows and reject an in-flight provider response.
    /// The parent must also discard any Window values it already owns.
    func invalidate() {
        failed = true
        candidate = nil
        sizes = []
        cursors = []
        scan = nil
        summary = nil
        replayTarget = nil
    }

    /// Calls must be serial. Concurrent calls fail without poisoning the active call.
    /// All provider/validation/cancellation errors poison this reader; restart from a
    /// previously returned checkpoint instead of publishing partial financial state.
    func nextWindow() async throws -> Window {
        guard !busy else { throw WindowError.busy }
        guard !failed else { throw WindowError.failed }
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            var rows: [LedgerTransaction] = []
            var bytes = 0
            while !eof {
                try Task.checkCancellation()
                if candidate == nil { try await loadPage() }
                guard let page = candidate else { break }
                if let target = replayTarget {
                    guard consumed <= target.consumed else { throw WindowError.invalidCheckpoint }
                    if consumed == target.consumed, cursor == target.cursor, offset == target.offset {
                        replayTarget = nil
                    }
                }
                if offset == page.transactions.count {
                    cursor = page.nextCursor
                    candidate = nil
                    sizes = []
                    offset = 0
                    if cursor == nil { eof = true }
                    continue
                }
                let row = page.transactions[offset]
                if replayTarget == nil, filter.matches(row) {
                    let size = sizes[offset]
                    guard size <= limits.maxBytes else { throw WindowError.rowBytes }
                    // Look through unmatched suffixes/pages before declaring more:
                    // an exactly full final window must still report accurate EOF.
                    if rows.count == limits.maxRows || size > limits.maxBytes - bytes {
                        return Window(transactions: rows, accountedBytes: bytes,
                                      continuation: try checkpoint(), revision: page.revision, summary: nil)
                    }
                    rows.append(row)
                    bytes += size // <= maxBytes, checked before adding
                }
                offset += 1 // <= 500
                consumed += 1 // <= 10,000 pages * 500 rows
            }
            guard replayTarget == nil else { throw WindowError.invalidCheckpoint }
            return Window(transactions: rows, accountedBytes: bytes, continuation: nil,
                          revision: revision ?? "", summary: summary)
        } catch {
            invalidate()
            throw error
        }
    }

    private func loadPage() async throws {
        guard pageCount < limits.maxPages else { throw WindowError.pages }
        let page = try await provider(Request(workspaceID: workspaceID, cursor: cursor, expectedRevision: revision))
        try Task.checkCancellation()
        guard !failed else { throw WindowError.failed }
        guard page.sensitiveUnlocked else { throw WindowError.locked }
        guard !page.revision.isEmpty, revision == nil || page.revision == revision else {
            throw WindowError.revisionMismatch
        }
        guard page.transactions.count <= 500 else { throw WindowError.pageRows }
        if let next = page.nextCursor {
            guard !next.isEmpty else { throw WindowError.emptyCursor }
            guard !cursors.contains(next) else { throw WindowError.repeatedCursor }
            let charge = try Self.stringBytes(next)
            guard charge <= limits.maxCursorBytes - cursorBytes else { throw WindowError.cursorBytes }
            cursorBytes += charge
            cursors.insert(next)
        }
        var pageBytes = try Self.stringBytes(page.revision)
        if let next = page.nextCursor { pageBytes = try Self.add(pageBytes, Self.stringBytes(next)) }
        var rowSizes: [Int] = []
        // Shared accounting and arithmetic rules; no per-row temporary reducer.
        for row in page.transactions {
            try Task.checkCancellation()
            _ = try LocalTransactionScan.checkedExpense(row)
            let size = try LocalTransactionScan.transactionBytes(row)
            pageBytes = try Self.add(pageBytes, size)
            guard pageBytes <= 8 * 1_024 * 1_024 else { throw WindowError.candidateBytes }
            rowSizes.append(size)
        }
        guard pageBytes <= 8 * 1_024 * 1_024 else { throw WindowError.candidateBytes }
        revision = page.revision
        if ownsSummary {
            if scan == nil {
                var scanLimits = LocalTransactionScan.Limits()
                scanLimits.maxVisibleCount = 0
                scanLimits.maxPages = limits.maxPages
                scan = try LocalTransactionScan(expectedRevision: page.revision, filter: filter, limits: scanLimits)
            }
            // Exactly once per raw forward page, never once per visible window.
            summary = try scan?.consume(page, requestedCursor: cursor)
        }
        candidate = page
        sizes = rowSizes
        pageCount += 1
    }

    private func checkpoint() throws -> Checkpoint {
        guard let revision else { throw WindowError.invalidCheckpoint }
        var bytes = try Self.add(256, Self.stringBytes(revision))
        bytes = try Self.add(bytes, Self.stringBytes(scope))
        bytes = try Self.add(bytes, Self.stringBytes(filter.query))
        if let cursor { bytes = try Self.add(bytes, Self.stringBytes(cursor)) }
        if let account = filter.account { bytes = try Self.add(bytes, Self.stringBytes(account)) }
        for tag in filter.tags { bytes = try Self.add(bytes, Self.stringBytes(tag)) }
        guard bytes <= 64 * 1_024 else { throw WindowError.checkpointBytes }
        return Checkpoint(workspaceID: workspaceID, scope: scope, revision: revision, filter: filter, limits: limits,
                          cursor: cursor, offset: offset, consumed: consumed, accountedBytes: bytes)
    }

    private static func stringBytes(_ value: String) throws -> Int { try add(128, value.utf8.count) }
    private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw LocalTransactionScan.ScanError.arithmeticOverflow }
        return value
    }
}
