import XCTest

@MainActor
final class LocalSyncToolbarUITests: XCTestCase {
    func testLocalOnlyOverviewHidesSyncAndConfiguredOverviewOpensDetails() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing", "--local-sync-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10))
        app.buttons["local-ledger-create"].tap()
        XCTAssertTrue(app.buttons["local-ledger-confirm-create"].waitForExistence(timeout: 5))
        app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.buttons["navigation-time-range"].waitForExistence(timeout: 30), app.debugDescription)

        XCTAssertTrue(app.buttons["local-ledger-confirm-create"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.buttons["ledger-sync-status"].exists, "Local-only overview has no sync indicator")
        let accounts = app.tabBars.buttons["账户"]
        accounts.tap()
        // Creating the first local ledger replaces the onboarding host. As in
        // LocalLedgerUITests, allow its first navigation transition to settle.
        if !app.collectionViews["accounts-list"].waitForExistence(timeout: 3) { accounts.tap() }
        XCTAssertTrue(app.collectionViews["accounts-list"].waitForExistence(timeout: 5))
        let toolbar = app.buttons["ledger-sync-status"]
        XCTAssertFalse(toolbar.exists, "Local-only Accounts also hides sync")
        app.tabBars.buttons["更多"].tap()
        app.buttons["more-settings"].tap()
        let storage = app.buttons["存储与同步"]
        for _ in 0..<5 where !storage.isHittable { app.swipeUp() }
        storage.tap()
        XCTAssertTrue(app.navigationBars["存储与同步"].waitForExistence(timeout: 5))
        let repository = app.textFields["local-git-url"]
        XCTAssertTrue(repository.waitForExistence(timeout: 5))
        repository.tap()
        repository.typeText("https://example.invalid/ledger.git\n")
        let save = app.buttons["local-git-save"]
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable, app.debugDescription)
        save.tap()
        app.swipeUp()
        XCTAssertTrue(app.switches["local-git-auto-sync"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars["存储与同步"].buttons.firstMatch.tap()
        app.tabBars.buttons["账户"].tap()
        expect(toolbar, label: "等待同步", enabled: true)
        toolbar.tap()
        XCTAssertTrue(app.navigationBars["存储与同步"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["同步这个 Git 工作区？"].exists)
        app.navigationBars["存储与同步"].buttons["完成"].tap()
        expect(toolbar, label: "等待同步", enabled: true)
        app.tabBars.buttons["概览"].tap()
        expect(toolbar, label: "等待同步", enabled: true)
        toolbar.tap()
        XCTAssertTrue(app.navigationBars["存储与同步"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["同步这个 Git 工作区？"].exists)
        app.navigationBars["存储与同步"].buttons["完成"].tap()
        expect(toolbar, label: "等待同步", enabled: true)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "local-toolbar-pending"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #else
        throw XCTSkip("Uses a simulator-only UUID-scoped local ledger and in-memory Git transport")
        #endif
    }

    private func expect(_ element: XCUIElement, label: String, enabled: Bool, timeout: TimeInterval = 10,
                        file: StaticString = #filePath, line: UInt = #line) {
        let state = NSPredicate(format: "exists == true AND label == %@ AND enabled == %@", label, NSNumber(value: enabled))
        let expectation = XCTNSPredicateExpectation(predicate: state, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
            "Expected \(label), enabled=\(enabled); got \(element.debugDescription)", file: file, line: line)
    }
}
