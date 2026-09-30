import XCTest

@MainActor
final class TerminalAccountsMoreUITests: XCTestCase {
    func testAccountsAndMoreNavigation() {
        let app = launch()
        app.tabBars.buttons["账户"].tap()
        XCTAssertTrue(app.collectionViews["accounts-list"].waitForExistence(timeout: 10), app.debugDescription)
        assertHeader(app)
        capture("terminal-accounts")
        app.buttons["账户操作"].tap()
        app.buttons["accounts-add-button"].tap()
        XCTAssertTrue(app.navigationBars["新建账户"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["取消"].tap()
        app.buttons["account-groups-toggle-all"].tap()
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'account-link-'")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5), app.debugDescription)
        capture("terminal-accounts-expanded")
        account.tap()
        XCTAssertTrue(app.buttons["校对余额"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["返回上一页"].tap()
        XCTAssertTrue(app.collectionViews["accounts-list"].waitForExistence(timeout: 5))
        app.buttons["隐藏金额"].tap()
        XCTAssertTrue(app.staticTexts["金额已隐藏"].firstMatch.exists)
        capture("terminal-accounts-private")
        app.buttons["显示金额"].tap()
        app.tabBars.buttons["更多"].tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 5))
        assertNoDateHeader(app)
        capture("terminal-more")
        app.buttons["more-analysis-assets"].tap()
        XCTAssertTrue(app.staticTexts["01 / 净资产历史"].waitForExistence(timeout: 10))
        app.buttons["返回上一页"].tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 5))
        app.buttons["more-header-search"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testAccessibilityKeepsAccountFiltersAndMoreReachable() {
        let app = launch(category: "UICTContentSizeCategoryAccessibilityXXXL")
        app.tabBars.buttons["账户"].tap()
        XCTAssertTrue(app.collectionViews["accounts-list"].waitForExistence(timeout: 5))
        assertHeader(app)
        capture("terminal-accounts-accessibility")
        app.tabBars.buttons["更多"].tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 5))
        capture("terminal-more-accessibility")
        let query = app.buttons["more-query"]
        for _ in 0..<8 where !query.isHittable { app.swipeUp() }
        XCTAssertTrue(query.isHittable, app.debugDescription)
    }

    private func assertHeader(_ app: XCUIApplication) {
        XCTAssertEqual(app.buttons.matching(identifier: "navigation-time-range").count, 1)
        XCTAssertEqual(app.buttons["navigation-time-range"].frame.midY, app.buttons["ledger-sync-status"].frame.midY, accuracy: 2)
    }
    private func assertNoDateHeader(_ app: XCUIApplication) {
        XCTAssertEqual(app.buttons.matching(identifier: "navigation-time-range").count, 0)
    }
    private func launch(category: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-UIPreferredContentSizeCategoryName", category]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["账户"].waitForExistence(timeout: 15))
        return app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
