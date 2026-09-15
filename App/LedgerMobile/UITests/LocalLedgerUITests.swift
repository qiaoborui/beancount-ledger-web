import XCTest

@MainActor
final class LocalLedgerUITests: XCTestCase {
    func testCreateOfflineLedgerAddTransactionAndRestart() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["https://ledger.example.com"].exists)
        app.buttons["local-ledger-create"].tap()
        XCTAssertTrue(app.buttons["local-ledger-confirm-create"].waitForExistence(timeout: 5))
        app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.navigationBars["财务概览"].waitForExistence(timeout: 30), app.debugDescription)
        app.tabBars.buttons["交易"].tap()
        XCTAssertTrue(app.buttons["transaction-create-local"].waitForExistence(timeout: 5))
        app.buttons["transaction-create-local"].tap()
        let payee = app.textFields["transaction-edit-payee"]
        XCTAssertTrue(payee.waitForExistence(timeout: 5))
        payee.tap()
        payee.typeText("Offline coffee")
        let amount = app.textFields["transaction-edit-posting-amount-0"]
        amount.tap()
        amount.typeText("12.34")
        app.buttons["transaction-edit-save"].tap()
        XCTAssertTrue(app.buttons["transaction-create-confirm"].waitForExistence(timeout: 5))
        app.buttons["transaction-create-confirm"].tap()
        XCTAssertTrue(app.navigationBars["流水"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Offline coffee"].firstMatch.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "local-offline-transaction"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["财务概览"].waitForExistence(timeout: 30), app.debugDescription)
        app.tabBars.buttons["交易"].tap()
        XCTAssertTrue(app.staticTexts["Offline coffee"].firstMatch.waitForExistence(timeout: 10))
        #else
        throw XCTSkip("Simulator-only isolated authentication fixture; physical runtime uses integration tests and device authentication")
        #endif
    }
}
