import Foundation

/// Same tabs/reason membership as PendingInboxView, without loaded-page counts.
enum LedgerPendingFilter: String, CaseIterable, Sendable {
    case all, uncategorized, needsReview, missingPayee
    func includes(_ reasons: [PendingTransactionReason]) -> Bool {
        switch self {
        case .all: return !reasons.isEmpty
        case .uncategorized: return reasons.contains { if case .uncategorized = $0 { return true }; return false }
        case .needsReview: return reasons.contains {
            if case .needsReviewFlag = $0 { return true }
            if case .pendingTag = $0 { return true }
            return false
        }
        case .missingPayee: return reasons.contains(.missingPayee)
        }
    }
}

/// Consumes full-range pending candidates in the legacy native order. Returns
/// complete counts/amount/account choices and only one selected row window at
/// EOF. The adapter must pin revision/filter for offset replay. No whole-history
/// IDs/rows are retained; explicit capacity errors never imply an empty inbox.
struct LocalPendingScan {
    struct Limits {
        var rows = 100
        var rowBytes = 4 * 1_024 * 1_024
        var accounts = 10_000
        var pages = 10_000
        var stateBytes = 4 * 1_024 * 1_024
    }
    struct Result: Sendable {
        let revision: String
        let counts: [LedgerPendingFilter: Int]
        let totalMinorUnits: Int
        let expenseAccounts: [String]
        let transactions: [LedgerTransaction]
        let nextOffset: Int?
        var totalCount: Int { counts[.all] ?? 0 }
    }
    enum ScanError: Error, Equatable {
        case invalidConfiguration, invalidPage, revision, cursor, order, capacity, offset, failed, completed
    }
    private let revision: String
    private let filter: LedgerPendingFilter
    private let offset: Int
    private let limits: Limits
    private var counts: [LedgerPendingFilter: Int] = [:]
    private var total = 0
    private var accounts: Set<String> = []
    private var cursors: Set<String> = []
    private var cursor: String?
    private var previousDate: String?
    private var pages = 0
    private var matched = 0
    private var rows: [LedgerTransaction] = []
    private var failed = false
    private var complete = false
    private(set) var rowBytes = 0
    private(set) var stateBytes = 0

    init(revision: String, filter: LedgerPendingFilter = .all, offset: Int = 0,
         declaredAccounts: [String] = [], limits: Limits = .init()) throws {
        guard !revision.isEmpty, offset >= 0, (1...1_000).contains(limits.rows),
              (0...4 * 1_024 * 1_024).contains(limits.rowBytes),
              (0...10_000).contains(limits.accounts), (1...10_000).contains(limits.pages),
              (0...4 * 1_024 * 1_024).contains(limits.stateBytes) else { throw ScanError.invalidConfiguration }
        self.revision = revision; self.filter = filter; self.offset = offset; self.limits = limits
        stateBytes = try LocalTransactionScan.add(512, LocalTransactionScan.stringBytes(revision))
        guard stateBytes <= limits.stateBytes else { throw ScanError.capacity }
        for account in declaredAccounts where account.hasPrefix("Expenses:") { try addAccount(account) }
    }

    mutating func consume(_ page: LedgerTransactionPage, requestedCursor: String?) throws -> Result? {
        guard !failed else { throw ScanError.failed }
        guard !complete else { throw ScanError.completed }
        do {
            guard page.sensitiveUnlocked, page.transactions.count <= 500,
                  page.transactions.allSatisfy({ $0.pendingReviewFlag != nil && $0.editableEntry == nil }) else { throw ScanError.invalidPage }
            guard page.revision == revision else { throw ScanError.revision }
            guard requestedCursor == cursor else { throw ScanError.cursor }
            pages = try LocalTransactionScan.add(pages, 1)
            guard pages <= limits.pages else { throw ScanError.capacity }
            if let next = page.nextCursor {
                guard !next.isEmpty, next.utf8.count <= 1_024, next != requestedCursor, !cursors.contains(next) else { throw ScanError.cursor }
                try charge(LocalTransactionScan.stringBytes(next)); cursors.insert(next)
            }
            for row in page.transactions {
                guard previousDate.map({ $0 >= row.date }) ?? true else { throw ScanError.order }
                if let previousDate { stateBytes -= try LocalTransactionScan.stringBytes(previousDate) }
                try charge(LocalTransactionScan.stringBytes(row.date)); previousDate = row.date
                for posting in row.postings where posting.account.hasPrefix("Expenses:") { try addAccount(posting.account) }
                let reasons = row.pendingReasons
                guard !reasons.isEmpty else { continue }
                // Evaluate precisely the branches reached by the legacy amount
                // presentation before constructing it; avoid all integer traps.
                _ = try LocalTransactionScan.checkedExpense(row)
                total = try LocalTransactionScan.add(total, TransactionPresentation(transaction: row).minorUnits)
                for tab in LedgerPendingFilter.allCases where tab.includes(reasons) {
                    counts[tab] = try LocalTransactionScan.add(counts[tab] ?? 0, 1)
                }
                guard filter.includes(reasons) else { continue }
                matched = try LocalTransactionScan.add(matched, 1)
                guard matched > offset, rows.count < limits.rows else { continue }
                let bytes = try LocalTransactionScan.add(rowBytes, LocalTransactionScan.transactionBytes(row))
                guard bytes <= limits.rowBytes else { throw ScanError.capacity }
                rowBytes = bytes; rows.append(row)
            }
            cursor = page.nextCursor
            guard cursor == nil else { return nil }
            guard offset == 0 || offset < matched else { throw ScanError.offset }
            let consumed = try LocalTransactionScan.add(offset, rows.count)
            let result = Result(revision: revision, counts: counts, totalMinorUnits: total,
                expenseAccounts: accounts.sorted(), transactions: rows, nextOffset: consumed < matched ? consumed : nil)
            complete = true
            rows.removeAll(); accounts.removeAll(); cursors.removeAll()
            return result
        } catch {
            failed = true; rows.removeAll(); accounts.removeAll(); cursors.removeAll()
            rowBytes = 0; stateBytes = 0
            throw error
        }
    }
    private mutating func addAccount(_ account: String) throws {
        guard !accounts.contains(account) else { return }
        guard accounts.count < limits.accounts else { throw ScanError.capacity }
        try charge(LocalTransactionScan.stringBytes(account)); accounts.insert(account)
    }
    private mutating func charge(_ bytes: Int) throws {
        let total = try LocalTransactionScan.add(stateBytes, bytes)
        guard total <= limits.stateBytes else { throw ScanError.capacity }
        stateBytes = total
    }
}
