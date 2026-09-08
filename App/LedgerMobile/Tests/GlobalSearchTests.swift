import XCTest
@testable import LedgerMobile

final class GlobalSearchTests: XCTestCase {
    func testSearchAcrossDatesAmountsMetadataAliasesTagsAndFiles() {
        let transaction = LedgerTransaction(date: "2020-01-02", payee: "Coffee", narration: "旅行早餐", metadata: ["receipt": .string("ORDER-987")], tags: ["旅行"], postings: [LedgerPosting(account: "Expenses:Food", amount: 1250, currency: "CNY")], source: TransactionSource(file: "2020.bean", line: 1, hash: "hash", gitSHA: "sha"))
        let account = LedgerAccount(account: "Expenses:Food", openDate: "2020-01-01", closeDate: nil, currency: "CNY", alias: "餐饮", label: "饮食", group: "Expenses", active: true)
        let document = LedgerImportDocument(name: "账单.csv", provider: "alipay", dateStart: "2020-01-01", dateEnd: "2020-02-01", modTime: "2020-02-02")
        for query in ["coffee", "2020-01", "12.5", "ORDER-987", "餐饮", "旅行", "Coffee 12.5"] {
            XCTAssertEqual(LedgerGlobalSearch.search(query, transactions: [transaction], accounts: [account], documents: [document]).transactions.count, 1, query)
        }
        let result = LedgerGlobalSearch.search("旅行", transactions: [transaction], accounts: [account], documents: [])
        XCTAssertEqual(result.tags, ["旅行"])
        XCTAssertEqual(LedgerGlobalSearch.search("餐饮", transactions: [], accounts: [account], documents: []).accounts.count, 1)
        XCTAssertEqual(LedgerGlobalSearch.search("账单.csv", transactions: [], accounts: [], documents: [document]).documents.count, 1)
        XCTAssertEqual(LedgerGlobalSearch.search("faceid", transactions: [], accounts: [], documents: []).destinations, [.settings])
        XCTAssertTrue(LedgerGlobalSearch.search("不存在", transactions: [transaction], accounts: [account], documents: [document]).isEmpty)
        XCTAssertTrue(LedgerGlobalSearch.search("  ", transactions: [transaction], accounts: [account], documents: [document]).isEmpty)
        XCTAssertEqual(LedgerDestination.search.compactSelection(in: [.overview]), .search)
        XCTAssertFalse(LedgerDestination.compactTabCandidates.contains(.search))
    }
}
