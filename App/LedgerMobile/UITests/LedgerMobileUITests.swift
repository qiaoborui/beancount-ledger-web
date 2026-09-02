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
        XCTAssertTrue(app.staticTexts["环比"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["同比"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["总资产"].exists)
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
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "选择时间范围")).count,
            1
        )
        rangeButton.tap()
        XCTAssertTrue(app.navigationBars["时间范围"].waitForExistence(timeout: 3))
        capture("02-time-range")
        app.buttons["本季度"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "应用 ")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["季度结论"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["环比"].firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["同比"].firstMatch.exists)

        let quarterRangeButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "选择时间范围")
        ).firstMatch
        quarterRangeButton.tap()
        XCTAssertTrue(app.navigationBars["时间范围"].waitForExistence(timeout: 3))
        app.buttons["本月"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "应用 ")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["月度结论"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["环比"].firstMatch.waitForExistence(timeout: 3))

        openDestination(compact: "交易", regular: "交易账本")
        XCTAssertTrue(app.textFields["搜索交易、账户或标签"].waitForExistence(timeout: 3))
        capture("03-transactions")

        app.buttons["筛选交易"].tap()
        XCTAssertTrue(app.navigationBars["筛选交易"].waitForExistence(timeout: 3))
        let learningTag = app.buttons["transaction-tag-filter-learning"]
        XCTAssertTrue(learningTag.waitForExistence(timeout: 3))
        learningTag.tap()
        capture("04-transaction-filters")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["#learning"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["1 / 10 笔"].exists)

        let firstTransaction = app.staticTexts["城市书房"].firstMatch
        XCTAssertTrue(firstTransaction.waitForExistence(timeout: 3))
        firstTransaction.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars["交易详情"].buttons["隐藏金额"].exists)
        capture("04b-transaction-detail")
        app.navigationBars["交易详情"].buttons.firstMatch.tap()

        openDestination(compact: "账户", regular: "账户")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "选择时间范围")).firstMatch.exists)
        let longAccount = app.staticTexts["家庭长期储备与教育基金（含海外留学与应急资金）"]
        XCTAssertTrue(longAccount.waitForExistence(timeout: 3))

        app.buttons["account-filter-liabilities"].tap()
        XCTAssertTrue(longAccount.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["信用卡"].waitForExistence(timeout: 3))
        app.buttons["account-filter-assets"].tap()
        XCTAssertTrue(longAccount.waitForExistence(timeout: 3))

        let wealthGroup = app.buttons["account-group-wealth"]
        XCTAssertTrue(wealthGroup.exists)
        wealthGroup.tap()
        XCTAssertTrue(longAccount.waitForNonExistence(timeout: 3))
        wealthGroup.tap()
        XCTAssertTrue(longAccount.waitForExistence(timeout: 3))
        capture("05-accounts")
        longAccount.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "期末余额")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.staticTexts.matching(
                NSPredicate(format: "label == %@", "家庭长期储备与教育基金（含海外留学与应急资金）")
            ).count,
            1
        )
        XCTAssertTrue(app.staticTexts["期初余额"].exists)
        XCTAssertTrue(app.staticTexts["期间变化"].firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "选择时间范围")).firstMatch.exists)
        let accountTrend = app.descendants(matching: .any)["account-balance-trend-chart"]
        XCTAssertTrue(accountTrend.waitForExistence(timeout: 3))
        dragAcrossChart(accountTrend)
        XCTAssertTrue(app.descendants(matching: .any)["account-balance-chart-selection"].waitForExistence(timeout: 3))
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
                captureName: "11-investments"
            )

            let currencyEntry = app.buttons["more-currencies"]
            for _ in 0..<3 where !currencyEntry.isHittable {
                app.swipeUp()
            }
            waitUntilHittable(currencyEntry)
            currencyEntry.tap()
            exerciseCurrencies(capturePrefix: "12")

            let queryEntry = app.buttons["more-query"]
            for _ in 0..<3 where !queryEntry.isHittable {
                app.swipeUp()
            }
            waitUntilHittable(queryEntry)
            queryEntry.tap()
            exerciseBQL(capturePrefix: "13")

            let settingsEntry = app.buttons["设置, Face ID、自动锁定、服务器与会话"]
            for _ in 0..<3 where !settingsEntry.isHittable {
                app.swipeDown()
            }
            waitUntilHittable(settingsEntry)
            settingsEntry.tap()
        } else {
            app.buttons["sidebar-currencies"].tap()
            exerciseCurrencies(capturePrefix: "07")
            openRegularAnalysis(identifier: "sidebar-dashboard", kind: "dashboard", captureName: "07-dashboard")
            openRegularAnalysis(identifier: "sidebar-netWorth", kind: "netWorth", captureName: "08-net-worth")
            openRegularAnalysis(identifier: "sidebar-incomeStatement", kind: "incomeStatement", captureName: "09-income-statement")
            openRegularAnalysis(identifier: "sidebar-investments", kind: "investments", captureName: "10-investments")
            app.buttons["sidebar-query"].tap()
            exerciseBQL(capturePrefix: "11")
            app.buttons["sidebar-settings"].tap()
        }
        XCTAssertTrue(app.staticTexts["设备安全"].waitForExistence(timeout: 3))
        capture(isPad ? "14-settings" : "15-settings")
    }

    func testCurrencySwitchKeepsSelectedCurrencyVisible() throws {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))

        if isPad {
            let entry = app.buttons["sidebar-currencies"]
            XCTAssertTrue(entry.waitForExistence(timeout: 3))
            entry.tap()
        } else {
            app.tabBars.buttons["更多"].tap()
            let entry = app.buttons["more-currencies"]
            XCTAssertTrue(entry.waitForExistence(timeout: 3))
            for _ in 0..<3 where !entry.isHittable {
                app.swipeUp()
            }
            waitUntilHittable(entry)
            entry.tap()
        }
        XCTAssertTrue(app.scrollViews["currency-analysis-content"].waitForExistence(timeout: 3))

        let usd = app.buttons["valuation-currency-USD"]
        XCTAssertTrue(usd.exists)
        usd.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: usd)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
        XCTAssertTrue(usd.isHittable)
        XCTAssertGreaterThanOrEqual(usd.frame.minX, 16)
        capture("currency-selected-visible")
    }

    func testImportHistoryShowsProviderFreshnessAndArchivedFiles() throws {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))

        if isPad {
            let entry = app.buttons["sidebar-imports"]
            XCTAssertTrue(entry.waitForExistence(timeout: 3))
            entry.tap()
        } else {
            app.tabBars.buttons["更多"].tap()
            let entry = app.buttons["more-imports"]
            for _ in 0..<3 where !entry.isHittable { app.swipeUp() }
            waitUntilHittable(entry)
            entry.tap()
        }

        let content = app.scrollViews["import-history-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["渠道状态"].exists)
        XCTAssertTrue(app.staticTexts["支付宝"].exists)
        XCTAssertTrue(app.staticTexts["微信支付"].exists)
        XCTAssertTrue(app.staticTexts["招商银行信用卡"].exists)
        XCTAssertTrue(app.buttons["import-select-file"].exists)

        let archivedFile = app.staticTexts["alipay-2026-08.csv"]
        for _ in 0..<5 where !archivedFile.exists { content.swipeUp() }
        XCTAssertTrue(archivedFile.exists)

        let safetyNotice = app.staticTexts["预览确认后写入"]
        for _ in 0..<3 where !safetyNotice.exists { content.swipeUp() }
        XCTAssertTrue(safetyNotice.exists)
        capture("import-history")
    }

    func testNativeImportPreviewSelectionAndCommitFlow() throws {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--safe-import-flow"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))

        if isPad {
            let entry = app.buttons["sidebar-imports"]
            XCTAssertTrue(entry.waitForExistence(timeout: 3))
            entry.tap()
        } else {
            app.tabBars.buttons["更多"].tap()
            let entry = app.buttons["more-imports"]
            for _ in 0..<3 where !entry.isHittable { app.swipeUp() }
            waitUntilHittable(entry)
            entry.tap()
        }

        XCTAssertTrue(app.navigationBars["导入账单"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.scrollViews["native-import-preparation"].exists)
        XCTAssertTrue(app.staticTexts["wechat-2026-08.xlsx"].exists)
        capture("import-flow-01-preparation")

        app.buttons["import-generate-preview"].tap()
        XCTAssertTrue(app.navigationBars["核对交易"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["已选择 2 / 2"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["跳过 1"].exists)

        let toggle = app.buttons["import-entry-toggle-safe-import-1"]
        XCTAssertTrue(toggle.exists)
        toggle.tap()
        XCTAssertTrue(app.staticTexts["已选择 1 / 2"].waitForExistence(timeout: 3))
        toggle.tap()
        XCTAssertTrue(app.staticTexts["已选择 2 / 2"].waitForExistence(timeout: 3))

        let edit = app.buttons["import-entry-edit-safe-import-1"]
        XCTAssertTrue(edit.exists)
        edit.tap()
        XCTAssertTrue(app.navigationBars["编辑交易"].waitForExistence(timeout: 3))

        replaceText(in: app.textFields["import-edit-payee"], with: "新城市书房")
        replaceText(in: app.textFields["import-edit-narration"], with: "九月阅读计划")
        replaceText(in: app.textFields["import-edit-amount"], with: "368.50")
        app.buttons["import-edit-keyboard-done"].tap()
        app.buttons["import-edit-save"].tap()

        XCTAssertTrue(app.navigationBars["编辑交易"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["核对交易"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["新城市书房"].waitForExistence(timeout: 3))
        let reviewedEntry = app.buttons["import-entry-safe-import-1"]
        let review = app.scrollViews["native-import-preview"]
        for _ in 0..<3 where !reviewedEntry.isHittable { review.swipeUp() }
        waitUntilHittable(reviewedEntry)
        reviewedEntry.tap()
        XCTAssertTrue(app.staticTexts["分类账户"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Expenses:Education:Books"].exists)
        XCTAssertTrue(app.staticTexts["368.50 CNY"].exists)

        let editAgain = app.buttons["import-entry-edit-safe-import-1"]
        waitUntilHittable(editAgain)
        editAgain.tap()
        XCTAssertTrue(app.navigationBars["编辑交易"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["import-edit-payee"].value as? String, "新城市书房")
        XCTAssertEqual(app.textFields["import-edit-narration"].value as? String, "九月阅读计划")
        XCTAssertEqual(app.textFields["import-edit-amount"].value as? String, "368.50")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["核对交易"].waitForExistence(timeout: 3))
        capture("import-flow-02-review")

        app.buttons["写入 2 条交易"].tap()
        let confirmation = app.alerts["确认写入账本？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["写入 2 条交易"].tap()

        XCTAssertTrue(app.scrollViews["native-import-complete"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["已写入 2 条交易"].exists)
        XCTAssertTrue(app.staticTexts["归档位置"].exists)
        capture("import-flow-03-complete")

        app.buttons["完成"].tap()
        let history = app.scrollViews["import-history-content"]
        XCTAssertTrue(history.waitForExistence(timeout: 4))
        let newArchive = app.staticTexts["2026-08-01_2026-08-30-wechat-safe-preview.xlsx"]
        for _ in 0..<5 where !newArchive.exists { history.swipeUp() }
        XCTAssertTrue(newArchive.waitForExistence(timeout: 4))
    }

    func testChartAxesPreserveTimeSpacingAndTouchShowsSelections() throws {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))

        if isPad {
            app.buttons["sidebar-dashboard"].tap()
        } else {
            app.tabBars.buttons["更多"].tap()
            waitUntilHittable(app.buttons["more-analysis-dashboard"])
            app.buttons["more-analysis-dashboard"].tap()
        }

        let cashflow = app.descendants(matching: .any)["cashflow-trend-chart"]
        XCTAssertTrue(cashflow.waitForExistence(timeout: 4))
        XCTAssertEqual(cashflow.value as? String, "真实时间轴")
        dragAcrossChart(cashflow)
        XCTAssertTrue(app.descendants(matching: .any)["cashflow-chart-selection"].waitForExistence(timeout: 3))
        capture("chart-cashflow-selected")

        if isPad {
            app.buttons["sidebar-netWorth"].tap()
        } else {
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
            waitUntilHittable(app.buttons["more-analysis-netWorth"])
            app.buttons["more-analysis-netWorth"].tap()
        }
        let netWorth = app.descendants(matching: .any)["net-worth-trend-chart"]
        XCTAssertTrue(netWorth.waitForExistence(timeout: 4))
        dragAcrossChart(netWorth)
        XCTAssertTrue(app.descendants(matching: .any)["net-worth-chart-selection"].waitForExistence(timeout: 3))
        capture("chart-net-worth-selected")

        if isPad {
            app.buttons["sidebar-currencies"].tap()
        } else {
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
            let entry = app.buttons["more-currencies"]
            for _ in 0..<3 where !entry.isHittable { app.swipeUp() }
            waitUntilHittable(entry)
            entry.tap()
        }
        let currencyContent = app.scrollViews["currency-analysis-content"]
        XCTAssertTrue(currencyContent.waitForExistence(timeout: 4))
        let currencyChart = app.descendants(matching: .any)["currency-sparkline-USD"]
        for _ in 0..<4 where !currencyChart.isHittable { currencyContent.swipeUp() }
        waitUntilHittable(currencyChart)
        dragAcrossChart(currencyChart)
        XCTAssertTrue(app.descendants(matching: .any)["currency-chart-selection-USD"].waitForExistence(timeout: 3))
        capture("chart-currency-selected")

        if isPad {
            app.buttons["sidebar-query"].tap()
        } else {
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
            let entry = app.buttons["more-query"]
            for _ in 0..<3 where !entry.isHittable { app.swipeUp() }
            waitUntilHittable(entry)
            entry.tap()
        }
        let workbench = app.scrollViews["bql-workbench"]
        XCTAssertTrue(workbench.waitForExistence(timeout: 4))
        app.buttons["bql-run-all"].tap()
        let result = app.descendants(matching: .any)["bql-result-1"]
        for _ in 0..<5 where !result.exists { workbench.swipeUp() }
        XCTAssertTrue(result.waitForExistence(timeout: 4))

        app.buttons["柱状图"].tap()
        let barChart = app.descendants(matching: .any)["bql-bar-chart"]
        for _ in 0..<3 where !barChart.isHittable { workbench.swipeUp() }
        waitUntilHittable(barChart)
        dragAcrossChart(barChart)
        XCTAssertTrue(app.descendants(matching: .any)["bql-chart-selection"].waitForExistence(timeout: 3))
        capture("chart-bql-bar-selected")

        app.buttons["饼图"].tap()
        let pieChart = app.descendants(matching: .any)["bql-pie-chart"]
        waitUntilHittable(pieChart)
        pieChart.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.52)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["bql-chart-selection"].waitForExistence(timeout: 3))
        capture("chart-bql-pie-selected")
    }

    func testTimeRangeRefreshKeepsDetailContentVisible() throws {
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))

        if isPad {
            waitUntilHittable(app.buttons["sidebar-dashboard"])
            app.buttons["sidebar-dashboard"].tap()
        } else {
            app.tabBars.buttons["更多"].tap()
            waitUntilHittable(app.buttons["more-analysis-dashboard"])
            app.buttons["more-analysis-dashboard"].tap()
        }

        let content = app.scrollViews["analysis-content-dashboard"]
        XCTAssertTrue(content.waitForExistence(timeout: 4))
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "仪表盘")).count,
            isPad ? 2 : 1
        )

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "选择时间范围")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["时间范围"].waitForExistence(timeout: 3))
        app.buttons["本季度"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "应用 ")).firstMatch.tap()

        assertStaysPresent(content, duration: 1.0)
    }

    private func exerciseCurrencies(capturePrefix: String) {
        let content = app.scrollViews["currency-analysis-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["currency-missing-rate-warning"].exists)
        capture("\(capturePrefix)-currencies-cny")

        let usd = app.buttons["valuation-currency-USD"]
        XCTAssertTrue(usd.exists)
        usd.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: usd)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
        capture("\(capturePrefix)-currencies-usd")

        let usdRow = app.descendants(matching: .any)["currency-rate-USD"]
        for _ in 0..<3 where !usdRow.exists {
            content.swipeUp()
        }
        XCTAssertTrue(usdRow.exists)
        XCTAssertTrue(app.descendants(matching: .any)["currency-sparkline-USD"].exists)

        if app.tabBars.firstMatch.exists {
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "货币与汇率")).count, 1)
            let backButton = app.navigationBars.firstMatch.buttons.firstMatch
            waitUntilHittable(backButton)
            backButton.tap()
            XCTAssertTrue(app.staticTexts["当前客户端"].waitForExistence(timeout: 3))
        }
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
        captureName: String
    ) {
        let entry = app.buttons[identifier]
        waitUntilHittable(entry)
        entry.tap()
        XCTAssertTrue(app.scrollViews["analysis-content-\(kind)"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "选择时间范围")).firstMatch.exists)
        XCTAssertTrue(app.navigationBars[title].exists)
        XCTAssertFalse(app.navigationBars.firstMatch.buttons["隐藏金额"].exists)
        capture(captureName)
        let backButton = app.navigationBars.firstMatch.buttons.firstMatch
        waitUntilHittable(backButton)
        backButton.tap()
        XCTAssertTrue(app.staticTexts["当前客户端"].waitForExistence(timeout: 3))
        if app.scrollViews.firstMatch.exists {
            app.scrollViews.firstMatch.swipeDown()
        }
        waitUntilHittable(app.buttons["more-analysis-dashboard"])
    }

    private func exerciseBQL(capturePrefix: String) {
        XCTAssertTrue(app.scrollViews["bql-workbench"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textViews["bql-editor"].exists)
        XCTAssertTrue(app.buttons["bql-run-all"].exists)
        capture("\(capturePrefix)-bql-editor")

        app.buttons["bql-run-all"].tap()
        let workbench = app.scrollViews["bql-workbench"]
        let result = app.descendants(matching: .any)["bql-result-1"]
        for _ in 0..<5 where !result.exists {
            workbench.swipeUp()
        }
        XCTAssertTrue(result.waitForExistence(timeout: 4))
        let firstAmount = app.staticTexts["3,800.00"]
        XCTAssertTrue(firstAmount.waitForExistence(timeout: 3))
        revealAboveTabBar(firstAmount, in: workbench)
        capture("\(capturePrefix)-bql-table")

        let pieButton = app.buttons["饼图"]
        pieButton.tap()
        XCTAssertTrue(pieButton.isSelected)
        workbench.swipeUp()
        capture("\(capturePrefix)-bql-chart")

        if !isPad {
            for _ in 0..<5 {
                workbench.swipeDown()
            }
            let historyMenu = app.buttons["bql-history-menu-safe-preview-history"]
            XCTAssertTrue(historyMenu.waitForExistence(timeout: 3))
            historyMenu.tap()
            app.buttons["重命名"].tap()
            XCTAssertTrue(app.alerts["重命名查询"].waitForExistence(timeout: 3))
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertFalse(app.alerts["重命名查询"].waitForExistence(timeout: 1))
        }

        if app.tabBars.firstMatch.exists {
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "BQL 查询")).count, 1)
            let backButton = app.navigationBars.firstMatch.buttons.firstMatch
            waitUntilHittable(backButton)
            backButton.tap()
            XCTAssertTrue(app.staticTexts["当前客户端"].waitForExistence(timeout: 3))
        }
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }

    private func replaceText(in element: XCUIElement, with replacement: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        element.tap()
        let currentValue = (element.value as? String) ?? ""
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
        element.typeText(replacement)
        XCTAssertEqual(element.value as? String, replacement)
    }

    private func assertStaysPresent(_ element: XCUIElement, duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            XCTAssertTrue(element.exists)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func revealAboveTabBar(_ element: XCUIElement, in scrollView: XCUIElement) {
        guard app.tabBars.firstMatch.exists else { return }
        let obscuredEdge = app.tabBars.firstMatch.frame.minY - 12
        for _ in 0..<4 where element.frame.maxY > obscuredEdge {
            scrollView.swipeUp()
        }
        XCTAssertLessThanOrEqual(element.frame.maxY, obscuredEdge)
    }

    private func dragAcrossChart(_ chart: XCUIElement) {
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.54))
        let end = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.54))
        start.press(forDuration: 0.12, thenDragTo: end)
    }

    private func capture(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.55))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(isPad ? "ipad" : "iphone")-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
