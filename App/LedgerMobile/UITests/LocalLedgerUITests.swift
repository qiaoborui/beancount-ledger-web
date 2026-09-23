import XCTest

@MainActor
final class LocalLedgerUITests: XCTestCase {
    func testLocalContextActionsHydrateCancelReopenAndCommit() throws {
        continueAfterFailure = false
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
        XCTAssertTrue(app.buttons["高级"].waitForExistence(timeout: 5))
        app.buttons["高级"].tap()
        let payee = app.textFields["transaction-edit-payee"]
        XCTAssertTrue(payee.waitForExistence(timeout: 5))
        payee.tap(); payee.typeText("Synthetic context action")
        let amount = app.textFields["transaction-edit-posting-amount-0"]
        replaceActionText(amount, with: "12.34", in: app)
        replaceActionText(app.textFields["transaction-edit-posting-amount-1"], with: "-12.34", in: app)
        app.buttons["transaction-edit-save"].tap()
        XCTAssertTrue(app.buttons["bookkeeping-confirm-save"].waitForExistence(timeout: 30))
        app.buttons["bookkeeping-confirm-save"].tap()
        XCTAssertTrue(app.navigationBars["流水"].waitForExistence(timeout: 30))
        let row = app.staticTexts["Synthetic context action"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for action in ["edit", "tags", "delete"] {
            row.press(forDuration: 1)
            let menu = app.buttons["transaction-context-" + action].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
            if action == "edit" {
                let cancel = app.buttons["取消"].firstMatch
                XCTAssertTrue(cancel.waitForExistence(timeout: 15)); cancel.tap()
                XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
            } else {
                let control = action == "tags" ? app.textFields["transaction-bulk-tag-input"] : app.buttons["transaction-delete-confirm"]
                XCTAssertTrue(control.waitForExistence(timeout: 15))
                app.buttons["取消"].firstMatch.tap()
                XCTAssertTrue(control.waitForNonExistence(timeout: 5))
            }
        }
        // The detail screen also hydrates and prepares fresh authority; merely
        // opening/cancelling either editor must not revoke a future action.
        row.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 10))
        let edit = app.buttons["transaction-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: edit)
        waitForExpectations(timeout: 15)
        edit.tap()
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15)); cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        app.buttons["transaction-delete"].tap()
        let detailConfirm = app.buttons["transaction-delete-confirm"]
        XCTAssertTrue(detailConfirm.waitForExistence(timeout: 15))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(detailConfirm.waitForNonExistence(timeout: 5))
        app.buttons["transaction-edit"].tap()
        XCTAssertTrue(app.buttons["高级"].waitForExistence(timeout: 15))
        app.buttons["高级"].tap()
        replaceActionText(app.textFields["transaction-edit-payee"], with: "Synthetic action edited", in: app)
        app.buttons["transaction-edit-save"].tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForNonExistence(timeout: 30))
        let editedRow = app.staticTexts["Synthetic action edited"].firstMatch
        XCTAssertTrue(editedRow.waitForExistence(timeout: 15), app.debugDescription)
        // Swipe actions use the same exact-source authority, not a summary draft.
        editedRow.swipeLeft()
        let swipeEdit = app.buttons["编辑"].firstMatch
        XCTAssertTrue(swipeEdit.waitForExistence(timeout: 5)); swipeEdit.tap()
        XCTAssertTrue(app.buttons["取消"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.buttons["取消"].firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["transaction-actions"].tap()
        app.buttons["transaction-tag-selection"].tap()
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-select-row-'")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5)); selected.tap()
        app.buttons["添加标签"].tap()
        let tagInput = app.textFields["transaction-bulk-tag-input"]
        XCTAssertTrue(tagInput.waitForExistence(timeout: 15))
        tagInput.tap(); tagInput.typeText("synthetic-reviewed")
        app.buttons["transaction-bulk-tag-apply"].tap()
        XCTAssertTrue(tagInput.waitForNonExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["已验证，并为 1 条交易添加标签。"].waitForExistence(timeout: 10))
        editedRow.press(forDuration: 1)
        app.buttons["transaction-context-delete"].firstMatch.tap()
        let confirm = app.buttons["transaction-delete-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(editedRow.waitForNonExistence(timeout: 15), app.debugDescription)
        #else
        throw XCTSkip("Isolated synthetic simulator ledger only")
        #endif
    }

    private func replaceActionText(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.press(forDuration: 1)
        let predicate = NSPredicate(format: "label IN %@", ["Select All", "全选"])
        let options = app.menuItems.matching(predicate).allElementsBoundByIndex
            + app.buttons.matching(predicate).allElementsBoundByIndex
        if let all = options.first(where: { $0.isHittable }) { all.tap() }
        else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
            let old = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

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
