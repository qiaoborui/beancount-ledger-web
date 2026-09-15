import XCTest

@MainActor
final class LocalSyncToolbarUITests: XCTestCase {
    func testToolbarOpensDeviceStorageThenDirectlySyncsConfiguredGitTwice() throws {
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
        XCTAssertTrue(app.navigationBars["财务概览"].waitForExistence(timeout: 30), app.debugDescription)

        let toolbar = app.buttons["ledger-sync-status"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        expect(toolbar, label: "已保存到本机", enabled: true)
        toolbar.tap()
        XCTAssertTrue(app.navigationBars["存储与同步"].waitForExistence(timeout: 5))
        let repository = app.textFields["local-git-url"]
        XCTAssertTrue(repository.waitForExistence(timeout: 5))
        repository.tap()
        repository.typeText("https://example.invalid/ledger.git")
        let save = app.buttons["local-git-save"]
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable, app.debugDescription)
        save.tap()
        XCTAssertTrue(app.switches["local-git-auto-sync"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars["存储与同步"].buttons["完成"].tap()
        expect(toolbar, label: "等待同步", enabled: true)

        // The configured toolbar starts the exchange directly. Each invocation
        // must expose a disabled busy state and recover an enabled synced state.
        for attempt in 1...2 {
            toolbar.tap()
            expect(toolbar, label: "正在同步", enabled: false, timeout: 5)
            XCTAssertEqual(app.navigationBars["财务概览"].progressIndicators.count, 0,
                "Sync status uses a static dot while the action remains disabled")
            let busyScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            busyScreenshot.name = "local-toolbar-busy-\(attempt)"
            busyScreenshot.lifetime = .keepAlways
            add(busyScreenshot)
            XCTAssertFalse(app.navigationBars["存储与同步"].exists)
            XCTAssertFalse(app.alerts["同步这个 Git 工作区？"].exists)
            expect(toolbar, label: "已同步", enabled: true, timeout: 30)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "local-toolbar-synced"
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
