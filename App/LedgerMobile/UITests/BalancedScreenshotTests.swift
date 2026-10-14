import XCTest

/// Navigation-only screenshot capture for the Balanced design-conformance
/// pass (stream B: library, onboarding, categories, storage, settings,
/// lock, local files). Not part of the regular assertion suite — it exists
/// to get simulator screenshots of each d0N frame onto disk so they can be
/// compared against `docs/design/ios-balanced/index.html`.
///
/// All local-only tests use `--local-ui-testing` with a fresh
/// `LEDGER_LOCAL_TEST_ID`, which is an in-memory, UUID-scoped sandbox — no
/// writes ever touch a real ledger. Categories/add-category use
/// `--safe-preview`, the existing read-mostly preview fixture, since that
/// screen needs a populated set of accounts the empty local-ui-testing
/// ledger doesn't have.
@MainActor
final class BalancedScreenshotTests: XCTestCase {
    private let outputDir = ProcessInfo.processInfo.environment["BALANCED_SCREENSHOT_DIR"]

    private func save(_ screenshot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let outputDir else { return }
        let path = outputDir + "/" + name + ".png"
        do {
            try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
        } catch {
            XCTFail("Could not write screenshot to \(path): \(error)")
        }
    }

    // MARK: - d01 library, d02-d04 onboarding (light)

    func testCaptureLibraryAndOnboardingLight() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()

        // d01 — the library is the very first screen for a fresh fixture.
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 1)
        save(app.screenshot(), as: "d01-library")

        // d02 — wizard step 1: name + currency.
        app.buttons["local-ledger-open-wizard"].tap()
        XCTAssertTrue(app.navigationBars["开账"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "d02-onboarding-name")

        // d03 — wizard step 2: accounts + opening balances.
        app.buttons["下一步"].tap()
        XCTAssertTrue(app.navigationBars["选择账户"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "d03-onboarding-accounts")

        // Step 3 (categories) has no design frame of its own — pass through.
        app.buttons["下一步"].tap()
        XCTAssertTrue(app.navigationBars["选择分类"].waitForExistence(timeout: 10), app.debugDescription)

        // d04 — wizard step 4: net-worth settle + accounts.bean preview.
        // Stop here; do not tap 创建账本.
        app.buttons["下一步"].tap()
        XCTAssertTrue(app.navigationBars["核对期初"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "d04-onboarding-summary")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    // MARK: - d04 dark

    func testCaptureOnboardingSummaryDark() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing", "-AppleInterfaceStyle", "Dark"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()

        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["local-ledger-open-wizard"].tap()
        XCTAssertTrue(app.navigationBars["开账"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["下一步"].tap()
        XCTAssertTrue(app.navigationBars["选择账户"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["下一步"].tap()
        XCTAssertTrue(app.navigationBars["选择分类"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["下一步"].tap()
        XCTAssertTrue(app.navigationBars["核对期初"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "d21-onboarding-summary-dark")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    // MARK: - d07 categories, d08 add-category sheet

    func testCaptureCategoriesAndAddCategory() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--safe-preview"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["更多"].waitForExistence(timeout: 20), app.debugDescription)
        app.tabBars.buttons["更多"].tap()
        let categories = app.buttons["more-categories"]
        for _ in 0..<5 where !categories.isHittable { app.swipeUp() }
        XCTAssertTrue(categories.waitForExistence(timeout: 10), app.debugDescription)
        categories.tap()

        // d07
        XCTAssertTrue(app.staticTexts["分类管理"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.8)
        save(app.screenshot(), as: "d07-categories")

        // d08 — the add-category sheet.
        app.buttons["新建分类"].tap()
        XCTAssertTrue(app.navigationBars["新建分类"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "d08-add-category")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    // MARK: - d13 storage, d19 local files

    func testCaptureStorageAndFiles() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["local-ledger-create"].tap()
        XCTAssertTrue(app.buttons["local-ledger-confirm-create"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 40), app.debugDescription)

        app.tabBars.buttons["更多"].tap()
        let settings = app.buttons["more-settings"]
        for _ in 0..<5 where !settings.isHittable { app.swipeUp() }
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        settings.tap()

        // d13 — 存储与同步.
        let storage = app.buttons["local-storage-settings"]
        for _ in 0..<5 where !storage.isHittable { app.swipeUp() }
        XCTAssertTrue(storage.waitForExistence(timeout: 10), app.debugDescription)
        storage.tap()
        XCTAssertTrue(app.navigationBars["存储与同步"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.8)
        save(app.screenshot(), as: "d13-storage")
        app.navigationBars["存储与同步"].buttons.firstMatch.tap()

        // d19 — 本地文件.
        let files = app.buttons["settings-local-files"]
        for _ in 0..<5 where !files.isHittable { app.swipeUp() }
        XCTAssertTrue(files.waitForExistence(timeout: 10), app.debugDescription)
        files.tap()
        XCTAssertTrue(app.navigationBars["本地文件"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.8)
        save(app.screenshot(), as: "d19-local-files")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    // d14 (sync conflict) is not captured: the isolated `--local-sync-ui-testing`
    // transport has no scripted way to produce a two-sided conflict without a
    // second, independently-mutated clone of the same in-memory remote, which
    // the current fixture (`LocalUITestGitTransport`) doesn't expose.

    // MARK: - d15 settings (top + scrolled)

    func testCaptureSettings() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["local-ledger-create"].tap()
        XCTAssertTrue(app.buttons["local-ledger-confirm-create"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 40), app.debugDescription)

        app.tabBars.buttons["更多"].tap()
        let settings = app.buttons["more-settings"]
        for _ in 0..<5 where !settings.isHittable { app.swipeUp() }
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.staticTexts["设置"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.8)
        save(app.screenshot(), as: "d15-settings-top")

        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.4)
        save(app.screenshot(), as: "d15-settings-scrolled")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    // MARK: - d16 lock

    func testCaptureLock() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["local-ledger-create"].tap()
        XCTAssertTrue(app.buttons["local-ledger-confirm-create"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 40), app.debugDescription)

        app.tabBars.buttons["更多"].tap()
        let settings = app.buttons["more-settings"]
        for _ in 0..<5 where !settings.isHittable { app.swipeUp() }
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.staticTexts["设置"].waitForExistence(timeout: 10), app.debugDescription)

        let lockNow = app.buttons["立即锁定"]
        for _ in 0..<5 where !lockNow.isHittable { app.swipeUp() }
        XCTAssertTrue(lockNow.waitForExistence(timeout: 10), app.debugDescription)
        lockNow.tap()
        XCTAssertTrue(app.navigationBars["账本已锁定"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.8)
        save(app.screenshot(), as: "d16-lock")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    // MARK: - P3 part B: transaction detail, create/edit, share (debug launch args)

    func testCaptureTransactionDetail() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--open-transaction-detail"]
        app.launch()
        XCTAssertTrue(app.navigationBars.buttons["关闭"].waitForExistence(timeout: 20), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.8)
        save(app.screenshot(), as: "p3b-transaction-detail")

        // Double-entry breakdown + source disclosure sit further down.
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.4)
        save(app.screenshot(), as: "p3b-transaction-detail-scrolled")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    func testCaptureCreateTransaction() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--open-create-transaction"]
        app.launch()
        // CookieFastTransactionEditorBody has no nav bar title; wait on the keypad.
        XCTAssertTrue(app.buttons["keypad-7"].waitForExistence(timeout: 20), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.8)
        save(app.screenshot(), as: "p3b-create-transaction-expense")

        let incomeTab = app.buttons["收入"]
        if incomeTab.waitForExistence(timeout: 5) {
            incomeTab.tap()
            Thread.sleep(forTimeInterval: 0.4)
            save(app.screenshot(), as: "p3b-create-transaction-income")
        }
        let transferTab = app.buttons["转账"]
        if transferTab.waitForExistence(timeout: 5) {
            transferTab.tap()
            Thread.sleep(forTimeInterval: 0.4)
            save(app.screenshot(), as: "p3b-create-transaction-transfer")
        }
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    func testCaptureNaturalLanguageBookkeeping() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["local-ledger-create"].tap()
        XCTAssertTrue(app.buttons["local-ledger-confirm-create"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 40), app.debugDescription)

        app.tabBars.buttons["流水"].tap()
        XCTAssertTrue(app.buttons["transaction-actions"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["transaction-actions"].tap()
        app.buttons["transaction-create-local"].tap()
        let natural = app.buttons["bookkeeping-natural-entry"]
        XCTAssertTrue(natural.waitForExistence(timeout: 10), app.debugDescription)
        natural.tap()
        XCTAssertTrue(app.navigationBars["用一句话记账"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.8)
        save(app.screenshot(), as: "p3-natural-bookkeeping-empty")

        // Parsed state: a sentence that yields one expense with a known account.
        let input = app.textViews["bookkeeping-natural-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), app.debugDescription)
        input.tap()
        input.typeText("中午在美团外卖点餐 35 元，微信零钱支付。")
        app.buttons["bookkeeping-parse"].tap()
        let prepare = app.buttons["bookkeeping-prepare"]
        for _ in 0..<7 where !prepare.exists || !prepare.isHittable { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1.2)
        save(app.screenshot(), as: "p3-natural-bookkeeping-parsed")

        // 修改交易信息 sheet.
        app.swipeDown()
        let edit = app.buttons["修改商户或备注"].firstMatch
        if edit.waitForExistence(timeout: 5), edit.isHittable {
            edit.tap()
            Thread.sleep(forTimeInterval: 0.6)
            save(app.screenshot(), as: "p3-natural-bookkeeping-details-sheet")
        }
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    func testCaptureTransactionShare() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--open-transaction-share"]
        app.launch()
        Thread.sleep(forTimeInterval: 1.5)
        save(app.screenshot(), as: "p3b-transaction-share")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    // MARK: - b04 — 流水, 收入筛选 (navigation-only, dark set by the caller)

    func testCaptureTransactionsIncomeFilter() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--tab=transactions"]
        app.launch()
        let segBar = app.descendants(matching: .any)["transaction-kind-filter"]
        XCTAssertTrue(segBar.waitForExistence(timeout: 10), app.debugDescription)
        let incomeTab = segBar.buttons["收入2"].firstMatch
        if !incomeTab.exists {
            // VoiceOver label concatenates title + count without a space.
            for button in segBar.buttons.allElementsBoundByIndex where button.label.hasPrefix("收入") {
                button.tap()
                break
            }
        } else {
            incomeTab.tap()
        }
        Thread.sleep(forTimeInterval: 1)
        save(app.screenshot(), as: "b04-transactions-income-filter")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    // MARK: - b05/b06 — 收支分析

    func testCaptureIncomeExpenseAnalysis() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--tab=incomeExpense"]
        app.launch()
        Thread.sleep(forTimeInterval: 1.5)
        save(app.screenshot(), as: "b05-income-expense-top")

        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "b06-income-expense-mid0")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "b06-income-expense-mid1")
        for _ in 0..<2 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "b06-income-expense-mid2")
        for _ in 0..<2 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "b06-income-expense-tables")
        for _ in 0..<6 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "b06-income-expense-tail")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }
}
