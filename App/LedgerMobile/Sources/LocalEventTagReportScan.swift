import Foundation

/// Complete report aggregates, independent of its transaction window/export.
/// Native candidate order must match the legacy stable descending date order.
/// No transaction rows survive consume(); capacities fail the entire report.
struct LocalEventTagReportScan {
    struct Limits {
        var categories = 10_000
        var days = 4_096
        var bytes = 4 * 1_024 * 1_024
    }
    struct Result: Sendable {
        let revision: String
        let summary: EventTagSummary
        let categoryBreakdown: [EventTagCategoryBreakdown]
        let dailySeries: [EventTagDailyPoint]
    }
    enum ScanError: Error, Equatable {
        case invalidConfiguration, capacity, failed, completed
    }
    private let tag: String
    private let revision: String
    private let labels: [String: String]
    private let limits: Limits
    // Reuse checked totals, currency/date semantics and bounded cursor validation.
    // Matching candidates are projected to one internal tag (even for empty tags).
    private var summary: LocalEventTagSummaryScan?
    private var categories: [String: Int] = [:]
    private var days: [String: Int] = [:]
    private var failed = false
    private var complete = false
    private(set) var retainedBytes = 0
    var retainedCategories: Int { categories.count }
    var retainedDays: Int { days.count }
    /// Nested cursor/summary state has its own <=4MiB budget, separate from
    /// aggregate/output accounting. Neither counter measures allocator RSS.
    var summaryRetainedBytes: Int { summary?.retainedBytes ?? 0 }

    init(revision: String, tag: String, accountLabels: [String: String] = [:], limits: Limits = .init()) throws {
        guard (0...10_000).contains(limits.categories), (0...4_096).contains(limits.days),
              (0...4 * 1_024 * 1_024).contains(limits.bytes), accountLabels.count <= 10_000 else {
            throw ScanError.invalidConfiguration
        }
        self.revision = revision; self.tag = tag; self.labels = accountLabels; self.limits = limits
        summary = try LocalEventTagSummaryScan(revision: revision, limits: .init(tags: 1))
        retainedBytes = try LocalTransactionScan.add(512, LocalTransactionScan.stringBytes(tag))
        retainedBytes = try LocalTransactionScan.add(retainedBytes, LocalTransactionScan.stringBytes(revision))
        for (account, label) in accountLabels {
            retainedBytes = try LocalTransactionScan.add(retainedBytes, LocalTransactionScan.stringBytes(account))
            retainedBytes = try LocalTransactionScan.add(retainedBytes, LocalTransactionScan.stringBytes(label))
        }
        guard retainedBytes <= limits.bytes else { throw ScanError.capacity }
    }

    mutating func consume(_ page: LedgerTransactionPage, requestedCursor: String?) throws -> Result? {
        guard !failed else { throw ScanError.failed }
        guard !complete else { throw ScanError.completed }
        do {
            // Validate the original envelope/row bound before projecting it.
            guard page.transactions.count <= 500 else { throw LocalEventTagSummaryScan.ScanError.invalidPage }
            let projected = page.transactions.map { row in
                LedgerTransaction(date: row.date, payee: "", narration: "",
                    tags: (row.tags ?? []).contains(tag) ? ["report"] : [],
                    postings: row.postings, source: row.source)
            }
            let totals = try summary?.consume(.init(revision: page.revision, transactions: projected,
                nextCursor: page.nextCursor, sensitiveUnlocked: page.sensitiveUnlocked), requestedCursor: requestedCursor)
            for row in page.transactions where (row.tags ?? []).contains(tag) {
                var expense = 0
                for posting in row.postings where posting.account.hasPrefix("Expenses:") {
                    expense = try LocalTransactionScan.add(expense, posting.amount)
                    if categories[posting.account] == nil {
                        guard categories.count < limits.categories else { throw ScanError.capacity }
                        try charge(LocalTransactionScan.stringBytes(posting.account))
                    }
                    categories[posting.account] = try LocalTransactionScan.add(categories[posting.account] ?? 0, posting.amount)
                }
                // Legacy omits a zero-net transaction's day, but retains days
                // whose nonzero transactions subsequently cancel each other.
                if expense != 0 {
                    if days[row.date] == nil {
                        guard days.count < limits.days else { throw ScanError.capacity }
                        try charge(LocalTransactionScan.stringBytes(row.date))
                    }
                    days[row.date] = try LocalTransactionScan.add(days[row.date] ?? 0, expense)
                }
            }
            guard let totals else { return nil }
            let total = totals.first
            var positiveTotal = 0
            for value in categories.values where value > 0 {
                positiveTotal = try LocalTransactionScan.add(positiveTotal, value)
            }
            // Output is independently bounded by the group caps; charge labels
            // and output elements as well as the retained aggregate keys.
            var breakdown: [EventTagCategoryBreakdown] = []
            for (account, amount) in categories where amount > 0 {
                let label = labels[account] ?? account.replacingOccurrences(of: "Expenses:", with: "")
                try charge(LocalTransactionScan.add(128, LocalTransactionScan.stringBytes(label)))
                breakdown.append(.init(account: account, label: label, amount: amount,
                    percentage: positiveTotal > 0 ? Double(amount) / Double(positiveTotal) : 0))
            }
            breakdown.sort { $0.amount > $1.amount }
            for date in days.keys {
                try charge(LocalTransactionScan.add(128, LocalTransactionScan.stringBytes(date)))
            }
            try charge(256)
            for value in [tag, total?.currency ?? "CNY", total?.startDate, total?.endDate].compactMap({ $0 }) {
                try charge(LocalTransactionScan.stringBytes(value))
            }
            let daily = days.map { EventTagDailyPoint(date: $0.key, amount: max(0, $0.value)) }.sorted { $0.date < $1.date }
            let result = Result(revision: revision,
                summary: .init(tag: tag, transactionCount: total?.transactionCount ?? 0,
                    totalExpense: total?.totalExpense ?? 0, totalIncome: total?.totalIncome ?? 0,
                    netSpend: total?.netSpend ?? 0, currency: total?.currency ?? "CNY",
                    startDate: total?.startDate, endDate: total?.endDate,
                    daysCount: total?.daysCount ?? 0, dailyAverage: total?.dailyAverage ?? 0),
                categoryBreakdown: breakdown, dailySeries: daily)
            complete = true
            categories.removeAll(); days.removeAll(); summary = nil
            return result
        } catch {
            failed = true; categories.removeAll(); days.removeAll(); summary = nil; retainedBytes = 0
            throw error
        }
    }
    private mutating func charge(_ bytes: Int) throws {
        let next = try LocalTransactionScan.add(retainedBytes, bytes)
        guard next <= limits.bytes else { throw ScanError.capacity }
        retainedBytes = next
    }
}
