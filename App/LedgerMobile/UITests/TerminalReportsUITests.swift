import XCTest

@MainActor
final class TerminalReportsUITests: XCTestCase {
    func testReportsShareDateHeaderAndKeepDrillDowns() {
        let app = launch()
        openReport(app, id: "more-analysis-incomeExpense")
        XCTAssertTrue(app.staticTexts["01 / 月度收支"].waitForExistence(timeout: 15), app.debugDescription)
        assertHeader(app)
        capture("terminal-income-light")
        app.swipeUp()
        capture("terminal-income-categories-light")
        app.swipeDown()
        let income = app.buttons.containing(.staticText, identifier: "收入").matching(NSPredicate(format: "label CONTAINS '50,500'")).firstMatch
        XCTAssertTrue(income.isHittable, app.debugDescription)
        income.tap()
        XCTAssertTrue(app.textFields["transaction-quick-search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["收入"].isSelected)
        app.tabBars.buttons["更多"].tap()
        if app.buttons["返回上一页"].exists { app.buttons["返回上一页"].tap() }
        openReport(app, id: "more-analysis-assets")
        XCTAssertTrue(app.staticTexts["01 / 净资产历史"].waitForExistence(timeout: 15), app.debugDescription)
        assertHeader(app)
        capture("terminal-assets-light")
        app.swipeUp()
        capture("terminal-assets-accounts-light")
    }

    func testTransactionSearchSelectionAndDetail() {
        let app = launch()
        app.tabBars.buttons["流水"].tap()
        let search = app.textFields["transaction-quick-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        assertHeader(app)
        capture("terminal-transactions-light")
        search.tap()
        search.typeText("城市书房\n")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 5))
        app.navigationBars["交易详情"].buttons.firstMatch.tap()
        XCTAssertEqual(search.value as? String, "城市书房")
        app.buttons["transaction-actions"].tap()
        app.buttons["多选流水"].tap()
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-select-row-'")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        selected.tap()
        XCTAssertTrue(app.buttons["完成多选"].exists)
        capture("terminal-transactions-selection")
        app.buttons["完成多选"].tap()
        XCTAssertTrue(app.buttons["transaction-actions"].exists)
    }

    func testReportPrivacyHidesChartsAndRatios() {
        let app = launch()
        app.tabBars.buttons["账户"].tap()
        let hide = app.buttons["隐藏金额"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()
        openReport(app, id: "more-analysis-incomeExpense")
        XCTAssertTrue(app.staticTexts["01 / 月度收支"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["terminal-cashflow-chart"].exists)
        XCTAssertTrue(app.staticTexts["金额已隐藏"].firstMatch.exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "%")).count, 0)
        capture("terminal-income-private")
    }

    func testReportAccessibilityKeepsHeaderAndSectionsReachable() {
        let app = launch(category: "UICTContentSizeCategoryAccessibilityXXXL")
        openReport(app, id: "more-analysis-incomeExpense")
        XCTAssertTrue(app.staticTexts["01 / 月度收支"].waitForExistence(timeout: 10))
        assertHeader(app)
        capture("terminal-report-accessibility")
        let categories = app.staticTexts["03 / 分类构成"]
        for _ in 0..<5 where !categories.isHittable { app.swipeUp() }
        XCTAssertTrue(categories.isHittable, app.debugDescription)
        app.buttons["返回上一页"].tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 5))
    }

    private func openReport(_ app: XCUIApplication, id: String) {
        app.tabBars.buttons["更多"].tap()
        let button = app.buttons[id]
        for _ in 0..<5 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, app.debugDescription)
        button.tap()
    }
    private func assertHeader(_ app: XCUIApplication) {
        let date = app.buttons["navigation-time-range"]
        XCTAssertEqual(app.buttons.matching(identifier: "navigation-time-range").count, 1)
        XCTAssertEqual(date.frame.midY, app.buttons["ledger-sync-status"].frame.midY, accuracy: 2)
        XCTAssertGreaterThanOrEqual(date.frame.height, 44)
        date.tap()
        XCTAssertTrue(app.buttons["apply-time-range"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
    }
    private func launch(category: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-UIPreferredContentSizeCategoryName", category]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["更多"].waitForExistence(timeout: 15))
        return app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
