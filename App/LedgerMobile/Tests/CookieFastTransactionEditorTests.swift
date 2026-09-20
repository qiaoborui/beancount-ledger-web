import XCTest
@testable import LedgerMobile

final class CookieFastTransactionEditorTests: XCTestCase {

    func testCalculatorBasicOperations() {
        var calc = CookieKeypadCalculator()
        calc.appendDigit("1")
        calc.appendDigit("2")
        calc.appendDigit(".")
        calc.appendDigit("5")
        XCTAssertEqual(calc.displayText, "12.5")
        XCTAssertEqual(calc.evaluatedResult, Decimal(string: "12.5"))

        calc.appendOperator("+")
        calc.appendDigit("7")
        calc.appendDigit(".")
        calc.appendDigit("5")
        XCTAssertEqual(calc.displayText, "12.5+7.5")
        XCTAssertEqual(calc.evaluatedResult, Decimal(20))

        calc.evaluateToResult()
        XCTAssertEqual(calc.displayText, "20")
    }

    func testCalculatorDeleteAndClear() {
        var calc = CookieKeypadCalculator()
        calc.appendDigit("5")
        calc.appendDigit("0")
        calc.deleteLast()
        XCTAssertEqual(calc.displayText, "5")

        calc.clear()
        XCTAssertEqual(calc.displayText, "0")
    }

    func testCurrencySymbols() {
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "CNY"), "¥")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "USD"), "$")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "EUR"), "€")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "GBP"), "£")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "HKD"), "HK$")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "JPY"), "¥")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "CAD"), "CAD")
    }

    func testDefaultCategories() {
        let expenses = CookieCategoryItem.expenseCategories
        XCTAssertFalse(expenses.isEmpty)
        XCTAssertTrue(expenses.contains(where: { $0.id == "food" }))
        XCTAssertTrue(expenses.contains(where: { $0.id == "transport" }))

        let incomes = CookieCategoryItem.incomeCategories
        XCTAssertFalse(incomes.isEmpty)
        XCTAssertTrue(incomes.contains(where: { $0.id == "salary" }))
        XCTAssertTrue(incomes.contains(where: { $0.id == "bonus" }))
    }
}
