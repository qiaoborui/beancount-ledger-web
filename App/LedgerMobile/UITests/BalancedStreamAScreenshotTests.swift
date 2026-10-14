import XCTest

/// Navigation-only screenshot capture for the Balanced design-conformance
/// pass (stream A: reconciliation, pending inbox, event tags, global
/// search). Not part of the regular assertion suite — it exists to get
/// simulator screenshots of each d0N frame onto disk so they can be
/// compared against `docs/design/ios-balanced/index.html`.
///
/// Search and reconciliation use `--safe-preview`, the existing read-mostly
/// preview fixture with populated accounts/transactions, so no manual
/// transaction creation is needed. Pending-inbox uses `--local-ui-testing`
/// with a fresh `LEDGER_LOCAL_TEST_ID` sandbox, reusing the same seeding
/// steps as `LocalLedgerUITests.testLocalPendingInboxHydratesPayeeCancelReopenAndCommit`.
@MainActor
final class BalancedStreamAScreenshotTests: XCTestCase {
    /// No hardcoded scratch path in committed code. Set `BALANCED_SCREENSHOT_DIR`
    /// via `TEST_RUNNER_BALANCED_SCREENSHOT_DIR` (xcodebuild forwards
    /// `TEST_RUNNER_*` env vars into the test process) to also write PNGs to
    /// disk for manual review; unset, the attachment is still captured.
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

    // MARK: - d05/d06 global search (light)

    func testCaptureSearchEmptyAndResults() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--tab=search"]
        app.launch()

        let search = app.searchFields["搜索整个账本"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.8)
        save(app.screenshot(), as: "d05-search-empty")

        search.tap()
        search.typeText("工资")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "d06-search-results")

        // Debug-only: broader queries that also surface account/document/tag
        // result sections, to check their section-head and row styling.
        // `Bank` hits account paths, `Daily` hits the account label, and
        // `#learning` hits the tag section (the app strips the leading `#`
        // before searching, so the tag row renders as `learning`).
        let clear = app.buttons["Clear text"]
        func searchAgain(_ query: String, as name: String) {
            if clear.waitForExistence(timeout: 3) { clear.tap() }
            search.typeText(query)
            Thread.sleep(forTimeInterval: 1.2)
            save(app.screenshot(), as: name)
        }
        searchAgain("Bank", as: "d06-search-results-broad")
        searchAgain("Daily", as: "d06-search-results-daily")
        searchAgain("#learning", as: "d06-search-results-tag")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    // MARK: - d11/d12 reconciliation (light)

    func testCaptureReconciliationListAndDetail() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--safe-preview", "--tab=accounts"]
        app.launch()

        let accountsMenu = app.buttons["账户操作"].firstMatch
        if !accountsMenu.waitForExistence(timeout: 5) {
            app.tabBars.buttons["账户"].tap()
        }
        XCTAssertTrue(accountsMenu.waitForExistence(timeout: 15), app.debugDescription)
        accountsMenu.tap()
        let reconcileEntry = app.buttons["账户对账"].firstMatch
        XCTAssertTrue(reconcileEntry.waitForExistence(timeout: 10), app.debugDescription)
        reconcileEntry.tap()
        // `ReconciliationView` uses the custom `terminalPageChrome`, which hides
        // the native bar on a compact size class and draws its own title —
        // not a `navigationBars` accessibility element.
        XCTAssertTrue(app.staticTexts["对账"].waitForExistence(timeout: 15), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "d11-reconciliation-list")

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'reconciliation-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        row.tap()
        // `ReconciliationFormBody`'s outer `.accessibilityIdentifier("reconciliation-card-…")`
        // shadows every descendant's own identifier in the accessibility
        // snapshot (a pre-existing quirk — `reconciliation-submit` has the
        // same symptom), so the date field is found by its visible label —
        // today's date, since the form seeds `balanceDate` to today.
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateField = app.buttons[formatter.string(from: Date())].firstMatch
        XCTAssertTrue(dateField.waitForExistence(timeout: 15), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "d12-reconciliation-detail")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    // MARK: - d09/d10 pending inbox (light), d23 pending inbox (dark)

    func testCapturePendingInboxListAndSuggestionSheet() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        try capturePendingInbox(dark: false, suffix: "")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    func testCapturePendingInboxDark() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        try capturePendingInbox(dark: true, suffix: "-dark")
        #else
        throw XCTSkip("Simulator-only screenshot capture")
        #endif
    }

    #if targetEnvironment(simulator)
    private func capturePendingInbox(dark: Bool, suffix: String) throws {
        // `-AppleInterfaceStyle Dark` as a launch argument does not flip a
        // SwiftUI app's rendered appearance; the simulator's own appearance
        // (`xcrun simctl ui <device> appearance dark|light`, set by the
        // caller before/after this run) controls it instead.
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing", "--pending-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10))
        app.buttons["local-ledger-create"].tap(); app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 30))
        app.tabBars.buttons["流水"].tap()
        app.buttons["transaction-actions"].tap()
        app.buttons["transaction-create-local"].tap()
        XCTAssertTrue(app.buttons["高级"].waitForExistence(timeout: 5)); app.buttons["高级"].tap()
        let genericPayee = app.textFields["transaction-edit-payee"]
        XCTAssertTrue(genericPayee.waitForExistence(timeout: 5))
        genericPayee.tap(); genericPayee.typeText("商户")
        let amount0 = app.textFields["transaction-edit-posting-amount-0"]
        replaceText(amount0, with: "12.34", in: app)
        // The second posting's amount row can sit below the fold until the
        // form scrolls — nudge the list into view before looking it up.
        let amount1 = app.textFields["transaction-edit-posting-amount-1"]
        if !amount1.exists || !amount1.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(amount1.waitForExistence(timeout: 10), app.debugDescription)
        replaceText(amount1, with: "-12.34", in: app)
        app.buttons["transaction-edit-save"].tap()
        XCTAssertTrue(app.buttons["bookkeeping-confirm-save"].waitForExistence(timeout: 30))
        app.buttons["bookkeeping-confirm-save"].tap()
        XCTAssertTrue(app.textFields["transaction-quick-search"].waitForExistence(timeout: 30))
        app.buttons["test-open-pending-inbox"].tap()
        XCTAssertTrue(app.navigationBars["待整理账单"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), as: "d09-pending-inbox\(suffix)")

        // Tapping a pending row (not the pencil, which only opens the payee
        // sheet) opens `PendingCategorySuggestionSheet`.
        let row = app.staticTexts["商户"].firstMatch
        if row.waitForExistence(timeout: 5) {
            row.tap()
            Thread.sleep(forTimeInterval: 0.5)
            save(app.screenshot(), as: "d10-pending-category\(suffix)")
        }
    }
    #endif

    /// Mirrors `LocalLedgerUITests.replaceActionText`: posting-amount fields
    /// come prefilled, so a plain `typeText` appends instead of replacing.
    private func replaceText(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.press(forDuration: 1)
        let predicate = NSPredicate(format: "label IN %@", ["Select All", "全选"])
        let options = app.menuItems.matching(predicate).allElementsBoundByIndex
            + app.buttons.matching(predicate).allElementsBoundByIndex
        if let all = options.first(where: { $0.isHittable }) {
            all.tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
            let old = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(text)
    }
}
