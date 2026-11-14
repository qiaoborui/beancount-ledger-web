import XCTest

/// Screenshots of the AI 开账 surfaces, for looking at the screens without a
/// model, a key or a network: a fresh `--local-ui-testing` ledger reaches the
/// model setup and its settings sheet on its own.
///
/// Not part of the assertion suite — like `BalancedScreenshotTests` it exists to
/// get simulator PNGs onto disk. CI runs it only when `ui_tests_only` names it,
/// and uploads the PNGs as the `ui-screenshots` artifact.
///
/// What is not here: 助手设置, 技能 and the conversation itself. They live behind
/// the assistant's floating tab, and tapping that tab does not reach the app's
/// selection binding on a simulator, so the cover never opens (`--initial-tab=
/// agent` does not help: the tab bar writes its own selection over it). Until a
/// reachable entry exists, capture those by hand on a device.
///
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
