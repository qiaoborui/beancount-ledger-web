import XCTest
@testable import LedgerMobile

final class LocalPendingScanTests: XCTestCase {
    private func row(_ line: Int, payee: String = "Synthetic", account: String = "Expenses:Food", tags: [String] = [], flag: Bool = false, amount: Int = 100) -> LedgerTransaction {
        .init(date: "2026-09-24", payee: payee, narration: "", tags: tags,
            postings: [.init(account: account, amount: amount, currency: "CNY")],
            pendingReviewFlag: flag, source: .init(file: "fixture.bean", line: line))
    }
    private func page(_ rows: [LedgerTransaction], next: String? = nil, revision: String = "r") -> LedgerTransactionPage {
        .init(revision: revision, transactions: rows, nextCursor: next, sensitiveUnlocked: true)
    }
    func testTabsTotalsAccountsAndEveryWindowMatchCompleteLegacyClassification() throws {
        let rows = [row(1), row(2, account: "Expenses:Unknown"), row(3, tags: ["todo"]), row(4, flag: true),
                    row(5, payee: ""), row(6, payee: "商户", account: "Expenses:Other", tags: ["review"], flag: true, amount: -25),
                    row(7, account: "Expenses:Tail")]
        let pending = rows.filter { !$0.pendingReasons.isEmpty }
        for tab in LedgerPendingFilter.allCases {
            let expected = pending.filter { tab.includes($0.pendingReasons) }
            var collected: [LedgerTransaction] = []
            var offset = 0
            repeat {
                var scan = try LocalPendingScan(revision: "r", filter: tab, offset: offset,
                    declaredAccounts: ["Expenses:Declared", "Assets:Cash"], limits: .init(rows: 2))
                XCTAssertNil(try scan.consume(page(Array(rows.prefix(3)), next: "n"), requestedCursor: nil))
                let result = try XCTUnwrap(scan.consume(page(Array(rows.dropFirst(3))), requestedCursor: "n"))
                XCTAssertEqual(result.totalCount, 5)
                XCTAssertEqual(result.counts[.uncategorized], 2)
                XCTAssertEqual(result.counts[.needsReview], 3)
                XCTAssertEqual(result.counts[.missingPayee], 2)
                XCTAssertEqual(result.totalMinorUnits, 425)
                XCTAssertEqual(result.expenseAccounts, ["Expenses:Declared", "Expenses:Food", "Expenses:Other", "Expenses:Tail", "Expenses:Unknown"])
                XCTAssertLessThanOrEqual(result.transactions.count, 2)
                collected += result.transactions
                guard let next = result.nextOffset else { break }
                offset = next
            } while true
            XCTAssertEqual(collected, expected)
        }
    }
    func testEmptyFilteredWindowStillReturnsCompleteInboxFacts() throws {
        var scan = try LocalPendingScan(revision: "r", filter: .missingPayee)
        let result = try XCTUnwrap(scan.consume(page([row(1, flag: true)]), requestedCursor: nil))
        XCTAssertEqual(result.totalCount, 1)
        XCTAssertEqual(result.totalMinorUnits, 100)
        XCTAssertTrue(result.transactions.isEmpty)
        XCTAssertNil(result.nextOffset)
        var beyond = try LocalPendingScan(revision: "r", offset: 1)
        XCTAssertThrowsError(try beyond.consume(page([row(1, flag: true)]), requestedCursor: nil)) {
            XCTAssertEqual($0 as? LocalPendingScan.ScanError, .offset)
        }
    }
    func testMissingEvidenceLockRevisionAndCursorFailWithoutFalseCleanInbox() throws {
        let noEvidence = LedgerTransaction(date: "2026-09-24", payee: "", narration: "", postings: [], source: .init(file: "fixture.bean", line: 1))
        for invalid in [page([noEvidence]), page([], revision: "other"),
                        LedgerTransactionPage(revision: "r", transactions: [], nextCursor: nil, sensitiveUnlocked: false)] {
            var scan = try LocalPendingScan(revision: "r")
            XCTAssertThrowsError(try scan.consume(invalid, requestedCursor: nil))
            XCTAssertThrowsError(try scan.consume(page([]), requestedCursor: nil)) {
                XCTAssertEqual($0 as? LocalPendingScan.ScanError, .failed)
            }
        }
        var cycle = try LocalPendingScan(revision: "r")
        XCTAssertNil(try cycle.consume(page([], next: "a"), requestedCursor: nil))
        XCTAssertNil(try cycle.consume(page([], next: "b"), requestedCursor: "a"))
        XCTAssertThrowsError(try cycle.consume(page([], next: "a"), requestedCursor: "b"))
    }
    func testIndependentRowAccountStateAndNumericLimits() throws {
        let tx = row(1, flag: true)
        let bytes = try LocalTransactionScan.transactionBytes(tx)
        var exact = try LocalPendingScan(revision: "r", limits: .init(rowBytes: bytes))
        XCTAssertNotNil(try exact.consume(page([tx]), requestedCursor: nil))
        for limits in [LocalPendingScan.Limits(rowBytes: bytes - 1), .init(accounts: 0), .init(stateBytes: 700)] {
            var scan = try LocalPendingScan(revision: "r", limits: limits)
            XCTAssertThrowsError(try scan.consume(page([tx]), requestedCursor: nil))
            XCTAssertEqual(scan.rowBytes, 0)
        }
        for rows in [[row(1, flag: true, amount: .min)], [row(1, flag: true, amount: .max), row(2, flag: true, amount: 1)]] {
            var scan = try LocalPendingScan(revision: "r")
            XCTAssertThrowsError(try scan.consume(page(rows), requestedCursor: nil))
        }
        // Clean rows never contribute an amount, as in the legacy inbox.
        var clean = try LocalPendingScan(revision: "r")
        XCTAssertEqual(try clean.consume(page([row(1, amount: .min)]), requestedCursor: nil)?.totalMinorUnits, 0)
    }
    func testHundredThousandPendingRowsRetainOnlyOneHundredAndCompleteTotals() throws {
        var scan = try LocalPendingScan(revision: "r")
        var result: LocalPendingScan.Result?
        for index in 0..<200 {
            result = try scan.consume(page((0..<500).map { row(index * 500 + $0, flag: true, amount: 1) },
                next: index == 199 ? nil : String(index + 1)), requestedCursor: index == 0 ? nil : String(index))
            XCTAssertLessThanOrEqual(scan.rowBytes, 4 * 1_024 * 1_024)
            if index < 199 { XCTAssertNil(result) }
        }
        XCTAssertEqual(result?.totalCount, 100_000)
        XCTAssertEqual(result?.counts[.needsReview], 100_000)
        XCTAssertEqual(result?.totalMinorUnits, 100_000)
        XCTAssertEqual(result?.transactions.count, 100)
        XCTAssertEqual(result?.nextOffset, 100)
    }
}
