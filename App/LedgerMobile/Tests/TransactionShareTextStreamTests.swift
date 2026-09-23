import Foundation
import XCTest
@testable import LedgerMobile

final class TransactionShareTextStreamTests: XCTestCase {
    private func row(_ id: Int, date: String = "2026-09-23", payee: String = "Synthetic") -> LedgerTransaction {
        LedgerTransaction(date: date, payee: payee, narration: "测试 · note", tags: ["synthetic"],
            postings: [.init(account: "Expenses:Food", amount: 125, currency: "CNY"),
                       .init(account: "Assets:Cash", amount: -125, currency: "CNY")],
            source: .init(file: "synthetic.bean", line: id, hash: "row-\(id)"))
    }

    func testStreamExactlyMatchesLegacyFormattingForEmptySingleAndMultipleRows() throws {
        for rows in [[], [row(1)], [row(1), row(2)],
                     [row(1), row(2, date: "2026-09-22"), row(3, date: "2026-09-22", payee: "")]] {
            let labels = ["Assets:Cash": "现金"]
            var stream = try TransactionShareTextStream(summary: .init(count: rows.count,
                firstDate: rows.first?.date, lastDate: rows.last?.date), currency: "CNY", accountLabels: labels)
            var data = Data()
            for row in rows { try stream.append(row) { data.append($0) } }
            try stream.finish { data.append($0) }
            XCTAssertEqual(String(decoding: data, as: UTF8.self),
                TransactionShareTextFormatter.format(transactions: rows, currency: "CNY", accountLabels: labels))
        }
    }

    func testGoldenSingleAndMultipleLayout() throws {
        let single = TransactionShareTextFormatter.format(transactions: [row(1)], currency: "CNY")
        XCTAssertTrue(single.hasPrefix("【Ledger 记账凭证】\n类型：支出\n金额：-¥1.25\n时间：2026-09-23"))
        XCTAssertTrue(single.contains("标签：#synthetic\n----------------------------\n由 Beancount Ledger 生成"))
        let multiple = TransactionShareTextFormatter.format(transactions: [row(2, date: "2026-09-22"), row(1)], currency: "CNY")
        XCTAssertEqual(multiple, """
        【Ledger 流水明细】
        时间：2026-09-22 ~ 2026-09-23（共 2 笔）
        ----------------------------
        [2026-09-23]
          · Synthetic  -¥1.25 · 测试 · note · Cash

        [2026-09-22]
          · Synthetic  -¥1.25 · 测试 · note · Cash
        ----------------------------
        由 Beancount Ledger 生成
        """)
    }

    func testHundredThousandRowsCanStreamWithoutRetainingRowsOrOutput() throws {
        var stream = try TransactionShareTextStream(summary: .init(count: 100_000,
            firstDate: "2026-09-23", lastDate: "2026-09-23"), currency: "CNY")
        var bytes = 0, chunks = 0, maxChunk = 0
        let sink: (Data) -> Void = { data in bytes += data.count; chunks += 1; maxChunk = max(maxChunk, data.count) }
        for id in 0..<100_000 { try stream.append(row(id), write: sink) }
        try stream.finish(write: sink)
        XCTAssertGreaterThan(bytes, 4_000_000)
        XCTAssertGreaterThan(chunks, 100_000)
        XCTAssertLessThanOrEqual(maxChunk, 16 * 1_024)
    }

    func testUnicodeChunksReassembleAndStayBounded() throws {
        let tx = row(1, payee: String(repeating: "中文😀", count: 10_000))
        var stream = try TransactionShareTextStream(summary: .init(count: 1,
            firstDate: tx.date, lastDate: tx.date), currency: "CNY")
        var data = Data(), largest = 0
        try stream.append(tx) { largest = max(largest, $0.count); data.append($0) }
        try stream.finish { data.append($0) }
        XCTAssertLessThanOrEqual(largest, 16 * 1_024)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), TransactionShareTextFormatter.format(transactions: [tx], currency: "CNY"))
    }

    func testIncompleteExtraWrongOrderAndSinkFailurePoisonStream() throws {
        var incomplete = try TransactionShareTextStream(summary: .init(count: 2,
            firstDate: "2026-09-23", lastDate: "2026-09-22"), currency: "CNY")
        try incomplete.append(row(1)) { _ in }
        XCTAssertThrowsError(try incomplete.finish { _ in })
        XCTAssertThrowsError(try incomplete.append(row(2, date: "2026-09-22")) { _ in })
        var order = try TransactionShareTextStream(summary: .init(count: 2,
            firstDate: "2026-09-23", lastDate: "2026-09-22"), currency: "CNY")
        XCTAssertThrowsError(try order.append(row(1, date: "2026-09-22")) { _ in })
        var failed = try TransactionShareTextStream(summary: .init(count: 1,
            firstDate: "2026-09-23", lastDate: "2026-09-23"), currency: "CNY")
        struct SinkFailure: Error { }
        XCTAssertThrowsError(try failed.append(row(1)) { _ in throw SinkFailure() })
        XCTAssertThrowsError(try failed.finish { _ in })
        var extra = try TransactionShareTextStream(summary: .init(count: 0, firstDate: nil, lastDate: nil), currency: "CNY")
        XCTAssertThrowsError(try extra.append(row(1)) { _ in })
        var done = try TransactionShareTextStream(summary: .init(count: 0, firstDate: nil, lastDate: nil), currency: "CNY")
        try done.finish { _ in }
        XCTAssertThrowsError(try done.finish { _ in })
        XCTAssertThrowsError(try TransactionShareTextStream(summary: .init(count: 1,
            firstDate: "2026-09-23", lastDate: "2026-09-22"), currency: "CNY"))
    }
}
