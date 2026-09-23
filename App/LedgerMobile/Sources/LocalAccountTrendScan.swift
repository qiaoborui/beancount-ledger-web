import Foundation

/// Complete account-page scan. Retains bounded day closings, never transaction
/// rows. Publication waits for EOF/count/continuity validation; no partial chart.
/// Cursor history is independently page/byte bounded to reject arbitrary cycles;
/// exhausting that explicit budget fails rather than dropping cycle detection.
struct LocalAccountTrendScan {
    struct Result: Sendable {
        let revision: String
        /// Header only: rows deliberately empty, not an empty-history assertion.
        let detail: LedgerAccountDetail
        let rowCount: Int
        let points: [LedgerAccountBalanceTrendPoint]
    }
    enum ScanError: Error, Equatable {
        case invalidConfiguration, invalidPage, scope, cursor, continuity, capacity, failed, completed
    }
    private let range: LedgerDateRange
    private let endExclusive: String
    private let expectedAccount: String
    private let expectedCurrency: String
    private let expectedRevision: String
    private let maxDays: Int
    private let maxBytes: Int
    private let maxPages: Int
    private let maxPoints: Int
    private var header: LedgerAccountDetail?
    private var revision: String?
    private var rowCount: Int?
    private var consumed = 0
    private var pageCount = 0
    private var cursor: String?
    private var cursors: Set<String> = []
    private var days: [LedgerAccountBalanceTrendPoint] = []
    private var previousID: String?
    private var previousBalance: Int?
    private var previousDate: String?
    private var failed = false
    private var completed = false
    private(set) var retainedBytes = 0
    var retainedDays: Int { days.count }

    init(range: LedgerDateRange, account: String, currency: String, revision: String, maxDays: Int = 4_096, maxBytes: Int = 4 * 1_024 * 1_024,
         maxPages: Int = 10_000, maxPoints: Int = 180) throws {
        guard !account.isEmpty, !currency.isEmpty, !revision.isEmpty, (0...4_096).contains(maxDays), (0...4 * 1_024 * 1_024).contains(maxBytes),
              (1...10_000).contains(maxPages), (2...180).contains(maxPoints), range.start <= range.end else {
            throw ScanError.invalidConfiguration
        }
        self.range = range; endExclusive = range.queryEndExclusive; expectedAccount = account; expectedCurrency = currency; expectedRevision = revision
        self.maxDays = maxDays; self.maxBytes = maxBytes
        self.maxPages = maxPages; self.maxPoints = maxPoints
        retainedBytes = try LocalTransactionScan.add(512, LocalTransactionScan.stringBytes(range.start))
        retainedBytes = try LocalTransactionScan.add(retainedBytes, LocalTransactionScan.stringBytes(range.end))
        for text in [account, currency, revision, endExclusive] {
            retainedBytes = try LocalTransactionScan.add(retainedBytes, LocalTransactionScan.stringBytes(text))
        }
        guard retainedBytes <= maxBytes else { throw ScanError.capacity }
    }

    mutating func consume(_ page: LedgerAccountPage, requestedCursor: String?) throws -> Result? {
        guard !failed else { throw ScanError.failed }
        guard !completed else { throw ScanError.completed }
        do {
            guard page.revision == expectedRevision, page.detail.account == expectedAccount,
                  page.detail.currency == expectedCurrency else { throw ScanError.scope }
            guard page.sensitiveUnlocked, !page.revision.isEmpty, page.detail.rows.count <= 500,
                  page.rowCount >= page.detail.rows.count, page.detail.start == range.start,
                  page.detail.end == endExclusive,
                  let opening = page.detail.openingBalance, let closing = page.detail.closingBalance,
                  let change = page.detail.periodChange else { throw ScanError.invalidPage }
            let (calculated, overflow) = closing.subtractingReportingOverflow(opening)
            guard !overflow, calculated == change else { throw ScanError.continuity }
            guard cursor == requestedCursor else { throw ScanError.cursor }
            let current = Self.withoutRows(page.detail)
            if let header {
                guard header == current, revision == page.revision, rowCount == page.rowCount else { throw ScanError.scope }
            } else {
                header = current; revision = page.revision; rowCount = page.rowCount
                for text in [current.account, current.label, current.alias, current.group, current.currency, page.revision].compactMap({ $0 }) {
                    try charge(LocalTransactionScan.stringBytes(text))
                }
                previousBalance = opening
            }
            pageCount = try LocalTransactionScan.add(pageCount, 1)
            guard pageCount <= maxPages else { throw ScanError.capacity }
            if let next = page.nextCursor {
                guard !next.isEmpty, next.utf8.count <= 1_024, next != requestedCursor, !cursors.contains(next),
                      !page.detail.rows.isEmpty else { throw ScanError.cursor }
                try charge(LocalTransactionScan.stringBytes(next)); cursors.insert(next)
            }
            for row in page.detail.rows {
                guard row.date >= range.start, row.date < endExclusive,
                      row.date == row.transaction.date, row.payee == row.transaction.payee,
                      row.narration == row.transaction.narration, previousID != row.id,
                      previousDate.map({ $0 <= row.date }) ?? true else { throw ScanError.continuity }
                let (balance, overflow) = (previousBalance ?? opening).addingReportingOverflow(row.change)
                guard !overflow, balance == row.balance else { throw ScanError.continuity }
                consumed = try LocalTransactionScan.add(consumed, 1)
                guard consumed <= page.rowCount else { throw ScanError.continuity }
                let point = LedgerAccountBalanceTrendPoint(date: row.date, balance: row.balance)
                if days.last?.date == row.date { days[days.count - 1] = point }
                else {
                    guard days.count < maxDays else { throw ScanError.capacity }
                    try charge(LocalTransactionScan.stringBytes(row.date)); days.append(point)
                }
                if let previousID { retainedBytes -= try LocalTransactionScan.stringBytes(previousID) }
                try charge(LocalTransactionScan.stringBytes(row.id))
                previousID = row.id; previousDate = row.date; previousBalance = balance
            }
            cursor = page.nextCursor
            if cursor != nil {
                guard consumed < page.rowCount else { throw ScanError.continuity }
                return nil
            }
            guard consumed == page.rowCount, previousBalance == closing else { throw ScanError.continuity }
            var points = [LedgerAccountBalanceTrendPoint(date: range.start, balance: opening)]
            points.append(contentsOf: days)
            let last = LedgerAccountBalanceTrendPoint(date: range.end, balance: closing)
            if points.last != last { points.append(last) }
            completed = true
            return Result(revision: page.revision, detail: current, rowCount: consumed,
                points: LedgerAccountDetail.downsampledBalanceTrend(points, maxPoints: maxPoints))
        } catch {
            failed = true; header = nil; days.removeAll(); cursors.removeAll(); previousID = nil; retainedBytes = 0
            throw error
        }
    }
    private mutating func charge(_ bytes: Int) throws {
        let total = try LocalTransactionScan.add(retainedBytes, bytes)
        guard total <= maxBytes else { throw ScanError.capacity }
        retainedBytes = total
    }
    private static func withoutRows(_ detail: LedgerAccountDetail) -> LedgerAccountDetail {
        .init(account: detail.account, label: detail.label, alias: detail.alias, group: detail.group,
            active: detail.active, currency: detail.currency, currentBalance: detail.currentBalance, rows: [],
            start: detail.start, end: detail.end, openingBalance: detail.openingBalance,
            closingBalance: detail.closingBalance, periodChange: detail.periodChange)
    }
}
