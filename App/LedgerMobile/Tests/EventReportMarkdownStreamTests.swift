import XCTest
@testable import LedgerMobile

final class EventReportMarkdownStreamTests: XCTestCase {
    private func row(_ line: Int, date: String = "2026-09-24", title: String = "Synthetic", amount: Int = 100) -> LedgerTransaction {
        .init(date: date, payee: title, narration: "", tags: ["trip"],
            postings: [.init(account: "Expenses:Food", amount: amount, currency: "CNY")],
            source: .init(file: "fixture.bean", line: line))
    }
    private func formatter(_ rows: [LedgerTransaction]) throws -> EventReportMarkdownStream {
        let report = EventTagCalculator.generateReport(tag: "trip", from: rows)
        return try .init(summary: .init(tag: report.tag, transactionCount: rows.count,
            totalExpense: report.totalExpense, totalIncome: report.totalIncome, netSpend: report.netSpend,
            currency: report.currency, startDate: report.startDate, endDate: report.endDate,
            daysCount: report.daysCount, dailyAverage: report.dailyAverage), categories: report.categoryBreakdown)
    }
    // Independent frozen legacy clipboard format; do not derive expected output
    // through the new stream's header/row helpers.
    private func legacy(_ rows: [LedgerTransaction]) -> String {
        let report = EventTagCalculator.generateReport(tag: "trip", from: rows)
        var lines = ["# 事件核算报告：#\(report.tag)"]
        if let s = report.startDate, let e = report.endDate {
            lines.append("时间跨度：\(s) ~ \(e)（共 \(report.daysCount) 天）")
        }
        lines.append("净支出：\(MoneyText.format(minorUnits: report.netSpend, currency: report.currency))")
        lines.append("总支出：\(MoneyText.format(minorUnits: report.totalExpense, currency: report.currency))，收入/退款：\(MoneyText.format(minorUnits: report.totalIncome, currency: report.currency))")
        lines.append("日均消费：\(MoneyText.format(minorUnits: report.dailyAverage, currency: report.currency))")
        lines.append(""); lines.append("## 分类支出")
        for cat in report.categoryBreakdown {
            lines.append("- \(cat.label)：\(MoneyText.format(minorUnits: cat.amount, currency: report.currency)) (\(String(format: "%.1f%%", cat.percentage * 100)))")
        }
        lines.append(""); lines.append("## 交易清单 (\(report.transactions.count) 笔)")
        for row in report.transactions {
            let p = TransactionPresentation(transaction: row)
            let prefix = p.kind == .expense ? "−" : p.kind == .income ? "+" : ""
            lines.append("- \(row.date) | \(p.title) | \(prefix)\(MoneyText.format(minorUnits: p.minorUnits, currency: p.currency))")
        }
        return lines.joined(separator: "\n")
    }
    func testEmptySingleRefundAndMultipleDaysMatchLegacyByteForByte() throws {
        for rows in [[LedgerTransaction](), [row(1)], [row(1, amount: -100)],
                     [row(1), row(2, date: "2026-09-23", title: "Café 👩‍💻", amount: -10)]] {
            var stream = try formatter(rows)
            var output = Data()
            for row in rows { try stream.append(row) { output.append($0) } }
            try stream.finish { output.append($0) }
            XCTAssertEqual(String(decoding: output, as: UTF8.self), legacy(rows))
            XCTAssertThrowsError(try stream.finish { _ in })
        }
    }
    func testUnicodeChunksStayBoundedWithoutCorruptingUTF8() throws {
        let rows = [row(1, title: String(repeating: "旅行👩‍💻", count: 10_000))]
        var stream = try formatter(rows)
        var chunks = [Data]()
        try stream.append(rows[0]) { chunks.append($0) }
        try stream.finish { chunks.append($0) }
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 16 * 1_024 })
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertEqual(String(decoding: chunks.reduce(into: Data()) { $0.append($1) }, as: UTF8.self), legacy(rows))
    }
    func testMismatchOrderOverflowAndSinkFailurePoisonStream() throws {
        let rows = [row(1), row(2, date: "2026-09-23")]
        var partial = try formatter(rows)
        try partial.append(rows[0]) { _ in }
        XCTAssertThrowsError(try partial.finish { _ in })
        XCTAssertThrowsError(try partial.append(rows[1]) { _ in }) { XCTAssertEqual($0 as? EventReportMarkdownStream.StreamError, .failed) }
        var reversed = try formatter(rows)
        XCTAssertThrowsError(try reversed.append(rows[1]) { _ in })
        var badAmount = try formatter([row(1)])
        XCTAssertThrowsError(try badAmount.append(row(1, amount: .min)) { _ in })
        enum SinkError: Error { case failed }
        var sink = try formatter(rows)
        XCTAssertThrowsError(try sink.append(rows[0]) { _ in throw SinkError.failed })
        XCTAssertThrowsError(try sink.finish { _ in }) { XCTAssertEqual($0 as? EventReportMarkdownStream.StreamError, .failed) }
    }
    func testHundredThousandRowsWriteWithoutCollectingOutput() throws {
        let count = 100_000
        var stream = try EventReportMarkdownStream(summary: .init(tag: "trip", transactionCount: count,
            totalExpense: count * 100, totalIncome: 0, netSpend: count * 100, currency: "CNY",
            startDate: "2026-09-24", endDate: "2026-09-24", daysCount: 1, dailyAverage: count * 100), categories: [])
        var bytes = 0
        for index in 0..<count {
            try stream.append(row(index)) { chunk in
                XCTAssertLessThanOrEqual(chunk.count, 16 * 1_024)
                bytes += chunk.count
            }
        }
        try stream.finish { bytes += $0.count }
        XCTAssertGreaterThan(bytes, 1_000_000)
    }
}
