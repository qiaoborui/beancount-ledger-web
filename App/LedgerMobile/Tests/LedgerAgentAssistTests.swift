import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerAgentAssistTests: XCTestCase {
    func testTurnCarriesMemoryBothWays() throws {
        var request = LedgerAgentTurnRequest(turnId: "t", workspaceRoot: "/w", runtimeRoot: "/r", entrypoint: "main.bean",
            sensitiveUnlocked: true, provider: "anthropic", model: "m", apiKey: "k", history: [], message: "hi")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(object["memoryPath"])
        request.memoryPath = "/r/agent-memory.md"
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["memoryPath"] as? String, "/r/agent-memory.md")

        let response = try JSONDecoder().decode(LedgerAgentTurnResponse.self, from: Data(#"{"ok":true,"reply":"记住了","memoryUpdated":true}"#.utf8))
        XCTAssertTrue(response.memoryUpdated)
        let older = try JSONDecoder().decode(LedgerAgentTurnResponse.self, from: Data(#"{"ok":true,"reply":"好"}"#.utf8))
        XCTAssertFalse(older.memoryUpdated)
    }

    func testAssistRequestEncodesOnlyWhatItHas() throws {
        let request = LedgerAgentAssistRequest(provider: "anthropic", model: "m", apiKey: "k",
                                               history: [.init(role: "user", content: "q")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "sensitiveUnlocked", "provider", "model", "apiKey", "history"])
        XCTAssertThrowsError(try LedgerAgentAssistant.decode(Data(#"{"version":1,"ok":false,"error":"401 unauthorized"}"#.utf8)))
        XCTAssertEqual(try LedgerAgentAssistant.decode(Data(#"{"version":1,"ok":true,"suggestions":["a"]}"#.utf8)).suggestions, ["a"])
    }

    @MainActor
    func testSavedConversationKeepsTheRecapAndMemoryMarks() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let older = Data("""
        {"version":1,"id":"\(UUID().uuidString)","createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z",
         "messages":[{"role":"user","text":"q","toolCalls":[]},{"role":"assistant","text":"a","toolCalls":[]}],"unwrittenChange":false}
        """.utf8)
        let record = try decoder.decode(LedgerAgentSavedConversation.self, from: older)
        XCTAssertNil(record.recap)
        XCTAssertNil(record.messages.last?.memory)

        let conversation = LedgerAgentConversation(restoring: record)
        XCTAssertTrue(conversation.restored)
        XCTAssertFalse(conversation.wantsRecap, "one answer is not worth a recap")

        var withRecap = record
        withRecap.messages[1].memory = true
        withRecap.recap = .init(text: "- 查了 A\n- 结论 B", messageCount: 2, createdAt: Date(timeIntervalSince1970: 0))
        let round = try decoder.decode(LedgerAgentSavedConversation.self, from: encoder.encode(withRecap))
        XCTAssertEqual(round.recap?.points, ["查了 A", "结论 B"])
        let reopened = LedgerAgentConversation(restoring: round)
        XCTAssertTrue(reopened.messages[1].rememberedMemory)
        XCTAssertTrue(reopened.recapIsCurrent)
        XCTAssertEqual(reopened.saved()?.recap, round.recap)
        XCTAssertEqual(reopened.saved()?.messages[1].memory, true)
    }

    @MainActor
    func testSavedConversationUsesItsGeneratedTitleOrTheFirstQuestion() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let older = try decoder.decode(LedgerAgentSavedConversation.self, from: Data("""
        {"version":1,"id":"\(UUID().uuidString)","createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z",
         "messages":[{"role":"user","text":"这个月外卖花了多少？","toolCalls":[]},{"role":"assistant","text":"1,280 元","toolCalls":[]}],"unwrittenChange":false}
        """.utf8))
        XCTAssertEqual(older.title, "这个月外卖花了多少？", "an older save is named by its first question")

        var named = older
        named.generatedTitle = "本月外卖支出"
        let round = try decoder.decode(LedgerAgentSavedConversation.self, from: encoder.encode(named))
        XCTAssertEqual(round.generatedTitle, "本月外卖支出")
        XCTAssertEqual(round.title, "本月外卖支出")

        var blank = older
        blank.generatedTitle = "   "
        XCTAssertEqual(blank.title, "这个月外卖花了多少？", "a blank name falls back to the question")
    }

    @MainActor
    func testTheFirstAnswerNamesTheConversationOnce() async throws {
        let record = try XCTUnwrap(
            LedgerAgentConversation(restoring: try decodedConversation(messages: [("user", "这个月外卖花了多少？"),
                                                                                ("assistant", "本月餐饮支出合计 1,280.00 元。")]))
                .saved())
        let conversation = LedgerAgentConversation(restoring: record)
        let calls = TitleCalls()
        conversation.nameSession { _ in
            await calls.record()
            return "本月外卖支出"
        }
        for _ in 0..<100 where conversation.generatedTitle == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let firstCount = await calls.count
        XCTAssertEqual(conversation.generatedTitle, "本月外卖支出")
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(conversation.saved()?.generatedTitle, "本月外卖支出")

        conversation.nameSession { _ in
            await calls.record()
            return "另一个名字"
        }
        try? await Task.sleep(for: .milliseconds(80))
        let afterSecond = await calls.count
        XCTAssertEqual(afterSecond, 1, "a named conversation is not renamed")
        XCTAssertEqual(conversation.generatedTitle, "本月外卖支出")
    }

    @MainActor
    func testOnlyTheFirstAnswerNamesAConversation() async throws {
        let longer = LedgerAgentConversation(restoring: try decodedConversation(messages: [
            ("user", "这个月外卖花了多少？"), ("assistant", "1,280.00 元"),
            ("user", "那上周呢？"), ("assistant", "320.00 元"),
        ]))
        let calls = TitleCalls()
        longer.nameSession { _ in
            await calls.record()
            return "外卖"
        }
        try? await Task.sleep(for: .milliseconds(80))
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertNil(longer.generatedTitle)
    }

    private func decodedConversation(messages: [(String, String)]) throws -> LedgerAgentSavedConversation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = messages.map { #"{"role":"\#($0.0)","text":"\#($0.1)","toolCalls":[]}"# }.joined(separator: ",")
        let json = """
        {"version":1,"id":"\(UUID().uuidString)","createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z",
         "messages":[\(stored)],"unwrittenChange":false}
        """
        return try decoder.decode(LedgerAgentSavedConversation.self, from: Data(json.utf8))
    }

    func testStarterCacheIsFreshForTheDayUntilTheLedgerMoves() {
        let now = Date()
        let cache = LedgerAgentStarterCache(day: "2026-11-03", revisionID: "r1", memoryDigest: 7, suggestions: ["a"],
                                            createdAt: now.addingTimeInterval(-2 * 60 * 60))
        XCTAssertTrue(cache.isFresh(day: "2026-11-03", revisionID: "r1", memoryDigest: 7, now: now))
        XCTAssertFalse(cache.isFresh(day: "2026-11-04", revisionID: "r1", memoryDigest: 7, now: now))
        XCTAssertFalse(cache.isFresh(day: "2026-11-03", revisionID: "r2", memoryDigest: 7, now: now))
        XCTAssertFalse(cache.isFresh(day: "2026-11-03", revisionID: "r1", memoryDigest: 8, now: now))
        // A ledger that just changed does not ask again within the hour.
        XCTAssertTrue(cache.isFresh(day: "2026-11-03", revisionID: "r2", memoryDigest: 7, now: now.addingTimeInterval(-90 * 60)))
        XCTAssertEqual(LedgerAgentStarterCache.digest("记忆"), LedgerAgentStarterCache.digest("记忆"))
        XCTAssertNotEqual(LedgerAgentStarterCache.digest("记忆"), LedgerAgentStarterCache.digest("记忆 "))
    }

    @MainActor
    func testStartersShowTheCacheAndRefreshWhenStale() async throws {
        let starters = LedgerAgentStarters()
        XCTAssertEqual(starters.suggestions, LedgerAgentStarters.fallback)
        let saved = SavedStarters()
        let ledger = UUID()
        let source = LedgerAgentStarters.Source(
            load: { await saved.cache },
            save: { await saved.set($0) },
            state: { ("r1", 1) },
            fetch: { ["这个月咖啡花了多少", "最近 10 笔打车"] })
        starters.refresh(ledger: ledger, source: source)
        for _ in 0..<200 where !starters.isDynamic || starters.loading { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(starters.suggestions, ["这个月咖啡花了多少", "最近 10 笔打车"])
        let cache = await saved.cache
        XCTAssertEqual(cache?.revisionID, "r1")

        // A fresh cache is shown without asking the model again.
        let again = LedgerAgentStarters()
        let fetches = Counter()
        again.refresh(ledger: ledger, source: .init(load: { await saved.cache }, save: { _ in }, state: { ("r1", 1) },
                                                    fetch: { await fetches.bump(); return ["x"] }))
        for _ in 0..<200 where !again.isDynamic { try await Task.sleep(nanoseconds: 2_000_000) }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(again.suggestions, ["这个月咖啡花了多少", "最近 10 笔打车"])
        let count = await fetches.value
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testNextSuggestionIsDroppedOnceTheUserMovesOn() async throws {
        let conversation = LedgerAgentConversation()
        conversation.send("这个月餐饮多少") { _, _, _ in .init(ok: true, reply: "1820 元") }
        try await waitUntilIdle(conversation)
        let gate = Gate()
        conversation.predictNext { history in
            XCTAssertEqual(history.map(\.content), ["这个月餐饮多少", "1820 元"])
            await gate.wait()
            return ["按周画个图"]
        }
        conversation.send("上个月呢") { _, _, _ in .init(ok: true, reply: "1640 元") }
        try await waitUntilIdle(conversation)
        await gate.open()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(conversation.nextSuggestion, "a prediction for an older answer must not show")

        conversation.predictNext { _ in ["按周画个图"] }
        for _ in 0..<200 where conversation.nextSuggestion == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(conversation.nextSuggestion, "按周画个图")
        conversation.send("按周画个图") { _, _, _ in .init(ok: true, reply: "图") }
        XCTAssertNil(conversation.nextSuggestion)
        try await waitUntilIdle(conversation)
    }

    @MainActor
    func testRecapCoversTheConversationAndGoesStale() async throws {
        let conversation = LedgerAgentConversation()
        var settled = 0
        conversation.onSettled = { _ in settled += 1 }
        for (question, answer) in [("q1", "a1"), ("q2", "a2")] {
            conversation.send(question) { _, _, _ in .init(ok: true, reply: answer) }
            try await waitUntilIdle(conversation)
        }
        XCTAssertTrue(conversation.wantsRecap)
        let before = settled
        conversation.summarize { history in
            XCTAssertEqual(history.count, 4)
            return "- 问了 q1 和 q2"
        }
        XCTAssertTrue(conversation.recapping)
        for _ in 0..<200 where conversation.recapping { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(conversation.recap?.points, ["问了 q1 和 q2"])
        XCTAssertTrue(conversation.recapIsCurrent)
        XCTAssertFalse(conversation.wantsRecap)
        XCTAssertEqual(settled, before + 1, "a recap is saved with the conversation")

        conversation.send("q3") { _, _, _ in .init(ok: true, reply: "a3") }
        try await waitUntilIdle(conversation)
        XCTAssertFalse(conversation.recapIsCurrent)
        XCTAssertTrue(conversation.wantsRecap)

        conversation.summarize { _ in throw LedgerAgentError.failed("429 rate limit") }
        for _ in 0..<200 where conversation.recapping { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNotNil(conversation.recapError)
        XCTAssertEqual(conversation.recap?.points, ["问了 q1 和 q2"], "a failed recap keeps the previous one")

        conversation.reset()
        XCTAssertNil(conversation.recap)
    }

    @MainActor
    func testSessionsListRecentQuestionsNewestFirst() async throws {
        let sessions = LedgerAgentSessions()
        for question in ["一", "二", "一"] {
            sessions.current.send(question) { _, _, _ in .init(ok: true, reply: "ok") }
            try await waitUntilIdle(sessions.current)
        }
        XCTAssertEqual(sessions.recentQuestions(), ["一", "二"])
        XCTAssertEqual(sessions.recentQuestions(limit: 1), ["一"])
    }

    func testWorkspaceKeepsMemoryOutsideTheLedger() async throws {
        let workspace = LocalLedgerWorkspace(rootDirectory: try root())
        let empty = await workspace.agentMemory()
        XCTAssertEqual(empty, "")
        try await workspace.saveAgentMemory("## 偏好\n- 金额保留两位小数\n\n")
        let saved = await workspace.agentMemory()
        XCTAssertEqual(saved, "## 偏好\n- 金额保留两位小数\n")
        XCTAssertTrue(workspace.agentMemoryLocation.path.hasSuffix("runtime/agent-memory.md"))
        try await workspace.saveAgentMemory("  ")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.agentMemoryLocation.path))

        try await workspace.saveAgentStarters(Data("{}".utf8))
        let starters = await workspace.agentStarters()
        XCTAssertEqual(starters, Data("{}".utf8))
    }

    // MARK: Fixtures

    private actor SavedStarters {
        var cache: LedgerAgentStarterCache?
        func set(_ cache: LedgerAgentStarterCache) { self.cache = cache }
    }

    private actor Counter {
        var value = 0
        func bump() { value += 1 }
    }

    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerAgentAssistTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// Counts the naming requests a conversation makes, from any thread.
private actor TitleCalls {
    private(set) var count = 0
    func record() { count += 1 }
}
