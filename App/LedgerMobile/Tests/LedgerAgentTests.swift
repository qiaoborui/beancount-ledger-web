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

    func testReplySegmentsParseBlockMarkdown() {
        let reply = """
        ## 十月支出
        一共 **¥2,486.40**，比九月少一些。
        - 餐饮 ¥1,120.00
          含外卖
        - 交通
          1. 地铁
          2. 打车
        - [x] 已对账

        | 分类 | 金额 |
        |:---|---:|
        | 餐饮 | 1,120.00 |
        | 交通 | 86.50 | 多余 |
        ---
        > 只读了已提交的账本。
        """
        XCTAssertEqual(LedgerAgentReplyText.segments(reply), [
            .heading(level: 2, text: "十月支出"),
            .prose("一共 **¥2,486.40**，比九月少一些。"),
            .list(ordered: false, items: [
                .init(marker: "•", text: "餐饮 ¥1,120.00\n含外卖", depth: 0),
                .init(marker: "•", text: "交通", depth: 0),
                .init(marker: "1.", text: "地铁", depth: 1),
                .init(marker: "2.", text: "打车", depth: 1),
                .init(marker: "☑", text: "已对账", depth: 0),
            ]),
            .table(header: ["分类", "金额"], rows: [["餐饮", "1,120.00"], ["交通", "86.50"]]),
            .rule,
            .quote("只读了已提交的账本。"),
        ])
        XCTAssertEqual(LedgerAgentReplyText.segments("#话题 不是标题\n**加粗**开头"), [.prose("#话题 不是标题\n**加粗**开头")])
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
        conversation.send("这个月花了多少") { _, history, _ in
            XCTAssertTrue(history.isEmpty)
            return .init(ok: true, reply: "共 2,486.40 元。", toolCalls: [.init(name: "get_ledger_summary", isError: false)])
        }
        XCTAssertTrue(conversation.isRunning)
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["这个月花了多少", "共 2,486.40 元。"])
        XCTAssertEqual(conversation.messages.last?.toolCalls.count, 1)

        conversation.send("再看看上个月") { _, history, _ in
            XCTAssertEqual(history.count, 2)
            return .init(ok: false, error: "401 invalid x-api-key")
        }
        try await waitUntilIdle(conversation)
        guard case let .failed(error, question) = conversation.phase else { return XCTFail("turn did not fail") }
        XCTAssertEqual(question, "再看看上个月")
        if case .invalidKey = error {} else { XCTFail("auth failure not classified: \(error)") }

        // Retrying the same question replaces it instead of repeating it.
        conversation.send("再看看上个月") { _, _, _ in .init(ok: true, reply: "上月 2,031.70 元。") }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["这个月花了多少", "共 2,486.40 元。", "再看看上个月", "上月 2,031.70 元。"])

        conversation.reset()
        XCTAssertTrue(conversation.messages.isEmpty)
    }

    @MainActor
    func testStoppedTurnDropsALateReply() async throws {
        let conversation = LedgerAgentConversation()
        conversation.send("慢问题") { _, _, _ in
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

    func testFileDiffShowsChangedLinesWithContext() {
        let before = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let after = before.replacingOccurrences(of: "line 3\n", with: "line three\n")
            .replacingOccurrences(of: "line 18\n", with: "line 18\nline 18b\n")
        let diff = LedgerAgentFileDiff(path: "main.bean", before: Data(before.utf8), after: Data(after.utf8))
        XCTAssertEqual(diff.change, .modified)
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 1)
        XCTAssertEqual(diff.lines.map(\.kind), [.context, .context, .removed, .added, .context, .context, .gap,
                                               .context, .context, .added, .context, .context])
        XCTAssertEqual(diff.lines[2].text, "line 3")
        XCTAssertEqual(diff.lines[3].text, "line three")
        XCTAssertEqual(diff.lines[6].text, "11 行未改动")

        let created = LedgerAgentFileDiff(path: "2026/02.bean", before: nil, after: Data("a\nb\n".utf8))
        XCTAssertEqual(created.change, .added)
        XCTAssertEqual(created.lines.map(\.kind), [.added, .added])
    }

    func testDraftMirrorCopiesChangedBeanFilesAndRemovesMissingOnes() throws {
        let draft = try root(), stage = try root()
        let fm = FileManager.default
        try fm.createDirectory(at: draft.appendingPathComponent("2026"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stage.appendingPathComponent("old"), withIntermediateDirectories: true)
        try Data("same".utf8).write(to: draft.appendingPathComponent("main.bean"))
        try Data("same".utf8).write(to: stage.appendingPathComponent("main.bean"))
        try Data("new".utf8).write(to: draft.appendingPathComponent("2026/02.bean"))
        try Data("gone".utf8).write(to: stage.appendingPathComponent("old/gone.bean"))
        try Data("keep".utf8).write(to: stage.appendingPathComponent("receipt.pdf"))
        let stamp = try fm.attributesOfItem(atPath: stage.appendingPathComponent("main.bean").path)[.modificationDate] as? Date

        try LedgerAgentDraftMirror.apply(from: draft, to: stage)

        XCTAssertEqual(try LedgerAgentDraftMirror.beanFiles(in: stage), ["main.bean", "2026/02.bean"])
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("2026/02.bean")), Data("new".utf8))
        XCTAssertTrue(fm.fileExists(atPath: stage.appendingPathComponent("receipt.pdf").path))
        // An unchanged file is not rewritten, so it is not a change candidate.
        XCTAssertEqual(try fm.attributesOfItem(atPath: stage.appendingPathComponent("main.bean").path)[.modificationDate] as? Date, stamp)
    }

    @MainActor
    func testConversationReviewsAnEditedTurnAndWritesOnlyOnConfirm() async throws {
        let ledger = FakeDraftLedger()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.send("午饭改成 26") { message, _, draft in
            XCTAssertEqual(message, "午饭改成 26")
            XCTAssertEqual(draft?.lastPathComponent, "draft-1")
            return .init(ok: true, reply: "改动已准备好。", edited: true)
        }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.pending?.status, .ready)
        XCTAssertEqual(conversation.pending?.review?.files.map(\.path), ["main.bean"])
        let writesBefore = await ledger.writes
        XCTAssertEqual(writesBefore, 0)

        conversation.write()
        for _ in 0..<200 where conversation.pending != nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(conversation.pending)
        XCTAssertEqual(conversation.written?.files.count, 1)
        let writes = await ledger.writes
        XCTAssertEqual(writes, 1)

        // The next question tells the model its change was written, and reuses the draft.
        conversation.send("好了吗") { message, _, draft in
            XCTAssertTrue(message.hasSuffix("好了吗"))
            XCTAssertTrue(message.contains("已写入账本"))
            XCTAssertEqual(draft?.lastPathComponent, "draft-1")
            return .init(ok: true, reply: "好了。")
        }
        try await waitUntilIdle(conversation)
        XCTAssertNil(conversation.pending)
        let opened = await ledger.opened
        XCTAssertEqual(opened, 1)
    }

    @MainActor
    func testConversationReportsAStaleDraftAndStartsOverOnDiscard() async throws {
        let ledger = FakeDraftLedger()
        await ledger.failReview(with: .stale)
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.send("批量改分类") { _, _, _ in .init(ok: true, reply: "改好了。", edited: true) }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.pending, .init(review: nil, status: .stale))

        conversation.discard()
        XCTAssertNil(conversation.pending)
        conversation.send("重新来") { message, _, draft in
            XCTAssertTrue(message.contains("放弃"))
            XCTAssertEqual(draft?.lastPathComponent, "draft-2")
            return .init(ok: true, reply: "好。")
        }
        try await waitUntilIdle(conversation)
        conversation.reset()
        for _ in 0..<200 { if await ledger.closed == 1 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let closed = await ledger.closed
        XCTAssertEqual(closed, 1)
    }

    func testStepDecodesNativeEvents() {
        XCTAssertEqual(LedgerAgentStep.decode(#"{"version":1,"kind":"model"}"#)?.title, "正在思考")
        let read = LedgerAgentStep.decode(#"{"version":1,"kind":"tool","name":"read_file","arguments":{"path":"2026/10.bean"}}"#)
        XCTAssertEqual(read?.kind, .tool)
        XCTAssertEqual(read?.title, "读取文件 · 2026/10.bean")
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":2,"kind":"model"}"#))
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":1,"kind":"stream"}"#))
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":1,"kind":"tool"}"#))
    }

    @MainActor
    func testConversationReportsStepsAndEndingsToItsLifecycle() async throws {
        let lifecycle = RecordingLifecycle()
        let conversation = LedgerAgentConversation()
        conversation.lifecycle = lifecycle
        conversation.send("这个月餐饮", reporting: { _, _, _, report in
            report(.init(kind: .model))
            report(.init(kind: .tool, call: .init(name: "run_bql", isError: false)))
            try? await Task.sleep(nanoseconds: 30_000_000)
            return .init(ok: true, reply: "共 812 元。")
        })
        XCTAssertEqual(lifecycle.events.first, "started 这个月餐饮")
        for _ in 0..<200 where conversation.step?.kind != .tool { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(conversation.step?.title, "BQL 查询")
        try await waitUntilIdle(conversation)
        XCTAssertNil(conversation.step)
        XCTAssertEqual(lifecycle.events, ["started 这个月餐饮", "step 1 正在思考", "step 2 BQL 查询",
                                          "ended answered(\"共 812 元。\")"])

        conversation.send("慢问题") { _, _, _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return .init(ok: true, reply: "迟到")
        }
        conversation.stop()
        XCTAssertEqual(lifecycle.events.last, "ended stopped")
    }

    @MainActor
    func testInterruptedTurnReturnsTheQuestionAndReviewsTheDraftNext() async throws {
        let ledger = FakeDraftLedger()
        let lifecycle = RecordingLifecycle()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.lifecycle = lifecycle
        conversation.send("看看草稿") { _, _, _ in .init(ok: true, reply: "好。") }
        try await waitUntilIdle(conversation)
        XCTAssertNil(conversation.pending)

        conversation.send("批量改分类") { _, _, draft in
            XCTAssertEqual(draft?.lastPathComponent, "draft-1")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return .init(ok: true, reply: "迟到的回答", edited: true)
        }
        conversation.interrupt()
        XCTAssertEqual(conversation.phase, .failed(.interrupted, question: "批量改分类"))
        XCTAssertEqual(lifecycle.events.last, "ended interrupted")

        // The retry is told about the interruption and shows whatever the
        // interrupted turn left in the draft, even if it edits nothing itself.
        conversation.send("批量改分类") { message, _, draft in
            XCTAssertTrue(message.contains("中断"))
            XCTAssertEqual(draft?.lastPathComponent, "draft-1")
            return .init(ok: true, reply: "改好了。")
        }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["看看草稿", "好。", "批量改分类", "改好了。"])
        XCTAssertEqual(conversation.pending?.status, .ready)
        XCTAssertEqual(lifecycle.events.last, "ended changeReady(\"改好了。\", files: 1)")
    }

    @MainActor
    func testConversationStartsOverForAnotherLedger() async throws {
        let conversation = LedgerAgentConversation()
        let first = UUID()
        conversation.bind(ledger: first)
        conversation.send("问题") { _, _, _ in .init(ok: true, reply: "回答") }
        try await waitUntilIdle(conversation)
        conversation.bind(ledger: first)
        XCTAssertEqual(conversation.messages.count, 2)
        conversation.bind(ledger: UUID())
        XCTAssertTrue(conversation.messages.isEmpty)
    }

    func testRepositoryWritesAnAgentDraftThroughThePreparedPath() async throws {
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: HandleEngine(), validator: { root, entry in
            let text = try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8)
            if text.contains("Expenses:Nope") { throw LocalLedgerError.invalidConfiguration("unknown account Expenses:Nope") }
        })
        let descriptor = try await catalog.create(name: "Agent draft")
        let repository = catalog.repository(for: descriptor)
        let draft = try await repository.openAgentDraft()
        let main = draft.root.appendingPathComponent("main.bean")
        let original = try String(contentsOf: main, encoding: .utf8)
        let noChange = try await repository.reviewAgentDraft(draft)
        XCTAssertNil(noChange)

        // The turn sends the draft as its scratch copy.
        let recorder = RequestRecorder()
        let runner = LedgerAgentRunner(run: { data in
            _ = await recorder.record(data)
            return Data(#"{"version":1,"ok":true,"reply":"ok","edited":true}"#.utf8)
        }, cancel: { _ in })
        let response = try await repository.runAgentTurn(message: "记一笔", history: [],
            choice: .init(provider: "anthropic", model: "claude-sonnet-4-5"), apiKey: "k", sensitiveUnlocked: true,
            draft: draft.root, runner: runner)
        XCTAssertTrue(response.edited)
        let requests = await recorder.requests
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first)) as? [String: Any])
        XCTAssertEqual(sent["scratchRoot"] as? String, draft.root.path)

        try Data((original + "\n2026-10-31 open Expenses:Nope\n").utf8).write(to: main)
        do {
            _ = try await repository.reviewAgentDraft(draft)
            XCTFail("an invalid draft was prepared")
        } catch let error as LedgerAgentEditError {
            guard case .invalid = error else { return XCTFail("\(error)") }
        }
        // The template already opens Expenses:Food, so assert on the exact
        // line the draft adds rather than on the account name.
        let added = "2026-10-31 open Expenses:Food CNY"
        try Data((original + "\n" + added + "\n").utf8).write(to: main)
        try FileManager.default.createDirectory(at: draft.root.appendingPathComponent("2026"), withIntermediateDirectories: true)
        try Data("; 新文件\n".utf8).write(to: draft.root.appendingPathComponent("2026/02.bean"))
        let prepared = try await repository.reviewAgentDraft(draft)
        let review = try XCTUnwrap(prepared)
        XCTAssertEqual(review.files.map(\.path), ["2026/02.bean", "main.bean"])
        XCTAssertEqual(review.files.first?.change, .added)
        let before = try await repository.readFile(path: "main.bean").text
        XCTAssertFalse(before.contains(added))

        let rebased = try await repository.writeAgentDraft(review, draft: draft)
        XCTAssertNotEqual(rebased.baseRevisionID, draft.baseRevisionID)
        let after = try await repository.readFile(path: "main.bean").text
        XCTAssertTrue(after.contains(added))
        let created = try await repository.readFile(path: "2026/02.bean").text
        XCTAssertEqual(created, "; 新文件\n")
        let clean = try await repository.reviewAgentDraft(rebased)
        XCTAssertNil(clean)

        // A commit from elsewhere makes the rebased draft stale.
        let other = try await repository.openAgentDraft()
        try Data("; 别处\n".utf8).write(to: other.root.appendingPathComponent("other.bean"))
        let otherReview = try await repository.reviewAgentDraft(other)
        _ = try await repository.writeAgentDraft(try XCTUnwrap(otherReview), draft: other)
        try Data("; 晚了\n".utf8).write(to: draft.root.appendingPathComponent("late.bean"))
        do {
            _ = try await repository.reviewAgentDraft(rebased)
            XCTFail("a stale draft was prepared")
        } catch let error as LedgerAgentEditError {
            XCTAssertEqual(error, .stale)
        }
        let fresh = try await repository.discardAgentDraft(nil, draft: rebased)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.root.appendingPathComponent("late.bean").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.root.appendingPathComponent("other.bean").path))
        await repository.closeAgentDraft(fresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.root.path))
    }

    // MARK: Fixtures

    @MainActor
    private final class RecordingLifecycle: LedgerAgentLifecycle {
        var events: [String] = []
        func turnStarted(question: String, conversation: LedgerAgentConversation) { events.append("started " + question) }
        func turnStepped(_ step: LedgerAgentStep, count: Int) { events.append("step \(count) \(step.title)") }
        func turnEnded(_ ending: LedgerAgentTurnEnding) { events.append("ended \(ending)") }
    }

    private actor FakeDraftLedger {
        var opened = 0, writes = 0, closed = 0
        private var reviewError: LedgerAgentEditError?
        func failReview(with error: LedgerAgentEditError) { reviewError = error }

        nonisolated var editor: LedgerAgentEditor {
            LedgerAgentEditor(
                open: { await self.open() },
                review: { try await self.review($0) },
                write: { _, draft in await self.write(draft) },
                discard: { _, _ in await self.open() },
                close: { _ in await self.close() })
        }

        private func open() -> LedgerAgentDraft {
            opened += 1
            return .init(id: UUID(), root: URL(fileURLWithPath: "/tmp/draft-\(opened)"), baseRevisionID: UUID())
        }
        private func review(_ draft: LedgerAgentDraft) throws -> LedgerAgentReview? {
            if let reviewError { throw reviewError }
            return .init(id: UUID(), files: [.init(path: "main.bean", before: Data("a\n".utf8), after: Data("b\n".utf8))])
        }
        private func write(_ draft: LedgerAgentDraft) -> LedgerAgentDraft {
            writes += 1
            return .init(id: draft.id, root: draft.root, baseRevisionID: UUID())
        }
        private func close() { closed += 1 }
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
