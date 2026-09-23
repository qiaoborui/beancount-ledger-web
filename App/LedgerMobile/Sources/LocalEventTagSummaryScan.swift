import Foundation

/// Complete tag summaries in one descending candidate pass, without retaining
/// any tag's transactions. Native order must equal the legacy stable date sort.
/// The last expense posting encountered determines currency, as in the legacy
/// calculator (including refunds); no FX conversion or alternative totals.
struct LocalEventTagSummaryScan {
    struct Limits {
        var tags = 10_000
        var pages = 10_000
        var bytes = 4 * 1_024 * 1_024
    }
    enum ScanError: Error, Equatable {
        case invalidConfiguration, invalidPage, revision, cursor, order, capacity, failed, completed
    }
    private struct Totals {
        var count = 0
        var expense = 0
        var income = 0
        var currency = "CNY"
        var start: String
        let end: String
    }
    private let revision: String
    private let limits: Limits
    private var values: [String: Totals] = [:]
    private var cursors: Set<String> = []
    private var cursor: String?
    private var previousDate: String?
    private var pages = 0
    private var failed = false
    private var complete = false
    private(set) var retainedBytes = 0
    var retainedTags: Int { values.count }

    init(revision: String, limits: Limits = .init()) throws {
        guard !revision.isEmpty, (0...10_000).contains(limits.tags), (1...10_000).contains(limits.pages),
              (0...4 * 1_024 * 1_024).contains(limits.bytes) else { throw ScanError.invalidConfiguration }
        self.revision = revision; self.limits = limits
        retainedBytes = try LocalTransactionScan.add(512, LocalTransactionScan.stringBytes(revision))
        guard retainedBytes <= limits.bytes else { throw ScanError.capacity }
    }
    mutating func consume(_ page: LedgerTransactionPage, requestedCursor: String?) throws -> [EventTagSummary]? {
        guard !failed else { throw ScanError.failed }
        guard !complete else { throw ScanError.completed }
        do {
            guard page.sensitiveUnlocked, page.transactions.count <= 500 else { throw ScanError.invalidPage }
            guard page.revision == revision else { throw ScanError.revision }
            guard cursor == requestedCursor else { throw ScanError.cursor }
            pages = try LocalTransactionScan.add(pages, 1)
            guard pages <= limits.pages else { throw ScanError.capacity }
            if let next = page.nextCursor {
                guard !next.isEmpty, next.utf8.count <= 1_024, next != requestedCursor, !cursors.contains(next) else { throw ScanError.cursor }
                try charge(LocalTransactionScan.stringBytes(next)); cursors.insert(next)
            }
            for row in page.transactions {
                guard previousDate.map({ $0 >= row.date }) ?? true else { throw ScanError.order }
                if let previousDate { retainedBytes -= try LocalTransactionScan.stringBytes(previousDate) }
                try charge(LocalTransactionScan.stringBytes(row.date)); previousDate = row.date
                // A bounded per-row set avoids double-counting duplicate tags.
                var seen: Set<String> = []
                var rowTagBytes = 0
                var expense = 0, income = 0
                var currency: String?
                guard row.tags?.contains(where: { !$0.isEmpty }) == true else { continue }
                for posting in row.postings {
                    if posting.account.hasPrefix("Expenses:") {
                        expense = try LocalTransactionScan.add(expense, posting.amount)
                        if let value = posting.currency, !value.isEmpty { currency = value }
                    }
                    if posting.account.hasPrefix("Income:") { income = try LocalTransactionScan.add(income, posting.amount) }
                }
                guard income != Int.min else { throw LocalTransactionScan.ScanError.arithmeticOverflow }
                let received = income < 0 ? -income : 0
                for tag in row.tags ?? [] where !tag.isEmpty && !seen.contains(tag) {
                    guard seen.count < limits.tags else { throw ScanError.capacity }
                    rowTagBytes = try LocalTransactionScan.add(rowTagBytes, LocalTransactionScan.stringBytes(tag))
                    guard rowTagBytes <= limits.bytes else { throw ScanError.capacity }
                    seen.insert(tag)
                    if values[tag] == nil {
                        guard values.count < limits.tags else { throw ScanError.capacity }
                        try charge(LocalTransactionScan.add(256, LocalTransactionScan.stringBytes(tag)))
                        try charge(LocalTransactionScan.stringBytes(row.date))
                        try charge(LocalTransactionScan.stringBytes(row.date))
                        try charge(LocalTransactionScan.stringBytes("CNY"))
                        values[tag] = Totals(start: row.date, end: row.date)
                    }
                    var total = values[tag]!
                    total.count = try LocalTransactionScan.add(total.count, 1)
                    total.expense = try LocalTransactionScan.add(total.expense, expense)
                    total.income = try LocalTransactionScan.add(total.income, received)
                    retainedBytes -= try LocalTransactionScan.stringBytes(total.start)
                    try charge(LocalTransactionScan.stringBytes(row.date)); total.start = row.date
                    if let currency {
                        retainedBytes -= try LocalTransactionScan.stringBytes(total.currency)
                        try charge(LocalTransactionScan.stringBytes(currency)); total.currency = currency
                    }
                    values[tag] = total
                }
            }
            cursor = page.nextCursor
            guard cursor == nil else { return nil }
            var result: [EventTagSummary] = []
            for (tag, total) in values {
                let expense = max(0, total.expense)
                let (net, overflow) = expense.subtractingReportingOverflow(total.income)
                guard !overflow else { throw LocalTransactionScan.ScanError.arithmeticOverflow }
                var days = 1
                if let start = LedgerDateRange.parse(total.start), let end = LedgerDateRange.parse(total.end) {
                    let difference = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
                    guard difference != Int.min else { throw LocalTransactionScan.ScanError.arithmeticOverflow }
                    days = max(1, try LocalTransactionScan.add(abs(difference), 1))
                }
                result.append(EventTagSummary(tag: tag, transactionCount: total.count, totalExpense: expense,
                    totalIncome: total.income, netSpend: max(0, net), currency: total.currency,
                    startDate: total.start, endDate: total.end, daysCount: days, dailyAverage: expense / days))
            }
            complete = true
            return result.sorted {
                if $0.endDate != $1.endDate { return ($0.endDate ?? "") > ($1.endDate ?? "") }
                return $0.totalExpense > $1.totalExpense
            }
        } catch {
            failed = true; values.removeAll(); cursors.removeAll(); previousDate = nil; retainedBytes = 0
            throw error
        }
    }
    private mutating func charge(_ bytes: Int) throws {
        let next = try LocalTransactionScan.add(retainedBytes, bytes)
        guard next <= limits.bytes else { throw ScanError.capacity }
        retainedBytes = next
    }
}
