import Foundation

/// Complete native search-candidate scan with a bounded, globally sorted window.
/// Candidate order is NOT the Swift date+ID result order. Scan to EOF before
/// publishing counts or the best window; never sort just the first native page.
/// Anchors require unique revision-local source IDs and are scoped to revision,
/// query, scope, filters and account labels by the adapter, not reusable cursors.
/// The byte cap applies to provisional top-K state too: fail explicitly rather
/// than retain oversized candidates or silently return a shorter window. Thus an
/// encounter order can conservatively fail even if its final top-K would fit.
struct LocalGlobalSearchScan {
    struct Anchor: Equatable, Sendable {
        let date: String
        let id: String
        init(_ row: LedgerTransaction) { date = row.date; id = row.id }
        func precedes(_ row: LedgerTransaction) -> Bool {
            date == row.date ? id < row.id : date > row.date
        }
    }
    struct Limits: Sendable {
        var rows = 100
        var rowBytes = 4 * 1_024 * 1_024
        var stateBytes = 4 * 1_024 * 1_024
        var pages = 10_000
        var tags = 10_000
        var accounts = 10_000
    }
    struct Result: Sendable {
        let revision: String
        let matchedCount: Int
        let remainingCount: Int
        let transactions: [LedgerTransaction]
        let tags: [String]
        let continuation: Anchor?
        let rowBytes: Int
        let stateBytes: Int
    }
    enum ScanError: Error, Equatable {
        case invalidConfiguration, invalidPage, revisionMismatch, cursor, capacity, failed, completed
    }
    private let revision: String
    private let query: String
    private let filters: LedgerGlobalSearchFilters
    private let labels: [String: String]
    private let scope: LedgerGlobalSearchScope
    private let after: Anchor?
    private let limits: Limits
    private let enabled: Bool
    private var rows: [(row: LedgerTransaction, bytes: Int)] = []
    private var tags: Set<String> = []
    private var cursors: Set<String> = []
    private var cursor: String?
    private var pageCount = 0
    private var matchedCount = 0
    private var remainingCount = 0
    private(set) var rowBytes = 0
    private(set) var stateBytes = 0
    private var failed = false
    private var completed = false

    init(revision: String, query: String, accounts: [LedgerAccount],
         scope: LedgerGlobalSearchScope = .all, filters: LedgerGlobalSearchFilters = .init(),
         after: Anchor? = nil, limits: Limits = .init()) throws {
        guard !revision.isEmpty, (1...1_000).contains(limits.rows),
              (0...4 * 1_024 * 1_024).contains(limits.rowBytes),
              (0...4 * 1_024 * 1_024).contains(limits.stateBytes),
              (1...10_000).contains(limits.pages), (0...10_000).contains(limits.tags),
              (0...10_000).contains(limits.accounts), accounts.count <= limits.accounts else {
            throw ScanError.invalidConfiguration
        }
        self.revision = revision; self.query = query; self.scope = scope
        self.filters = filters; self.after = after; self.limits = limits
        enabled = !(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && scope == .all && filters.isEmpty)
            && !(filters.startDate != nil && filters.endDate != nil && filters.startDate! > filters.endDate!)
        var bytes = 512
        for text in [revision, query, filters.account, filters.tag, filters.startDate, filters.endDate, after?.date, after?.id].compactMap({ $0 }) {
            bytes = try LocalTransactionScan.add(bytes, LocalTransactionScan.stringBytes(text))
        }
        var labels: [String: String] = [:]
        for account in accounts where labels[account.account] == nil {
            let label = account.label + " " + (account.alias ?? "")
            bytes = try LocalTransactionScan.add(bytes, LocalTransactionScan.stringBytes(account.account))
            bytes = try LocalTransactionScan.add(bytes, LocalTransactionScan.stringBytes(label))
            guard bytes <= limits.stateBytes else { throw ScanError.capacity }
            labels[account.account] = label
        }
        guard bytes <= limits.stateBytes else { throw ScanError.capacity }
        self.labels = labels; stateBytes = bytes
    }

    mutating func consume(_ page: LedgerTransactionPage, requestedCursor: String?) throws -> Result? {
        guard !failed else { throw ScanError.failed }
        guard !completed else { throw ScanError.completed }
        do {
            guard page.sensitiveUnlocked, page.transactions.count <= 500 else { throw ScanError.invalidPage }
            guard page.revision == revision else { throw ScanError.revisionMismatch }
            guard requestedCursor == cursor else { throw ScanError.cursor }
            pageCount = try LocalTransactionScan.add(pageCount, 1)
            guard pageCount <= limits.pages else { throw ScanError.capacity }
            if let next = page.nextCursor {
                guard !next.isEmpty, next.utf8.count <= 1_024, !cursors.contains(next), next != requestedCursor else { throw ScanError.cursor }
                try charge(LocalTransactionScan.stringBytes(next))
                cursors.insert(next)
            }
            for row in page.transactions where enabled && filters.includes(row) {
                // Tag search is independent of the transaction query match.
                if scope == .all {
                    for tag in row.tags ?? [] where (filters.tag == nil || filters.tag == tag)
                        && (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || LedgerGlobalSearch.matches("#" + tag, query: query)) {
                        if !tags.contains(tag) {
                            guard tags.count < limits.tags else { throw ScanError.capacity }
                            try charge(LocalTransactionScan.stringBytes(tag))
                            tags.insert(tag)
                        }
                    }
                }
                guard scope == .all || scope == .transactions,
                      LedgerGlobalSearch.transactionMatches(row, query: query, labels: labels) else { continue }
                matchedCount = try LocalTransactionScan.add(matchedCount, 1)
                guard after?.precedes(row) ?? true else { continue }
                remainingCount = try LocalTransactionScan.add(remainingCount, 1)
                // Binary insertion into a small top-K buffer; never collect all matches.
                var lower = 0, upper = rows.count
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if LedgerGlobalSearch.transactionPrecedes(row, rows[middle].row) { upper = middle }
                    else { lower = middle + 1 }
                }
                guard lower < limits.rows else { continue }
                let bytes = try LocalTransactionScan.transactionBytes(row)
                if rows.count == limits.rows { rowBytes -= rows.removeLast().bytes }
                let total = try LocalTransactionScan.add(rowBytes, bytes)
                guard total <= limits.rowBytes else { throw ScanError.capacity }
                rows.insert((row, bytes), at: lower); rowBytes = total
            }
            cursor = page.nextCursor
            guard cursor == nil else { return nil }
            completed = true
            return Result(revision: revision, matchedCount: matchedCount, remainingCount: remainingCount,
                transactions: rows.map(\.row), tags: tags.sorted(),
                continuation: remainingCount > rows.count ? rows.last.map { Anchor($0.row) } : nil,
                rowBytes: rowBytes, stateBytes: stateBytes)
        } catch {
            failed = true; rows.removeAll(); tags.removeAll(); cursors.removeAll(); rowBytes = 0
            throw error
        }
    }

    private mutating func charge(_ bytes: Int) throws {
        let total = try LocalTransactionScan.add(stateBytes, bytes)
        guard total <= limits.stateBytes else { throw ScanError.capacity }
        stateBytes = total
    }
}
