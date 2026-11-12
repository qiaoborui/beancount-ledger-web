import XCTest

@MainActor
final class TerminalOverviewUITests: XCTestCase {
    func testOverviewDateDraftAndDetailNavigation() {
        let app = launch()
        let date = app.buttons["navigation-time-range"]
        XCTAssertTrue(date.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "navigation-time-range").count, 1)
        XCTAssertTrue(date.label.contains("2026年8月"))
        XCTAssertGreaterThanOrEqual(date.frame.height, 44)
        XCTAssertFalse(app.staticTexts["月度概览"].exists)
        XCTAssertFalse(app.staticTexts["消费节奏"].exists)
        // The Balanced overview leads with the period's net retention.
        XCTAssertTrue(app.staticTexts["本期净结余"].exists, app.debugDescription)
        let net = app.staticTexts["overview-monthly-net"]
        XCTAssertTrue(net.exists, app.debugDescription)
        // A 30pt headline on one line, not wrapped onto a second.
        XCTAssertLessThan(net.frame.height, 50)
        let sync = app.buttons["ledger-sync-status"]
        XCTAssertEqual(date.frame.midY, sync.frame.midY, accuracy: 2)
        XCTAssertLessThanOrEqual(sync.frame.width, 44)
        capture("terminal-overview")
        date.tap()
        app.buttons["上一周期"].tap()
        app.buttons["取消"].tap()
        XCTAssertTrue(date.label.contains("2026年8月"))
        date.tap()
        app.buttons["上一周期"].tap()
        app.buttons["apply-time-range"].tap()
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        XCTAssertTrue(date.label.contains("2026年7月"))
        date.tap()
        app.buttons["下一周期"].tap()
        capture("terminal-date-sheet")
        app.buttons["apply-time-range"].tap()
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        XCTAssertTrue(date.label.contains("2026年8月"))
        // The overview's detail is the comparison basis behind each 本期指标 tile.
        let comparison = comparisonTile(app)
        for _ in 0..<4 where !comparison.isHittable { app.swipeUp() }
        XCTAssertTrue(comparison.isHittable, app.debugDescription)
        comparison.tap()
        XCTAssertTrue(app.navigationBars["支出 · 比较口径"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["支出 · 比较口径"].waitForNonExistence(timeout: 5))
        for _ in 0..<4 where !date.isHittable { app.swipeDown() }
        XCTAssertTrue(date.label.contains("2026年8月"))
    }

    func testAccessibilityOverviewStillReachesDateAndTransactions() {
        let app = launch(category: "UICTContentSizeCategoryAccessibilityXXXL")
        let date = app.buttons["navigation-time-range"]
        XCTAssertTrue(date.waitForExistence(timeout: 15))
        let amount = app.staticTexts["overview-monthly-net"]
        XCTAssertTrue(amount.exists)
        XCTAssertGreaterThanOrEqual(amount.frame.minX, 16)
        XCTAssertLessThanOrEqual(amount.frame.maxX, app.frame.maxX - 16)
        capture("terminal-overview-accessibility")
        date.tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        // The overview lists no transactions; at this size they stay one tab away.
        let transactions = app.compactTab("流水")
        XCTAssertTrue(transactions.isHittable, app.debugDescription)
        transactions.tap()
        XCTAssertTrue(app.textFields["transaction-quick-search"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testPrivacyMasksOverviewAmountsAndCategoryPercentages() {
        let app = launch()
        XCTAssertTrue(app.buttons["navigation-time-range"].waitForExistence(timeout: 15))
        app.tabBars.buttons["账户"].tap()
        let hide = app.buttons["隐藏金额"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()
        app.compactTab("概览").tap()
        let net = app.staticTexts["overview-monthly-net"]
        XCTAssertTrue(net.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(net.label, "金额已隐藏")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '¥'")).count, 0)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "%")).count, 0)
        capture("terminal-overview-private")
    }

    func testFlatNavigationKeepsSearchAndOverviewReachable() {
        let app = launch()
        XCTAssertTrue(app.buttons["navigation-time-range"].waitForExistence(timeout: 15))
        // Search floats beside the native tab bar on a server ledger.
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        let search = app.tabBars.buttons["搜索"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        app.compactTab("概览").tap()
        XCTAssertTrue(app.buttons["navigation-time-range"].waitForExistence(timeout: 5))
    }

    func testNativeTabsScrollAndSearchNavigation() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["概览"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        capture("native-tabs-expanded")
        app.swipeUp()
        app.swipeUp()
        capture("native-tabs-scrolled")
        app.swipeDown()
        app.swipeDown()
        // Scrolling minimizes the bar; tapping the selected tab expands it again.
        let more = app.compactTab("更多")
        XCTAssertTrue(more.exists, app.debugDescription)
        more.tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["navigation-time-range"].exists)
        app.tabBars.buttons["搜索"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        capture("native-tabs-search")
    }

    func testLatestOverviewComparisonsAndManagementDateScope() {
        let app = launch()
        XCTAssertTrue(app.buttons["navigation-time-range"].waitForExistence(timeout: 15))
        let comparison = comparisonTile(app)
        for _ in 0..<4 where !comparison.isHittable { app.swipeUp() }
        XCTAssertTrue(comparison.isHittable, app.debugDescription)
        capture("terminal-latest-overview")
        comparison.tap()
        XCTAssertTrue(app.navigationBars["支出 · 比较口径"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["变化金额"].firstMatch.exists)
        app.buttons["完成"].tap()
        app.compactTab("更多").tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["navigation-time-range"].exists)
        capture("terminal-more-no-date")
    }

    /// 支出环比 in 本期指标: one combined element whose label starts with its title.
    private func comparisonTile(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "支出环比")).firstMatch
    }

    private func launch(category: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-UIPreferredContentSizeCategoryName", category]
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
