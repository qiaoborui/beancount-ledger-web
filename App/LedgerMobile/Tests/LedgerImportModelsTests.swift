import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerImportModelsTests: XCTestCase {
    func testSelectedFileNormalizesExtensionAndDetectsZIP() {
        XCTAssertEqual(
            LedgerImportSelectedFile(name: "微信账单.XLSX", data: Data([1])).fileExtension,
            ".xlsx"
        )
        XCTAssertTrue(LedgerImportSelectedFile(name: "账单.ZIP", data: Data([1])).isZIP)
        XCTAssertEqual(LedgerImportSelectedFile(name: "账单", data: Data([1])).fileExtension, "")
    }

    func testFileValidatorAcceptsServerExtensionsAndMaximumSize() throws {
        let providers = [
            LedgerImportProviderInfo(
                id: "ccb-credit",
                label: "建设银行信用卡",
                detail: "邮件或 PDF",
                extensions: ["eml", ".PDF"],
                accept: ".eml / .pdf",
                engine: "native-ccb-credit"
            ),
        ]

        XCTAssertNoThrow(try LedgerImportFileValidator.validate(
            name: "statement.EML",
            byteCount: LedgerImportFileValidator.maximumBytes,
            providers: providers
        ))
        XCTAssertNoThrow(try LedgerImportFileValidator.validate(
            name: "statement.zip",
            byteCount: 1,
            providers: providers
        ))
    }

    func testFileValidatorRejectsEmptyOversizedAndUnsupportedFiles() {
        XCTAssertThrowsError(try LedgerImportFileValidator.validate(
            name: "statement.csv",
            byteCount: 0,
            providers: []
        )) { error in
            XCTAssertEqual(error as? LedgerImportFileValidationError, .empty)
        }

        XCTAssertThrowsError(try LedgerImportFileValidator.validate(
            name: "statement.csv",
            byteCount: LedgerImportFileValidator.maximumBytes + 1,
            providers: []
        )) { error in
            XCTAssertEqual(error as? LedgerImportFileValidationError, .tooLarge)
        }

        XCTAssertThrowsError(try LedgerImportFileValidator.validate(
            name: "statement.txt",
            byteCount: 1,
            providers: []
        )) { error in
            XCTAssertEqual(error as? LedgerImportFileValidationError, .unsupported(".txt"))
        }

        XCTAssertThrowsError(try LedgerImportFileValidator.validate(
            name: "statement",
            byteCount: 1,
            providers: []
        )) { error in
            XCTAssertEqual(error as? LedgerImportFileValidationError, .unsupported(""))
        }
    }

    func testReviewEditsUpdateTextAccountsAndBalancedMainAmount() {
        let entry = makeEntry(
            amount: 12.30,
            tags: ["travel", "trip-2026-shanghai"],
            postings: [
                LedgerImportPosting(
                    account: "Expenses:Food",
                    amount: "12.30",
                    currency: "CNY",
                    priceKind: nil,
                    priceAmount: nil,
                    priceCurrency: nil
                ),
                LedgerImportPosting(
                    account: "Assets:Wechat",
                    amount: "-12.30",
                    currency: "CNY",
                    priceKind: nil,
                    priceAmount: nil,
                    priceCurrency: nil
                ),
            ]
        )

        XCTAssertTrue(entry.supportsMainAmountEditing)
        let updated = entry.applyingReviewEdits(
            date: "2026-09-02",
            flag: "!",
            payee: "  城市书房  ",
            narration: "  九月新书  ",
            amount: 18.75,
            categoryAccount: "Expenses:Education:Books",
            fundingAccount: "Assets:Bank:Daily"
        )

        XCTAssertEqual(updated.date, "2026-09-02")
        XCTAssertEqual(updated.flag, "!")
        XCTAssertEqual(updated.payee, "城市书房")
        XCTAssertEqual(updated.narration, "九月新书")
        XCTAssertEqual(updated.amount, 18.75)
        XCTAssertEqual(updated.categoryAccount, "Expenses:Education:Books")
        XCTAssertEqual(updated.fundingAccount, "Assets:Bank:Daily")
        XCTAssertEqual(updated.tags, ["travel", "trip-2026-shanghai"])
        XCTAssertEqual(updated.postings.map(\.account), ["Expenses:Education:Books", "Assets:Bank:Daily"])
        XCTAssertEqual(updated.postings.map(\.amount), ["18.75", "-18.75"])
    }

    func testImportEntryCodablePreservesTags() throws {
        let entry = makeEntry(
            amount: 12.30,
            tags: ["travel", "trip-2026-shanghai"],
            postings: [
                LedgerImportPosting(account: "Expenses:Food", amount: "12.30", currency: "CNY", priceKind: nil, priceAmount: nil, priceCurrency: nil),
                LedgerImportPosting(account: "Assets:Wechat", amount: "-12.30", currency: "CNY", priceKind: nil, priceAmount: nil, priceCurrency: nil),
            ]
        )

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LedgerImportEntry.self, from: encoded)

        XCTAssertEqual(decoded.tags, ["travel", "trip-2026-shanghai"])
    }

    func testComplexReviewEntryKeepsOriginalAmountsWhileUpdatingAccounts() {
        let entry = makeEntry(
            amount: 20,
            postings: [
                LedgerImportPosting(account: "Expenses:Food", amount: "12.00", currency: "CNY", priceKind: nil, priceAmount: nil, priceCurrency: nil),
                LedgerImportPosting(account: "Expenses:Transport", amount: "8.00", currency: "CNY", priceKind: nil, priceAmount: nil, priceCurrency: nil),
                LedgerImportPosting(account: "Assets:Wechat", amount: "-20.00", currency: "CNY", priceKind: nil, priceAmount: nil, priceCurrency: nil),
            ]
        )

        XCTAssertFalse(entry.supportsMainAmountEditing)
        let updated = entry.applyingReviewEdits(
            date: entry.date,
            flag: entry.flag,
            payee: entry.payee,
            narration: entry.narration,
            amount: 99,
            categoryAccount: "Expenses:Daily",
            fundingAccount: "Assets:Bank:Daily"
        )

        XCTAssertEqual(updated.amount, 20)
        XCTAssertEqual(updated.postings.map(\.amount), ["12.00", "8.00", "-20.00"])
        XCTAssertEqual(updated.postings.map(\.account), ["Expenses:Daily", "Expenses:Transport", "Assets:Bank:Daily"])
    }

    func testHighPrecisionReviewEntryKeepsOriginalAmounts() {
        let entry = makeEntry(
            amount: 12.345,
            postings: [
                LedgerImportPosting(account: "Expenses:Food", amount: "12.345", currency: "CNY", priceKind: nil, priceAmount: nil, priceCurrency: nil),
                LedgerImportPosting(account: "Assets:Wechat", amount: "-12.345", currency: "CNY", priceKind: nil, priceAmount: nil, priceCurrency: nil),
            ]
        )

        XCTAssertFalse(entry.supportsMainAmountEditing)
        let updated = entry.applyingReviewEdits(
            date: entry.date,
            flag: entry.flag,
            payee: "新商家",
            narration: entry.narration,
            amount: 12.35,
            categoryAccount: entry.categoryAccount,
            fundingAccount: entry.fundingAccount
        )

        XCTAssertEqual(updated.amount, 12.345)
        XCTAssertEqual(updated.postings.map(\.amount), ["12.345", "-12.345"])
        XCTAssertEqual(updated.payee, "新商家")
    }

    func testUnsafeReviewAmountKeepsOriginalAmounts() {
        let entry = makeEntry(
            amount: 12.30,
            postings: [
                LedgerImportPosting(account: "Expenses:Food", amount: "12.30", currency: "CNY", priceKind: nil, priceAmount: nil, priceCurrency: nil),
                LedgerImportPosting(account: "Assets:Wechat", amount: "-12.30", currency: "CNY", priceKind: nil, priceAmount: nil, priceCurrency: nil),
            ]
        )

        let updated = entry.applyingReviewEdits(
            date: entry.date,
            flag: entry.flag,
            payee: entry.payee,
            narration: entry.narration,
            amount: .infinity,
            categoryAccount: entry.categoryAccount,
            fundingAccount: entry.fundingAccount
        )

        XCTAssertEqual(updated.amount, 12.30)
        XCTAssertEqual(updated.postings.map(\.amount), ["12.30", "-12.30"])
    }

    private func makeEntry(
        amount: Double,
        tags: [String]? = nil,
        postings: [LedgerImportPosting]
    ) -> LedgerImportEntry {
        LedgerImportEntry(
            id: "entry-1",
            date: "2026-09-01",
            flag: "*",
            payee: "原商家",
            narration: "原标题",
            source: "wechat",
            orderID: "order-1",
            merchantID: nil,
            payTime: nil,
            method: "零钱",
            transactionType: nil,
            status: nil,
            type: nil,
            categoryAccount: "Expenses:Food",
            fundingAccount: "Assets:Wechat",
            amount: amount,
            currency: "CNY",
            tags: tags,
            metadata: [:],
            postings: postings
        )
    }
}
