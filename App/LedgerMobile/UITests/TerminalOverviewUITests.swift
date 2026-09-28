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
        XCTAssertTrue(app.staticTexts["01 / 支出矩阵"].exists)
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
        let transaction = app.buttons.containing(.staticText, identifier: "城市书房").firstMatch
        for _ in 0..<3 where !transaction.isHittable { app.swipeUp() }
        XCTAssertTrue(transaction.isHittable, app.debugDescription)
        transaction.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 5))
        app.navigationBars["交易详情"].buttons.firstMatch.tap()
        XCTAssertTrue(date.waitForExistence(timeout: 5))
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
        let all = app.buttons["全部"]
        for _ in 0..<8 where !all.isHittable { app.swipeUp() }
        XCTAssertTrue(all.isHittable, app.debugDescription)
        all.tap()
        XCTAssertTrue(app.navigationBars["流水"].waitForExistence(timeout: 5))
    }

    func testPrivacyMasksOverviewAmountsAndCategoryPercentages() {
        let app = launch()
        XCTAssertTrue(app.buttons["navigation-time-range"].waitForExistence(timeout: 15))
        app.tabBars.buttons["账户"].tap()
        let hide = app.buttons["隐藏金额"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()
        app.tabBars.buttons["概览"].tap()
        let net = app.staticTexts["overview-monthly-net"]
        XCTAssertTrue(net.waitForExistence(timeout: 5))
        XCTAssertEqual(net.label, "金额已隐藏")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '¥'")).count, 0)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "%")).count, 0)
        capture("terminal-overview-private")
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
