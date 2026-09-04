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

    func testNativeCapabilityRemovesAutomaticEmailWithoutHidingManualStatementFormats() throws {
        let providers = [
            LedgerImportProviderInfo(
                id: "ccb-credit",
                label: "建设银行信用卡",
                detail: "邮件或 PDF",
                extensions: ["eml", ".PDF", ".csv"],
                accept: ".eml / .pdf",
                engine: "native-ccb-credit"
            ),
            LedgerImportProviderInfo(
                id: "gmail-auto",
                label: "Gmail 自动账单",
                detail: "自动同步邮件账单",
                extensions: [".eml"],
                accept: ".eml",
                engine: "gmail"
            ),
        ]
        let nativeProviders = LedgerMobileImportCapabilities.fileImportProviders(from: providers)

        XCTAssertFalse(LedgerMobileImportCapabilities.supportsAutomaticEmailImport)
        XCTAssertEqual(nativeProviders.map(\.id), ["ccb-credit"])
        XCTAssertEqual(nativeProviders[0].extensions, ["eml", ".PDF", ".csv"])
        XCTAssertEqual(nativeProviders[0].detail, "邮件或 PDF")
        XCTAssertNoThrow(try LedgerImportFileValidator.validate(
            name: "statement.PDF",
            byteCount: LedgerImportFileValidator.maximumBytes,
            providers: nativeProviders
        ))
        XCTAssertNoThrow(try LedgerImportFileValidator.validate(
            name: "statement.zip",
            byteCount: 1,
            providers: nativeProviders
        ))
        XCTAssertNoThrow(try LedgerImportFileValidator.validate(
            name: "statement.EML",
            byteCount: 1,
            providers: nativeProviders
        ))
        XCTAssertNoThrow(try LedgerImportFileValidator.validate(
            name: "statement.html",
            byteCount: 1,
            providers: []
        ))
    }

    func testEmailArchiveHistoryRemainsVisibleAfterNativeEmailImportRemoval() {
        let emailArchive = LedgerImportDocument(
            path: "transactions/2026/documents/imports/statement.eml",
            name: "statement.eml",
            year: "2026",
            ext: ".eml",
            provider: "ccb-credit",
            dateStart: "2026-08-01",
            dateEnd: "2026-08-31",
            size: 1_024,
            modTime: "2026-09-01T08:00:00Z"
        )

        XCTAssertEqual(LedgerImportHistory.sortedDocuments([emailArchive]), [emailArchive])
    }

    func testCommitFailureDispositionProtectsUnknownWriteOutcomes() {
        XCTAssertEqual(
            LedgerImportCommitFailureDisposition(error: LedgerAPIError.transport("connection lost")),
            .outcomeUnknown
        )
        XCTAssertEqual(
            LedgerImportCommitFailureDisposition(error: LedgerAPIError.decoding("truncated JSON")),
            .outcomeUnknown
        )
        XCTAssertEqual(
            LedgerImportCommitFailureDisposition(error: LedgerAPIError.invalidResponse),
            .outcomeUnknown
        )
        XCTAssertEqual(
            LedgerImportCommitFailureDisposition(error: LedgerAPIError.server(status: 400, message: "invalid")),
            .failed
        )
    }

    func testCommitReconciliationRequiresExactImportIDSuffix() throws {
        let expected = LedgerImportDocument(
            path: "transactions/2026/documents/imports/2026-08-01_2026-08-31-wechat-preview-123.xlsx",
            name: "2026-08-01_2026-08-31-wechat-preview-123.xlsx",
            provider: "wechat",
            dateStart: "2026-08-01",
            dateEnd: "2026-08-31",
            modTime: "2026-09-01T08:00:00Z"
        )
        let collision = LedgerImportDocument(
            path: "transactions/2026/documents/imports/2026-08-01_2026-08-31-wechat-preview-1234.xlsx",
            name: "2026-08-01_2026-08-31-wechat-preview-1234.xlsx",
            provider: "wechat",
            dateStart: "2026-08-01",
            dateEnd: "2026-08-31",
            modTime: "2026-09-01T08:01:00Z"
        )

        XCTAssertEqual(
            LedgerImportCommitReconciliation.archivedDocument(
                importID: "preview-123",
                in: [collision, expected]
            ),
            expected
        )
        XCTAssertNil(
            LedgerImportCommitReconciliation.archivedDocument(
                importID: "preview-12",
                in: [collision, expected]
            )
        )
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
            fundingAccount: "Assets:Bank:Daily",
            tags: ["books", "travel"]
        )

        XCTAssertEqual(updated.date, "2026-09-02")
        XCTAssertEqual(updated.flag, "!")
        XCTAssertEqual(updated.payee, "城市书房")
        XCTAssertEqual(updated.narration, "九月新书")
        XCTAssertEqual(updated.amount, 18.75)
        XCTAssertEqual(updated.categoryAccount, "Expenses:Education:Books")
        XCTAssertEqual(updated.fundingAccount, "Assets:Bank:Daily")
        XCTAssertEqual(updated.tags, ["books", "travel"])
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

    func testTagRulesNormalizeValidateAndRejectInvalidTags() throws {
        XCTAssertEqual(
            try LedgerTagRules.parse("#travel, dining  travel，trip-2026"),
            ["dining", "travel", "trip-2026"]
        )
        XCTAssertThrowsError(try LedgerTagRules.parse("旅行")) { error in
            XCTAssertEqual(error as? LedgerTagValidationError, .invalid("旅行"))
        }
        XCTAssertThrowsError(try LedgerTagRules.parse("travel#")) { error in
            XCTAssertEqual(error as? LedgerTagValidationError, .invalid("travel#"))
        }
        XCTAssertThrowsError(try LedgerTagRules.validating((0...50).map { "tag-\($0)" })) { error in
            XCTAssertEqual(error as? LedgerTagValidationError, .tooMany)
        }
        XCTAssertThrowsError(try LedgerTagRules.parse("")) { error in
            XCTAssertEqual(error as? LedgerTagValidationError, .empty)
        }
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
