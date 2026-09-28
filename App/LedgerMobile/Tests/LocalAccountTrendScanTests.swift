import XCTest
@testable import LedgerMobile

final class LocalAccountTrendScanTests: XCTestCase {
    private let range = LedgerDateRange(start: "2026-01-01", end: "2026-12-31", preset: .custom)
    private func rows(_ count: Int) -> [LedgerAccountDetailRow] {
        (0..<count).map { index in
            let date = String(format: "2026-%02d-%02d", index / 56 + 1, (index / 2) % 28 + 1)
            let transaction = LedgerTransaction(date: date, payee: "Synthetic", narration: "Trend",
                postings: [.init(account: "Assets:Cash", amount: 1, currency: "CNY")],
                source: .init(file: "main.bean", line: index + 1, hash: "h"))
            return .init(date: date, payee: transaction.payee, narration: transaction.narration,
                         change: 1, balance: index + 1, transaction: transaction)
        }
    }
    private func page(_ rows: [LedgerAccountDetailRow], count: Int, next: String? = nil,
                      revision: String = "r", closing: Int? = nil) -> LedgerAccountPage {
        .init(revision: revision, sensitiveUnlocked: true,
            detail: .init(account: "Assets:Cash", label: "Cash", alias: nil, group: "Assets", active: true,
                currency: "CNY", currentBalance: count, rows: rows, start: range.start, end: range.queryEndExclusive,
                openingBalance: 0, closingBalance: closing ?? count, periodChange: closing ?? count),
            rowCount: count, nextCursor: next)
    }
    func testWholePeriodTrendMatchesLegacyAcrossDaySplitPagesAndDownsampleSizes() throws {
        let rows = rows(600)
        let legacy = page(rows, count: rows.count).detail
        for size in [2, 3, 6, 180] {
            var scan = try LocalAccountTrendScan(range: range, account: "Assets:Cash", currency: "CNY", revision: "r", maxPoints: size)
            var result: LocalAccountTrendScan.Result?
            for index in stride(from: 0, to: rows.count, by: 137) {
                let end = min(rows.count, index + 137)
                result = try scan.consume(page(Array(rows[index..<end]), count: rows.count,
                    next: end == rows.count ? nil : String(end)), requestedCursor: index == 0 ? nil : String(index))
                if end < rows.count { XCTAssertNil(result) }
            }
            XCTAssertEqual(result?.points, legacy.balanceTrend(in: range, maxPoints: size))
            XCTAssertEqual(result?.rowCount, 600)
            XCTAssertTrue(try XCTUnwrap(result).detail.rows.isEmpty)
            XCTAssertEqual(scan.retainedDays, 300)
        }
    }
    func testFirstPageRequiresExpectedAccountCurrencyAndRevision() throws {
        for scope in [("Assets:Other", "CNY", "r"), ("Assets:Cash", "USD", "r"), ("Assets:Cash", "CNY", "old")] {
            var scan = try LocalAccountTrendScan(range: range, account: scope.0, currency: scope.1, revision: scope.2)
            XCTAssertThrowsError(try scan.consume(page([], count: 0), requestedCursor: nil)) {
                XCTAssertEqual($0 as? LocalAccountTrendScan.ScanError, .scope)
            }
        }
    }

    func testLongCursorHistoryHasExplicitByteLimitAndPoisonsRatherThanForgettingCycles() throws {
        let rows = rows(4)
        var scan = try LocalAccountTrendScan(range: range, account: "Assets:Cash", currency: "CNY", revision: "r", maxBytes: 3_500)
        let first = String(repeating: "a", count: 1_024)
        XCTAssertNil(try scan.consume(page(Array(rows.prefix(1)), count: 4, next: first), requestedCursor: nil))
        XCTAssertThrowsError(try scan.consume(page(Array(rows[1...1]), count: 4,
            next: String(repeating: "b", count: 1_024)), requestedCursor: first)) {
            XCTAssertEqual($0 as? LocalAccountTrendScan.ScanError, .capacity)
        }
        XCTAssertEqual(scan.retainedBytes, 0)
    }

    func testEmptyPeriodPreservesBoundaryPoints() throws {
        var scan = try LocalAccountTrendScan(range: range, account: "Assets:Cash", currency: "CNY", revision: "r")
        let result = try XCTUnwrap(scan.consume(page([], count: 0), requestedCursor: nil))
        XCTAssertEqual(result.points, page([], count: 0).detail.balanceTrend(in: range, maxPoints: 180))
        XCTAssertThrowsError(try scan.consume(page([], count: 0), requestedCursor: nil))
    }
    func testCrossPageCountRevisionCursorAndRunningBalanceFailWithoutPartialChart() throws {
        let rows = rows(4)
        for failure in 0..<5 {
            var scan = try LocalAccountTrendScan(range: range, account: "Assets:Cash", currency: "CNY", revision: "r")
            XCTAssertNil(try scan.consume(page(Array(rows.prefix(2)), count: 4, next: "n"), requestedCursor: nil))
            let invalid: LedgerAccountPage
            switch failure {
            case 0: invalid = page(Array(rows.suffix(2)), count: 4, revision: "new")
            case 1: invalid = page(Array(rows.suffix(1)), count: 4)
            case 2: invalid = page(Array(rows.prefix(2)), count: 4)
            case 3: invalid = page(Array(rows.suffix(2)), count: 4, next: "n")
            default: invalid = page(Array(rows.suffix(2)), count: 5)
            }
            XCTAssertThrowsError(try scan.consume(invalid, requestedCursor: "n"))
            XCTAssertEqual(scan.retainedDays, 0)
            XCTAssertThrowsError(try scan.consume(page([], count: 0), requestedCursor: "n")) {
                XCTAssertEqual($0 as? LocalAccountTrendScan.ScanError, .failed)
            }
        }
    }
    func testExplicitDayByteAndPageBounds() throws {
        let rows = rows(4)
        var days = try LocalAccountTrendScan(range: range, account: "Assets:Cash", currency: "CNY", revision: "r", maxDays: 1)
        XCTAssertThrowsError(try days.consume(page(rows, count: 4), requestedCursor: nil))
        var complete = try LocalAccountTrendScan(range: range, account: "Assets:Cash", currency: "CNY", revision: "r")
        _ = try complete.consume(page(Array(rows.prefix(2)), count: 2), requestedCursor: nil)
        let bytes = complete.retainedBytes
        var exact = try LocalAccountTrendScan(range: range, account: "Assets:Cash", currency: "CNY", revision: "r", maxBytes: bytes)
        XCTAssertNotNil(try exact.consume(page(Array(rows.prefix(2)), count: 2), requestedCursor: nil))
        var short = try LocalAccountTrendScan(range: range, account: "Assets:Cash", currency: "CNY", revision: "r", maxBytes: bytes - 1)
        XCTAssertThrowsError(try short.consume(page(Array(rows.prefix(2)), count: 2), requestedCursor: nil))
        var pages = try LocalAccountTrendScan(range: range, account: "Assets:Cash", currency: "CNY", revision: "r", maxPages: 1)
        XCTAssertNil(try pages.consume(page(Array(rows.prefix(2)), count: 4, next: "n"), requestedCursor: nil))
        XCTAssertThrowsError(try pages.consume(page(Array(rows.suffix(2)), count: 4), requestedCursor: "n"))
    }
    func testHundredThousandRowsKeepOnlyDayClosingsAndLastIdentity() throws {
        var scan = try LocalAccountTrendScan(range: range, account: "Assets:Cash", currency: "CNY", revision: "r")
        var result: LocalAccountTrendScan.Result?
        for pageIndex in 0..<200 {
            let rows = (0..<500).map { index -> LedgerAccountDetailRow in
                let number = pageIndex * 500 + index + 1
                let date = "2026-09-23"
                let transaction = LedgerTransaction(date: date, payee: "Synthetic", narration: "Trend", postings: [],
                    source: .init(file: "fixture.bean", line: number, hash: "h"))
                return .init(date: date, payee: transaction.payee, narration: transaction.narration,
                    change: 1, balance: number, transaction: transaction)
            }
            result = try scan.consume(page(rows, count: 100_000, next: pageIndex == 199 ? nil : String(pageIndex + 1)),
                requestedCursor: pageIndex == 0 ? nil : String(pageIndex))
            XCTAssertEqual(scan.retainedDays, 1)
            XCTAssertLessThan(scan.retainedBytes, 64 * 1_024)
        }
        XCTAssertEqual(result?.rowCount, 100_000)
        XCTAssertEqual(result?.points.map(\.balance), [0, 100_000, 100_000])
    }
}
