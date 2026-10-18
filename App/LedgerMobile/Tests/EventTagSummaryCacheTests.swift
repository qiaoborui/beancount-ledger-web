import XCTest
@testable import LedgerMobile

/// `summarizeAllTags` is called from computed properties inside view bodies, so
/// the same input was rescanned on every unrelated publish. It now memoizes the
/// last aggregation. The cache must key on content, never on identity.
final class EventTagSummaryCacheTests: XCTestCase {
    private func transaction(_ line: Int, tags: [String], expense: Int) -> LedgerTransaction {
        LedgerTransaction(
            date: "2026-09-0\(line)",
            payee: "商户\(line)",
            narration: "",
            tags: tags,
            postings: [
                LedgerPosting(account: "Expenses:Food", amount: expense, currency: "CNY"),
                LedgerPosting(account: "Assets:Bank", amount: -expense, currency: "CNY"),
            ],
            source: TransactionSource(file: "test.bean", line: line, hash: nil, gitSHA: nil)
        )
    }

    func testRepeatedCallReturnsTheSameResult() {
        let rows = [transaction(1, tags: ["trip"], expense: 100),
                    transaction(2, tags: ["trip", "work"], expense: 250)]
        let first = EventTagCalculator.summarizeAllTags(from: rows)
        let second = EventTagCalculator.summarizeAllTags(from: rows)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.tag), ["trip", "work"].sorted())
    }

    /// Different content with the same shape must not be served from the cache.
    func testDifferentTransactionsProduceDifferentResults() {
        let base = [transaction(1, tags: ["trip"], expense: 100)]
        let first = EventTagCalculator.summarizeAllTags(from: base)

        let changed = [transaction(1, tags: ["trip"], expense: 900)]
        let second = EventTagCalculator.summarizeAllTags(from: changed)

        XCTAssertEqual(first.first?.totalExpense, 100)
        XCTAssertEqual(second.first?.totalExpense, 900,
            "a changed amount must not return the cached summary")
    }

    /// Labels change the reported category names, so they are part of the key.
    func testDifferentLabelsProduceDifferentResults() {
        let rows = [transaction(1, tags: ["trip"], expense: 100)]
        let unlabelled = EventTagCalculator.summarizeAllTags(from: rows)
        let labelled = EventTagCalculator.summarizeAllTags(from: rows,
            accountLabels: ["Expenses:Food": "餐饮"])
        XCTAssertEqual(unlabelled, labelled, "summary fields do not include category labels")

        // An empty-tag call must still see the new transaction set.
        let more = rows + [transaction(2, tags: ["work"], expense: 50)]
        let extended = EventTagCalculator.summarizeAllTags(from: more)
        XCTAssertEqual(extended.map(\.tag).sorted(), ["trip", "work"])
    }
}
