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
            app.buttons["设置, Face ID、自动锁定、服务器与会话"].tap()
        } else {
            app.buttons["sidebar-settings"].tap()
        }
        XCTAssertTrue(app.staticTexts["设备安全"].waitForExistence(timeout: 3))
        capture("08-settings")
    }

    private func openDestination(compact: String, regular: String) {
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons[compact].tap()
        } else {
            app.buttons[regular].tap()
        }
    }

    private func capture(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(isPad ? "ipad" : "iphone")-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
