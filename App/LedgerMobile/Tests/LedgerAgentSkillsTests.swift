import XCTest
@testable import LedgerMobile

final class LedgerAgentSkillsTests: XCTestCase {
    /// The catalog JSON as `SkillCatalogJSON` returns it.
    private let catalogJSON = #"""
    {"version":1,"ok":true,"skills":[
      {"name":"alipay-bill-import","description":"导入支付宝账单","source":"builtin","path":"skills/alipay-bill-import/SKILL.md","body":"第一步","disabled":true},
      {"name":"monthly-close","description":"月底对账","source":"ledger","path":"skills/monthly-close/SKILL.md","body":"第二步"}
    ],"problems":[{"path":"skills/broken/SKILL.md","error":"缺少 frontmatter"}]}
    """#

    func testCatalogDecodesWhatTheNativeSideLists() throws {
        let catalog = try JSONDecoder().decode(LedgerAgentSkillCatalog.self, from: Data(catalogJSON.utf8))
        XCTAssertTrue(catalog.ok)
        XCTAssertEqual(catalog.skills.map(\.name), ["alipay-bill-import", "monthly-close"])
        XCTAssertEqual(catalog.skills.map(\.isBuiltIn), [true, false])
        XCTAssertEqual(catalog.skills.map(\.sourceTitle), [String(localized: "内置"), String(localized: "账本")])
        XCTAssertEqual(catalog.skills.first?.disabled, true)
        XCTAssertEqual(catalog.skills.last?.body, "第二步")
        XCTAssertEqual(catalog.skills.last?.path, "skills/monthly-close/SKILL.md")
        XCTAssertEqual(catalog.problems.first?.path, "skills/broken/SKILL.md")
        XCTAssertEqual(catalog.problems.first?.error, "缺少 frontmatter")
    }

    func testLoadAsksTheNativeSideForTheLedgerAndItsDisabledNames() async throws {
        let recorder = Recorder()
        let lister = await recorder.lister(catalogJSON)
        let catalog = try await LedgerAgentSkillCatalog.load(workspaceRoot: "/ledger", disabled: ["monthly-close"],
                                                            using: lister)
        XCTAssertEqual(catalog.skills.count, 2)
        let recorded = await recorder.lastRequest()
        let data = try XCTUnwrap(recorded)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(request["workspaceRoot"] as? String, "/ledger")
        XCTAssertEqual(request["disabledSkills"] as? [String], ["monthly-close"])
        XCTAssertEqual(request["version"] as? Int, 1)
    }

    func testLoadSendsNoDisabledNamesWhenNothingIsOff() async throws {
        let recorder = Recorder()
        let lister = await recorder.lister(catalogJSON)
        _ = try await LedgerAgentSkillCatalog.load(workspaceRoot: "/ledger", using: lister)
        let recorded = await recorder.lastRequest()
        let data = try XCTUnwrap(recorded)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(request["disabledSkills"])
    }

    func testCatalogSurfacesTheNativeError() async {
        let lister = LedgerAgentSkillLister(list: { _, _ in throw LedgerAgentError.failed("boom") })
        do {
            _ = try await LedgerAgentSkillCatalog.load(workspaceRoot: "/ledger", using: lister)
            XCTFail("a failed read was reported as an empty catalog")
        } catch {
            XCTAssertEqual(error.localizedDescription, "boom")
        }
    }

    @MainActor
    func testDisabledSkillsPersistAndTravelOnlyWhenSet() throws {
        let suite = "LedgerAgentSkillsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = LedgerAgentSkillSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled("alipay-bill-import"))
        XCTAssertNil(settings.turnValue)

        settings.setEnabled(false, name: "monthly-close")
        settings.setEnabled(false, name: "alipay-bill-import")
        XCTAssertFalse(settings.isEnabled("alipay-bill-import"))
        XCTAssertEqual(settings.turnValue, ["alipay-bill-import", "monthly-close"])

        // The choice survives the page: it is this device's, not the ledger's.
        let restored = LedgerAgentSkillSettings(defaults: defaults)
        XCTAssertEqual(restored.disabled, ["alipay-bill-import", "monthly-close"])
        restored.setEnabled(true, name: "alipay-bill-import")
        XCTAssertEqual(restored.disabled, ["monthly-close"])
        restored.setEnabled(true, name: "monthly-close")
        XCTAssertNil(restored.turnValue)
    }

    func testTurnRequestCarriesDisabledSkillsOnlyWhenSet() throws {
        var request = LedgerAgentTurnRequest(turnId: "t", workspaceRoot: "/w", runtimeRoot: "/r", entrypoint: "main.bean",
            modelHandle: nil, sensitiveUnlocked: true, provider: "anthropic", model: "m", apiKey: "k", history: [], message: "hi")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(object["disabledSkills"])
        request.disabledSkills = ["alipay-bill-import"]
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["disabledSkills"] as? [String], ["alipay-bill-import"])
    }

    func testRepositorySendsTheDisabledSkillsWithTheTurn() async throws {
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: SkillEngine(), validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Skills fixture")
        let repository = catalog.repository(for: descriptor)
        let recorder = Recorder()
        let runner = LedgerAgentRunner(run: { data in
            await recorder.record(data)
            return Data(#"{"version":1,"ok":true,"reply":"ok","toolCalls":[]}"#.utf8)
        }, cancel: { _ in })
        let response = try await repository.runAgentTurn(message: "你好", history: [],
            choice: .init(provider: "anthropic", model: "m"), apiKey: "k", sensitiveUnlocked: true,
            disabledSkills: ["alipay-bill-import"], runner: runner)
        XCTAssertTrue(response.ok)
        let recorded = await recorder.lastRequest()
        let data = try XCTUnwrap(recorded)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(request["disabledSkills"] as? [String], ["alipay-bill-import"])
    }

    // MARK: Fixtures

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerAgentSkillsTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Records the JSON each native call received.
    private actor Recorder {
        private var requests: [Data] = []

        func record(_ data: Data) { requests.append(data) }

        /// The last request, for the tests to read field by field.
        func lastRequest() -> Data? { requests.last }

        /// A stand-in for the native lister that records the request it was
        /// given, encoding it the way `LedgerAgentSkillLister.native` does.
        func lister(_ response: String) -> LedgerAgentSkillLister {
            LedgerAgentSkillLister(list: { [self] root, disabled in
                let request = try JSONEncoder().encode(Request(workspaceRoot: root,
                                                               disabledSkills: disabled.isEmpty ? nil : disabled))
                await record(request)
                return try JSONDecoder().decode(LedgerAgentSkillCatalog.self, from: Data(response.utf8))
            })
        }

        private struct Request: Encodable {
            let version = 1
            let workspaceRoot: String
            let disabledSkills: [String]?
        }
    }

    private actor SkillEngine: LocalLedgerEngine {
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data { Data("{}".utf8) }
        func committedModelHandle(for request: LocalLedgerEngineRequest, replacing stale: String?) async throws -> String? { "h1" }
    }
}
