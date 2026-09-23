import Foundation

struct TransactionShareTextFormatter {
    static func format(
        transactions: [LedgerTransaction],
        currency: String,
        accountLabels: [String: String] = [:]
    ) -> String {
        if transactions.count == 1, let tx = transactions.first {
            let p = TransactionPresentation(transaction: tx)
            let kindStr = p.isRefund ? "退款" : (p.kind == .expense ? "支出" : (p.kind == .income ? "收入" : "转账"))
            let sign = p.isRefund ? "+" : (p.kind == .expense ? "-" : (p.kind == .income ? "+" : ""))
            var lines = [
                "【Ledger 记账凭证】",
                "类型：\(kindStr)",
                "金额：\(sign)\(MoneyText.format(minorUnits: p.minorUnits, currency: p.currency))",
                "时间：\(tx.date)"
            ]
            let desc = tx.payee.isEmpty ? (tx.narration.isEmpty ? p.title : tx.narration) : (tx.narration.isEmpty ? tx.payee : "\(tx.payee) - \(tx.narration)")
            lines.append("描述：\(desc)")

            if !tx.postings.isEmpty {
                lines.append("分录：")
                for posting in tx.postings {
                    let label = accountLabels[posting.account] ?? posting.account
                    let amt = MoneyText.format(minorUnits: abs(posting.amount), currency: posting.currency ?? p.currency)
                    let sign = posting.amount >= 0 ? "+" : "-"
                    lines.append("  · \(label): \(sign)\(amt)")
                }
            }
            if let tags = tx.tags, !tags.isEmpty {
                lines.append("标签：\(tags.map { "#\($0)" }.joined(separator: " "))")
            }
            lines.append("----------------------------")
            lines.append("由 Beancount Ledger 生成")
            return lines.joined(separator: "\n")
        }

        // Multiple transactions
        let sorted = transactions.sorted { $0.date > $1.date }
        let dates = sorted.map(\.date)
        let dateRange = dates.last == dates.first ? (dates.first ?? "") : "\(dates.last ?? "") ~ \(dates.first ?? "")"

        var lines = [
            "【Ledger 流水明细】",
            "时间：\(dateRange)（共 \(sorted.count) 笔）",
            "----------------------------"
        ]

        let grouped = Dictionary(grouping: sorted, by: \.date)
        let sortedDates = grouped.keys.sorted(by: >)

        for date in sortedDates {
            lines.append("[\(date)]")
            for tx in (grouped[date] ?? []) {
                lines.append(row(tx, accountLabels: accountLabels))
            }
            lines.append("")
        }

        if lines.last == "" { lines.removeLast() }
        lines.append("----------------------------")
        lines.append("由 Beancount Ledger 生成")
        return lines.joined(separator: "\n")
    }
    static func row(_ tx: LedgerTransaction, accountLabels: [String: String]) -> String {
        let p = TransactionPresentation(transaction: tx)
        let sign = p.kind == .expense ? "-" : (p.kind == .income ? "+" : "")
        let amt = MoneyText.format(minorUnits: p.minorUnits, currency: p.currency)
        let title = tx.payee.isEmpty ? (tx.narration.isEmpty ? p.title : tx.narration) : tx.payee

        var detailParts: [String] = []
        if !tx.payee.isEmpty && !tx.narration.isEmpty {
            detailParts.append(tx.narration)
        }
        if let posting = tx.postings.first(where: { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }) {
            let acctLabel = accountLabels[posting.account] ?? posting.account.components(separatedBy: ":").last ?? posting.account
            detailParts.append(acctLabel)
        }
        let detailStr = detailParts.isEmpty ? "" : " · \(detailParts.joined(separator: " · "))"
        return "  · \(title)  \(sign)\(amt)\(detailStr)"
    }

}


/// Incremental formatter for an already ordered, exact selection. It retains only
/// scalar counters/date state, never transactions or the complete output. The
/// caller owns a private temporary sink and must discard ALL output if append or
/// finish throws. Sink chunks are bounded; partial output is not a valid export.
struct TransactionShareTextStream {
    enum StreamError: Error, Equatable { case invalidSummary, invalidOrder, countMismatch, arithmeticOverflow, finished, failed }
    struct Summary: Equatable, Sendable {
        let count: Int
        let firstDate: String?
        let lastDate: String?
    }
    private let summary: Summary
    private let currency: String
    private let accountLabels: [String: String]
    private var count = 0
    private var lastDate: String?
    private var started = false
    private var completed = false
    private var failed = false

    init(summary: Summary, currency: String, accountLabels: [String: String] = [:]) throws {
        guard summary.count >= 0,
              summary.count == 0 ? (summary.firstDate == nil && summary.lastDate == nil) :
                (summary.firstDate != nil && summary.lastDate != nil && summary.firstDate! >= summary.lastDate!),
              summary.count != 1 || summary.firstDate == summary.lastDate else { throw StreamError.invalidSummary }
        self.summary = summary
        self.currency = currency
        self.accountLabels = accountLabels
    }

    mutating func append(_ transaction: LedgerTransaction, write: (Data) throws -> Void) throws {
        guard !failed else { throw StreamError.failed }
        guard !completed else { throw StreamError.finished }
        do {
            guard count < summary.count else { throw StreamError.countMismatch }
            guard transaction.date <= (lastDate ?? summary.firstDate!),
                  transaction.date >= summary.lastDate!,
                  count != 0 || transaction.date == summary.firstDate else { throw StreamError.invalidOrder }
            // The single receipt formats every posting, unlike presentation's
            // early-return expense/income branch. Reject abs(Int.min) explicitly.
            _ = try LocalTransactionScan.checkedExpense(transaction)
            if summary.count == 1 {
                guard transaction.postings.allSatisfy({ $0.amount != Int.min }) else {
                    throw StreamError.arithmeticOverflow
                }
                try emit(TransactionShareTextFormatter.format(transactions: [transaction], currency: currency,
                    accountLabels: accountLabels), write: write)
            } else {
                if !started { try emit(header(), write: write) }
                if lastDate != transaction.date {
                    try emit((count == 0 ? "\n" : "\n\n") + "[\(transaction.date)]", write: write)
                }
                try emit("\n" + TransactionShareTextFormatter.row(transaction, accountLabels: accountLabels), write: write)
            }
            started = true
            lastDate = transaction.date
            count += 1
        } catch { failed = true; throw error }
    }

    mutating func finish(write: (Data) throws -> Void) throws {
        guard !failed else { throw StreamError.failed }
        guard !completed else { throw StreamError.finished }
        do {
            guard count == summary.count, lastDate == summary.lastDate else { throw StreamError.countMismatch }
            if count != 1 {
                if !started { try emit(header(), write: write) }
                try emit("\n----------------------------\n由 Beancount Ledger 生成", write: write)
            }
            completed = true
        } catch { failed = true; throw error }
    }

    private func header() -> String {
        let first = summary.firstDate ?? "", last = summary.lastDate ?? ""
        let range = first == last ? first : "\(last) ~ \(first)"
        return "【Ledger 流水明细】\n时间：\(range)（共 \(summary.count) 笔）\n----------------------------"
    }

    private func emit(_ text: String, write: (Data) throws -> Void) throws {
        // UTF-8 bytes may split across chunks. Consumers concatenate raw bytes;
        // they must not decode each chunk as a standalone string.
        var chunk = Data()
        chunk.reserveCapacity(16 * 1_024)
        for byte in text.utf8 {
            chunk.append(byte)
            if chunk.count == 16 * 1_024 { try write(chunk); chunk.removeAll(keepingCapacity: true) }
        }
        if !chunk.isEmpty { try write(chunk) }
    }
}
