import XCTest

/// Screenshots of the 账本助手 surfaces the AI-native batch added: 助手设置
/// with its 写入账本 policy, 技能, MCP 服务器, and AI 开账's model setup.
///
/// Not part of the assertion suite — like `BalancedScreenshotTests` it exists to
/// get simulator PNGs onto disk, so a person can look at the screens without
/// waiting for a model, a key or a real MCP server. Nothing here needs a
/// network: a fresh local ledger in `--local-ui-testing` is enough for the
/// settings pages, and the built-in skills come from the app itself.
///
/// The pages that need a model key (a conversation, the draft's completeness
/// bar, the change card) are not captured here; they cannot be reached on a
/// simulator without a real key.
@MainActor
final class AssistantScreenshotTests: XCTestCase {
    private let outputDir = ProcessInfo.processInfo.environment["UI_SCREENSHOT_DIR"]

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

    /// Let the push or the sheet finish animating before the capture.
    private func settle() {
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// A `NavigationLink` row by the identifier it carries. SwiftUI exposes the
    /// row as a button on most list styles and as a cell on others.
    private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The pushed page's leading button. The pages below add nothing else to
    /// that side of the navigation bar.
    private func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        settle()
    }

    func testCaptureAssistantSettingsAndCapabilities() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        // The pagination fixture seeds a populated ledger in one tap, which is
        // what gives the app a 助手 tab; no model key is involved.
        app.launchArguments = ["--local-ui-testing", "--pagination-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()

        let seed = app.buttons["test-import-pagination-ledger"]
        XCTAssertTrue(seed.waitForExistence(timeout: 15), app.debugDescription)
        seed.tap()
        XCTAssertTrue(app.staticTexts["财务概览"].waitForExistence(timeout: 30), app.debugDescription)
        // The seeding overlay sits over the tab bar and eats the tab tap until
        // the fixture says it is done.
        XCTAssertTrue(app.staticTexts["pagination-fixture-ready"].waitForExistence(timeout: 30), app.debugDescription)

        app.tabBars.buttons["助手"].tap()
        let setUp = app.buttons["ledger-agent-setup"]
        XCTAssertTrue(setUp.waitForExistence(timeout: 10), app.debugDescription)
        settle()
        save(app.screenshot(), as: "assistant-intro")

        // Without a key the screen is the intro card; its button opens the same
        // 助手设置 sheet the round button in the bar opens.
        setUp.tap()
        XCTAssertTrue(app.navigationBars["助手设置"].waitForExistence(timeout: 10), app.debugDescription)
        settle()
        save(app.screenshot(), as: "assistant-settings")

        let skills = row(app, "ledger-agent-skills")
        XCTAssertTrue(skills.waitForExistence(timeout: 5), app.debugDescription)
        skills.tap()
        XCTAssertTrue(app.navigationBars["技能"].waitForExistence(timeout: 10), app.debugDescription)
        // The catalog is read through the native bridge; give it a moment to
        // list the built-in skills before the capture.
        _ = app.staticTexts["alipay-bill-import"].waitForExistence(timeout: 15)
        settle()
        save(app.screenshot(), as: "assistant-skills")
        goBack(app)

        let mcp = row(app, "ledger-agent-mcp")
        XCTAssertTrue(mcp.waitForExistence(timeout: 5), app.debugDescription)
        mcp.tap()
        XCTAssertTrue(app.navigationBars["MCP 服务器"].waitForExistence(timeout: 10), app.debugDescription)
        settle()
        save(app.screenshot(), as: "assistant-mcp")
        #else
        throw XCTSkip("Uses isolated simulator ledger")
        #endif
    }

    func testCaptureAIOnboarding() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--local-ui-testing"]
        app.launchEnvironment["LEDGER_LOCAL_TEST_ID"] = UUID().uuidString
        app.launch()

        let start = app.buttons["local-ledger-open-ai-onboarding"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), app.debugDescription)
        settle()
        save(app.screenshot(), as: "onboarding-library")

        start.tap()
        let setUpModel = app.buttons["ai-onboarding-setup-model"]
        XCTAssertTrue(setUpModel.waitForExistence(timeout: 10), app.debugDescription)
        settle()
        save(app.screenshot(), as: "onboarding-setup")

        // AI 开账 has no ledger yet, so its settings are the model page alone.
        setUpModel.tap()
        XCTAssertTrue(app.navigationBars["模型与密钥"].waitForExistence(timeout: 10), app.debugDescription)
        settle()
        save(app.screenshot(), as: "onboarding-model-only-settings")
        #else
        throw XCTSkip("Uses isolated simulator ledger")
        #endif
    }
}
