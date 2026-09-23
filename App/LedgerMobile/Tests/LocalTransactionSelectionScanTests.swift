import XCTest
@testable import LedgerMobile

final class LocalTransactionSelectionScanTests: XCTestCase {
    private func row(_ id: Int, payee: String = "Synthetic", hash: String? = "exact") -> LedgerTransaction {
        LedgerTransaction(date: "2026-09-23", payee: payee, narration: "selection",
            postings: [.init(account: "Expenses:Food", amount: 1, currency: "CNY")],
            source: .init(file: "synthetic.bean", line: id, hash: hash))
    }
    private func page(_ rows: [LedgerTransaction], next: String? = nil, revision: String = "r") -> LedgerTransactionPage {
        .init(revision: revision, transactions: rows, nextCursor: next, sensitiveUnlocked: true)
    }

    func testSelectionScopesMatchLegacyAcrossFilterHiddenAndBlockedRows() throws {
        let rows = [row(1, payee: "Needle"), row(2), row(3, payee: "Needle"), row(4, hash: nil)]
        var scan = try LocalTransactionSelectionScan(revision: "r", filter: .init(query: "Needle"),
            selectedIDs: Set(rows.map(\.id)), blockedIDs: [rows[2].id])
        XCTAssertNil(try scan.consume(page(Array(rows.prefix(2)), next: "n"), requestedCursor: nil))
        let result = try XCTUnwrap(scan.consume(page(Array(rows.suffix(2))), requestedCursor: "n"))
        XCTAssertEqual(result.rangeCount, 4)
        XCTAssertEqual(result.matchingCount, 2)
        XCTAssertEqual(result.selectedCount, 4)
        XCTAssertEqual(result.selectedMatchingCount, 2)
        XCTAssertEqual(result.selectedEligibleCount, 2)
        XCTAssertEqual(result.selectedMatchingEligibleCount, 1)
        XCTAssertEqual(result.tagSources, Array(rows.prefix(2)).map(\.source))
        XCTAssertTrue(result.allMatchingSelected)
    }

    func testEmptyAndMissingIDsDoNotBecomeImplicitAllSelection() throws {
        for selection in [Set<String>(), ["missing"]] {
            var scan = try LocalTransactionSelectionScan(revision: "r", filter: .init(), selectedIDs: selection)
            let result = try XCTUnwrap(scan.consume(page([row(1)]), requestedCursor: nil))
            XCTAssertEqual(result.selectedCount, 0)
            XCTAssertEqual(result.tagSources, [])
            XCTAssertFalse(result.allMatchingSelected)
        }
        var scan = try LocalTransactionSelectionScan(revision: "r", filter: .init(query: "absent"), selectedIDs: [row(1).id])
        let result = try XCTUnwrap(scan.consume(page([row(1)]), requestedCursor: nil))
        XCTAssertEqual(result.selectedCount, 1)
        XCTAssertEqual(result.selectedMatchingCount, 0)
        XCTAssertFalse(result.allMatchingSelected)
    }

    func testExistingTagLimitReportsWholeBatchUnavailableNotPartialSources() throws {
        let rows = (1...201).map { row($0) }
        var scan = try LocalTransactionSelectionScan(revision: "r", filter: .init(), selectedIDs: Set(rows.map(\.id)))
        let result = try XCTUnwrap(scan.consume(page(rows), requestedCursor: nil))
        XCTAssertEqual(result.selectedEligibleCount, 201)
        XCTAssertNil(result.tagSources)
        XCTAssertTrue(result.allMatchingSelected)
    }

    func testRevisionAndCursorErrorsPoisonSelectionScan() throws {
        var scan = try LocalTransactionSelectionScan(revision: "r", filter: .init(), selectedIDs: [row(1).id])
        XCTAssertNil(try scan.consume(page([row(1)], next: "n"), requestedCursor: nil))
        XCTAssertThrowsError(try scan.consume(page([row(2)], revision: "changed"), requestedCursor: "n"))
        XCTAssertThrowsError(try scan.consume(page([]), requestedCursor: "n"))
    }

    func testSourceByteBudgetExactFitOverflowAndOptionalFieldsAcrossPages() throws {
        let a = row(1), b = row(2)
        let bytes = try LocalTransactionSelectionScan.sourceBytes(a.source) + LocalTransactionSelectionScan.sourceBytes(b.source)
        for budget in [bytes, bytes - 1] {
            var scan = try LocalTransactionSelectionScan(revision: "r", filter: .init(),
                selectedIDs: [a.id, b.id], maximumSourceBytes: budget)
            XCTAssertNil(try scan.consume(page([a], next: "n"), requestedCursor: nil))
            if budget == bytes {
                XCTAssertEqual(try scan.consume(page([b]), requestedCursor: "n")?.tagSources, [a.source, b.source])
                XCTAssertEqual(scan.retainedSourceBytes, bytes)
            } else {
                XCTAssertThrowsError(try scan.consume(page([b]), requestedCursor: "n")) {
                    XCTAssertEqual($0 as? LocalTransactionSelectionScan.SelectionError, .sourceBytes)
                }
                XCTAssertEqual(scan.retainedSourceBytes, 0)
                XCTAssertThrowsError(try scan.consume(page([]), requestedCursor: "n"))
            }
        }
        for field in 0..<3 {
            let large = String(repeating: "x", count: 260_000)
            let source = TransactionSource(file: field == 0 ? large : "s.bean", line: 1,
                hash: field == 1 ? large : "hash", gitSHA: field == 2 ? large : nil)
            let tx = LedgerTransaction(date: "2026-09-23", payee: "", narration: "", postings: [], source: source)
            var scan = try LocalTransactionSelectionScan(revision: "r", filter: .init(), selectedIDs: [tx.id], maximumSourceBytes: 1_024)
            XCTAssertThrowsError(try scan.consume(page([tx]), requestedCursor: nil))
        }
    }

    func testEmptyIntermediatePageWrongCursorAndAfterEOFRejected() throws {
        var scan = try LocalTransactionSelectionScan(revision: "r", filter: .init(), selectedIDs: [row(1).id])
        XCTAssertNil(try scan.consume(page([], next: "n"), requestedCursor: nil))
        XCTAssertThrowsError(try scan.consume(page([row(1)]), requestedCursor: "wrong"))
        var complete = try LocalTransactionSelectionScan(revision: "r", filter: .init(), selectedIDs: [])
        XCTAssertNotNil(try complete.consume(page([]), requestedCursor: nil))
        XCTAssertThrowsError(try complete.consume(page([]), requestedCursor: nil))
    }

    func testHundredThousandRowsCountWithoutCollectingHistoryIDsOrRows() throws {
        // Only one explicitly selected ID is retained, not all history IDs.
        var scan = try LocalTransactionSelectionScan(revision: "r", filter: .init(), selectedIDs: [row(99_999).id])
        var result: LocalTransactionSelectionScan.Result?
        for index in 0..<200 {
            let rows = (0..<500).map { row(index * 500 + $0) }
            result = try scan.consume(page(rows, next: index == 199 ? nil : String(index + 1)),
                requestedCursor: index == 0 ? nil : String(index))
            if index < 199 { XCTAssertNil(result) }
        }
        XCTAssertEqual(result?.rangeCount, 100_000)
        XCTAssertEqual(result?.selectedCount, 1)
        XCTAssertEqual(result?.tagSources, [row(99_999).source])
        XCTAssertFalse(try XCTUnwrap(result).allMatchingSelected)
    }
}
