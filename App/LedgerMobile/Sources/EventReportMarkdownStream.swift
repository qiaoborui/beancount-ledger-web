import Foundation

/// Exact legacy event Markdown, emitted in <=16KiB UTF-8 chunks. The caller
/// supplies complete aggregates and then every matching transaction in native
/// stable date-descending order. A failure poisons the stream; discard its sink.
/// No complete Markdown string or transaction history is retained here.
struct EventReportMarkdownStream {
    enum StreamError: Error, Equatable {
        case invalidSummary, mismatch, order, failed, finished
    }
    private let summary: EventTagSummary
    private let categories: [EventTagCategoryBreakdown]
    private var count = 0
    private var lastDate: String?
    private var started = false
    private var complete = false
    private var failed = false

    init(summary: EventTagSummary, categories: [EventTagCategoryBreakdown]) throws {
        guard summary.transactionCount >= 0, summary.totalExpense >= 0, summary.totalIncome >= 0,
              summary.netSpend >= 0, summary.dailyAverage >= 0,
              summary.transactionCount == 0
                ? (summary.startDate == nil && summary.endDate == nil && summary.daysCount == 0)
                : (summary.startDate != nil && summary.endDate != nil && summary.startDate! <= summary.endDate! && summary.daysCount > 0),
              categories.count <= 10_000,
              categories.allSatisfy({ $0.amount > 0 && $0.percentage.isFinite && (0...1).contains($0.percentage) }) else {
            throw StreamError.invalidSummary
        }
        self.summary = summary; self.categories = categories
    }

    mutating func append(_ transaction: LedgerTransaction, write: (Data) throws -> Void) throws {
        guard !failed else { throw StreamError.failed }
        guard !complete else { throw StreamError.finished }
        do {
            guard count < summary.transactionCount, (transaction.tags ?? []).contains(summary.tag) else { throw StreamError.mismatch }
            guard transaction.date <= (lastDate ?? summary.endDate!), transaction.date >= summary.startDate!,
                  count != 0 || transaction.date == summary.endDate else { throw StreamError.order }
            _ = try LocalTransactionScan.checkedExpense(transaction)
            if !started { try header(write: write); started = true }
            let value = TransactionPresentation(transaction: transaction)
            let prefix: String
            switch value.kind {
            case .expense: prefix = "−"
            case .income: prefix = "+"
            case .transfer: prefix = ""
            }
            try emit("\n- \(transaction.date) | \(value.title) | \(prefix)\(MoneyText.format(minorUnits: value.minorUnits, currency: value.currency))", write: write)
            count += 1; lastDate = transaction.date
        } catch { failed = true; throw error }
    }

    mutating func finish(write: (Data) throws -> Void) throws {
        guard !failed else { throw StreamError.failed }
        guard !complete else { throw StreamError.finished }
        do {
            guard count == summary.transactionCount, lastDate == summary.startDate else { throw StreamError.mismatch }
            if !started { try header(write: write); started = true }
            complete = true
        } catch { failed = true; throw error }
    }

    private func header(write: (Data) throws -> Void) throws {
        try emit("# 事件核算报告：#\(summary.tag)", write: write)
        if let start = summary.startDate, let end = summary.endDate {
            try emit("\n时间跨度：\(start) ~ \(end)（共 \(summary.daysCount) 天）", write: write)
        }
        try emit("\n净支出：\(MoneyText.format(minorUnits: summary.netSpend, currency: summary.currency))", write: write)
        try emit("\n总支出：\(MoneyText.format(minorUnits: summary.totalExpense, currency: summary.currency))，收入/退款：\(MoneyText.format(minorUnits: summary.totalIncome, currency: summary.currency))", write: write)
        try emit("\n日均消费：\(MoneyText.format(minorUnits: summary.dailyAverage, currency: summary.currency))\n\n## 分类支出", write: write)
        for category in categories {
            try emit("\n- \(category.label)：\(MoneyText.format(minorUnits: category.amount, currency: summary.currency)) (\(String(format: "%.1f%%", category.percentage * 100)))", write: write)
        }
        try emit("\n\n## 交易清单 (\(summary.transactionCount) 笔)", write: write)
    }
    private func emit(_ text: String, write: (Data) throws -> Void) throws {
        var chunk = Data()
        chunk.reserveCapacity(16 * 1_024)
        for byte in text.utf8 {
            chunk.append(byte)
            if chunk.count == 16 * 1_024 { try write(chunk); chunk.removeAll(keepingCapacity: true) }
        }
        if !chunk.isEmpty { try write(chunk) }
    }
}
