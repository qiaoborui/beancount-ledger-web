import XCTest
@testable import LedgerMobile

final class LocalEventTagReportScanTests: XCTestCase {
    private func row(_ line: Int, date: String = "2026-09-24", tags: [String] = ["trip"], postings: [LedgerPosting]) -> LedgerTransaction {
        .init(date: date, payee: "Synthetic", narration: "Event report", tags: tags, postings: postings,
            source: .init(file: "fixture.bean", line: line))
    }
    private func page(_ rows: [LedgerTransaction], next: String? = nil, revision: String = "r") -> LedgerTransactionPage {
        .init(revision: revision, transactions: rows, nextCursor: next, sensitiveUnlocked: true)
    }
    private func assertMatches(_ actual: LocalEventTagReportScan.Result, _ expected: EventTagReport,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.summary.tag, expected.tag, file: file, line: line)
        XCTAssertEqual(actual.summary.transactionCount, expected.transactions.count, file: file, line: line)
        XCTAssertEqual(actual.summary.totalExpense, expected.totalExpense, file: file, line: line)
        XCTAssertEqual(actual.summary.totalIncome, expected.totalIncome, file: file, line: line)
        XCTAssertEqual(actual.summary.netSpend, expected.netSpend, file: file, line: line)
        XCTAssertEqual(actual.summary.currency, expected.currency, file: file, line: line)
        XCTAssertEqual(actual.summary.startDate, expected.startDate, file: file, line: line)
        XCTAssertEqual(actual.summary.endDate, expected.endDate, file: file, line: line)
        XCTAssertEqual(actual.summary.daysCount, expected.daysCount, file: file, line: line)
        XCTAssertEqual(actual.summary.dailyAverage, expected.dailyAverage, file: file, line: line)
        // Equal-amount category tie ordering was never specified by the legacy dictionary.
        XCTAssertEqual(actual.categoryBreakdown.sorted { $0.account < $1.account },
            expected.categoryBreakdown.sorted { $0.account < $1.account }, file: file, line: line)
        XCTAssertEqual(actual.dailySeries, expected.dailySeries, file: file, line: line)
    }
    func testCompleteReportMatchesLegacyAcrossRefundIncomeAndSplitDays() throws {
        let rows = [
            row(1, tags: ["trip", "trip", "other"], postings: [.init(account: "Expenses:Food", amount: 100, currency: "USD")]),
            row(2, postings: [.init(account: "Expenses:Food", amount: -100, currency: "EUR")]),
            row(3, date: "2026-09-23", postings: [.init(account: "Expenses:Travel", amount: 500, currency: "JPY"),
                .init(account: "Income:Refund", amount: -40, currency: "CNY"), .init(account: "Income:Refund", amount: 10, currency: "CNY")]),
            row(4, date: "2026-09-22", postings: [.init(account: "Expenses:Food", amount: -20, currency: nil)]),
            row(5, date: "2026-09-21", postings: [.init(account: "Assets:Cash", amount: 10, currency: "CNY")]),
            row(6, date: "2026-09-20", tags: ["other"], postings: [.init(account: "Expenses:Other", amount: 800, currency: "CNY")])]
        let labels = ["Expenses:Travel": "Travel label"]
        var scan = try LocalEventTagReportScan(revision: "r", tag: "trip", accountLabels: labels)
        XCTAssertNil(try scan.consume(page(Array(rows.prefix(1)), next: "n"), requestedCursor: nil))
        let result = try XCTUnwrap(scan.consume(page(Array(rows.dropFirst())), requestedCursor: "n"))
        assertMatches(result, EventTagCalculator.generateReport(tag: "trip", from: rows, accountLabels: labels))
        XCTAssertEqual(result.summary.totalExpense, 480)
        XCTAssertEqual(result.summary.totalIncome, 30)
        XCTAssertEqual(result.summary.transactionCount, 5)
        XCTAssertEqual(result.categoryBreakdown.map(\.amount), [500])
        XCTAssertEqual(result.dailySeries.map(\.amount), [0, 500, 0])
        XCTAssertEqual(result.summary.currency, "JPY")
    }
    func testEmptyTagAbsentTagAndZeroNetDayMatchLegacy() throws {
        let rows = [row(1, tags: ["", "trip"], postings: [.init(account: "Expenses:A", amount: 10, currency: "CNY"),
             .init(account: "Expenses:B", amount: -10, currency: "CNY")])]
        for tag in ["", "missing", "trip"] {
            var scan = try LocalEventTagReportScan(revision: "r", tag: tag)
            let result = try XCTUnwrap(scan.consume(page(rows), requestedCursor: nil))
            assertMatches(result, EventTagCalculator.generateReport(tag: tag, from: rows))
            XCTAssertTrue(result.dailySeries.isEmpty)
        }
    }
    func testCategoryDayLabelAndByteCapFailWholeReportAndPoison() throws {
        let rows = [row(1, postings: [.init(account: "Expenses:A", amount: 10, currency: "CNY")]),
            row(2, date: "2026-09-23", postings: [.init(account: "Expenses:B", amount: 20, currency: "CNY")])]
        for limits in [LocalEventTagReportScan.Limits(categories: 1), .init(days: 1), .init(bytes: 900)] {
            var scan = try LocalEventTagReportScan(revision: "r", tag: "trip", limits: limits)
            XCTAssertThrowsError(try scan.consume(page(rows), requestedCursor: nil))
            XCTAssertEqual(scan.retainedCategories, 0)
            XCTAssertEqual(scan.retainedDays, 0)
            XCTAssertThrowsError(try scan.consume(page([]), requestedCursor: nil))
        }
        XCTAssertThrowsError(try LocalEventTagReportScan(revision: "r", tag: "trip",
            accountLabels: ["Expenses:A": String(repeating: "x", count: 4 * 1_024 * 1_024)]))
        var measured = try LocalEventTagReportScan(revision: "r", tag: "trip")
        _ = try measured.consume(page([rows[0]]), requestedCursor: nil)
        let bytes = measured.retainedBytes
        var exact = try LocalEventTagReportScan(revision: "r", tag: "trip", limits: .init(bytes: bytes))
        XCTAssertNotNil(try exact.consume(page([rows[0]]), requestedCursor: nil))
        var short = try LocalEventTagReportScan(revision: "r", tag: "trip", limits: .init(bytes: bytes - 1))
        XCTAssertThrowsError(try short.consume(page([rows[0]]), requestedCursor: nil))
    }
    func testOutputSummaryAndDailyBytesAreChargedAndNestedStateReleased() throws {
        let refund = row(1, postings: [.init(account: "Expenses:A", amount: -10, currency: "CNY")])
        var measured = try LocalEventTagReportScan(revision: "r", tag: "trip")
        _ = try measured.consume(page([refund]), requestedCursor: nil)
        let bytes = measured.retainedBytes
        // Independently enumerate config, aggregate keys and output payloads.
        let stringBytes = LocalTransactionScan.stringBytes
        let config = 512 + (try stringBytes("trip")) + (try stringBytes("r"))
        let keys = (try stringBytes("Expenses:A")) + (try stringBytes(refund.date))
        let daily = 128 + (try stringBytes(refund.date))
        let output = 256 + (try stringBytes("trip")) + (try stringBytes("CNY")) + 2 * (try stringBytes(refund.date))
        XCTAssertEqual(bytes, config + keys + daily + output)
        XCTAssertEqual(measured.summaryRetainedBytes, 0)
        var short = try LocalEventTagReportScan(revision: "r", tag: "trip", limits: .init(bytes: bytes - 1))
        XCTAssertThrowsError(try short.consume(page([refund]), requestedCursor: nil))
        XCTAssertEqual(short.summaryRetainedBytes, 0)
        let large = row(2, postings: [.init(account: "Expenses:A", amount: -10, currency: String(repeating: "X", count: 5_000))])
        var currency = try LocalEventTagReportScan(revision: "r", tag: "trip", limits: .init(bytes: 4_096))
        XCTAssertThrowsError(try currency.consume(page([large]), requestedCursor: nil))
        XCTAssertEqual(currency.summaryRetainedBytes, 0)
        var categories = try LocalEventTagReportScan(revision: "r", tag: "trip", limits: .init(categories: 1))
        XCTAssertNil(try categories.consume(page([refund], next: "n"), requestedCursor: nil))
        XCTAssertGreaterThan(categories.summaryRetainedBytes, 0)
        let other = row(3, postings: [.init(account: "Expenses:B", amount: 1, currency: "CNY")])
        XCTAssertThrowsError(try categories.consume(page([other]), requestedCursor: "n"))
        XCTAssertEqual(categories.summaryRetainedBytes, 0)
        XCTAssertThrowsError(try categories.consume(page([]), requestedCursor: "n")) {
            XCTAssertEqual($0 as? LocalEventTagReportScan.ScanError, .failed)
        }
    }

    func testOverflowAndRawPageValidationAreNotHiddenByTagProjection() throws {
        let huge = row(1, postings: [.init(account: "Expenses:A", amount: .max, currency: "CNY"),
            .init(account: "Expenses:B", amount: 1, currency: "CNY")])
        var numeric = try LocalEventTagReportScan(revision: "r", tag: "trip")
        XCTAssertThrowsError(try numeric.consume(page([huge]), requestedCursor: nil))
        for invalid in [page(Array(repeating: huge, count: 501)), page([], revision: "wrong"),
            LedgerTransactionPage(revision: "r", transactions: [], nextCursor: nil, sensitiveUnlocked: false)] {
            var scan = try LocalEventTagReportScan(revision: "r", tag: "missing")
            XCTAssertThrowsError(try scan.consume(invalid, requestedCursor: nil))
        }
        var scan = try LocalEventTagReportScan(revision: "r", tag: "trip")
        XCTAssertNil(try scan.consume(page([], next: "a"), requestedCursor: nil))
        XCTAssertNil(try scan.consume(page([], next: "b"), requestedCursor: "a"))
        XCTAssertThrowsError(try scan.consume(page([], next: "a"), requestedCursor: "b"))
    }
    func testHundredThousandRowsRetainOnlyOneCategoryAndDay() throws {
        var scan = try LocalEventTagReportScan(revision: "r", tag: "trip")
        var result: LocalEventTagReportScan.Result?
        for index in 0..<200 {
            let rows = (0..<500).map { row(index * 500 + $0, postings: [.init(account: "Expenses:Food", amount: 1, currency: "CNY")]) }
            result = try scan.consume(page(rows, next: index == 199 ? nil : String(index + 1)),
                requestedCursor: index == 0 ? nil : String(index))
            XCTAssertLessThanOrEqual(scan.retainedCategories, 1)
            XCTAssertLessThanOrEqual(scan.retainedDays, 1)
            XCTAssertLessThan(scan.retainedBytes, 4_096)
            if index < 199 { XCTAssertNil(result) }
        }
        XCTAssertEqual(result?.summary.transactionCount, 100_000)
        XCTAssertEqual(result?.categoryBreakdown.first?.amount, 100_000)
        XCTAssertEqual(result?.dailySeries.first?.amount, 100_000)
    }
}
