import XCTest
@testable import LedgerMobile

final class ImportReviewQueueTests: XCTestCase {
    func testSplitsIncludedEntriesByWhetherTheyNeedThePerson() {
        let entries = [
            entry("ready", category: "Expenses:Food"),
            entry("unknown", category: "Expenses:Unknown"),
            entry("classified", category: "Expenses:Books"),
            entry("excluded", category: "Expenses:Unknown"),
            entry("no-funding", category: "Expenses:Food", funding: ""),
        ]
        let queue = ImportReviewQueue(
            entries: entries,
            included: ["ready", "unknown", "classified", "no-funding"],
            needsReview: ["classified"]
        )

        XCTAssertEqual(queue.pendingIDs, ["unknown", "classified", "no-funding"])
        XCTAssertEqual(queue.readyIDs, ["ready"])
        XCTAssertEqual(queue.uncheckedIDs, ["excluded"])
        XCTAssertEqual(queue.allIDs, entries.map(\.id))
        XCTAssertEqual(queue.count(for: .pending), 3)
        XCTAssertEqual(queue.defaultFilter, .pending)
    }

    func testOpensOnEverythingWhenNothingNeedsConfirmation() {
        let queue = ImportReviewQueue(entries: [entry("a", category: "Expenses:Food")], included: ["a"], needsReview: [])
        XCTAssertEqual(queue.defaultFilter, .all)
    }

    func testNeighborsAndPositionStayWithinTheFilter() {
        let entries = ["a", "b", "c", "d"].map { entry($0, category: $0 == "b" ? "Expenses:Food" : "Expenses:Unknown") }
        let queue = ImportReviewQueue(entries: entries, included: Set(entries.map(\.id)), needsReview: [])

        XCTAssertEqual(queue.pendingIDs, ["a", "c", "d"])
        XCTAssertEqual(queue.neighbor(of: "a", in: .pending, offset: 1), "c")
        XCTAssertEqual(queue.neighbor(of: "c", in: .pending, offset: -1), "a")
        XCTAssertNil(queue.neighbor(of: "d", in: .pending, offset: 1))
        XCTAssertNil(queue.neighbor(of: "b", in: .pending, offset: 1))
        XCTAssertEqual(queue.position(of: "c", in: .pending)?.index, 2)
        XCTAssertEqual(queue.position(of: "c", in: .pending)?.count, 3)
    }

    func testBulkTagsOnlyTouchTheNamedEntries() throws {
        let entries = [entry("a", category: "Expenses:Food", tags: ["dining"]), entry("b", category: "Expenses:Food")]

        let added = try ImportBulkEdit.applyingTags("travel #trip-2026", mode: .add, to: entries, ids: ["a"])
        XCTAssertEqual(added[0].tags, ["dining", "travel", "trip-2026"])
        XCTAssertNil(added[1].tags)

        let removed = try ImportBulkEdit.applyingTags("dining", mode: .remove, to: added, ids: ["a", "b"])
        XCTAssertEqual(removed[0].tags, ["travel", "trip-2026"])

        XCTAssertThrowsError(try ImportBulkEdit.applyingTags("  ", mode: .add, to: entries, ids: ["a"]))
        XCTAssertThrowsError(try ImportBulkEdit.applyingTags("bad tag!", mode: .add, to: entries, ids: ["a"]))
    }

    private func entry(_ id: String, category: String, funding: String = "Assets:Alipay", tags: [String]? = nil) -> LedgerImportEntry {
        LedgerImportEntry(
            id: id, date: "2026-08-01", flag: "*", payee: id, narration: "", source: "alipay",
            orderID: nil, merchantID: nil, payTime: nil, method: nil, transactionType: nil, status: nil, type: nil,
            categoryAccount: category, fundingAccount: funding, amount: 12.5, currency: "CNY", tags: tags,
            metadata: [:], postings: []
        )
    }
}
