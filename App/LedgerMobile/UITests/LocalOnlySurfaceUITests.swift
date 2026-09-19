import XCTest

@MainActor
final class LocalOnlySurfaceUITests: XCTestCase {
    func testSmartClassificationSettingsAreOptInForEachLocalLedger() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10))
        app.buttons["local-ledger-create"].tap()
        app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.navigationBars["财务概览"].waitForExistence(timeout: 40))
        app.tabBars.buttons["更多"].tap()
        app.buttons["more-settings"].tap()
        let settings = app.buttons["settings-classification"]
        for _ in 0..<4 where !settings.isHittable { app.swipeUp() }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["智能分类"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["classification-enabled"].value as? String, "0")
        XCTAssertTrue(app.secureTextFields["classification-api-key"].exists)
        XCTAssertFalse(app.buttons["classification-save-key"].isEnabled)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "classification-settings-opt-in"
        shot.lifetime = .keepAlways
        add(shot)
        #else
        throw XCTSkip("Uses the isolated simulator ledger fixture")
        #endif
    }

    func testLocalSettingsAndImportsExposeDeviceFeatures() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["local-ledger-create"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["local-ledger-import"].exists)
        XCTAssertTrue(app.buttons["local-ledger-add-git"].exists)
        XCTAssertFalse(app.buttons["ledger-remote-connect"].exists)
        app.buttons["local-ledger-create"].tap()
        app.buttons["local-ledger-confirm-create"].tap()
        XCTAssertTrue(app.navigationBars["财务概览"].waitForExistence(timeout: 40))
        let syncStatus = app.buttons["ledger-sync-status"]
        XCTAssertTrue(syncStatus.exists)
        XCTAssertEqual(syncStatus.label, "已保存到本机")
        XCTAssertFalse(app.buttons["隐藏金额"].exists)
        XCTAssertFalse(app.buttons["显示金额"].exists)
        syncStatus.tap()
        XCTAssertTrue(app.navigationBars["存储与同步"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.tabBars.buttons["更多"].tap()
        app.buttons["more-settings"].tap()
        XCTAssertTrue(app.buttons["settings-local-files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["local-storage-settings"].exists)
        XCTAssertFalse(app.buttons["更换服务器"].exists)
        XCTAssertFalse(app.staticTexts["服务器"].exists)
        XCTAssertFalse(app.buttons["settings-widget-background-refresh"].exists)
        let settings = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        settings.name = "local-settings-device-only"
        settings.lifetime = .keepAlways
        add(settings)

        let storage = app.buttons["local-storage-settings"]
        for _ in 0..<4 where !storage.isHittable { app.swipeUp() }
        storage.tap()
        XCTAssertTrue(app.navigationBars["存储与同步"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["状态, 已保存到本机"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["local-git-url"].exists)
        XCTAssertTrue(app.textFields["local-git-branch"].exists)
        XCTAssertFalse(app.buttons["local-git-save"].isEnabled)
        XCTAssertFalse(app.buttons["local-git-sync"].exists)
        let storageScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        storageScreen.name = "local-storage-explicit-sync"
        storageScreen.lifetime = .keepAlways
        add(storageScreen)
        // Isolated fixture sessions keep networking disabled. Exercise the real
        // persisted automatic-sync control without accessing a remote repository.
        let gitURL = app.textFields["local-git-url"]
        gitURL.tap()
        gitURL.typeText("https://example.invalid/auto-sync-fixture.git\n")
        let saveGit = app.buttons["local-git-save"]
        for _ in 0..<4 where !saveGit.isHittable { app.swipeUp() }
        saveGit.tap()
        let automaticSync = app.switches["local-git-auto-sync"]
        XCTAssertTrue(automaticSync.waitForExistence(timeout: 5))
        for _ in 0..<4 where !automaticSync.isHittable || automaticSync.frame.maxY > app.frame.height * 0.75 { app.swipeUp() }
        XCTAssertEqual(automaticSync.value as? String, "1")
        // XCTest exposes both the entire labeled row and the native thumb as
        // switches. Target the visible trailing control within the labeled row.
        automaticSync.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: automaticSync)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["local-git-sync"].exists)
        let automaticScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        automaticScreen.name = "local-storage-automatic-sync"
        automaticScreen.lifetime = .keepAlways
        add(automaticScreen)
        app.navigationBars["存储与同步"].buttons.firstMatch.tap()

        let files = app.buttons["settings-local-files"]
        for _ in 0..<4 where !files.isHittable { app.swipeUp() }
        files.tap()
        XCTAssertTrue(app.buttons["main.bean"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["准备导出账本"].exists)
        app.buttons["main.bean"].tap()
        XCTAssertTrue(app.textViews["local-ledger-file-editor"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["local-ledger-file-save"].exists)
        XCTAssertFalse(app.buttons["local-ledger-file-save"].isEnabled)
        app.navigationBars["main.bean"].buttons.firstMatch.tap()
        app.navigationBars["本地文件"].buttons.firstMatch.tap()
        app.navigationBars["设置"].buttons.firstMatch.tap()
        let imports = app.buttons["more-imports"]
        for _ in 0..<4 where !imports.isHittable { app.swipeUp() }
        imports.tap()
        XCTAssertTrue(app.buttons["import-select-file"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Gmail 自动账单"].exists)
        XCTAssertFalse(app.buttons["gmail-connect"].exists)
        XCTAssertFalse(app.buttons["gmail-sync"].exists)
        let importScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        importScreen.name = "local-import-file-only"
        importScreen.lifetime = .keepAlways
        add(importScreen)
        #else
        throw XCTSkip("Uses the simulator-only isolated authentication fixture")
        #endif
    }
}
