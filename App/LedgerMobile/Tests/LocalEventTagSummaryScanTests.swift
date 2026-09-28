import XCTest
@testable import LedgerMobile

final class LocalEventTagSummaryScanTests: XCTestCase {
    private func row(_ line: Int, date: String = "2026-09-23", tags: [String] = ["trip"], expense: Int = 100,
                     income: Int = 0, currency: String = "CNY") -> LedgerTransaction {
        .init(date: date, payee: "Synthetic", narration: "Event", tags: tags,
            postings: [.init(account: "Expenses:Food", amount: expense, currency: currency),
                       .init(account: "Income:Other", amount: income, currency: "CNY")],
            source: .init(file: "fixture.bean", line: line))
    }
    private func page(_ rows: [LedgerTransaction], next: String? = nil, revision: String = "r") -> LedgerTransactionPage {
        .init(revision: revision, transactions: rows, nextCursor: next, sensitiveUnlocked: true)
    }
    func testSummariesMatchLegacyIncludingRefundsIncomeDuplicatesAndLastExpenseCurrency() throws {
        let rows = [row(1, tags: ["trip", "trip", "", "work"], expense: -30, currency: "USD"),
                    row(2, tags: ["trip", "work"], expense: 100, income: -20, currency: "EUR"),
                    row(3, date: "2026-09-21", tags: ["trip"], expense: 50, income: 10, currency: "JPY"),
                    row(4, date: "2026-09-20", tags: ["work"], expense: -100, income: -10)]
        var scan = try LocalEventTagSummaryScan(revision: "r")
        XCTAssertNil(try scan.consume(page(Array(rows.prefix(2)), next: "n"), requestedCursor: nil))
        let result = try XCTUnwrap(scan.consume(page(Array(rows.suffix(2))), requestedCursor: "n"))
        XCTAssertEqual(result.sorted { $0.tag < $1.tag }, EventTagCalculator.summarizeAllTags(from: rows).sorted { $0.tag < $1.tag })
        let trip = try XCTUnwrap(result.first { $0.tag == "trip" })
        XCTAssertEqual(trip.transactionCount, 3); XCTAssertEqual(trip.totalExpense, 120)
        XCTAssertEqual(trip.totalIncome, 20); XCTAssertEqual(trip.currency, "JPY")
    }
    func testSameDateCurrencyWinnerAcrossPageBoundaryAndMixedIncome() throws {
        let rows = [row(1, income: -20, currency: "USD"), row(2, income: 30, currency: "EUR")]
        var scan = try LocalEventTagSummaryScan(revision: "r")
        XCTAssertNil(try scan.consume(page([rows[0]], next: "n"), requestedCursor: nil))
        let result = try XCTUnwrap(scan.consume(page([rows[1]]), requestedCursor: "n"))
        XCTAssertEqual(result, EventTagCalculator.summarizeAllTags(from: rows))
        XCTAssertEqual(result.first?.currency, "EUR")
        XCTAssertEqual(result.first?.totalIncome, 20)
        let mixed = LedgerTransaction(date: "2026-09-23", payee: "", narration: "", tags: ["trip"], postings: [
            .init(account: "Expenses:Food", amount: 100, currency: "USD"),
            .init(account: "Expenses:Food", amount: -20, currency: ""),
            .init(account: "Expenses:Food", amount: 1, currency: nil),
            .init(account: "Income:Salary", amount: -30, currency: "CNY"),
            .init(account: "Income:Salary", amount: 10, currency: "CNY")], source: .init(file: "fixture.bean", line: 3))
        var mixedScan = try LocalEventTagSummaryScan(revision: "r")
        let mixedResult = try XCTUnwrap(mixedScan.consume(page([mixed]), requestedCursor: nil))
        XCTAssertEqual(mixedResult, EventTagCalculator.summarizeAllTags(from: [mixed]))
        XCTAssertEqual(mixedResult.first?.currency, "USD"); XCTAssertEqual(mixedResult.first?.totalIncome, 20)
    }

    func testLockedWrongCursorCycleAndPageLimitRejectResults() throws {
        var locked = try LocalEventTagSummaryScan(revision: "r")
        XCTAssertThrowsError(try locked.consume(.init(revision: "r", transactions: [], nextCursor: nil, sensitiveUnlocked: false), requestedCursor: nil))
        var wrong = try LocalEventTagSummaryScan(revision: "r")
        XCTAssertThrowsError(try wrong.consume(page([]), requestedCursor: "unexpected"))
        var cycle = try LocalEventTagSummaryScan(revision: "r")
        XCTAssertNil(try cycle.consume(page([], next: "a"), requestedCursor: nil))
        XCTAssertNil(try cycle.consume(page([], next: "b"), requestedCursor: "a"))
        XCTAssertThrowsError(try cycle.consume(page([], next: "a"), requestedCursor: "b"))
        var pages = try LocalEventTagSummaryScan(revision: "r", limits: .init(pages: 1))
        XCTAssertNil(try pages.consume(page([], next: "a"), requestedCursor: nil))
        XCTAssertThrowsError(try pages.consume(page([]), requestedCursor: "a"))
    }

    func testNoTagsDoNotEvaluateIrrelevantPostingOverflow() throws {
        var scan = try LocalEventTagSummaryScan(revision: "r")
        XCTAssertEqual(try scan.consume(page([row(1, tags: [], income: .min)]), requestedCursor: nil), [])
    }
    func testLimitsOverflowAndFailedStateAreExplicit() throws {
        for limits in [LocalEventTagSummaryScan.Limits(tags: 1), .init(bytes: 700)] {
            var scan = try LocalEventTagSummaryScan(revision: "r", limits: limits)
            XCTAssertThrowsError(try scan.consume(page([row(1, tags: ["a", "b"])]), requestedCursor: nil))
            XCTAssertEqual(scan.retainedTags, 0)
            XCTAssertThrowsError(try scan.consume(page([]), requestedCursor: nil))
        }
        for rows in [[row(1, income: .min)], [row(1, expense: .max), row(2, expense: 1)]] {
            var scan = try LocalEventTagSummaryScan(revision: "r")
            XCTAssertThrowsError(try scan.consume(page(rows), requestedCursor: nil))
        }
    }
    func testCursorRevisionAndDescendingOrderRequired() throws {
        for failure in 0..<3 {
            var scan = try LocalEventTagSummaryScan(revision: "r")
            XCTAssertNil(try scan.consume(page([row(1)], next: "n"), requestedCursor: nil))
            switch failure {
            case 0: XCTAssertThrowsError(try scan.consume(page([row(2)], revision: "new"), requestedCursor: "n"))
            case 1: XCTAssertThrowsError(try scan.consume(page([row(2)], next: "n"), requestedCursor: "n"))
            default: XCTAssertThrowsError(try scan.consume(page([row(2, date: "2026-09-24")]), requestedCursor: "n"))
            }
        }
    }
    func testHundredThousandTransactionsRetainOnlyOneTagAndBoundedCursors() throws {
        var scan = try LocalEventTagSummaryScan(revision: "r")
        var result: [EventTagSummary]?
        for index in 0..<200 {
            result = try scan.consume(page((0..<500).map { row(index * 500 + $0) }, next: index == 199 ? nil : String(index + 1)),
                requestedCursor: index == 0 ? nil : String(index))
            XCTAssertEqual(scan.retainedTags, 1)
            XCTAssertLessThan(scan.retainedBytes, 64 * 1_024)
            if index < 199 { XCTAssertNil(result) }
        }
        XCTAssertEqual(result?.first?.transactionCount, 100_000)
        XCTAssertEqual(result?.first?.totalExpense, 10_000_000)
        XCTAssertEqual(result?.first?.dailyAverage, 10_000_000)
    }
}
