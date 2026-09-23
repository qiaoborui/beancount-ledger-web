import XCTest
@testable import LedgerMobile

final class LocalGlobalSearchScanTests: XCTestCase {
    private let account = LedgerAccount(account: "Expenses:Food", openDate: "2020-01-01", closeDate: nil,
        currency: "CNY", alias: "餐饮", label: "饮食", group: "Expenses", active: true)
    private func row(_ index: Int) -> LedgerTransaction {
        .init(date: index % 3 == 0 ? "2026-09-22" : "2026-09-23", payee: "Ｃａｆé", narration: "Synthetic",
              metadata: ["receipt": .string("Order Cafe\u{301}"), "number": .number(12.5), "bool": .bool(true), "empty-key": .null],
              tags: index % 2 == 0 ? ["trip"] : ["office"],
              postings: [.init(account: "Expenses:Food", amount: 1250, currency: "CNY")],
              source: .init(file: "fixture.bean", line: index, hash: String(index)))
    }
    private func page(_ rows: [LedgerTransaction], next: String? = nil, revision: String = "r", unlocked: Bool = true) -> LedgerTransactionPage {
        .init(revision: revision, transactions: rows, nextCursor: next, sensitiveUnlocked: unlocked)
    }
    func testEveryWindowMatchesLegacyGlobalOrderAndExactSearchAcrossNativeOrder() throws {
        let rows = (1...53).map(row)
        let queries = ["", "cafe", "ＣＡＦＥ", "Cafe\u{301}", "receipt true", "empty-key", "12.50 餐饮", "#trip", "absent", "payee:cafe"]
        for query in queries {
            for scope in [LedgerGlobalSearchScope.all, .transactions, .accounts, .documents] {
                let filters = LedgerGlobalSearchFilters(startDate: "2026-09-22", endDate: "2026-09-23")
                let expected = LedgerGlobalSearch.search(query, transactions: rows, accounts: [account], documents: [], scope: scope, filters: filters)
                var collected: [LedgerTransaction] = [], anchor: LocalGlobalSearchScan.Anchor?
                repeat {
                    var scan = try LocalGlobalSearchScan(revision: "r", query: query, accounts: [account],
                        scope: scope, filters: filters, after: anchor, limits: .init(rows: 7))
                    XCTAssertNil(try scan.consume(page(Array(rows.prefix(25)), next: "n"), requestedCursor: nil))
                    let result = try XCTUnwrap(scan.consume(page(Array(rows.suffix(28))), requestedCursor: "n"))
                    XCTAssertEqual(result.matchedCount, expected.transactions.count, query)
                    XCTAssertEqual(result.tags, expected.tags, query)
                    XCTAssertEqual(result.remainingCount, expected.transactions.count - collected.count)
                    XCTAssertLessThanOrEqual(result.transactions.count, 7)
                    collected += result.transactions; anchor = result.continuation
                } while anchor != nil
                XCTAssertEqual(collected, expected.transactions, query)
            }
        }
    }
    func testBlankDefaultAndInvalidDateRangeMatchLegacy() throws {
        for filters in [LedgerGlobalSearchFilters(), .init(startDate: "2026-10-01", endDate: "2026-01-01")] {
            var scan = try LocalGlobalSearchScan(revision: "r", query: "", accounts: [], filters: filters)
            let result = try XCTUnwrap(scan.consume(page([row(1)]), requestedCursor: nil))
            XCTAssertEqual(result.matchedCount, 0); XCTAssertTrue(result.tags.isEmpty)
        }
    }
    func testTagsMatchFilteredUniverseNotOnlyMatchingTransactions() throws {
        var scan = try LocalGlobalSearchScan(revision: "r", query: "trip", accounts: [], filters: .init(tag: "trip"))
        let result = try XCTUnwrap(scan.consume(page([row(1), row(2)]), requestedCursor: nil))
        XCTAssertEqual(result.tags, ["trip"]); XCTAssertEqual(result.transactions, [row(2)])
        var filtered = try LocalGlobalSearchScan(revision: "r", query: "trip", accounts: [], filters: .init(account: "Expenses:Other"))
        XCTAssertEqual(try filtered.consume(page([row(2)]), requestedCursor: nil)?.tags, [])
    }
    func testByteBudgetExactFitOverflowAndPoisoning() throws {
        let bytes = try LocalTransactionScan.transactionBytes(row(1))
        var exact = try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [], limits: .init(rows: 1, rowBytes: bytes))
        XCTAssertEqual(try exact.consume(page([row(1)]), requestedCursor: nil)?.rowBytes, bytes)
        var short = try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [], limits: .init(rows: 1, rowBytes: bytes - 1))
        XCTAssertThrowsError(try short.consume(page([row(1)]), requestedCursor: nil))
        XCTAssertEqual(short.rowBytes, 0)
        XCTAssertThrowsError(try short.consume(page([]), requestedCursor: nil)) {
            XCTAssertEqual($0 as? LocalGlobalSearchScan.ScanError, .failed)
        }
        XCTAssertThrowsError(try LocalGlobalSearchScan(revision: "r", query: String(repeating: "x", count: 1000), accounts: [], limits: .init(stateBytes: 600)))
        var tags = try LocalGlobalSearchScan(revision: "r", query: "", accounts: [], filters: .init(account: "Expenses:Food"), limits: .init(tags: 1))
        XCTAssertThrowsError(try tags.consume(page([row(1), row(2)]), requestedCursor: nil))
    }
    func testRevisionCursorLockAndPageBoundsFailWithoutPublishingPartialCounts() throws {
        for bad in [page([], revision: "other"), page([], unlocked: false), page([], next: ""), page((1...501).map(row))] {
            var scan = try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [])
            XCTAssertThrowsError(try scan.consume(bad, requestedCursor: nil))
            XCTAssertThrowsError(try scan.consume(page([]), requestedCursor: nil))
        }
        var scan = try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [])
        XCTAssertNil(try scan.consume(page([], next: "a"), requestedCursor: nil))
        XCTAssertNil(try scan.consume(page([], next: "b"), requestedCursor: "a"))
        XCTAssertThrowsError(try scan.consume(page([], next: "a"), requestedCursor: "b"))
        var completed = try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [])
        XCTAssertNotNil(try completed.consume(page([]), requestedCursor: nil))
        XCTAssertThrowsError(try completed.consume(page([]), requestedCursor: nil))
    }
    func testIndependentGoldenMatchingAndLexicalSourceIDOrder() throws {
        let rows = [row(2), row(10), row(3), row(1)]
        for query in ["cafe", "ＣＡＦＥ", "Cafe\u{301}", "receipt true", "empty-key", "12.50 餐饮", "fixture.bean", "number 12.5"] {
            var scan = try LocalGlobalSearchScan(revision: "r", query: query, accounts: [account])
            let result = try XCTUnwrap(scan.consume(page(rows), requestedCursor: nil))
            XCTAssertEqual(result.transactions.map(\.source.line), [10, 1, 2, 3], query)
        }
        var tagged = try LocalGlobalSearchScan(revision: "r", query: "#trip", accounts: [])
        XCTAssertEqual(try tagged.consume(page(rows), requestedCursor: nil)?.transactions.map(\.source.line), [10, 2])
        let duplicate = LedgerAccount(account: account.account, openDate: "2020-01-01", closeDate: nil,
            currency: "CNY", alias: "second-only", label: "different", group: "Expenses", active: true)
        var firstWins = try LocalGlobalSearchScan(revision: "r", query: "second-only", accounts: [account, duplicate])
        XCTAssertEqual(try firstWins.consume(page(rows), requestedCursor: nil)?.matchedCount, 0)
    }

    func testProvisionalByteOverflowFailsExplicitlyRatherThanShorteningWindow() throws {
        let rows = [row(3), row(1)]
        let bytes = try LocalTransactionScan.transactionBytes(rows[0])
        var scan = try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [], limits: .init(rows: 2, rowBytes: bytes))
        XCTAssertThrowsError(try scan.consume(page(rows), requestedCursor: nil)) {
            XCTAssertEqual($0 as? LocalGlobalSearchScan.ScanError, .capacity)
        }
        XCTAssertEqual(scan.rowBytes, 0)
    }

    func testStateAndPageBoundsAndUnexpectedCursors() throws {
        var initial = try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [account])
        let base = initial.stateBytes
        XCTAssertNotNil(try initial.consume(page([]), requestedCursor: nil))
        XCTAssertNoThrow(try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [account], limits: .init(stateBytes: base)))
        XCTAssertThrowsError(try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [account], limits: .init(stateBytes: base - 1)))
        XCTAssertThrowsError(try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [account], limits: .init(accounts: 0)))
        var cursorBudget = try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [account], limits: .init(stateBytes: base))
        XCTAssertThrowsError(try cursorBudget.consume(page([], next: "n"), requestedCursor: nil))
        var pages = try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [], limits: .init(pages: 1))
        XCTAssertNil(try pages.consume(page([], next: "n"), requestedCursor: nil))
        XCTAssertThrowsError(try pages.consume(page([]), requestedCursor: "n"))
        for next in [String(repeating: "x", count: 1_025), "n"] {
            var invalid = try LocalGlobalSearchScan(revision: "r", query: "cafe", accounts: [])
            XCTAssertThrowsError(try invalid.consume(page([], next: next), requestedCursor: next == "n" ? "wrong" : nil))
        }
    }

    func testHundredThousandCandidatesRetainOnlyTopWindowAndCompleteCount() throws {
        var scan = try LocalGlobalSearchScan(revision: "r", query: "", accounts: [], scope: .transactions,
            limits: .init(rows: 10))
        var result: LocalGlobalSearchScan.Result?
        for index in 0..<200 {
            result = try scan.consume(page((0..<500).map { row(index * 500 + $0) }, next: index == 199 ? nil : String(index + 1)),
                requestedCursor: index == 0 ? nil : String(index))
            if index < 199 { XCTAssertNil(result) }
            XCTAssertLessThanOrEqual(scan.rowBytes, 4 * 1_024 * 1_024)
        }
        XCTAssertEqual(result?.matchedCount, 100_000)
        XCTAssertEqual(result?.transactions.count, 10)
        XCTAssertNotNil(result?.continuation)
    }
}
