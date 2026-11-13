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

    func testAnalysisNativeBackAndCachedReentry() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 10))
        app.tabBars.buttons["更多"].tap()
        let entry = app.buttons["more-analysis-incomeExpense"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
        XCTAssertTrue(app.scrollViews["analysis-content-incomeExpense"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["balanced-cashflow-chart"].waitForExistence(timeout: 5), app.debugDescription)
        capture("income-expense-native")
        // Native interactive pop starts at the left edge.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.scrollViews["analysis-content-incomeExpense"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["正在整理收支分析数据"].exists)
        capture("income-expense-cached-reentry")
    }

    func testWidgetDaySheetOpensDetailsAndReturnsToOriginalMonth() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        let range = app.buttons["navigation-time-range"]
        XCTAssertTrue(range.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(range.label.contains("2026年8月"))

        // XCUIApplication.open relaunches the fixture app. Warm/cross-month state
        // preservation is covered by the session tests; this exercises the actual URL UI.
        app.open(URL(string: "ledger://transactions?date=2026-08-28")!)
        let confirm = app.alerts.buttons["打开"]
        if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        XCTAssertTrue(app.navigationBars["2026-08-28 支出"].waitForExistence(timeout: 8))
        let bookshop = app.buttons["transaction-row-88"].firstMatch
        XCTAssertTrue(bookshop.waitForExistence(timeout: 5))
        capture("widget-day-isolated-list")
        bookshop.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["交易来源已变化"].exists)
        XCTAssertFalse(app.buttons["transaction-edit"].exists)
        capture("widget-day-snapshot-detail")
        app.navigationBars["交易详情"].buttons.firstMatch.tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 3))
        XCTAssertTrue(range.label.contains("2026年8月"))
        capture("widget-day-original-month-preserved")
    }

    func testLiquidGlassSearchAndConfirmedDeletion() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        openDestination(compact: "交易", regular: "交易账本")
        if !isPad {
            let tab = app.tabBars.buttons["流水"]
            XCTAssertTrue(tab.waitForExistence(timeout: 3))
            XCTAssertGreaterThan(tab.frame.midY, app.frame.height * 0.65)
        }
        capture("glass-transactions-search-collapsed")
        let row = app.buttons["transaction-row-88"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        app.buttons["transaction-delete"].tap()
        XCTAssertTrue(app.buttons["transaction-delete-confirm"].waitForExistence(timeout: 3))
        capture("glass-delete-confirmation")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["transaction-delete"].waitForExistence(timeout: 3))
        app.buttons["transaction-delete"].tap()
        app.buttons["transaction-delete-confirm"].tap()
        XCTAssertTrue(app.textFields["transaction-quick-search"].waitForExistence(timeout: 5))
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        let search = revealSearch("收付款对象、说明、账户或标签")
        typeInto(search, "不存在的交易")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '不存在的交易'")).firstMatch.waitForExistence(timeout: 3))
        capture("glass-search-expanded")
    }

    /// `typeText` needs the field focused, and a tap that lands while the search
    /// page or its sheet is still presenting does not focus it: XCTest then
    /// fails the event with "Neither element nor any descendant has keyboard
    /// focus". Tap until the keyboard is up, then type.
    private func typeInto(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<3 where !app.keyboards.firstMatch.exists {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        }
        field.typeText(text)
    }

    @discardableResult
    private func revealSearch(_ prompt: String) -> XCUIElement {
        let search = app.searchFields["搜索整个账本"]
        if search.exists && search.isHittable { return search }
        if isPad { app.buttons["sidebar-search"].tap() }
        else {
            openCompactSearch()

        }
        XCTAssertTrue(search.waitForExistence(timeout: 3), app.debugDescription)
        return search
    }

    private func openCompactSearch() {
        let entry = app.tabBars.buttons["搜索"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
    }

    func testSystemDeepLinksReachAccountDateAndSearch() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        app.open(URL(string: "ledger://accounts?account=Assets%3ABank%3ADaily&currency=CNY")!)
        // The link relaunches the app and the detail loads its own page, which can
        // take a while on a loaded machine.
        XCTAssertTrue(app.staticTexts["Assets:Bank:Daily"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts["日常账户"].firstMatch.exists)
        capture("system-account-link")
        app.open(URL(string: "ledger://transactions?date=2026-08-28")!)
        XCTAssertTrue(app.buttons["transaction-row-88"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["transaction-row-82"].exists)
        capture("system-date-link")
        app.open(URL(string: "ledger://search?q=%E5%9F%8E%E5%B8%82")!)
        let search = app.searchFields["搜索整个账本"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(search.value as? String, "城市")
        XCTAssertTrue(app.buttons["transaction-row-88"].waitForExistence(timeout: 5))
        capture("system-search-link")
    }

    func testTransactionContextMenuOpensNativeActions() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        openDestination(compact: "交易", regular: "交易账本")
        let row = app.buttons["transaction-row-88"]
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["transaction-context-copy"].firstMatch.waitForExistence(timeout: 3))
        capture("native-transaction-context-menu")
        app.buttons["transaction-context-edit"].firstMatch.tap()
        XCTAssertTrue(app.buttons["取消"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["编辑交易"].waitForNonExistence(timeout: 3))
        row.press(forDuration: 1)
        app.buttons["transaction-context-tags"].firstMatch.tap()
        XCTAssertTrue(app.textFields["transaction-bulk-tag-input"].waitForExistence(timeout: 3))
        capture("native-single-transaction-tags")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.textFields["transaction-bulk-tag-input"].waitForNonExistence(timeout: 3))
        row.press(forDuration: 1)
        app.buttons["transaction-context-delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["transaction-delete-confirm"].waitForExistence(timeout: 3))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }

    func testGlobalSearchScopesFiltersAndRecentQueries() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        let search = revealSearch("搜索整个账本")
        typeInto(search, "城市\n")
        XCTAssertTrue(app.buttons["transaction-row-88"].waitForExistence(timeout: 5))
        let scopes = app.segmentedControls.firstMatch
        XCTAssertTrue(scopes.buttons["流水"].waitForExistence(timeout: 3), app.debugDescription)
        scopes.buttons["账户"].tap()
        XCTAssertTrue(app.buttons["transaction-row-88"].waitForNonExistence(timeout: 3))
        scopes.buttons["流水"].tap()
        XCTAssertTrue(app.buttons["transaction-row-88"].waitForExistence(timeout: 3))
        app.buttons["global-search-filters"].tap()
        app.buttons["global-search-tag-filter"].tap()
        app.buttons["#learning"].firstMatch.tap()
        if !app.buttons["global-search-apply-filters"].exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
        app.buttons["global-search-apply-filters"].tap()
        XCTAssertTrue(app.buttons["transaction-row-88"].waitForExistence(timeout: 3))
        capture("global-search-scopes-and-filters")
        app.buttons["global-search-filters"].tap()
        app.buttons["清除全部筛选"].tap()
        app.buttons["global-search-apply-filters"].tap()
        scopes.buttons["全部"].tap()
        replaceText(in: search, with: "")
        XCTAssertTrue(app.staticTexts["最近搜索"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["城市"].firstMatch.exists)
        capture("global-search-recent-queries")
    }

    func testSharedImportInboxReviewCancellationKeepsFile() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--safe-shared-import"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        app.open(URL(string: "ledger://imports")!)
        let item = app.buttons["shared-import-review-shared-preview.csv"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.tap()
        // The shared file parses straight into review; leaving without edits keeps it.
        let review = app.navigationBars["核对交易"]
        XCTAssertTrue(review.waitForExistence(timeout: 8), app.debugDescription)
        capture("system-shared-import-review")
        review.buttons["返回"].tap()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        capture("system-shared-import-retained")
    }

    func testSearchFromMoreReturnsToMoreWithoutNestedSearch() throws {
        try XCTSkipIf(isPad, "Compact search tab return path")
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        app.tabBars.buttons["更多"].tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 3))
        let search = revealSearch("搜索整个账本")
        XCTAssertTrue(app.navigationBars["搜索"].exists)
        capture("global-search-entry")
        typeInto(search, "城市\n")
        XCTAssertTrue(app.buttons["transaction-row-88"].waitForExistence(timeout: 5))
        app.tabBars.buttons["更多"].tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.searchFields["搜索整个账本"].exists)
        app.tabBars.buttons["概览"].tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 3))
        app.tabBars.buttons["更多"].tap()
        let reopenedSearch = revealSearch("搜索整个账本")
        typeInto(reopenedSearch, "城市\n")
        app.tabBars.buttons["更多"].tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.searchFields["搜索整个账本"].exists)
        capture("search-more-return")
    }

    func testGlobalSearchTabAlignmentAndResults() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        if !isPad {
            let more = app.tabBars.buttons["更多"]
            let overview = app.tabBars.buttons["概览"]
            XCTAssertTrue(more.waitForExistence(timeout: 3))
            XCTAssertEqual(overview.frame.midY, more.frame.midY, accuracy: 5)
            let searchTab = app.tabBars.buttons["搜索"]
            XCTAssertTrue(searchTab.exists, app.debugDescription)
            XCTAssertEqual(searchTab.frame.midY, overview.frame.midY, accuracy: 5)
        }
        capture("global-search-aligned-tab")
        let search = revealSearch("搜索整个账本")
        typeInto(search, "城市\n")
        XCTAssertTrue(app.buttons["transaction-row-88"].waitForExistence(timeout: 5), app.debugDescription)
        capture("global-search-results")
        app.buttons["transaction-row-88"].tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 3))
        capture("global-search-detail")
    }

    func testGlassImportActionSurface() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--safe-import-flow"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        if isPad {
            app.buttons["sidebar-imports"].tap()
        } else {
            app.tabBars.buttons["更多"].tap()
            openMoreRow("more-imports")
        }
        XCTAssertTrue(app.navigationBars["核对交易"].waitForExistence(timeout: 8))
        let commit = app.buttons["import-commit"]
        XCTAssertTrue(commit.waitForExistence(timeout: 3))
        XCTAssertTrue(commit.isHittable)
        XCTAssertLessThanOrEqual(commit.frame.maxX, app.frame.maxX)
        capture("glass-import-action-surface")
    }

    func testAccountGroupsStartCollapsedAndSupportSearch() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        openDestination(compact: "账户", regular: "账户")
        let daily = app.staticTexts["日常账户"]
        XCTAssertFalse(app.segmentedControls["account-category-picker"].exists)
        XCTAssertFalse(app.buttons["account-filter-assets"].exists)
        // Group cards start collapsed; tapping a header opens its accounts.
        // There is no bulk expand/collapse control.
        let cashGroup = app.descendants(matching: .any)["account-group-cash"].firstMatch
        XCTAssertTrue(cashGroup.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["account-groups-toggle-all"].exists)
        XCTAssertFalse(daily.exists)
        capture("accounts-default-collapsed")
        cashGroup.tap()
        XCTAssertTrue(daily.waitForExistence(timeout: 3))
        capture("accounts-group-expanded")

        let search = revealSearch("账户名称或路径")
        typeInto(search, "日常\n")
        XCTAssertTrue(daily.waitForExistence(timeout: 3))
        openDestination(compact: "账户", regular: "账户")
        XCTAssertTrue(daily.waitForExistence(timeout: 3))
    }

    func testNavigationTimeRangePreservesDraftAndSearchHierarchy() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        openDestination(compact: "交易", regular: "交易账本")
        let dateButton = app.buttons["navigation-time-range"]
        XCTAssertTrue(dateButton.waitForExistence(timeout: 3))
        XCTAssertFalse(app.otherElements["page-time-range"].exists)
        XCTAssertTrue(dateButton.label.contains("2026年8月"))
        capture("navigation-date-and-search")

        dateButton.tap()
        app.buttons["上一周期"].tap()
        // LabeledContent exposes its period as a combined accessibility value.
        // Verify the committed period through the toolbar below and draft isolation in unit tests.
        capture("navigation-date-previous-draft")
        app.buttons["取消"].tap()
        XCTAssertTrue(dateButton.label.contains("2026年8月"))
        dateButton.tap()
        app.buttons["上一周期"].tap()
        app.buttons["apply-time-range"].tap()
        XCTAssertTrue(dateButton.waitForExistence(timeout: 3))
        XCTAssertTrue(dateButton.label.contains("2026年7月"))
        dateButton.tap()
        app.buttons["下一周期"].tap()
        app.buttons["apply-time-range"].tap()
        XCTAssertTrue(app.staticTexts["transaction-category-88"].waitForExistence(timeout: 3))
        capture("navigation-date-restored")
    }

    func testCompactLedgerShowsCategoriesAndAlignedTitles() throws {
        try XCTSkipIf(isPad, "Compact layout geometry")
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        // Compact pages draw their title in a custom bar: one static text whose
        // label is the full title (概览 reads as 财务概览).
        let overviewTitle = app.staticTexts["财务概览"]
        XCTAssertTrue(overviewTitle.waitForExistence(timeout: 8))
        let titleMidY = overviewTitle.frame.midY
        capture("compact-flat-overview")

        app.tabBars.buttons["流水"].tap()
        let category = app.staticTexts["transaction-category-88"]
        XCTAssertTrue(category.waitForExistence(timeout: 3))
        XCTAssertEqual(category.label, "图书")
        // A plain two-line row (63pt at the default size), not a card.
        XCTAssertLessThanOrEqual(app.buttons["transaction-row-88"].frame.height, 80)
        XCTAssertGreaterThanOrEqual(app.buttons["transaction-row-88"].frame.height, 60)
        XCTAssertEqual(app.staticTexts["流水"].frame.midY, titleMidY, accuracy: 2)
        XCTAssertTrue(app.buttons["transaction-row-52"].isHittable)
        capture("compact-flat-transactions")

        for (tab, title) in [("账户", "账户"), ("更多", "更多")] {
            app.tabBars.buttons[tab].tap()
            let heading = app.staticTexts[title]
            XCTAssertTrue(heading.waitForExistence(timeout: 3))
            XCTAssertEqual(heading.frame.midY, titleMidY, accuracy: 2)
            capture("compact-flat-\(title)")
        }
        app.buttons["more-analysis-assets"].tap()
        let assetsTitle = app.staticTexts["资产分析"]
        XCTAssertTrue(assetsTitle.waitForExistence(timeout: 3))
        XCTAssertEqual(assetsTitle.frame.midY, titleMidY, accuracy: 2)
        capture("compact-flat-assets")
    }

    func testNativeSearchRetainsFiltersAcrossTabsAndDetailNavigation() throws {
        try XCTSkipIf(isPad, "Compact stack persistence")
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        app.tabBars.buttons["流水"].tap()
        let search = revealSearch("收付款对象、说明、账户或标签")
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        typeInto(search, "不存在的交易")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '不存在的交易'")).firstMatch.waitForExistence(timeout: 3))
        replaceText(in: search, with: "城市")
        search.typeText("\n")
        let row = app.buttons["transaction-row-88"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 3))
        app.tabBars.buttons["账户"].tap()
        XCTAssertTrue(app.collectionViews["accounts-list"].waitForExistence(timeout: 3))
        openCompactSearch()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 3))
        app.navigationBars["交易详情"].buttons.firstMatch.tap()
        XCTAssertEqual(search.value as? String, "城市")
        capture("native-search-preserved")
    }

    func testNativeAccessibilityTypographyAndPrivacy() throws {
        app = XCUIApplication()
        app.launchArguments = [
            "--safe-preview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        let summaryHeading = app.staticTexts["本期净结余"]
        XCTAssertTrue(summaryHeading.exists, app.debugDescription)
        XCTAssertGreaterThanOrEqual(summaryHeading.frame.minX, 0)
        XCTAssertLessThanOrEqual(summaryHeading.frame.maxX, app.frame.maxX)
        capture("native-accessibility-overview")
        XCTAssertTrue(app.buttons["ledger-sync-status"].exists)
        XCTAssertFalse(app.buttons["隐藏金额"].exists)
        XCTAssertFalse(app.buttons["显示金额"].exists)
        capture("native-accessibility-sync-status")
        openDestination(compact: "交易", regular: "交易账本")
        XCTAssertTrue(app.textFields["transaction-quick-search"].waitForExistence(timeout: 3))
        capture("native-accessibility-transactions")
        openDestination(compact: "账户", regular: "账户")
        XCTAssertTrue(app.collectionViews["accounts-list"].waitForExistence(timeout: 3))
        capture("native-accessibility-accounts")
    }

    func testMorePreservesOverflowNavigationAcrossTabs() throws {
        try XCTSkipIf(isPad, "Compact overflow navigation")
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        app.tabBars.buttons["更多"].tap()
        app.buttons["more-analysis-assets"].tap()
        XCTAssertTrue(app.staticTexts["净值走势"].waitForExistence(timeout: 3), app.debugDescription)
        app.tabBars.buttons["账户"].tap()
        XCTAssertTrue(app.collectionViews["accounts-list"].waitForExistence(timeout: 3))
        app.tabBars.buttons["更多"].tap()
        XCTAssertTrue(app.staticTexts["净值走势"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["返回上一页"].tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 3))
        app.tabBars.buttons["账户"].tap()
        app.tabBars.buttons["更多"].tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 3))
    }

    func testReadOnlyNavigationAndResponsiveSurfaces() throws {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        // 本期指标 tiles each read as one element ("支出环比, +12.3%, 比上月 …").
        let monthOverMonth = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "支出环比")).firstMatch
        let yearOverYear = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "支出同比")).firstMatch
        let overview = app.scrollViews.firstMatch
        for _ in 0..<3 where !monthOverMonth.exists { overview.swipeUp() }
        XCTAssertTrue(monthOverMonth.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(yearOverYear.exists)
        // 总资产 is no longer the page's headline: it heads 资产与负债, below 本期指标.
        let periodStats = app.staticTexts["本期指标"]
        XCTAssertTrue(periodStats.exists, app.debugDescription)
        let totalAssets = app.staticTexts["总资产"]
        for _ in 0..<4 where !totalAssets.exists { overview.swipeUp() }
        XCTAssertTrue(totalAssets.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertGreaterThan(totalAssets.frame.minY, periodStats.frame.minY)
        for _ in 0..<4 { overview.swipeDown() }
        capture("01-overview")

        if isPad {
            app.buttons["Hide Sidebar"].tap()
            XCTAssertTrue(app.buttons["sidebar-overview"].waitForNonExistence(timeout: 3))
            capture("01b-overview-sidebar-collapsed")
            app.buttons["Show Sidebar"].tap()
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
        app.buttons["apply-time-range"].tap()
        // The headline names the period: a quarter by its title, a month as "8月".
        XCTAssertTrue(app.staticTexts["2026年第3季度"].waitForExistence(timeout: 10), app.debugDescription)

        let quarterRangeButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "选择时间范围")
        ).firstMatch
        quarterRangeButton.tap()
        XCTAssertTrue(app.navigationBars["时间范围"].waitForExistence(timeout: 3))
        app.buttons["本月"].tap()
        app.buttons["apply-time-range"].tap()
        XCTAssertTrue(app.staticTexts["2026年第3季度"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(quarterRangeButton.label.contains("2026年8月"))

        openDestination(compact: "交易", regular: "交易账本")
        capture("03-transactions")

        app.buttons["transaction-actions"].tap()
        app.buttons["筛选交易"].tapMenuItem()
        XCTAssertTrue(app.navigationBars["筛选交易"].waitForExistence(timeout: 5), app.debugDescription)
        let learningTag = app.buttons["transaction-tag-filter-learning"]
        for _ in 0..<3 where !learningTag.exists { app.collectionViews.allElementsBoundByIndex.last?.swipeUp() }
        XCTAssertTrue(learningTag.waitForExistence(timeout: 3))
        learningTag.tap()
        capture("04-transaction-filters")
        app.buttons["完成"].tap()
        // Rows show tags as labelled images; the footnote reports the filtered count.
        XCTAssertTrue(app.descendants(matching: .any)["#learning"].firstMatch.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已全部加载 1 笔")).firstMatch.exists,
                      app.debugDescription)

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
        let accountsList = app.collectionViews["accounts-list"]
        // Group cards start collapsed: open 理财 before looking for its account.
        let wealthGroup = app.descendants(matching: .any)["account-group-wealth"].firstMatch
        for _ in 0..<4 where !wealthGroup.isHittable { accountsList.swipeUp() }
        wealthGroup.tap()
        for _ in 0..<4 where !longAccount.exists { accountsList.swipeUp() }
        XCTAssertTrue(longAccount.waitForExistence(timeout: 3))

        // Account filters are chips labelled with their counts ("信用、1").
        let creditFilter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "信用、")).firstMatch
        let allFilter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "全部、")).firstMatch
        for _ in 0..<4 where !creditFilter.isHittable { accountsList.swipeDown() }
        creditFilter.tap()
        XCTAssertTrue(longAccount.waitForNonExistence(timeout: 3))
        let creditGroup = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'account-group-'")).firstMatch
        XCTAssertTrue(creditGroup.waitForExistence(timeout: 3), app.debugDescription)
        if !app.staticTexts["信用卡"].exists { creditGroup.tap() }
        XCTAssertTrue(app.staticTexts["信用卡"].waitForExistence(timeout: 3), app.debugDescription)
        allFilter.tap()
        for _ in 0..<4 where !longAccount.exists { accountsList.swipeUp() }
        XCTAssertTrue(longAccount.waitForExistence(timeout: 3))

        // The 理财 header is still on screen after the filter changes.
        XCTAssertTrue(wealthGroup.exists)
        XCTAssertTrue(longAccount.exists)
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

        if !isPad {
            app.compactTab("更多").tap()
            XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 3))
            capture("07-more")

            openCompactAnalysis(identifier: "more-analysis-assets", kind: "assets", title: "资产分析", captureName: "08-assets")
            openCompactAnalysis(identifier: "more-analysis-incomeExpense", kind: "incomeExpense", title: "收支分析", captureName: "09-income-expense")
            openCompactAnalysis(
                identifier: "more-analysis-investments",
                kind: "investments",
                title: "投资",
                captureName: "11-investments"
            )

            // 更多 pushes its overflow destinations through one navigation item, and
            // after it pops the next push is dropped until the page is rebuilt; also
            // give 查询 the list before the valuation-currency reload lands.
            reopenMore()
            openBQLWorkbench()
            exerciseBQL(capturePrefix: "13")

            reopenMore()
            let currencyEntry = app.buttons["more-currencies"]
            for _ in 0..<3 where !currencyEntry.isHittable {
                app.swipeUp()
            }
            waitUntilHittable(currencyEntry)
            currencyEntry.tap()
            exerciseCurrencies(capturePrefix: "12")

            let settingsEntry = app.buttons["more-settings"]
            for _ in 0..<3 where !settingsEntry.isHittable {
                app.swipeDown()
            }
            waitUntilHittable(settingsEntry)
            settingsEntry.tap()
        } else {
            app.buttons["sidebar-currencies"].tap()
            exerciseCurrencies(capturePrefix: "07")
            openRegularAnalysis(identifier: "sidebar-assets", kind: "assets", captureName: "07-assets")
            openRegularAnalysis(identifier: "sidebar-incomeExpense", kind: "incomeExpense", captureName: "08-income-expense")
            openRegularAnalysis(identifier: "sidebar-investments", kind: "investments", captureName: "10-investments")
            app.buttons["sidebar-query"].tap()
            exerciseBQL(capturePrefix: "11")
            for _ in 0..<3 where !app.buttons["sidebar-settings"].isHittable {
                app.collectionViews["ledger-sidebar"].swipeUp()
            }
            app.buttons["sidebar-settings"].tap()
        }
        XCTAssertTrue(app.staticTexts["隐私与安全"].waitForExistence(timeout: 3))
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
            openMoreRow("more-imports")
        }

        let content = app.collectionViews["import-history-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["import-select-file"].exists)
        XCTAssertFalse(app.staticTexts["Gmail 自动账单"].exists)
        XCTAssertFalse(app.buttons["gmail-sync"].exists)
        XCTAssertFalse(app.buttons["gmail-connect"].exists)

        capture("native-import-history")
        let coverage = app.descendants(matching: .any)["import-channel-coverage"].firstMatch
        XCTAssertTrue(coverage.waitForExistence(timeout: 3))
        // Channels are listed outright; nothing to expand.
        for provider in ["alipay", "wechat", "cmb"] {
            let row = app.descendants(matching: .any)["import-provider-\(provider)"].firstMatch
            for _ in 0..<5 where !row.exists { content.swipeUp() }
            XCTAssertTrue(row.exists)
        }
        let showAll = app.buttons["import-documents-toggle"]
        for _ in 0..<5 where !showAll.exists { content.swipeUp() }
        if showAll.exists { showAll.tap() }
        let archivedEmail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ccb-credit-2026-08.eml")).firstMatch
        for _ in 0..<5 where !archivedEmail.exists { content.swipeUp() }
        XCTAssertTrue(archivedEmail.exists)

        let archivedFile = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "alipay-2026-08.csv")).firstMatch
        for _ in 0..<5 where !archivedFile.exists { content.swipeUp() }
        XCTAssertTrue(archivedFile.exists)

        capture("import-history")
    }

    func testCompactTabBarCanAddReorderAndOpenDestination() throws {
        try XCTSkipIf(isPad, "Compact tab customization only applies to compact-width navigation")
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))

        app.tabBars.buttons["更多"].tap()
        let settingsEntry = app.buttons["more-settings"]
        for _ in 0..<3 where !settingsEntry.isHittable { app.swipeDown() }
        waitUntilHittable(settingsEntry)
        settingsEntry.tap()

        let configurationEntry = app.buttons["settings-compact-tabs"]
        XCTAssertTrue(configurationEntry.waitForExistence(timeout: 3))
        capture("compact-tabs-01-settings")
        configurationEntry.tap()

        XCTAssertTrue(app.navigationBars["底部标签栏"].waitForExistence(timeout: 5))
        // A previous session may have left a customised bar in UserDefaults: start
        // from the default tabs, which is also what the rest of the suite expects.
        if !app.buttons["compact-tab-remove-overview"].exists {
            let reset = app.buttons["compact-tab-reset"]
            let staleList = app.collectionViews["compact-tab-list"]
            for _ in 0..<4 where !reset.isHittable { staleList.swipeUp() }
            waitUntilHittable(reset)
            reset.tap()
            app.buttons["compact-tab-save"].tap()
            let configurationEntryAgain = app.buttons["settings-compact-tabs"]
            waitUntilHittable(configurationEntryAgain)
            configurationEntryAgain.tap()
            XCTAssertTrue(app.navigationBars["底部标签栏"].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.staticTexts["已显示 3/3"].exists)
        XCTAssertTrue(app.buttons["compact-tab-remove-overview"].exists)
        capture("compact-tabs-02-configuration")

        let configurationList = app.collectionViews["compact-tab-list"]
        XCTAssertTrue(configurationList.waitForExistence(timeout: 3))

        app.buttons["compact-tab-remove-overview"].tap()
        XCTAssertTrue(app.staticTexts["已显示 2/3"].waitForExistence(timeout: 3))

        // The system labels reorder controls in the simulator's language, which
        // is Chinese on CI.
        let reorderButtons = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label CONTAINS %@ OR label CONTAINS %@", "Reorder", "重新排列", "重新排序"))
        XCTAssertEqual(reorderButtons.count, 2, app.debugDescription)
        for handle in reorderButtons.allElementsBoundByIndex { waitUntilHittable(handle) }
        // After 概览 is removed the bar keeps the default order: 流水, then 账户.
        let accountsRow = app.buttons["compact-tab-remove-accounts"]
        let transactionsRow = app.buttons["compact-tab-remove-transactions"]
        XCTAssertLessThan(transactionsRow.frame.minY, accountsRow.frame.minY, app.debugDescription)
        // Drag 账户's control above 流水's. The query's element order is not the
        // layout order, so pair the controls with their rows by centre line, and
        // retry because the list only follows once the long press lifted the row.
        for _ in 0..<3 where accountsRow.frame.minY > transactionsRow.frame.minY {
            let handles = reorderButtons.allElementsBoundByIndex.sorted { $0.frame.midY < $1.frame.midY }
            handles[1].press(forDuration: 1.0,
                             thenDragTo: handles[0],
                             withVelocity: .slow,
                             thenHoldForDuration: 0.5)
        }
        XCTAssertLessThan(accountsRow.frame.minY, transactionsRow.frame.minY, app.debugDescription)
        capture("compact-tabs-03-reordered")

        let addAssets = app.buttons["compact-tab-add-assets"]
        configurationList.swipeUp()
        for _ in 0..<4 where !addAssets.isHittable { configurationList.swipeUp() }
        waitUntilHittable(addAssets)
        addAssets.tap()

        XCTAssertTrue(app.staticTexts["已显示 3/3"].waitForExistence(timeout: 3))

        app.buttons["compact-tab-save"].tap()
        let settingsBack = app.buttons["返回上一页"]
        waitUntilHittable(settingsBack)
        settingsBack.tap()
        XCTAssertTrue(app.buttons["more-overview"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons["资产分析"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.tabBars.buttons["更多"].exists)
        XCTAssertFalse(app.tabBars.buttons["概览"].exists)
        XCTAssertLessThan(app.tabBars.buttons["账户"].frame.minX, app.tabBars.buttons["流水"].frame.minX)
        capture("compact-tabs-04-tab-bar")

        app.tabBars.buttons["资产分析"].tap()
        XCTAssertTrue(app.staticTexts["净值走势"].waitForExistence(timeout: 4), app.debugDescription)
        capture("compact-tabs-05-assets")

        app.tabBars.buttons["更多"].tap()
        let overviewEntry = app.buttons["more-overview"]
        XCTAssertTrue(overviewEntry.waitForExistence(timeout: 3))
        overviewEntry.tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 3))
        app.buttons["返回上一页"].tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 3))

    }

    func testImportClassificationReviewsFieldsIndependentlyAndRestoresFullList() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--safe-import-flow", "--safe-classification-review"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        if isPad { app.buttons["sidebar-imports"].tap() }
        else {
            app.tabBars.buttons["更多"].tap()
            openMoreRow("more-imports")
        }
        XCTAssertTrue(app.navigationBars["核对交易"].waitForExistence(timeout: 8))
        let list = app.collectionViews["native-import-preview"]
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '导入信息待确认' OR label BEGINSWITH '草稿已补全'")).firstMatch
        func reveal(_ id: String) -> XCUIElement {
            // DisclosureGroup identifiers propagate to nested form rows in
            // SwiftUI. Locate group headers by their user-visible labels.
            let element: XCUIElement
            switch id {
            case "result": element = result
            case "funding": element = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '付款 / 收款账户'")).firstMatch
            case "category": element = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '分类 / 对应账户'")).firstMatch
            case "tags": element = app.buttons["标签建议"].firstMatch
            default: element = app.buttons[id].firstMatch
            }
            revealAboveImportActions(element, in: list)
            return element
        }
        reveal("result").tap()
        XCTAssertTrue(result.label.contains("待确认"))
        XCTAssertTrue(reveal("category").label.contains("Expenses:Education:Books"))
        capture("classification-category-preselected-awaiting-confirmation")
        reveal("funding").tap()
        reveal("import-suggestion-funding-Liabilities:CreditCard").tap()
        XCTAssertTrue(result.label.contains("待确认"))
        capture("classification-funding-selected-category-pending")
        reveal("funding").tap()
        reveal("category").tap()
        reveal("import-suggestion-category-Expenses:Education:Books").tap()
        XCTAssertTrue(result.label.contains("待确认"))
        reveal("category").tap()
        reveal("tags").tap()
        reveal("import-suggestion-tag-travel").tap()
        XCTAssertTrue(result.label.contains("已补全"))
        capture("classification-all-fields-reviewed")
        reveal("result").tap()
        XCTAssertTrue(reveal("import-entry-edit-safe-import-2").isHittable)
        XCTAssertEqual(app.buttons["import-commit"].label, "写入 2 条交易")
        capture("classification-full-list-restored")
        app.buttons["import-commit"].tap()
        XCTAssertTrue(app.alerts["确认写入账本？"].waitForExistence(timeout: 3))
        app.alerts.buttons["继续核对"].tap()
    }

    func testImportPreviewFinalRowStaysAboveCommitSurface() throws {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--safe-import-flow"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        if isPad {
            app.buttons["sidebar-imports"].tap()
        } else {
            app.tabBars.buttons["更多"].tap()
            openMoreRow("more-imports")
        }
        XCTAssertTrue(app.navigationBars["核对交易"].waitForExistence(timeout: 8))
        let lastEdit = app.buttons["import-entry-edit-safe-import-2"]
        revealAboveImportActions(lastEdit, in: app.collectionViews["native-import-preview"])
        capture("import-final-row-above-actions")
        lastEdit.tap()
        XCTAssertTrue(app.navigationBars["编辑交易"].waitForExistence(timeout: 3))
    }

    func testNativeImportPreviewSelectionAndCommitFlow() throws {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = [
            "--safe-preview",
            "--safe-import-flow",
            "--safe-import-block-index-baseline",
            "--safe-import-observe-commit",
            "--safe-import-fail-first-commit",
            "--safe-import-lose-success-response",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))

        if isPad {
            let entry = app.buttons["sidebar-imports"]
            XCTAssertTrue(entry.waitForExistence(timeout: 3))
            entry.tap()
        } else {
            app.tabBars.buttons["更多"].tap()
            openMoreRow("more-imports")
        }

        // Picking the file parses it straight away; channel options moved to 解析选项.
        XCTAssertTrue(app.navigationBars["核对交易"].waitForExistence(timeout: 8))
        app.buttons["import-parse-options"].tap()
        XCTAssertTrue(app.navigationBars["解析选项"].waitForExistence(timeout: 3))
        let providerMenu = app.buttons["import-provider-menu"]
        providerMenu.tap()
        XCTAssertTrue(app.buttons["招商银行信用卡"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Gmail 自动账单"].exists)
        app.buttons["自动识别"].tap()
        capture("import-flow-01-preparation")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["解析选项"].waitForNonExistence(timeout: 3))

        XCTAssertTrue(app.buttons["import-commit"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["import-commit"].label, "写入 2 条交易")
        let summary = app.descendants(matching: .any)["import-preview-summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 3))

        let toggle = app.buttons["import-entry-toggle-safe-import-1"]
        let review = app.collectionViews["native-import-preview"]
        revealAboveImportActions(toggle, in: review)
        toggle.tap()
        let oneSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "写入 1 条交易"), object: app.buttons["import-commit"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [oneSelected], timeout: 3), .completed)
        XCTAssertTrue(toggle.label.hasPrefix("包含"))
        revealAboveImportActions(toggle, in: review)
        toggle.tap()
        let twoSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "写入 2 条交易"), object: app.buttons["import-commit"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [twoSelected], timeout: 3), .completed)

        // Batch edits act on the checked entries of the current filter.
        app.buttons["import-batch"].tap()
        let bulkTagInput = app.textFields["import-bulk-tag-input"]
        XCTAssertTrue(bulkTagInput.waitForExistence(timeout: 3))
        replaceText(in: bulkTagInput, with: "travel dining")
        app.buttons["import-bulk-tag-add"].tap()
        app.buttons["import-batch-done"].tap()
        XCTAssertTrue(app.navigationBars["批量修改"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["#dining #learning"].waitForExistence(timeout: 3), app.debugDescription)

        let edit = app.buttons["import-entry-edit-safe-import-1"]
        revealAboveImportActions(edit, in: review)
        capture("import-edit-control-visible")
        edit.tap()
        XCTAssertTrue(app.navigationBars["编辑交易"].waitForExistence(timeout: 3))

        replaceText(in: app.textFields["import-edit-payee"], with: "新城市书房")
        replaceText(in: app.textFields["import-edit-narration"], with: "九月阅读计划")
        app.buttons["import-edit-keyboard-done"].tap()
        let editor = app.collectionViews["import-edit-content"]
        let amount = app.textFields["import-edit-amount"]
        revealAboveEditorBar(amount, in: editor)
        replaceText(in: amount, with: "368.50")
        app.buttons["import-edit-keyboard-done"].tap()
        let tags = app.textFields["import-edit-tags"]
        revealAboveEditorBar(tags, in: editor)
        XCTAssertEqual(tags.value as? String, "dining learning travel")
        replaceText(in: tags, with: "learning travel personal")
        app.buttons["import-edit-keyboard-done"].tap()
        XCTAssertEqual(tags.value as? String, "learning travel personal")
        waitUntilHittable(app.buttons["import-edit-save"])
        app.buttons["import-edit-save"].tap()

        XCTAssertTrue(app.navigationBars["编辑交易"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["核对交易"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)["import-edit-saved-status"].waitForExistence(timeout: 1)
        )
        XCTAssertTrue(app.staticTexts["新城市书房"].waitForExistence(timeout: 3))
        let editAgain = app.buttons["import-entry-edit-safe-import-1"]
        revealAboveImportActions(editAgain, in: review)
        editAgain.tap()
        XCTAssertTrue(app.navigationBars["编辑交易"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["import-edit-payee"].value as? String, "新城市书房")
        XCTAssertEqual(app.textFields["import-edit-narration"].value as? String, "九月阅读计划")
        for _ in 0..<4 where !tags.exists { editor.swipeUp() }
        XCTAssertEqual(app.textFields["import-edit-tags"].value as? String, "learning personal travel")
        XCTAssertEqual(app.textFields["import-edit-amount"].value as? String, "368.50")
        let posting = app.staticTexts["Expenses:Education:Books"]
        for _ in 0..<4 where !posting.exists { editor.swipeUp() }
        XCTAssertTrue(posting.exists)
        XCTAssertTrue(app.staticTexts["368.50 CNY"].exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["核对交易"].waitForExistence(timeout: 3))
        capture("import-flow-02-review")

        let visibleEntryControls = [toggle, editAgain].filter { $0.exists && $0.isHittable }

        app.buttons["写入 2 条交易"].tap()
        let confirmation = app.alerts["确认写入账本？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        let saveStartedAt = Date()
        confirmation.buttons["写入 2 条交易"].tap()

        let savingButton = app.buttons["import-commit"]
        waitForImportSavingState(savingButton, timeout: 2)
        let feedbackElapsed = Date().timeIntervalSince(saveStartedAt)
        XCTAssertFalse(app.buttons["import-batch"].isEnabled)
        for control in visibleEntryControls { XCTAssertFalse(control.isEnabled) }

        let commitError = app.descendants(matching: .any)["import-commit-error"]
        XCTAssertTrue(commitError.waitForExistence(timeout: 5))
        let preservedPayee = app.staticTexts["新城市书房"]
        for _ in 0..<4 where !preservedPayee.exists { review.swipeUp() }
        XCTAssertTrue(preservedPayee.waitForExistence(timeout: 3))

        app.buttons["import-commit"].tap()
        let retryConfirmation = app.alerts["确认写入账本？"]
        XCTAssertTrue(retryConfirmation.waitForExistence(timeout: 3))
        let retryStartedAt = Date()
        retryConfirmation.buttons["写入 2 条交易"].tap()
        let complete = app.scrollViews["native-import-complete"]
        // A slow accessibility snapshot may span the entire simulated response.
        // The first attempt checks the pending controls; retry may already be complete.
        let retryFeedback = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                complete.exists || (savingButton.exists
                    && savingButton.label == "正在验证并写入账本"
                    && savingButton.value as? String == "处理中")
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [retryFeedback], timeout: 5), .completed)
        let retryFeedbackElapsed = Date().timeIntervalSince(retryStartedAt)

        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        let saveElapsed = Date().timeIntervalSince(retryStartedAt)
        let timing = XCTAttachment(
            string: String(
                format: "first-tap-to-feedback=%.0fms retry-tap-to-feedback=%.0fms save-complete=%.0fms",
                feedbackElapsed * 1_000,
                retryFeedbackElapsed * 1_000,
                saveElapsed * 1_000
            )
        )
        timing.name = "native-import-save-timing"
        timing.lifetime = .keepAlways
        add(timing)
        XCTAssertTrue(app.staticTexts["已写入 2 条交易"].exists)
        XCTAssertTrue(app.staticTexts["归档位置"].exists)
        XCTAssertTrue(
            app.staticTexts["保存响应中断，但已通过导入归档确认账本写入完成。"].exists
        )
        capture("import-flow-03-complete")

        app.buttons["完成"].tap()
        let history = app.collectionViews["import-history-content"]
        XCTAssertTrue(history.waitForExistence(timeout: 4))
        let newArchive = app.descendants(matching: .any)[
            "import-document-transactions/2026/documents/imports/2026-08-01_2026-08-30-wechat-safe-import-preview.xlsx"
        ]
        for _ in 0..<5 where !newArchive.exists { history.swipeUp() }
        XCTAssertTrue(newArchive.waitForExistence(timeout: 4))
    }

    func testImportReviewDraftRequiresExplicitDiscard() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--safe-import-flow"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        if isPad { app.buttons["sidebar-imports"].tap() }
        else {
            app.tabBars.buttons["更多"].tap()
            openMoreRow("more-imports")
        }
        let toggle = app.buttons["import-entry-toggle-safe-import-1"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        let review = app.collectionViews["native-import-preview"]
        for _ in 0..<4 where !toggle.isHittable || toggle.frame.midY > app.frame.height * 0.6 { review.swipeUp() }
        toggle.tap()
        let oneSelected = app.buttons.matching(identifier: "import-commit")
            .matching(NSPredicate(format: "label == %@", "写入 1 条交易")).firstMatch
        XCTAssertTrue(oneSelected.waitForExistence(timeout: 3))
        app.navigationBars["核对交易"].buttons["返回"].tap()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 3))
        app.buttons["继续编辑"].tap()
        XCTAssertTrue(oneSelected.waitForExistence(timeout: 3))

        // Drafts are stored per local ledger, so this remote fixture offers no
        // draft to keep and leaving means discarding the review.
        app.navigationBars["核对交易"].buttons["返回"].tap()
        XCTAssertTrue(app.buttons["放弃修改"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["import-exit-keep-draft"].exists)
        app.buttons["放弃修改"].tap()
        XCTAssertTrue(app.collectionViews["import-history-content"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["import-continue-draft"].exists)
    }

    func testTransactionDraftDismissalKeepsChangesUntilDiscarded() throws {
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))
        openDestination(compact: "交易", regular: "交易账本")
        app.buttons["transaction-row-88"].tap()
        app.buttons["transaction-edit"].tap()
        openAdvancedTransactionEditor()
        let editor = app.navigationBars["编辑交易 (高级)"]
        app.buttons["transaction-edit-cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        app.buttons["transaction-edit"].tap()
        openAdvancedTransactionEditor()
        let payee = app.textFields["transaction-edit-payee"]
        replaceText(in: payee, with: "待保存的书店")
        app.buttons["transaction-edit-cancel"].tap()
        XCTAssertTrue(app.buttons["transaction-edit-continue"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["transaction-edit-continue"].firstMatch.tap()
        XCTAssertEqual(payee.value as? String, "待保存的书店")
        if !isPad {
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        }
        XCTAssertTrue(editor.exists)
        XCTAssertEqual(payee.value as? String, "待保存的书店")
        app.buttons["transaction-edit-cancel"].tap()
        XCTAssertTrue(app.buttons["transaction-edit-discard"].firstMatch.waitForExistence(timeout: 3), app.debugDescription)
        capture("transaction-draft-discard-confirmation")
        app.buttons["transaction-edit-discard"].firstMatch.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        app.buttons["transaction-edit"].tap()
        openAdvancedTransactionEditor()
        XCTAssertNotEqual(payee.value as? String, "待保存的书店")
    }

    func testTransactionEditingAndBulkTaggingFlow() throws {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--safe-slow-transaction-write"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))

        if isPad {
            app.buttons["sidebar-transactions"].tap()
        } else {
            app.tabBars.buttons["流水"].tap()
        }
        let transactionRow = app.buttons["transaction-row-88"]
        XCTAssertTrue(transactionRow.waitForExistence(timeout: 4))
        transactionRow.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 3))
        app.buttons["transaction-edit"].tap()
        openAdvancedTransactionEditor()

        replaceText(in: app.textFields["transaction-edit-payee"], with: "新城市书房")
        replaceText(in: app.textFields["transaction-edit-narration"], with: "九月阅读计划")
        replaceText(in: app.textFields["transaction-edit-tags"], with: "learning travel")
        let editStartedAt = Date()
        app.buttons["transaction-edit-save"].tap()
        XCTAssertTrue(app.buttons["正在验证并保存"].waitForExistence(timeout: 1))
        let editFeedbackElapsed = Date().timeIntervalSince(editStartedAt)
        XCTAssertFalse(app.buttons["transaction-edit-save"].isEnabled)

        XCTAssertTrue(app.navigationBars["编辑交易 (高级)"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["新城市书房"].waitForExistence(timeout: 3))
        let editCompleteElapsed = Date().timeIntervalSince(editStartedAt)
        XCTAssertGreaterThanOrEqual(editCompleteElapsed, 0.9)
        // Tags are buttons labelled "#travel" in the detail sheet, and images in
        // the list rows, so match any element by label.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "#travel")).firstMatch.exists,
                      app.debugDescription)
        app.navigationBars["交易详情"].buttons.firstMatch.tap()

        app.buttons["transaction-actions"].tap()
        app.buttons["transaction-tag-selection"].tap()
        let selectableRow = app.buttons["transaction-select-row-88"]
        XCTAssertTrue(selectableRow.waitForExistence(timeout: 3))
        selectableRow.tap()
        app.buttons["添加标签"].tap()
        replaceText(in: app.textFields["transaction-bulk-tag-input"], with: "reviewed")
        let tagStartedAt = Date()
        app.buttons["transaction-bulk-tag-apply"].tap()
        XCTAssertTrue(app.buttons["正在验证标签"].waitForExistence(timeout: 0.5), app.debugDescription)
        let tagFeedbackElapsed = Date().timeIntervalSince(tagStartedAt)
        XCTAssertFalse(app.buttons["transaction-bulk-tag-apply"].isEnabled)
        XCTAssertTrue(app.staticTexts["已验证，并为 1 条交易添加标签。"].waitForExistence(timeout: 4))
        let tagCompleteElapsed = Date().timeIntervalSince(tagStartedAt)
        XCTAssertGreaterThanOrEqual(tagCompleteElapsed, 0.9)
        XCTAssertTrue(app.buttons["transaction-actions"].waitForExistence(timeout: 3))
        app.buttons["transaction-row-88"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "#reviewed")).firstMatch.waitForExistence(timeout: 3),
                      app.debugDescription)
        let timing = XCTAttachment(
            string: String(
                format: "edit-feedback=%.0fms edit-complete=%.0fms bulk-tag-feedback=%.0fms bulk-tag-complete=%.0fms",
                editFeedbackElapsed * 1_000,
                editCompleteElapsed * 1_000,
                tagFeedbackElapsed * 1_000,
                tagCompleteElapsed * 1_000
            )
        )
        timing.name = "native-transaction-response-timing"
        timing.lifetime = .keepAlways
        add(timing)
    }

    func testBulkTagSelectionKeepsAmountClearOfSelectionControl() throws {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))

        if isPad {
            app.buttons["sidebar-transactions"].tap()
        } else {
            app.tabBars.buttons["流水"].tap()
        }

        app.buttons["transaction-actions"].tap()
        app.buttons["transaction-tag-selection"].tap()
        XCTAssertTrue(app.buttons["transaction-select-row-88"].waitForExistence(timeout: 3))

        let amount = app.descendants(matching: .any)["transaction-card-amount-88"]
        let selection = app.descendants(matching: .any)["transaction-card-selection-88"]
        XCTAssertTrue(amount.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        // The selection checkbox leads the row and the amount closes it.
        XCTAssertLessThanOrEqual(selection.frame.maxX, amount.frame.minX)
        let selectedRow = app.buttons["transaction-select-row-88"]
        selectedRow.tap()
        // The row announces its state as a value and the selected trait, not in
        // its label, the way VoiceOver reads it.
        XCTAssertEqual(selectedRow.value as? String, "已选择")
        XCTAssertTrue(selectedRow.isSelected)
        capture("transaction-selected-row-highlight")
    }

    func testChartAxesPreserveTimeSpacingAndTouchShowsSelections() throws {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 8))

        // The Balanced reports draw static charts and list their figures under
        // 查看数据; the account balance trend keeps the time axis and touch selection.
        openDestination(compact: "账户", regular: "账户")
        let cashGroup = app.descendants(matching: .any)["account-group-cash"].firstMatch
        XCTAssertTrue(cashGroup.waitForExistence(timeout: 3), app.debugDescription)
        cashGroup.tap()
        let daily = app.buttons["account-link-Assets:Bank:Daily-CNY"]
        XCTAssertTrue(daily.waitForExistence(timeout: 3), app.debugDescription)
        daily.tap()
        let balanceTrend = app.descendants(matching: .any)["account-balance-trend-chart"]
        XCTAssertTrue(balanceTrend.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertEqual(balanceTrend.value as? String, "真实时间轴")
        waitUntilHittable(balanceTrend)
        dragAcrossChart(balanceTrend)
        XCTAssertTrue(app.descendants(matching: .any)["account-balance-chart-selection"].waitForExistence(timeout: 3))
        capture("chart-account-balance-selected")

        if isPad {
            app.buttons["sidebar-currencies"].tap()
        } else {
            app.compactTab("更多").tap()
            let entry = app.buttons["more-currencies"]
            for _ in 0..<3 where !entry.isHittable { app.swipeUp() }
            waitUntilHittable(entry)
            entry.tap()
        }
        let currencyContent = app.scrollViews["currency-analysis-content"]
        XCTAssertTrue(currencyContent.waitForExistence(timeout: 4))
        let currencyChart = app.descendants(matching: .any)["currency-sparkline-USD"]
        for _ in 0..<8 where !currencyChart.isHittable {
            scrollUpThroughGutter(currencyContent)
        }
        waitUntilHittable(currencyChart)
        dragAcrossChart(currencyChart)
        XCTAssertTrue(app.descendants(matching: .any)["currency-chart-selection-USD"].waitForExistence(timeout: 3))
        capture("chart-currency-selected")

        if isPad {
            app.buttons["sidebar-query"].tap()
        } else {
            app.buttons["返回上一页"].tap()
            openBQLWorkbench()
        }
        let workbench = app.scrollViews["bql-workbench"]
        XCTAssertTrue(workbench.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["bql-run-all"].tap()
        let result = app.descendants(matching: .any)["bql-result-1"]
        for _ in 0..<5 where !result.exists { workbench.swipeUp() }
        XCTAssertTrue(result.waitForExistence(timeout: 4))

        app.buttons["柱状图"].tap()
        let barChart = app.descendants(matching: .any)["bql-bar-chart"]
        for _ in 0..<3 where !barChart.isHittable { workbench.swipeUp() }
        waitUntilHittable(barChart)
        revealAboveTabBar(barChart, in: workbench)
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
            waitUntilHittable(app.buttons["sidebar-incomeExpense"])
            app.buttons["sidebar-incomeExpense"].tap()
        } else {
            app.tabBars.buttons["更多"].tap()
            waitUntilHittable(app.buttons["more-analysis-incomeExpense"])
            app.buttons["more-analysis-incomeExpense"].tap()
        }

        let content = app.scrollViews["analysis-content-incomeExpense"]
        XCTAssertTrue(content.waitForExistence(timeout: 4))
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "收支分析")).count,
            isPad ? 2 : 1
        )

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "选择时间范围")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["时间范围"].waitForExistence(timeout: 3))
        app.buttons["本季度"].tap()
        app.buttons["apply-time-range"].tap()

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

        if !isPad {
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "货币与汇率")).count, 1)
            let backButton = app.buttons["返回上一页"]
            waitUntilHittable(backButton)
            backButton.tap()
            XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 3))
        }
    }

    private func openDestination(compact: String, regular: String) {
        if !isPad {
            // The compact tab bar is the native one; 交易 is titled 流水 there. The
            // bar minimizes on scroll, and a tap on the minimized one re-selects
            // the current tab, so confirm the tab took before moving on.
            let tab = app.compactTab(compact == "交易" ? "流水" : "账户")
            XCTAssertTrue(tab.waitForExistence(timeout: 5), app.debugDescription)
            for _ in 0..<3 where !tab.isSelected {
                waitUntilHittable(tab)
                tab.tap()
                _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "selected == true"), object: tab)], timeout: 3)
            }
            XCTAssertTrue(tab.isSelected, app.debugDescription)
        } else {
            app.buttons[regular == "交易账本" ? "sidebar-transactions" : "sidebar-accounts"].tap()
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
        // Compact pages hide the navigation bar and draw title, period and sync
        // status in their own top bar.
        XCTAssertTrue(app.staticTexts[title].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["ledger-sync-status"].exists)
        capture(captureName)
        let backButton = app.buttons["返回上一页"]
        waitUntilHittable(backButton)
        backButton.tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 3))
        if app.scrollViews.firstMatch.exists {
            app.scrollViews.firstMatch.swipeDown()
        }
        waitUntilHittable(app.buttons["more-analysis-assets"])
    }

    /// Re-enters 更多 from another tab.
    ///
    /// The page routes every overflow destination through one navigation item
    /// (`.navigationDestination(item: $overflowDestination)`), and after one of
    /// them pops the next push is dropped until the page is rebuilt. Switching
    /// tabs rebuilds it; see the PR for the app-side bug this works around.
    private func reopenMore() {
        guard !isPad else { return }
        // 概览 is a tab only while the bar keeps its default tabs; the tab-bar test
        // leaves its own set behind, so fall back to another tab.
        let other = app.tabBars.buttons["概览"].exists ? "概览" : "账户"
        app.compactTab(other).tap()
        app.compactTab("更多").tap()
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Opens 查询 from the compact 更多 list. The row is the last one, so the
    /// floating tab bar reaches over its lower half, and the pop back from the
    /// previous page can still swallow a tap: aim at the top of the row and retry
    /// until the workbench is on screen.
    private func openBQLWorkbench() {
        let entry = app.buttons["more-query"]
        for _ in 0..<3 where !entry.isHittable { app.swipeUp() }
        waitUntilHittable(entry)
        let workbench = app.scrollViews["bql-workbench"]
        for _ in 0..<3 where !workbench.exists {
            guard entry.exists else { break }
            entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            _ = workbench.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(workbench.waitForExistence(timeout: 10), app.debugDescription)
    }

    private func exerciseBQL(capturePrefix: String) {
        // The workbench is a page push from 更多; allow the list to settle under load.
        XCTAssertTrue(app.scrollViews["bql-workbench"].waitForExistence(timeout: 10), app.debugDescription)
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
#if !targetEnvironment(macCatalyst)
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertFalse(app.alerts["重命名查询"].waitForExistence(timeout: 1))
#endif
        }

        if !isPad {
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "BQL 查询")).count, 1)
            let backButton = app.buttons["返回上一页"]
            waitUntilHittable(backButton)
            backButton.tap()
            XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 3))
        }
    }

    /// Editing a plain two-posting entry opens the keypad editor (编辑交易). Its
    /// 高级 button switches to the full form (编辑交易 (高级)), which owns the
    /// field identifiers and the unsaved-changes confirmation.
    private func openAdvancedTransactionEditor() {
        let advanced = app.navigationBars["编辑交易 (高级)"]
        if advanced.exists { return }
        let fast = app.navigationBars["编辑交易"]
        XCTAssertTrue(fast.waitForExistence(timeout: 3), app.debugDescription)
        fast.buttons["高级"].tap()
        XCTAssertTrue(advanced.waitForExistence(timeout: 3), app.debugDescription)
    }

    /// Opens a row of the compact 更多 list. The list is rebuilt when the tab is
    /// selected, so wait for the row itself rather than only scrolling for it.
    private func openMoreRow(_ identifier: String) {
        XCTAssertTrue(app.collectionViews["more-list"].waitForExistence(timeout: 5), app.debugDescription)
        let entry = app.buttons[identifier]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<3 where !entry.isHittable { app.swipeUp() }
        waitUntilHittable(entry)
        entry.tap()
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        // iPad remote keyboard dismissal can make one accessibility snapshot exceed 3s.
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: isPad ? 8 : 3), .completed)
    }

    private func waitForImportSavingState(_ element: XCUIElement, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND label == %@ AND value == %@",
                "正在验证并写入账本",
                "处理中"
            ),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func replaceText(in element: XCUIElement, with replacement: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        element.tap()
        let originalValue = (element.value as? String) ?? ""
        if element.elementType == .textField,
           !originalValue.isEmpty, originalValue != element.placeholderValue {
            // Native forms can scroll while focusing lower fields. The text
            // selection menu follows that field through the keyboard animation.
            element.press(forDuration: 1.0)
            let selectionLabel = NSPredicate(format: "label IN %@", ["Select All", "全选"])
            // The edit menu can appear after the press returns, and lower fields
            // may still be scrolling above the keyboard. Poll briefly for it.
            var selectAll: XCUIElement?
            let deadline = Date().addingTimeInterval(3)
            repeat {
                let candidates = app.menuItems.matching(selectionLabel).allElementsBoundByIndex
                    + app.buttons.matching(selectionLabel).allElementsBoundByIndex
                // The preview behind the sheet also has a Select All action.
                // Only interact with the visible text-selection menu.
                selectAll = candidates.first(where: { $0.isHittable })
                if selectAll == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
            } while selectAll == nil && Date() < deadline
            if selectAll == nil {
                element.press(forDuration: 1.0)
                selectAll = (app.menuItems.matching(selectionLabel).allElementsBoundByIndex
                    + app.buttons.matching(selectionLabel).allElementsBoundByIndex).first(where: { $0.isHittable })
            }
            if let selectAll {
                selectAll.tap()
                element.typeText(replacement)
                XCTAssertEqual(element.value as? String, replacement)
                return
            }
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        // The trailing tap may activate UIKit's search clear control.
        let currentValue = (element.value as? String) ?? ""
        let isEmpty = currentValue.isEmpty || currentValue == element.placeholderValue
        if !isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
        }
        if !replacement.isEmpty {
            if isEmpty { element.tap() }
            element.typeText(replacement)
        }
        // UIKit exposes the placeholder as the accessibility value of an empty search field.
        let value = element.value as? String
        if replacement.isEmpty {
            XCTAssertTrue(value == "" || value == element.placeholderValue)
        } else {
            XCTAssertEqual(value, replacement)
        }
    }

    private func assertStaysPresent(_ element: XCUIElement, duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            XCTAssertTrue(element.exists)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func revealAboveTabBar(_ element: XCUIElement, in scrollView: XCUIElement) {
        let tabBar = app.tabBars.firstMatch
        guard !isPad, tabBar.exists else { return }
        let obscuredEdge = tabBar.frame.minY - 12
        for _ in 0..<4 where element.frame.maxY > obscuredEdge {
            scrollUpThroughGutter(scrollView)
        }
        XCTAssertLessThanOrEqual(element.frame.maxY, obscuredEdge)
    }

    private func revealAboveImportActions(_ element: XCUIElement, in scrollView: XCUIElement) {
        // Native sticky section headers and the commit surface both overlap
        // rows that XCTest reports as hittable. Keep the entire control inside
        // the unobscured band, using short drags to avoid overshooting it.
        let safeTop = app.navigationBars["核对交易"].frame.maxY + 80
        let safeBottom = app.buttons["import-commit"].frame.minY - 64
        let centerY = (safeTop + safeBottom) / 2
        for _ in 0..<10 {
            if element.exists && element.isHittable
                && element.frame.minY > safeTop && element.frame.maxY < safeBottom { break }
            let distance = element.exists ? max(-150, min(150, centerY - element.frame.midY)) : -150
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0))
                .withOffset(CGVector(dx: 0, dy: centerY - scrollView.frame.minY))
            start.press(forDuration: 0.1,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
        XCTAssertGreaterThan(element.frame.minY, safeTop)
        XCTAssertLessThan(element.frame.maxY, safeBottom)
    }

    private func revealAboveEditorBar(_ element: XCUIElement, in scrollView: XCUIElement) {
        // A two-or-more-entry queue adds a 跳过 / 保存，下一条 safeAreaInset to the
        // editor. It overlaps the last fields (金额, 标签) while XCTest still calls
        // them hittable, so a tap lands on the bar instead. Scroll with swipeUp
        // from the middle of the list: a drag anchored near the bottom edge would
        // start inside the bar and fire 保存，下一条, swapping the entry mid-edit.
        let editorTop = app.navigationBars["编辑交易"].frame.maxY + 8
        let barTop = app.buttons["import-edit-save-next"].exists
            ? app.buttons["import-edit-save-next"].frame.minY
            : scrollView.frame.maxY
        let safeBottom = barTop - 12
        for _ in 0..<6 {
            if element.exists && element.isHittable
                && element.frame.minY > editorTop && element.frame.maxY < safeBottom { break }
            scrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
        XCTAssertLessThan(element.frame.maxY, safeBottom)
    }

    private func scrollUpThroughGutter(_ scrollView: XCUIElement) {
        // Keep page scrolling outside the charts' point-selection gestures.
        scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo:
                scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.25)))
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
