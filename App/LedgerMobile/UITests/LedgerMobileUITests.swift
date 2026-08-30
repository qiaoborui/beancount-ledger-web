import XCTest

@MainActor
final class LedgerMobileUITests: XCTestCase {
    private var app: XCUIApplication!
    private var isPad: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReadOnlyNavigationAndResponsiveSurfaces() throws {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        capture("01-overview")

        if isPad {
            app.buttons["收起侧边栏"].tap()
            XCTAssertTrue(app.buttons["sidebar-overview"].waitForNonExistence(timeout: 3))
            capture("01b-overview-sidebar-collapsed")
            app.buttons["展开侧边栏"].tap()
            XCTAssertTrue(app.buttons["sidebar-overview"].waitForExistence(timeout: 3))
        }

        let rangeButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "选择时间范围")
        ).firstMatch
        XCTAssertTrue(rangeButton.exists)
        rangeButton.tap()
        XCTAssertTrue(app.navigationBars["时间范围"].waitForExistence(timeout: 3))
        capture("02-time-range")
        app.buttons["取消"].tap()

        openDestination(compact: "交易", regular: "交易账本")
        XCTAssertTrue(app.textFields["搜索交易、账户或标签"].waitForExistence(timeout: 3))
        capture("03-transactions")

        app.buttons["筛选交易"].tap()
        XCTAssertTrue(app.navigationBars["筛选交易"].waitForExistence(timeout: 3))
        capture("04-transaction-filters")
        app.buttons["完成"].tap()

        openDestination(compact: "账户", regular: "账户")
        let longAccount = app.staticTexts["家庭长期储备与教育基金（含海外留学与应急资金）"]
        XCTAssertTrue(longAccount.waitForExistence(timeout: 3))
        capture("05-accounts")
        longAccount.tap()
        XCTAssertTrue(app.staticTexts["当前余额"].waitForExistence(timeout: 3))
        capture("06-account-detail")

        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons["更多"].tap()
            XCTAssertTrue(app.staticTexts["当前客户端"].waitForExistence(timeout: 3))
            capture("07-more")

            openCompactAnalysis(identifier: "more-analysis-dashboard", kind: "dashboard", title: "仪表盘", captureName: "08-dashboard")
            openCompactAnalysis(identifier: "more-analysis-netWorth", kind: "netWorth", title: "净资产", captureName: "09-net-worth")
            openCompactAnalysis(identifier: "more-analysis-incomeStatement", kind: "incomeStatement", title: "损益", captureName: "10-income-statement")
            openCompactAnalysis(
                identifier: "more-analysis-investments",
                kind: "investments",
                title: "投资",
                captureName: "11-investments",
                verifiesPrivacy: true
            )

            app.buttons["设置, Face ID、自动锁定、服务器与会话"].tap()
        } else {
            openRegularAnalysis(identifier: "sidebar-dashboard", kind: "dashboard", captureName: "07-dashboard")
            openRegularAnalysis(identifier: "sidebar-netWorth", kind: "netWorth", captureName: "08-net-worth")
            openRegularAnalysis(identifier: "sidebar-incomeStatement", kind: "incomeStatement", captureName: "09-income-statement")
            openRegularAnalysis(identifier: "sidebar-investments", kind: "investments", captureName: "10-investments")
            app.buttons["sidebar-settings"].tap()
        }
        XCTAssertTrue(app.staticTexts["设备安全"].waitForExistence(timeout: 3))
        capture(isPad ? "11-settings" : "12-settings")
    }

    private func openDestination(compact: String, regular: String) {
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons[compact].tap()
        } else {
            app.buttons[regular].tap()
        }
    }

    private func openRegularAnalysis(identifier: String, kind: String, captureName: String) {
        app.buttons[identifier].tap()
        XCTAssertTrue(app.scrollViews["analysis-content-\(kind)"].waitForExistence(timeout: 3))
        capture(captureName)
    }

    private func openCompactAnalysis(
        identifier: String,
        kind: String,
        title: String,
        captureName: String,
        verifiesPrivacy: Bool = false
    ) {
        let entry = app.buttons[identifier]
        waitUntilHittable(entry)
        entry.tap()
        XCTAssertTrue(app.scrollViews["analysis-content-\(kind)"].waitForExistence(timeout: 3))
        capture(captureName)
        if verifiesPrivacy {
            app.buttons["隐藏金额"].tap()
            XCTAssertTrue(app.staticTexts["浮动 金额已隐藏"].waitForExistence(timeout: 3))
            app.buttons["显示金额"].tap()
            XCTAssertTrue(app.buttons["隐藏金额"].waitForExistence(timeout: 3))
        }
        let backButton = app.navigationBars[title].buttons.firstMatch
        waitUntilHittable(backButton)
        backButton.tap()
        XCTAssertTrue(app.staticTexts["当前客户端"].waitForExistence(timeout: 3))
        waitUntilHittable(app.buttons["more-analysis-dashboard"])
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }

    private func capture(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.55))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(isPad ? "ipad" : "iphone")-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
