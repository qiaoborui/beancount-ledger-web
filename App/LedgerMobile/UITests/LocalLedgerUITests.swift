import XCTest

@MainActor
final class LocalLedgerUITests: XCTestCase {
    func test292TransactionsPageThroughListButtons() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing", "--pagination-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        let seed = app.buttons["test-import-pagination-ledger"]
        XCTAssertTrue(seed.waitForExistence(timeout: 10))
        seed.tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["pagination-fixture-ready"].waitForExistence(timeout: 30))
        app.buttons["terminal-tab-transactions"].tap()
        if !app.textFields["transaction-quick-search"].waitForExistence(timeout: 3) { app.buttons["terminal-tab-transactions"].tap() }
        XCTAssertTrue(app.textFields["transaction-quick-search"].waitForExistence(timeout: 10), app.debugDescription)
        let next = app.buttons["transaction-window-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(app.staticTexts["第 1 页"].exists)
        XCTAssertTrue(next.isHittable)
        capture("transactions-first-page")
        // Scroll away from the top; the pager stays reachable and flips return to the filter.
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(next.isHittable)
        next.tap()
        XCTAssertTrue(app.staticTexts["第 2 页"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["全部"].isHittable)
        next.tap()
        XCTAssertTrue(app.staticTexts["第 3 页"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(next.isEnabled)
        XCTAssertTrue(app.staticTexts["共 292 笔 · 本页 92 笔"].exists)
        capture("transactions-third-page")
        let previous = app.buttons["transaction-window-previous"]
        previous.tap()
        XCTAssertTrue(app.staticTexts["第 2 页"].waitForExistence(timeout: 10))
        previous.tap()
        XCTAssertTrue(app.staticTexts["第 1 页"].waitForExistence(timeout: 10))
        XCTAssertFalse(previous.isEnabled)
        app.buttons["transaction-actions"].tap()
        let sync = app.buttons["transaction-storage"]
        XCTAssertTrue(sync.waitForExistence(timeout: 3), app.debugDescription)
        sync.tap()
        XCTAssertTrue(app.navigationBars["存储与同步"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["完成"].tap()
        app.buttons["transaction-actions"].tap()
        app.buttons["transaction-tag-selection"].tap()
        XCTAssertTrue(next.isHittable)
        next.tap()
        XCTAssertTrue(app.staticTexts["第 2 页"].waitForExistence(timeout: 10))
        app.buttons["完成多选"].tap()
        previous.tap()
        XCTAssertTrue(app.staticTexts["第 1 页"].waitForExistence(timeout: 10))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["正在读取交易"].exists)
        capture("transaction-detail-money-flow")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "DailySpendingAccount")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["资金分录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Assets:Bank:International:DailySpendingAccount"].exists)
        capture("transaction-flow-full-account")
        #else
        throw XCTSkip("Uses isolated simulator ledger")
        #endif
    }

    func testLocalRestartDoesNotShowPassiveLoadingCards() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10))
        app.buttons["local-ledger-create"].tap()
        app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 30))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["正在加载概览汇总…"].exists)
        XCTAssertFalse(app.staticTexts["流水统计加载中…"].exists)
        let overview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        overview.name = "overview-without-loading-card"
        overview.lifetime = .keepAlways
        add(overview)
        app.buttons["terminal-tab-transactions"].tap()
        XCTAssertTrue(app.textFields["transaction-quick-search"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["正在读取流水"].exists)
        XCTAssertFalse(app.staticTexts["统计中…"].exists)
        let transactions = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        transactions.name = "transactions-without-loading-card"
        transactions.lifetime = .keepAlways
        add(transactions)
        #else
        throw XCTSkip("Uses isolated simulator ledger")
        #endif
    }

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
        app.buttons["terminal-tab-transactions"].tap()
        if !app.buttons["transaction-actions"].waitForExistence(timeout: 3) {
            app.buttons["terminal-tab-transactions"].tap()
        }
        XCTAssertTrue(app.buttons["transaction-actions"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["transaction-actions"].tap()
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
        let island = app.otherElements["ledger-dynamic-island-notice"]
        XCTAssertTrue(island.waitForExistence(timeout: 5), "Dynamic Island notice should animate into view after bookkeeping save")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "dynamic-island-entry-verified"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(app.textFields["transaction-quick-search"].waitForExistence(timeout: 30))
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
        XCTAssertFalse(app.staticTexts["正在读取交易"].exists)
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
        app.buttons["transaction-batch-share"].press(forDuration: 1)
        let exportMenu = app.buttons["导出完整文字文件"].firstMatch
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 5)); exportMenu.tap()
        let exportShare = app.buttons["transaction-text-export-share"]
        XCTAssertTrue(exportShare.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '共 1 笔'")).firstMatch.exists)
        app.navigationBars["导出流水文字"].buttons["完成"].tap()
        XCTAssertTrue(exportShare.waitForNonExistence(timeout: 5))
        app.buttons["添加标签"].tap()
        let tagInput = app.textFields["transaction-bulk-tag-input"]
        XCTAssertTrue(tagInput.waitForExistence(timeout: 15))
        tagInput.tap(); tagInput.typeText("synthetic-reviewed")
        app.buttons["transaction-bulk-tag-apply"].tap()
        XCTAssertTrue(tagInput.waitForNonExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["已验证，并为 1 条交易添加标签。"].waitForExistence(timeout: 10))
        app.buttons["transaction-actions"].tap()
        app.buttons["事件与项目核算"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["事件与项目核算"].waitForExistence(timeout: 10))
        let event = app.buttons["event-tag-summary-synthetic-reviewed"]
        XCTAssertTrue(event.waitForExistence(timeout: 20), app.debugDescription)
        event.tap()
        XCTAssertTrue(app.staticTexts["event-report-count"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.staticTexts["event-report-count"].label, "1 笔流水")
        XCTAssertTrue(app.staticTexts["event-report-page"].waitForExistence(timeout: 20))
        let eventRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'event-report-row-'")).firstMatch
        XCTAssertTrue(eventRow.waitForExistence(timeout: 10))
        if !eventRow.isHittable { app.swipeUp() }
        eventRow.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 10))
        app.navigationBars["交易详情"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["event-report-count"].waitForExistence(timeout: 15))
        app.buttons["event-report-export-menu"].tap()
        app.buttons["导出完整 Markdown 文件"].tap()
        let eventFile = app.buttons["event-report-file-share"]
        XCTAssertTrue(eventFile.waitForExistence(timeout: 20), app.debugDescription)
        app.navigationBars["事件文件导出"].buttons["完成"].tap()
        XCTAssertTrue(eventFile.waitForNonExistence(timeout: 5))
        app.navigationBars["#synthetic-reviewed"].buttons.element(boundBy: 0).tap()
        app.buttons["关闭"].firstMatch.tap()
        // Native global search uses complete metadata candidates, not the
        // legacy all-history transaction array. Drill-down must survive refresh.
        app.buttons["terminal-tab-settings"].tap()
        let searchEntry = app.buttons["more-search"]
        for _ in 0..<4 where !searchEntry.isHittable { app.swipeUp() }
        XCTAssertTrue(searchEntry.isHittable, app.debugDescription)
        searchEntry.tap()
        let search = app.searchFields["搜索整个账本"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("synthetic")
        let searchRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'")).firstMatch
        XCTAssertTrue(searchRow.waitForExistence(timeout: 20), app.debugDescription)
        searchRow.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 10))
        app.navigationBars["交易详情"].buttons.element(boundBy: 0).tap()
        let tagLink = app.buttons["global-search-tag-synthetic-reviewed"]
        XCTAssertTrue(tagLink.waitForExistence(timeout: 15), app.debugDescription); tagLink.tap()
        XCTAssertTrue(app.navigationBars["#synthetic-reviewed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Synthetic action edited"].firstMatch.waitForExistence(timeout: 15))
        app.navigationBars["#synthetic-reviewed"].buttons.element(boundBy: 0).tap()
        app.open(URL(string: "ledger://accounts?account=Assets%3ABank&currency=CNY")!)
        let historyPage = app.staticTexts["account-history-page"]
        XCTAssertTrue(historyPage.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(historyPage.label, "第 1 页")
        XCTAssertFalse(app.buttons["account-history-previous"].isEnabled)
        XCTAssertFalse(app.buttons["account-history-next"].isEnabled)
        let trend = app.descendants(matching: .any)["account-balance-trend-chart"]
        XCTAssertTrue(trend.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["校对余额"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["校对余额"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["reconciliation-card-Assets:Bank"].waitForExistence(timeout: 20), app.debugDescription)
        app.navigationBars["校对余额"].buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["校对余额"].waitForNonExistence(timeout: 10))
        let accountRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'account-history-row-'")).firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 10), app.debugDescription)
        if !accountRow.isHittable { app.swipeUp() }
        accountRow.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 10))
        app.navigationBars["交易详情"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(historyPage.waitForExistence(timeout: 15))
        app.buttons["terminal-tab-transactions"].tap()
        XCTAssertTrue(editedRow.waitForExistence(timeout: 15))
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        let day = date.string(from: Date())
        app.open(URL(string: "ledger://transactions?date=" + day)!)
        XCTAssertTrue(app.navigationBars[day + " 支出"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["widget-day-page"].waitForExistence(timeout: 20), app.debugDescription)
        let widgetRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'")).firstMatch
        XCTAssertTrue(widgetRow.waitForExistence(timeout: 15)); widgetRow.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["transaction-edit"].exists)
        app.navigationBars["交易详情"].buttons.element(boundBy: 0).tap()
        app.buttons["完成"].firstMatch.tap()
        // open(URL:) relaunches the isolated app into its overview root. Return
        // explicitly to the transaction list before testing mutable row actions.
        app.buttons["terminal-tab-transactions"].tap()
        XCTAssertTrue(app.textFields["transaction-quick-search"].waitForExistence(timeout: 10))
        XCTAssertTrue(editedRow.waitForExistence(timeout: 15))
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

    func testLocalPendingInboxHydratesPayeeCancelReopenAndCommit() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing", "--pending-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10))
        app.buttons["local-ledger-create"].tap(); app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 30))
        app.buttons["terminal-tab-transactions"].tap()
        app.buttons["transaction-actions"].tap()
        app.buttons["transaction-create-local"].tap()
        XCTAssertTrue(app.buttons["高级"].waitForExistence(timeout: 5)); app.buttons["高级"].tap()
        // The backend requires a nonempty payee. A generic payee with blank
        // narration is still classified as missing-payee by the exact inbox rules.
        let genericPayee = app.textFields["transaction-edit-payee"]
        XCTAssertTrue(genericPayee.waitForExistence(timeout: 5))
        genericPayee.tap(); genericPayee.typeText("商户")
        replaceActionText(app.textFields["transaction-edit-posting-amount-0"], with: "12.34", in: app)
        replaceActionText(app.textFields["transaction-edit-posting-amount-1"], with: "-12.34", in: app)
        app.buttons["transaction-edit-save"].tap()
        XCTAssertTrue(app.buttons["bookkeeping-confirm-save"].waitForExistence(timeout: 30))
        app.buttons["bookkeeping-confirm-save"].tap()
        XCTAssertTrue(app.textFields["transaction-quick-search"].waitForExistence(timeout: 30))
        app.buttons["test-open-pending-inbox"].tap()
        XCTAssertTrue(app.navigationBars["待整理账单"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["pending-inbox-total"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.staticTexts["pending-inbox-total"].label, "1 笔待办")
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pending-edit-payee-'")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
        XCTAssertTrue(app.textFields["pending-payee-input"].waitForExistence(timeout: 15))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.textFields["pending-payee-input"].waitForNonExistence(timeout: 5))
        edit.tap()
        let input = app.textFields["pending-payee-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        replaceActionText(input, with: "Synthetic pending resolved", in: app)
        app.buttons["保存"].firstMatch.tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["账本全部整理完毕！"].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Synthetic pending resolved"].firstMatch.waitForExistence(timeout: 15))
        #else
        throw XCTSkip("Isolated synthetic simulator only")
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
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 30))
        app.buttons["terminal-tab-transactions"].tap()
        app.buttons["transaction-actions"].tap()
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
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 30))
        app.buttons["terminal-tab-transactions"].tap()
        app.buttons["transaction-actions"].tap()
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
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["terminal-tab-transactions"].tap()
        XCTAssertTrue(app.buttons["transaction-actions"].waitForExistence(timeout: 5))
        app.buttons["transaction-actions"].tap()
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
        XCTAssertTrue(app.textFields["transaction-quick-search"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Offline coffee"].firstMatch.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "local-offline-transaction"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["terminal-tab-transactions"].tap()
        XCTAssertTrue(app.staticTexts["Offline coffee"].firstMatch.waitForExistence(timeout: 10))
        #else
        throw XCTSkip("Simulator-only isolated authentication fixture; physical runtime uses integration tests and device authentication")
        #endif
    }
}
