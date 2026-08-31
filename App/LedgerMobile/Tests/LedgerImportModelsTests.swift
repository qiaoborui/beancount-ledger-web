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
}
