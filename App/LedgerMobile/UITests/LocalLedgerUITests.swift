import XCTest

@MainActor
final class LocalLedgerUITests: XCTestCase {
    func testNaturalLanguageSplitReachesValidatedDiffAndLocalSave() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing", "--safe-bookkeeping-parser"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10))
        app.buttons["local-ledger-create"].tap()
        app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.navigationBars["财务概览"].waitForExistence(timeout: 30))
        app.tabBars.buttons["交易"].tap()
        app.buttons["transaction-create-local"].tap()
        app.buttons["bookkeeping-natural-entry"].tap()
        let input = app.textViews["bookkeeping-natural-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Paid 128 CNY cash, including 48 for transport and the remainder for food.")
        app.buttons["bookkeeping-parse"].tap()
        let prepare = app.buttons["bookkeeping-prepare"]
        for _ in 0..<7 where !prepare.exists || !prepare.isHittable { app.swipeUp() }
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        prepare.tap()
        let confirm = app.buttons["bookkeeping-confirm-save"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["完整账本校验通过"].exists)
        let preview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        preview.name = "bookkeeping-split-validated-diff"
        preview.lifetime = .keepAlways
        add(preview)
        confirm.tap()
        // A nested natural-language sheet returns to the original manual editor.
        let cancel = app.buttons["取消"].firstMatch
        if cancel.waitForExistence(timeout: 10) { cancel.tap() }
        XCTAssertTrue(app.staticTexts["Synthetic split"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        #else
        throw XCTSkip("Uses the explicitly isolated synthetic parser")
        #endif
    }

    func testNaturalLanguageEntryExposesSeparateSemanticConfiguration() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10))
        app.buttons["local-ledger-create"].tap()
        app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.navigationBars["财务概览"].waitForExistence(timeout: 30))
        app.tabBars.buttons["交易"].tap()
        app.buttons["transaction-create-local"].tap()
        let natural = app.buttons["bookkeeping-natural-entry"]
        XCTAssertTrue(natural.waitForExistence(timeout: 5))
        natural.tap()
        XCTAssertTrue(app.navigationBars["用一句话记账"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["bookkeeping-natural-input"].exists)
        app.buttons["语义解析设置"].tap()
        XCTAssertTrue(app.navigationBars["语义解析设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Base URL（含 /v1）"].exists)
        XCTAssertTrue(app.textFields["模型名称"].exists)
        XCTAssertTrue(app.secureTextFields.firstMatch.exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "bookkeeping-semantic-settings"
        shot.lifetime = .keepAlways
        add(shot)
        #else
        throw XCTSkip("Uses isolated simulator ledger")
        #endif
    }

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
        XCTAssertTrue(app.buttons["高级"].waitForExistence(timeout: 5))
        app.buttons["高级"].tap()
        let payee = app.textFields["transaction-edit-payee"]
        XCTAssertTrue(payee.waitForExistence(timeout: 5))
        payee.tap()
        payee.typeText("Offline coffee")
        let amount = app.textFields["transaction-edit-posting-amount-0"]
        amount.tap()
        amount.typeText("12.34")
        app.buttons["transaction-edit-save"].tap()
        XCTAssertTrue(app.buttons["bookkeeping-confirm-save"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["完整账本校验通过"].exists)
        app.buttons["bookkeeping-confirm-save"].tap()
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
