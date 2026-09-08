#if canImport(UIKit)
import XCTest
@testable import LedgerMobile

final class TransactionCopyTests: XCTestCase {
    func testSummaryRespectsHiddenAmountsAndOmitsInternalFields() {
        let transaction = LedgerTransaction(date: "2026-09-08", payee: "书店", narration: "阅读", metadata: ["receipt": .string("PRIVATE-RECEIPT")], tags: ["学习"], postings: [LedgerPosting(account: "Expenses:Books", amount: 123456, currency: "CNY")], source: TransactionSource(file: "private-source.bean", line: 99, hash: "PRIVATE-HASH", gitSHA: "PRIVATE-SHA"))
        let hidden = LedgerTransactionCopySummary.text(for: transaction, accounts: [], amountsVisible: false)
        XCTAssertTrue(hidden.contains("金额已隐藏"))
        XCTAssertTrue(hidden.contains("书店"))
        for text in ["1234", "1,234", "PRIVATE", "private-source.bean"] { XCTAssertFalse(hidden.contains(text)) }
        let visible = LedgerTransactionCopySummary.text(for: transaction, accounts: [], amountsVisible: true)
        XCTAssertFalse(visible.contains("金额已隐藏"))
        XCTAssertTrue(visible.contains("1,234.56") || visible.contains("1234.56"))
    }
}
#endif
