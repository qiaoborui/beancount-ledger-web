import Foundation
import XCTest
@testable import LedgerMobile

/// The 账本助手's streamed turn: events, the live reducer, stop, saving and
/// the context meter.
final class LedgerAgentTimelineTests: XCTestCase {
    // MARK: Events

    func testDecodesEveryStreamedKindAndSkipsUnknownOnes() {
        XCTAssertEqual(LedgerAgentStep.decode(#"{"version":1,"kind":"text_delta","text":"共 8"}"#)?.live, .textDelta("共 8"))
        XCTAssertEqual(LedgerAgentStep.decode(#"{"version":1,"kind":"thinking_delta","text":"先查"}"#)?.live,
                       .thinkingDelta("先查"))
        XCTAssertEqual(LedgerAgentStep.decode(#"{"version":1,"kind":"thinking_end","durationMs":1200}"#)?.live,
                       .thinkingEnd(durationMs: 1200, redacted: false))
        XCTAssertEqual(LedgerAgentStep.decode(#"{"version":1,"kind":"thinking_end","redacted":true}"#)?.live,
                       .thinkingEnd(durationMs: nil, redacted: true))
        let start = LedgerAgentStep.decode(
            #"{"version":1,"kind":"tool_start","callId":"c1","name":"run_bql","arguments":{"query":"SELECT 1"}}"#)
        XCTAssertEqual(start?.kind, .live)
        XCTAssertEqual(start?.live, .toolStart(.init(name: "run_bql", arguments: .object(["query": .string("SELECT 1")]),
                                                     isError: false, callId: "c1")))
        XCTAssertEqual(LedgerAgentStep.decode(
            #"{"version":1,"kind":"tool_end","callId":"c1","name":"run_bql","isError":true,"durationMs":40,"preview":"x","errorText":"语法错误"}"#)?.live,
            .toolEnd(.init(name: "run_bql", isError: true, callId: "c1", durationMs: 40, preview: "x", errorText: "语法错误")))
        XCTAssertEqual(LedgerAgentStep.decode(
            #"{"version":1,"kind":"usage","usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":1,"contextTokens":17,"contextWindow":200000}}"#)?.live,
            .usage(.init(input: 10, output: 5, cacheRead: 2, cacheWrite: 1, contextTokens: 17, contextWindow: 200_000)))
        XCTAssertEqual(LedgerAgentStep.decode(#"{"version":1,"kind":"compaction_start"}"#)?.live, .compactionStart)
        XCTAssertEqual(LedgerAgentStep.decode(#"{"version":1,"kind":"compaction_end","summarizedTurns":3}"#)?.live,
                       .compactionEnd(summarizedTurns: 3))

        // The two step kinds stay steps, not live events.
        XCTAssertEqual(LedgerAgentStep.decode(#"{"version":1,"kind":"model"}"#)?.kind, .model)
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":1,"kind":"model"}"#)?.live)
        XCTAssertEqual(LedgerAgentStep.decode(#"{"version":1,"kind":"tool","name":"run_bql"}"#)?.kind, .tool)

        // Unknown kinds, other versions and events missing what they carry.
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":1,"kind":"heartbeat"}"#))
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":1,"kind":"live"}"#))
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":2,"kind":"text_delta","text":"x"}"#))
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":1,"kind":"text_delta"}"#))
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":1,"kind":"tool_start","callId":"c1"}"#))
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":1,"kind":"usage"}"#))
    }

    // MARK: Live turn

    func testLiveTurnJoinsDeltasAndTimesTheThinking() {
        var turn = LedgerAgentLiveTurn()
        turn.apply(.thinkingDelta("先查"))
        turn.apply(.thinkingDelta("十月\n餐饮"))
        XCTAssertTrue(turn.isThinking(0))
        turn.apply(.thinkingEnd(durationMs: 2300, redacted: false))
        XCTAssertFalse(turn.isThinking(0))
        turn.apply(.textDelta("共 "))
        turn.apply(.textDelta("812 元。"))
        XCTAssertEqual(turn.steps, [
            .init(kind: .thinking, text: "先查十月\n餐饮", durationMs: 2300),
            .init(kind: .text, text: "共 812 元。"),
        ])
        XCTAssertEqual(turn.text, "共 812 元。")

        // Redacted reasoning streams no text, only its end.
        var redacted = LedgerAgentLiveTurn()
        redacted.apply(.thinkingEnd(durationMs: 900, redacted: true))
        XCTAssertEqual(redacted.steps, [.init(kind: .thinking, durationMs: 900, redacted: true)])

        // Text after a tool is a new run; the reply is the latest one.
        var interleaved = LedgerAgentLiveTurn()
        interleaved.apply(.textDelta("我查一下。"))
        interleaved.apply(.toolStart(.init(name: "run_bql", isError: false, callId: "c1")))
        XCTAssertEqual(interleaved.text, "我查一下。")
        interleaved.apply(.toolEnd(.init(name: "run_bql", isError: false, callId: "c1", durationMs: 30)))
        interleaved.apply(.textDelta("共 812 元。"))
        XCTAssertEqual(interleaved.steps.map(\.kind), [.text, .tool, .text])
        XCTAssertEqual(interleaved.text, "共 812 元。")
    }

    func testLiveTurnUpsertsToolsByCallID() {
        var turn = LedgerAgentLiveTurn()
        let query: BQLCell = .object(["query": .string("SELECT 1")])
        turn.apply(.toolStart(.init(name: "run_bql", arguments: query, isError: false, callId: "c1")))
        turn.apply(.toolStart(.init(name: "read_file", isError: false, callId: "c2")))
        XCTAssertEqual(turn.running, [0, 1])

        // A second start of the same call is ignored.
        turn.apply(.toolStart(.init(name: "run_bql", arguments: query, isError: false, callId: "c1")))
        XCTAssertEqual(turn.steps.count, 2)

        turn.apply(.toolEnd(.init(name: "run_bql", isError: false, callId: "c1", durationMs: 40, preview: "812")))
        turn.apply(.toolEnd(.init(name: "read_file", isError: true, callId: "c2", durationMs: 5, errorText: "没有这个文件")))
        XCTAssertEqual(turn.running, [])
        XCTAssertEqual(turn.steps[0].call, .init(name: "run_bql", arguments: query, isError: false, callId: "c1",
                                                 durationMs: 40, preview: "812"))
        XCTAssertEqual(turn.steps[1].call?.isError, true)
        XCTAssertEqual(turn.steps[1].call?.errorText, "没有这个文件")

        // An end whose start never arrived is a finished row of its own.
        turn.apply(.toolEnd(.init(name: "grep_files", isError: false, callId: "c9", durationMs: 12)))
        XCTAssertEqual(turn.steps.count, 3)
        XCTAssertEqual(turn.steps[2].call?.name, "grep_files")
        XCTAssertFalse(turn.running.contains(2))

        turn.apply(.usage(.init(contextTokens: 1000, contextWindow: 4000)))
        XCTAssertEqual(turn.usage?.fraction, 0.25)
        turn.apply(.compactionStart)
        XCTAssertTrue(turn.compacting)
        turn.apply(.compactionEnd(summarizedTurns: 2))
        XCTAssertFalse(turn.compacting)
        XCTAssertTrue(turn.compacted)
    }

    func testLiveActivityFollowsTheCallOrReasoningAndHoldsBetweenSteps() {
        var turn = LedgerAgentLiveTurn()
        XCTAssertNil(turn.activity)

        // Reasoning: its last line with anything on it, as it streams.
        turn.apply(.thinkingDelta("先查十月"))
        XCTAssertEqual(turn.activity, .thinking(line: "先查十月"))
        turn.apply(.thinkingDelta("\n  再看餐饮  \n\n"))
        XCTAssertEqual(turn.activity, .thinking(line: "再看餐饮"))
        XCTAssertEqual(turn.activity?.text, String(localized: "正在思考：\("再看餐饮")"))

        // Its end, and text after it, keep the line rather than blank it.
        turn.apply(.thinkingEnd(durationMs: 1200, redacted: false))
        XCTAssertEqual(turn.activity, .thinking(line: "再看餐饮"))
        turn.apply(.textDelta("我查一下。"))
        XCTAssertEqual(turn.activity, .thinking(line: "再看餐饮"))

        // A call running.
        let bql = LedgerAgentToolCall(name: "run_bql", isError: false, callId: "c1")
        turn.apply(.toolStart(bql))
        XCTAssertEqual(turn.activity, .tool(title: bql.title, others: 0))
        XCTAssertEqual(turn.activity?.text, bql.title)

        // The gap between two steps keeps the call that just ended.
        turn.apply(.toolEnd(.init(name: "run_bql", isError: false, callId: "c1", durationMs: 40)))
        XCTAssertEqual(turn.activity, .tool(title: bql.title, others: 0))

        // Parallel calls: the latest started, and how many run.
        let file = LedgerAgentToolCall(name: "read_file", isError: false, callId: "c2")
        let search = LedgerAgentToolCall(name: "search_transactions", isError: false, callId: "c3")
        turn.apply(.toolStart(file))
        turn.apply(.toolStart(search))
        XCTAssertEqual(turn.activity, .tool(title: search.title, others: 1))
        XCTAssertEqual(turn.activity?.text, String(localized: "\(search.title) 等 \(2) 个调用"))
        turn.apply(.toolEnd(.init(name: "search_transactions", isError: false, callId: "c3", durationMs: 5)))
        XCTAssertEqual(turn.activity, .tool(title: file.title, others: 0))
        turn.apply(.toolEnd(.init(name: "read_file", isError: false, callId: "c2", durationMs: 5)))
        XCTAssertEqual(turn.activity, .tool(title: file.title, others: 0))

        // Reasoning with no line yet, and usage between steps, change nothing
        // they should not.
        turn.apply(.usage(.init(contextTokens: 10, contextWindow: 100)))
        XCTAssertEqual(turn.activity, .tool(title: file.title, others: 0))
        turn.apply(.thinkingDelta("  \n"))
        XCTAssertEqual(turn.activity, .thinking(line: nil))
        XCTAssertEqual(turn.activity?.text, String(localized: "正在思考…"))
    }

    func testLastLineSkipsBlankLinesFromTheEnd() {
        XCTAssertNil(LedgerAgentLiveTurn.lastLine(""))
        XCTAssertNil(LedgerAgentLiveTurn.lastLine(" \n\n  "))
        XCTAssertEqual(LedgerAgentLiveTurn.lastLine("一"), "一")
        XCTAssertEqual(LedgerAgentLiveTurn.lastLine("一\n 二 \n\n"), "二")
        XCTAssertEqual(LedgerAgentLiveTurn.lastLine("\n一"), "一")
        XCTAssertEqual(LedgerAgentLiveTurn.lastLine("一\r\n二"), "二")
    }

    func testTimelineGroupsAdjacentToolsAndLeavesTheAnswerLast() {
        let steps: [LedgerAgentStepRecord] = [
            .init(kind: .thinking, text: "想", durationMs: 1000),
            .init(kind: .text, text: "我查一下。"),
            .init(kind: .tool, call: .init(name: "run_bql", isError: false)),
            .init(kind: .tool, call: .init(name: "read_file", isError: false)),
            .init(kind: .thinking, text: "再想"),
            .init(kind: .text, text: "共 812 元。"),
        ]
        XCTAssertEqual(LedgerAgentTimelineItem.items(steps),
                       [.thinking(index: 0), .text(index: 1), .tools(indices: [2, 3]), .thinking(index: 4)])
        XCTAssertEqual(LedgerAgentTimelineItem.answerIndex(steps), 5)

        // While running, text the model went on from stays in its place.
        let running = Array(steps.prefix(4))
        XCTAssertEqual(LedgerAgentTimelineItem.items(running, answerTrails: true),
                       [.thinking(index: 0), .text(index: 1), .tools(indices: [2, 3])])
        XCTAssertNil(LedgerAgentTimelineItem.answerIndex(running, answerTrails: true))
        // A finished stopped reply draws its text last wherever it fell.
        XCTAssertEqual(LedgerAgentTimelineItem.items(running), [.thinking(index: 0), .tools(indices: [2, 3])])
        // The live list keeps the trailing reply in place, under the same id
        // it will have once a tool follows it.
        let streaming = Array(steps.prefix(2))
        XCTAssertEqual(LedgerAgentTimelineItem.items(streaming, includesAnswer: true), [.thinking(index: 0), .text(index: 1)])
        XCTAssertEqual(LedgerAgentTimelineItem.items(running, includesAnswer: true),
                       [.thinking(index: 0), .text(index: 1), .tools(indices: [2, 3])])
    }

    // MARK: Response

    func testResponseDecodesStepsUsageAndStopReason() throws {
        let json = """
        {"version":1,"ok":false,"cancelled":true,"reply":"共 8","transcript":"[]",
         "toolCalls":[{"name":"run_bql","isError":false,"callId":"c1","durationMs":40,"preview":"812"}],
         "steps":[{"kind":"thinking","text":"先查","durationMs":1200},
                  {"kind":"thinking","redacted":true},
                  {"kind":"tool","callId":"c1","name":"run_bql","arguments":{"query":"SELECT 1"},"durationMs":40,"preview":"812"},
                  {"kind":"tool","callId":"c2","name":"read_file","isError":true,"errorText":"没有这个文件"},
                  {"kind":"future","text":"?"},
                  {"kind":"text","text":"共 8"}],
         "usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"contextTokens":15,"contextWindow":200000},
         "stopReason":"aborted","compacted":true}
        """
        let response = try JSONDecoder().decode(LedgerAgentTurnResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.toolCalls.first?.callId, "c1")
        XCTAssertEqual(response.toolCalls.first?.durationMs, 40)
        XCTAssertEqual(response.toolCalls.first?.preview, "812")
        XCTAssertEqual(response.steps, [
            .init(kind: .thinking, text: "先查", durationMs: 1200),
            .init(kind: .thinking, redacted: true),
            .init(kind: .tool, call: .init(name: "run_bql", arguments: .object(["query": .string("SELECT 1")]),
                                           isError: false, callId: "c1", durationMs: 40, preview: "812")),
            .init(kind: .tool, call: .init(name: "read_file", isError: true, callId: "c2", errorText: "没有这个文件")),
            .init(kind: .text, text: "共 8"),
        ])
        XCTAssertEqual(response.usage, .init(input: 10, output: 5, contextTokens: 15, contextWindow: 200_000))
        XCTAssertEqual(response.stopReason, "aborted")
        XCTAssertTrue(response.compacted)

        let old = #"{"version":1,"ok":true,"reply":"好。","toolCalls":[{"name":"run_bql","isError":false}]}"#
        let decoded = try JSONDecoder().decode(LedgerAgentTurnResponse.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.reply, "好。")
        XCTAssertEqual(decoded.toolCalls, [.init(name: "run_bql", isError: false)])
        XCTAssertEqual(decoded.steps, [])
        XCTAssertNil(decoded.usage)
        XCTAssertNil(decoded.stopReason)
        XCTAssertFalse(decoded.compacted)
    }

    func testRequestAsksForStreamedEventsOnlyWhenSet() throws {
        var request = LedgerAgentTurnRequest(turnId: "t", workspaceRoot: "/w", runtimeRoot: "/r", entrypoint: "main.bean",
                                             sensitiveUnlocked: true, provider: "anthropic", model: "m", apiKey: "k",
                                             history: [], message: "q")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains("streamEvents"))
        request.streamEvents = true
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains(#""streamEvents":true"#))
    }

    func testUsageFraction() {
        XCTAssertEqual(LedgerAgentUsage(contextTokens: 50_000, contextWindow: 200_000).fraction, 0.25)
        XCTAssertEqual(LedgerAgentUsage(contextTokens: 160_000, contextWindow: 200_000).fraction, 0.8)
        XCTAssertEqual(LedgerAgentUsage(contextTokens: 250_000, contextWindow: 200_000).fraction, 1)
        XCTAssertNil(LedgerAgentUsage(contextTokens: 50_000, contextWindow: 0).fraction)
        XCTAssertNil(LedgerAgentUsage(contextTokens: 0, contextWindow: 200_000).fraction)
        XCTAssertNil(LedgerAgentUsage().fraction)
    }

    // MARK: Conversation

    @MainActor
    func testLiveEventsDrawTheTurnButAreNotCountedAsSteps() async throws {
        let lifecycle = Lifecycle()
        let conversation = LedgerAgentConversation()
        conversation.lifecycle = lifecycle
        let steps: [LedgerAgentStepRecord] = [
            .init(kind: .tool, call: .init(name: "run_bql", isError: false, callId: "c1", durationMs: 30)),
            .init(kind: .text, text: "共 812 元。"),
        ]
        let gate = Gate()
        conversation.send("这个月餐饮", reporting: { _, _, _, report in
            report(.init(kind: .model))
            report(.live(.thinkingDelta("先查")))
            report(.live(.thinkingEnd(durationMs: 1000, redacted: false)))
            report(.init(kind: .tool, call: .init(name: "run_bql", isError: false)))
            report(.live(.toolStart(.init(name: "run_bql", isError: false, callId: "c1"))))
            report(.live(.toolEnd(.init(name: "run_bql", isError: false, callId: "c1", durationMs: 30))))
            report(.live(.textDelta("共 ")))
            report(.live(.textDelta("812 元。")))
            report(.live(.usage(.init(contextTokens: 1000, contextWindow: 4000))))
            await gate.wait()
            return .init(ok: true, reply: "共 812 元。", steps: steps,
                         usage: .init(input: 900, output: 100, contextTokens: 1000, contextWindow: 4000))
        })
        for _ in 0..<200 where conversation.live?.usage == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(conversation.live?.text, "共 812 元。")
        XCTAssertEqual(conversation.live?.steps.map(\.kind), [.thinking, .tool, .text])
        XCTAssertEqual(conversation.usage?.fraction, 0.25)
        await gate.open()
        try await waitUntilIdle(conversation)

        XCTAssertNil(conversation.live)
        XCTAssertEqual(lifecycle.events, ["step 1 正在思考", "step 2 BQL 查询", "ended answered(\"共 812 元。\")"])
        XCTAssertEqual(conversation.messages.last?.steps, steps)
        XCTAssertEqual(conversation.messages.last?.usage?.contextTokens, 1000)
        XCTAssertFalse(conversation.messages.last?.stopped ?? true)
    }

    @MainActor
    func testTextDeltasArePublishedAtMostEveryInterval() async throws {
        let conversation = LedgerAgentConversation()
        let gate = Gate()
        var published = 0
        let watch = conversation.$live.sink { _ in published += 1 }
        defer { watch.cancel() }
        conversation.send("长回答", reporting: { _, _, _, report in
            for _ in 0..<40 { report(.live(.textDelta("字"))) }
            await gate.wait()
            return .init(ok: true, reply: String(repeating: "字", count: 40))
        })
        for _ in 0..<200 where conversation.live?.text.count != 40 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(conversation.live?.text, String(repeating: "字", count: 40))
        // The first delta at once, the rest folded into a few later redraws.
        XCTAssertLessThan(published, 10)
        await gate.open()
        try await waitUntilIdle(conversation)
    }

    @MainActor
    func testStopKeepsThePartialAndTheNextTurnFollowsItsTranscript() async throws {
        let lifecycle = Lifecycle()
        let conversation = LedgerAgentConversation()
        conversation.lifecycle = lifecycle
        let stoppedSteps: [LedgerAgentStepRecord] = [
            .init(kind: .thinking, text: "先查", durationMs: 800),
            .init(kind: .text, text: "十月餐饮共"),
        ]
        conversation.send("十月餐饮", reporting: { _, _, _, report in
            report(.live(.thinkingDelta("先查")))
            report(.live(.thinkingEnd(durationMs: 800, redacted: false)))
            report(.live(.textDelta("十月餐")))
            report(.live(.textDelta("饮共")))
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            // The native loop answers the stop with its own partial, which
            // may hold a little more than the screen had drawn.
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .init(ok: false, reply: "十月餐饮共", cancelled: true, transcript: "stopped-transcript",
                         steps: stoppedSteps, usage: .init(contextTokens: 300, contextWindow: 1000), stopReason: "aborted")
        })
        for _ in 0..<200 where conversation.live?.text != "十月餐饮共" { try await Task.sleep(nanoseconds: 2_000_000) }
        conversation.stop()

        // At once: the partial stays, marked stopped, and nothing runs.
        XCTAssertFalse(conversation.isRunning)
        XCTAssertNil(conversation.live)
        XCTAssertEqual(conversation.messages.map(\.text), ["十月餐饮", "十月餐饮共"])
        XCTAssertEqual(conversation.messages.last?.stopped, true)
        XCTAssertEqual(lifecycle.events.last, "ended stopped")

        // The next question, asked before the stopped turn returned, waits
        // for it and sends the transcript that ends on the partial.
        let sent = Box()
        conversation.send("那九月呢", reporting: { _, _, _, _ in
            sent.value = await conversation.transcript
            return .init(ok: true, reply: "九月 600 元。", transcript: "next-transcript")
        })
        try await waitUntilIdle(conversation)
        XCTAssertEqual(sent.value, "stopped-transcript")
        XCTAssertEqual(conversation.messages.map(\.text), ["十月餐饮", "十月餐饮共", "那九月呢", "九月 600 元。"])
        XCTAssertEqual(conversation.messages.filter(\.stopped).count, 1)
        XCTAssertEqual(conversation.messages[1].steps, stoppedSteps)
        XCTAssertEqual(conversation.messages[1].usage?.contextTokens, 300)
        XCTAssertEqual(conversation.transcript, "next-transcript")
    }

    @MainActor
    func testStopBeforeAnyTextAddsTheReturnedPartialAfterItsQuestion() async throws {
        let conversation = LedgerAgentConversation()
        conversation.send("十月餐饮", reporting: { _, _, _, report in
            report(.live(.toolStart(.init(name: "run_bql", isError: false, callId: "c1"))))
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            return .init(ok: false, reply: "我查一下。", cancelled: true, transcript: "stopped-transcript",
                         steps: [.init(kind: .text, text: "我查一下。")], stopReason: "aborted")
        })
        for _ in 0..<200 where conversation.live == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        conversation.stop()
        XCTAssertEqual(conversation.messages.map(\.text), ["十月餐饮"])
        for _ in 0..<200 where conversation.transcript == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(conversation.messages.map(\.text), ["十月餐饮", "我查一下。"])
        XCTAssertEqual(conversation.messages.last?.stopped, true)
        XCTAssertEqual(conversation.transcript, "stopped-transcript")

        // A stop that brings nothing back keeps the earlier transcript.
        conversation.send("再查", reporting: { _, _, _, report in
            report(.live(.thinkingDelta("想")))
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            return .init(ok: false, cancelled: true, stopReason: "aborted")
        })
        for _ in 0..<200 where conversation.live == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        conversation.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(conversation.messages.map(\.text), ["十月餐饮", "我查一下。", "再查"])
        XCTAssertEqual(conversation.transcript, "stopped-transcript")
    }

    @MainActor
    func testStopMarksARunningToolUnfinished() async throws {
        let conversation = LedgerAgentConversation()
        conversation.send("把这笔改成餐饮", reporting: { _, _, _, report in
            report(.live(.textDelta("我改一下。")))
            report(.live(.toolStart(.init(name: "edit_file", isError: false, callId: "c1"))))
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            return .init(ok: false, cancelled: true, stopReason: "aborted")
        })
        for _ in 0..<200 where conversation.live?.running.isEmpty != false { try await Task.sleep(nanoseconds: 2_000_000) }
        conversation.stop()
        let call = try XCTUnwrap(conversation.messages.last?.steps.last?.call)
        XCTAssertEqual(call.interrupted, true)
        XCTAssertFalse(call.editsDraft)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(conversation.messages.last?.steps.last?.call?.interrupted, true)
    }

    @MainActor
    func testAStopThatReturnsAfterTheNextAnswerKeepsTheNewerTranscript() async throws {
        let conversation = LedgerAgentConversation()
        conversation.stopSettleTimeout = 0.05
        let gate = Gate()
        conversation.send("十月餐饮", reporting: { _, _, _, report in
            report(.live(.textDelta("十月餐饮共")))
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            // A slow tool that does not notice the stop.
            await gate.wait()
            return .init(ok: false, reply: "十月餐饮共 812", cancelled: true, transcript: "stopped-transcript",
                         usage: .init(contextTokens: 300, contextWindow: 1000), stopReason: "aborted")
        })
        for _ in 0..<200 where conversation.live?.text != "十月餐饮共" { try await Task.sleep(nanoseconds: 2_000_000) }
        conversation.stop()

        // The next question gives up waiting and answers on its own.
        conversation.send("那九月呢", reporting: { _, _, _, _ in
            .init(ok: true, reply: "九月 600 元。", transcript: "next-transcript",
                  usage: .init(contextTokens: 500, contextWindow: 1000))
        })
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.transcript, "next-transcript")

        // The stopped turn returns late: its reply still lands in place,
        // but the newer transcript and meter stay.
        await gate.open()
        for _ in 0..<200 where conversation.messages[1].text != "十月餐饮共 812" { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(conversation.messages.map(\.text), ["十月餐饮", "十月餐饮共 812", "那九月呢", "九月 600 元。"])
        XCTAssertEqual(conversation.transcript, "next-transcript")
        XCTAssertEqual(conversation.usage?.contextTokens, 500)
    }

    // MARK: Saving

    @MainActor
    func testSavedMessagesKeepStepsUsageAndStopped() async throws {
        let conversation = LedgerAgentConversation()
        let steps: [LedgerAgentStepRecord] = [
            .init(kind: .thinking, text: "先查", durationMs: 1200),
            .init(kind: .thinking, redacted: true),
            .init(kind: .tool, call: .init(name: "run_bql", arguments: .object(["query": .string("SELECT 1")]),
                                           isError: false, callId: "c1", durationMs: 40, preview: "812")),
            .init(kind: .text, text: "共 812 元。"),
        ]
        let usage = LedgerAgentUsage(input: 900, output: 100, contextTokens: 1000, contextWindow: 4000)
        conversation.send("十月餐饮") { _, _, _ in
            .init(ok: true, reply: "共 812 元。", steps: steps, usage: usage, compacted: true)
        }
        try await waitUntilIdle(conversation)
        conversation.send("九月呢", reporting: { _, _, _, report in
            report(.live(.textDelta("九月")))
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            return .init(ok: false, cancelled: true)
        })
        for _ in 0..<200 where conversation.live == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        conversation.stop()
        try await Task.sleep(nanoseconds: 30_000_000)

        let saved = try XCTUnwrap(conversation.saved())
        let data = try Self.encoder.encode(saved)
        let decoded = try Self.decoder.decode(LedgerAgentSavedConversation.self, from: data)
        // Dates lose their fraction of a second in ISO 8601; the messages do not.
        XCTAssertEqual(decoded.messages, saved.messages)
        XCTAssertEqual(decoded.messages[1].text, "共 812 元。")
        XCTAssertEqual(decoded.messages[1].steps, steps)
        XCTAssertNil(decoded.messages[0].steps)
        XCTAssertNil(decoded.messages[1].stopped)
        XCTAssertEqual(decoded.messages[3].stopped, true)

        let reopened = LedgerAgentConversation(restoring: decoded)
        XCTAssertEqual(reopened.messages.map(\.text), ["十月餐饮", "共 812 元。", "九月呢", "九月"])
        XCTAssertEqual(reopened.messages[1].steps, steps)
        XCTAssertEqual(reopened.messages[1].usage, usage)
        XCTAssertTrue(reopened.messages[1].compacted)
        XCTAssertTrue(reopened.messages[3].stopped)
        XCTAssertEqual(reopened.usage, usage)
    }

    func testMessagesSavedBeforeStepsStillDecode() throws {
        let json = """
        {"version":1,"id":"11111111-1111-1111-1111-111111111111","createdAt":"2026-10-01T08:00:00Z",
         "updatedAt":"2026-10-01T08:01:00Z","unwrittenChange":false,
         "messages":[{"role":"user","text":"十月吃饭花了多少","toolCalls":[]},
                     {"role":"assistant","text":"共 812 元。","toolCalls":[{"name":"run_bql","isError":false}],"duration":3.2}]}
        """
        let record = try Self.decoder.decode(LedgerAgentSavedConversation.self, from: Data(json.utf8))
        XCTAssertNil(record.messages[1].steps)
        XCTAssertNil(record.messages[1].stopped)
        XCTAssertNil(record.messages[1].usage)
        let reopened = MainActor.assumeIsolated { LedgerAgentConversation(restoring: record) }
        let answer = MainActor.assumeIsolated { reopened.messages[1] }
        XCTAssertEqual(answer.steps, [])
        XCTAssertFalse(answer.stopped)
        XCTAssertEqual(answer.toolCalls, [.init(name: "run_bql", isError: false)])
        XCTAssertNil(MainActor.assumeIsolated { reopened.usage })
    }

    // MARK: Streaming text

    func testStreamingSegmentsReadAnUnclosedFenceAsProse() {
        let partial = "十月支出：\n```chart\n{\"type\":\"bar\",\"labels\":[\"餐饮\""
        XCTAssertEqual(LedgerAgentReplyText.segments(partial, streaming: true),
                       [.prose("十月支出："), .prose("{\"type\":\"bar\",\"labels\":[\"餐饮\"")])
        // A finished reply still shows an unclosed fence as code.
        XCTAssertEqual(LedgerAgentReplyText.segments(partial),
                       [.prose("十月支出："), .code("{\"type\":\"bar\",\"labels\":[\"餐饮\"")])
        // Once the fence closes it draws as what it is.
        let closed = partial + ",\"交通\"],\"series\":[{\"name\":\"支出\",\"values\":[812,120]}]}\n```"
        guard case .chart? = LedgerAgentReplyText.segments(closed, streaming: true).last else {
            return XCTFail("a closed chart fence should draw as a chart")
        }
        XCTAssertEqual(LedgerAgentReplyText.segments("```\nlet x = 1\n```\n后面", streaming: true),
                       [.code("let x = 1"), .prose("后面")])
    }

    // MARK: Helpers

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    @MainActor
    private final class Lifecycle: LedgerAgentLifecycle {
        var events: [String] = []
        func turnStarted(question: String, conversation: LedgerAgentConversation) {}
        func turnStepped(_ step: LedgerAgentStep, count: Int) { events.append("step \(count) \(step.title)") }
        func turnEnded(_ ending: LedgerAgentTurnEnding) { events.append("ended \(ending)") }
    }

    /// Holds a fake turn until the test lets it finish.
    private actor Gate {
        private var opened = false
        func open() { opened = true }
        func wait() async {
            while !opened { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    @MainActor
    private func waitUntilIdle(_ conversation: LedgerAgentConversation) async throws {
        for _ in 0..<400 where conversation.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(conversation.isRunning)
    }

    // MARK: Scroll fit

    func testShortConversationHasNothingToScroll() {
        XCTAssertFalse(LedgerAgentScrollFit.overflows(contentHeight: 300, topInset: 60, bottomInset: 120,
                                                      viewportHeight: 800))
        // Exactly filling the page, or within the rounding slack, still fits.
        XCTAssertFalse(LedgerAgentScrollFit.overflows(contentHeight: 620, topInset: 60, bottomInset: 120,
                                                      viewportHeight: 800))
        XCTAssertFalse(LedgerAgentScrollFit.overflows(contentHeight: 620.5, topInset: 60, bottomInset: 120,
                                                      viewportHeight: 800))
    }

    func testInsetsCountTowardOverflowing() {
        XCTAssertTrue(LedgerAgentScrollFit.overflows(contentHeight: 700, topInset: 60, bottomInset: 120,
                                                     viewportHeight: 800))
        XCTAssertFalse(LedgerAgentScrollFit.overflows(contentHeight: 700, viewportHeight: 800))
        XCTAssertTrue(LedgerAgentScrollFit.overflows(contentHeight: 900, viewportHeight: 800))
    }

    func testUnmeasuredPageNeverScrolls() {
        XCTAssertFalse(LedgerAgentScrollFit.overflows(contentHeight: 900, viewportHeight: 0))
    }

    // MARK: Process line

    private func tool(_ name: String) -> LedgerAgentStepRecord {
        LedgerAgentStepRecord(kind: .tool, call: LedgerAgentToolCall(name: name, isError: false))
    }

    func testProcessLineCountsTimeReasoningAndCalls() {
        let steps = [
            LedgerAgentStepRecord(kind: .thinking, text: "先查", durationMs: 4_200),
            tool("run_bql"), tool("search_transactions"),
            LedgerAgentStepRecord(kind: .text, text: "再看一下"),
            LedgerAgentStepRecord(kind: .thinking, text: "够了", durationMs: 7_600),
            tool("read_file"),
            LedgerAgentStepRecord(kind: .text, text: "共 1385 元"),
        ]
        XCTAssertEqual(LedgerAgentProcess.summary(steps, elapsed: 100), "已运行 1 分 40 秒 · 思考了 12 秒 · 读取了账本 3 次")
        XCTAssertEqual(LedgerAgentProcess.indices(steps), [0, 1, 2, 4, 5])
        // Saved, the last text is the answer, drawn by the reply; live, it
        // stays in the list.
        XCTAssertEqual(LedgerAgentProcess.textIndices(steps), [3])
        XCTAssertEqual(LedgerAgentProcess.textIndices(steps, includesAnswer: true), [3, 6])
        XCTAssertTrue(LedgerAgentProcess.hasSteps(steps))
    }

    func testProcessLineWithoutDurationOrFinishedReasoning() {
        // A save from before the duration was kept, with reasoning still
        // streaming (no duration yet) and a draft edit.
        let steps = [LedgerAgentStepRecord(kind: .thinking, text: "想"), tool("edit_file"), tool("run_bql")]
        XCTAssertEqual(LedgerAgentProcess.summary(steps, elapsed: nil), "调用了 2 次工具，改了草稿 1 处")
        XCTAssertEqual(LedgerAgentProcess.summary([LedgerAgentStepRecord(kind: .thinking, text: "想")], elapsed: nil),
                       "思考过程")
        XCTAssertEqual(LedgerAgentProcess.summary([], elapsed: 3), "已运行 3 秒")
        XCTAssertFalse(LedgerAgentProcess.hasSteps([LedgerAgentStepRecord(kind: .text, text: "好")]))
    }

    func testProcessDurationReadsInMinutesFromOneMinute() {
        XCTAssertEqual(LedgerAgentProcess.duration(seconds: 0), "0 秒")
        XCTAssertEqual(LedgerAgentProcess.duration(seconds: 59), "59 秒")
        XCTAssertEqual(LedgerAgentProcess.duration(seconds: 60), "1 分 0 秒")
        XCTAssertEqual(LedgerAgentProcess.duration(seconds: -4), "0 秒")
    }
}
