import XCTest
@testable import LedgerMobile

final class GlobalSearchTests: XCTestCase {
    private let account = LedgerAccount(account: "Expenses:Food", openDate: "2020-01-01", closeDate: nil, currency: "CNY", alias: "餐饮", label: "饮食", group: "Expenses", active: true)

    private func transaction(_ date: String, account: String = "Expenses:Food", tags: [String] = ["旅行"]) -> LedgerTransaction {
        LedgerTransaction(date: date, payee: "商户", narration: "早餐", tags: tags,
                          postings: [LedgerPosting(account: account, amount: 1250, currency: "CNY")],
                          source: TransactionSource(file: "fixture.bean", line: 1, hash: date + account, gitSHA: "fixture"))
    }

    func testScopeWithEmptyQueryReturnsOnlyRequestedType() {
        let transactions = [transaction("2020-01-01")]
        let documents = [LedgerImportDocument(name: "账单.csv", provider: nil, dateStart: nil, dateEnd: nil, modTime: "2020-02-02")]
        let ledger = LedgerGlobalSearch.search("", transactions: transactions, accounts: [account], documents: documents, scope: .transactions)
        XCTAssertEqual(ledger.transactions.count, 1)
        XCTAssertTrue(ledger.accounts.isEmpty && ledger.tags.isEmpty && ledger.documents.isEmpty && ledger.destinations.isEmpty)
        let accounts = LedgerGlobalSearch.search("", transactions: transactions, accounts: [account], documents: documents, scope: .accounts)
        XCTAssertEqual(accounts.accounts.count, 1)
        XCTAssertTrue(accounts.transactions.isEmpty && accounts.tags.isEmpty && accounts.documents.isEmpty)
        let files = LedgerGlobalSearch.search("", transactions: transactions, accounts: [account], documents: documents, scope: .documents)
        XCTAssertEqual(files.documents.count, 1)
        XCTAssertTrue(files.transactions.isEmpty && files.accounts.isEmpty && files.tags.isEmpty)
    }

    func testAccountTagAndInclusiveDatesCombineWithoutQuery() {
        let transactions = [transaction("2020-01-01"), transaction("2020-01-31"), transaction("2020-02-01"),
                            transaction("2020-01-15", account: "Expenses:Other"), transaction("2020-01-20", tags: ["办公"])]
        let filters = LedgerGlobalSearchFilters(account: "Expenses:Food", tag: "旅行", startDate: "2020-01-01", endDate: "2020-01-31")
        let result = LedgerGlobalSearch.search("", transactions: transactions, accounts: [account], documents: [], filters: filters)
        XCTAssertEqual(result.transactions.map(\.date), ["2020-01-31", "2020-01-01"])
        XCTAssertEqual(result.tags, ["旅行"])
        XCTAssertTrue(result.accounts.isEmpty && result.destinations.isEmpty)
        XCTAssertTrue(LedgerGlobalSearch.search("不存在", transactions: transactions, accounts: [], documents: [], filters: filters).isEmpty)
        XCTAssertTrue(LedgerGlobalSearch.search("", transactions: transactions, accounts: [], documents: [], filters: .init(startDate: "2020-02-01", endDate: "2020-01-01")).isEmpty)
    }

    func testFileCoverageOverlapsDateRangeAndUnknownCoverageIsExcluded() {
        let documents = [
            LedgerImportDocument(name: "overlap.csv", provider: nil, dateStart: "2019-12-01", dateEnd: "2020-01-01", modTime: "2020-02-02"),
            LedgerImportDocument(name: "inside.csv", provider: nil, dateStart: "2020-01-15", dateEnd: "2020-01-20", modTime: "2020-02-02"),
            LedgerImportDocument(name: "outside.csv", provider: nil, dateStart: "2020-02-01", dateEnd: "2020-02-20", modTime: "2020-02-02"),
            LedgerImportDocument(name: "unknown.csv", provider: nil, dateStart: nil, dateEnd: nil, modTime: "2020-01-15"),
        ]
        let result = LedgerGlobalSearch.search("", transactions: [], accounts: [], documents: documents, scope: .documents, filters: .init(startDate: "2020-01-01", endDate: "2020-01-31"))
        XCTAssertEqual(result.documents.compactMap(\.name), ["overlap.csv", "inside.csv"])
        XCTAssertTrue(LedgerGlobalSearch.search("", transactions: [], accounts: [], documents: documents, filters: .init(tag: "旅行")).documents.isEmpty)
    }

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
