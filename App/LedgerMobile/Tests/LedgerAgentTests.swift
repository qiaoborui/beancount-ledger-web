import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerAgentTests: XCTestCase {
    func testToolCallTitlesUseTheArguments() throws {
        let calls = try JSONDecoder().decode([LedgerAgentToolCall].self, from: Data("""
        [{"name":"get_ledger_summary","arguments":{"start":"2026-10-01","end":"2026-10-31"},"isError":false},
         {"name":"search_transactions","arguments":{"query":"巷口小馆"},"isError":false},
         {"name":"run_bql","arguments":{"query":"  SELECT 1  "},"isError":true},
         {"name":"get_accounts","isError":false}]
        """.utf8))
        XCTAssertEqual(calls.map(\.title), ["汇总 · 10-01 至 10-31", "搜索流水 · 巷口小馆", "BQL 查询", "账户"])
        XCTAssertEqual(calls[2].source, "SELECT 1")
        XCTAssertTrue(calls[2].isError)
        XCTAssertNil(calls[0].source)
    }

    func testHistoryReplaysAnsweredExchangesWithinTheBudget() {
        var messages: [LedgerAgentMessage] = []
        for index in 0..<10 {
            messages.append(.init(role: .user, text: "q\(index)"))
            messages.append(.init(role: .assistant, text: "a\(index)"))
        }
        // A stopped question has no answer and is not replayed.
        messages.append(.init(role: .user, text: "stopped"))
        let history = LedgerAgentHistory.entries(from: messages)
        XCTAssertEqual(history.count, LedgerAgentHistory.maximumMessages)
        XCTAssertEqual(history.first, .init(role: "user", content: "q4"))
        XCTAssertEqual(history.last, .init(role: "assistant", content: "a9"))

        let long = String(repeating: "x", count: LedgerAgentHistory.maximumBytes)
        let trimmed = LedgerAgentHistory.entries(from: [
            .init(role: .user, text: "old"), .init(role: .assistant, text: long),
            .init(role: .user, text: "new"), .init(role: .assistant, text: "ok"),
        ])
        XCTAssertEqual(trimmed.map(\.content), ["new", "ok"])
    }

    func testReplySegmentsAndBeancountDraft() {
        let reply = """
        这一版还不能直接写入账本。按你的账户，这一笔应该是：
        ```beancount
        2026-10-31 * "午饭"
          Expenses:Food:Lunch     38.00 CNY
          Assets:WeChat:Balance  -38.00 CNY
        ```
        """
        let segments = LedgerAgentReplyText.segments(reply)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first, .prose("这一版还不能直接写入账本。按你的账户，这一笔应该是："))
        XCTAssertEqual(LedgerAgentReplyText.beancountDraft(in: reply)?.hasPrefix("2026-10-31 * \"午饭\""), true)
        XCTAssertNil(LedgerAgentReplyText.beancountDraft(in: "```sql\nSELECT 1\n```"))
        XCTAssertNil(LedgerAgentReplyText.beancountDraft(in: "十月餐饮一共 ¥2,486.40。"))
    }

    func testTurnRequestEncodesOnlyFieldsTheNativeDecoderAccepts() throws {
        let request = LedgerAgentTurnRequest(turnId: "t", workspaceRoot: "/w", runtimeRoot: "/r", entrypoint: "main.bean",
            modelHandle: "h", sensitiveUnlocked: true, provider: "anthropic", model: "claude-sonnet-4-5", apiKey: "k",
            history: [.init(role: "user", content: "hi")], message: "m")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "turnId", "workspaceRoot", "runtimeRoot", "entrypoint", "modelHandle",
            "sensitiveUnlocked", "provider", "model", "apiKey", "history", "message"])
        XCTAssertEqual(object["version"] as? Int, 1)
    }

    func testCustomEndpointEncodesForTheNativeDecoder() throws {
        let choice = LedgerAgentModelChoice(provider: "custom", model: "qwen3", custom: .init(api: .anthropicMessages, baseURL: "https://gw.example.com/v1"))
        XCTAssertTrue(choice.isComplete)
        let request = LedgerAgentTurnRequest(turnId: "t", workspaceRoot: "/w", runtimeRoot: "/r", entrypoint: "main.bean",
            sensitiveUnlocked: true, provider: choice.provider, model: choice.model, apiKey: "k", custom: choice.custom,
            history: [], message: "m")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let custom = try XCTUnwrap(object["custom"] as? [String: String])
        XCTAssertEqual(custom, ["api": "anthropic-messages", "baseURL": "https://gw.example.com/v1"])
    }

    func testCustomChoiceNeedsAModelAndAPlainHTTPURL() {
        func choice(_ url: String, model: String = "m") -> LedgerAgentModelChoice {
            .init(provider: "custom", model: model, custom: .init(api: .openAICompletions, baseURL: url))
        }
        XCTAssertTrue(choice("http://192.168.1.8:11434/v1").isComplete)
        XCTAssertFalse(choice("https://api.example.com/v1", model: " ").isComplete)
        XCTAssertFalse(choice("").isComplete)
        XCTAssertFalse(choice("ftp://example.com").isComplete)
        XCTAssertFalse(choice("https://user:pass@example.com/v1").isComplete)
        XCTAssertFalse(choice("https://example.com/v1?key=1").isComplete)
        XCTAssertTrue(LedgerAgentModelChoice(provider: "anthropic", model: "claude-sonnet-4-5").isComplete)
    }

    @MainActor
    func testSettingsRestoreTheCustomEndpointAfterSwitchingProviders() throws {
        let suite = "LedgerAgentTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = LedgerAgentSettings(defaults: defaults, catalog: .fallback,
            keyStore: { .init(service: "LedgerAgentTests-" + suite, account: $0) })
        settings.select(provider: "custom")
        XCTAssertTrue(settings.choice.isCustom)
        settings.setCustom(api: .openAIResponses, baseURL: " https://gw.example.com/v1 ")
        settings.select(model: "my-model")
        settings.select(provider: "anthropic")
        XCTAssertNil(settings.choice.custom)
        settings.select(provider: "custom")
        XCTAssertEqual(settings.choice, .init(provider: "custom", model: "my-model",
            custom: .init(api: .openAIResponses, baseURL: "https://gw.example.com/v1")))
    }

    func testCrashReportShowsOnce() throws {
        let runtime = try root()
        XCTAssertNil(LedgerAgentCrashReport.take(runtimeRoot: runtime))
        try Data("panic: boom\n\ngoroutine 7 [running]:\nai.parseSSE()\n\ngoroutine 18 [force gc (idle)]:\nruntime.gopark()\n".utf8)
            .write(to: runtime.appendingPathComponent(LedgerAgentCrashReport.fileName))
        XCTAssertEqual(LedgerAgentCrashReport.take(runtimeRoot: runtime), "panic: boom\n\ngoroutine 7 [running]:\nai.parseSSE()")
        XCTAssertNil(LedgerAgentCrashReport.take(runtimeRoot: runtime))
    }

    func testErrorsClassifyAuthFailures() {
        XCTAssertEqual(LedgerAgentError.classify("401 Unauthorized: invalid x-api-key"), .invalidKey("401 Unauthorized: invalid x-api-key"))
        XCTAssertEqual(LedgerAgentError.classify("context deadline exceeded"), .failed("context deadline exceeded"))
    }

    @MainActor
    func testConversationAppendsRepliesAndKeepsFailedQuestions() async throws {
        let conversation = LedgerAgentConversation()
        conversation.send("这个月花了多少") { _, history in
            XCTAssertTrue(history.isEmpty)
            return .init(ok: true, reply: "共 2,486.40 元。", toolCalls: [.init(name: "get_ledger_summary", isError: false)])
        }
        XCTAssertTrue(conversation.isRunning)
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["这个月花了多少", "共 2,486.40 元。"])
        XCTAssertEqual(conversation.messages.last?.toolCalls.count, 1)

        conversation.send("再看看上个月") { _, history in
            XCTAssertEqual(history.count, 2)
            return .init(ok: false, error: "401 invalid x-api-key")
        }
        try await waitUntilIdle(conversation)
        guard case let .failed(error, question) = conversation.phase else { return XCTFail("turn did not fail") }
        XCTAssertEqual(question, "再看看上个月")
        if case .invalidKey = error {} else { XCTFail("auth failure not classified: \(error)") }

        // Retrying the same question replaces it instead of repeating it.
        conversation.send("再看看上个月") { _, _ in .init(ok: true, reply: "上月 2,031.70 元。") }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["这个月花了多少", "共 2,486.40 元。", "再看看上个月", "上月 2,031.70 元。"])

        conversation.reset()
        XCTAssertTrue(conversation.messages.isEmpty)
    }

    @MainActor
    func testStoppedTurnDropsALateReply() async throws {
        let conversation = LedgerAgentConversation()
        conversation.send("慢问题") { _, _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .init(ok: true, reply: "迟到的回答")
        }
        conversation.stop()
        XCTAssertEqual(conversation.phase, .idle)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(conversation.messages.map(\.text), ["慢问题"])
    }

    func testRepositoryRunsTheTurnOnTheCommittedGenerationAndRetriesAStaleModel() async throws {
        let engine = HandleEngine()
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: engine, validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Agent fixture")
        let repository = catalog.repository(for: descriptor)
        let recorder = RequestRecorder()
        let runner = LedgerAgentRunner(run: { data in
            let count = await recorder.record(data)
            return Data((count == 1 ? #"{"version":1,"ok":false,"toolCalls":[],"error":"stale","modelUnavailable":true}"#
                : #"{"version":1,"ok":true,"reply":"ok","toolCalls":[{"name":"get_accounts","arguments":{"activeOnly":true},"isError":false}]}"#).utf8)
        }, cancel: { _ in })
        let response = try await repository.runAgentTurn(message: "我有哪些账户", history: [],
            choice: .init(provider: "anthropic", model: "claude-sonnet-4-5"), apiKey: "k", sensitiveUnlocked: true, runner: runner)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.toolCalls.first?.title, "账户")
        let recorded = await recorder.requests
        let requests = try recorded.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0["modelHandle"] as? String }, ["h1", "h2"])
        let workspace = try XCTUnwrap(requests.first?["workspaceRoot"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: workspace).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "generations")
        XCTAssertNotEqual(requests[0]["turnId"] as? String, requests[1]["turnId"] as? String)
        let replaced = await engine.replaced
        XCTAssertEqual(replaced, [nil, "h1"])
    }

    // MARK: Fixtures

    private actor HandleEngine: LocalLedgerEngine {
        var replaced: [String?] = []
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data { Data("{}".utf8) }
        func committedModelHandle(for request: LocalLedgerEngineRequest, replacing stale: String?) async throws -> String? {
            replaced.append(stale)
            return "h\(replaced.count)"
        }
    }

    private actor RequestRecorder {
        var requests: [Data] = []
        func record(_ data: Data) -> Int {
            requests.append(data)
            return requests.count
        }
    }

    @MainActor
    private func waitUntilIdle(_ conversation: LedgerAgentConversation) async throws {
        for _ in 0..<200 where conversation.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(conversation.isRunning)
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerAgentTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
