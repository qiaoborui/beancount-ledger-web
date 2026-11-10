import Foundation
import XCTest
@testable import LedgerMobile

final class OpeningBalanceParsingTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")
    private let german = Locale(identifier: "de_DE")

    func testParsesPlainAmounts() {
        XCTAssertEqual(LedgerSession.parseOpeningBalance("1000", locale: posix), Decimal(1000))
        XCTAssertEqual(LedgerSession.parseOpeningBalance(" 12.50 ", locale: posix), Decimal(string: "12.5"))
        XCTAssertEqual(LedgerSession.parseOpeningBalance("-3.2", locale: posix), Decimal(string: "-3.2"))
        XCTAssertEqual(LedgerSession.parseOpeningBalance(".5", locale: posix), Decimal(string: "0.5"))
    }

    func testCommaDecimalLocaleKeepsTheFraction() {
        // A de_DE decimalPad types "12,50"; Decimal(string:) alone read 12.
        XCTAssertEqual(LedgerSession.parseOpeningBalance("12,50", locale: german), Decimal(string: "12.5"))
    }

    func testRejectsInputInsteadOfTruncating() {
        XCTAssertNil(LedgerSession.parseOpeningBalance("12,50", locale: posix))
        XCTAssertNil(LedgerSession.parseOpeningBalance("abc", locale: posix))
        XCTAssertNil(LedgerSession.parseOpeningBalance("12abc", locale: posix))
        XCTAssertNil(LedgerSession.parseOpeningBalance("1.2.3", locale: posix))
        XCTAssertNil(LedgerSession.parseOpeningBalance("-", locale: posix))
    }
}
