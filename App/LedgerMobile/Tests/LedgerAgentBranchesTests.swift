import Foundation
import XCTest
@testable import LedgerMobile

/// The 账本助手's versions: regenerated answers, edited questions, switching
/// between them, and saving them.
final class LedgerAgentBranchesTests: XCTestCase {
    // MARK: Thread

    func testForkSwitchAndActivePath() throws {
        let q1 = LedgerAgentMessage(role: .user, text: "十月餐饮")
        let a1 = LedgerAgentMessage(role: .assistant, text: "812 元")
        let q2 = LedgerAgentMessage(role: .user, text: "九月呢")
        let a2 = LedgerAgentMessage(role: .assistant, text: "600 元")
        var thread = LedgerAgentThread(path: [q1, a1, q2, a2])
        XCTAssertEqual(thread.activePath.map(\.text), ["十月餐饮", "812 元", "九月呢", "600 元"])
        XCTAssertEqual(thread.siblings(of: a2.id).count, 1)
        XCTAssertFalse(thread.hasBranches)

        // Another answer to the second question.
        let a2b = LedgerAgentMessage(role: .assistant, text: "九月 601 元")
        thread.addAlternateAnswer(to: q2.id, a2b)
        XCTAssertEqual(thread.activePath.map(\.text), ["十月餐饮", "812 元", "九月呢", "九月 601 元"])
        XCTAssertTrue(thread.siblings(of: a2b.id) == (1, 2))
        XCTAssertEqual(thread.sibling(of: a2b.id, offset: -1), a2.id)
        XCTAssertNil(thread.sibling(of: a2b.id, offset: 1))

        // Another version of the first question drops everything after it
        // from the path, but not from the thread.
        let edited = try XCTUnwrap(thread.fork(atUser: q1.id, newText: "十一月餐饮"))
        XCTAssertEqual(thread.activePath.map(\.text), ["十一月餐饮"])
        XCTAssertTrue(thread.siblings(of: edited.id) == (1, 2))
        XCTAssertEqual(thread.nodes.count, 6)
        thread.adopt(thread.activePath + [LedgerAgentMessage(role: .assistant, text: "900 元")])
        XCTAssertEqual(thread.activePath.count, 2)

        // Back to the first question: the newest answer under it shows.
        thread.switchTo(sibling: q1.id)
        XCTAssertEqual(thread.activePath.map(\.text), ["十月餐饮", "812 元", "九月呢", "九月 601 元"])
        thread.switchTo(sibling: a2.id)
        XCTAssertEqual(thread.activePath.last?.id, a2.id)
        XCTAssertEqual(thread.inactiveLeaves, [a2b.id, thread.children(of: edited.id).first!])

        // Saved branches put every version back in its place.
        let restored = LedgerAgentThread(path: thread.activePath, branches: thread.branches)
        XCTAssertEqual(restored, thread)
    }

    func testUserTurnIndexCountsQuestionsBeforeOnTheActivePath() {
        let q1 = LedgerAgentMessage(role: .user, text: "一")
        let a1 = LedgerAgentMessage(role: .assistant, text: "1")
        let q2 = LedgerAgentMessage(role: .user, text: "二")
        let a2 = LedgerAgentMessage(role: .assistant, text: "2")
        var thread = LedgerAgentThread(path: [q1, a1, q2, a2])
        XCTAssertEqual(thread.userTurnIndex(of: q1.id), 0)
        XCTAssertEqual(thread.userTurnIndex(of: a1.id), 1)
        XCTAssertEqual(thread.userTurnIndex(of: q2.id), 1)
        XCTAssertEqual(thread.userTurnIndex(of: a2.id), 2)
        thread.rewind(to: a1.id)
        XCTAssertNil(thread.userTurnIndex(of: q2.id))
        // A failed question nothing hangs under can be removed.
        thread.adopt(thread.activePath + [LedgerAgentMessage(role: .user, text: "失败")])
        let failed = thread.activeLeaf!
        thread.remove(failed)
        XCTAssertNil(thread.nodes[failed])
        XCTAssertEqual(thread.activeLeaf, a1.id)
    }

    // MARK: Saving

    @MainActor
    func testVersion1RecordsOpenAsOneBranchWithStableIDs() throws {
        let json = """
        {"version":1,"id":"6F9F1C2A-1111-4C3B-9D7E-2B8A1C0D4E5F","createdAt":"2026-11-01T08:00:00Z",
         "updatedAt":"2026-11-01T08:01:00Z","unwrittenChange":false,
         "messages":[{"role":"user","text":"十月餐饮","toolCalls":[]},{"role":"assistant","text":"812 元","toolCalls":[]},
                     {"role":"user","text":"九月呢","toolCalls":[]},{"role":"assistant","text":"600 元","toolCalls":[]}]}
        """
        let record = try Self.decoder.decode(LedgerAgentSavedConversation.self, from: Data(json.utf8))
        XCTAssertNil(record.branches)
        let first = LedgerAgentConversation(restoring: record)
        let second = LedgerAgentConversation(restoring: record)
        XCTAssertEqual(first.messages.map(\.text), ["十月餐饮", "812 元", "九月呢", "600 元"])
        XCTAssertEqual(first.messages.map(\.id), second.messages.map(\.id))
        XCTAssertEqual(Set(first.messages.map(\.id)).count, 4)
        XCTAssertFalse(first.messages.map(\.id).contains(record.id))
        XCTAssertFalse(first.thread.hasBranches)

        // Saving it again writes version 2 with the same ids.
        let saved = try XCTUnwrap(first.saved())
        XCTAssertEqual(saved.version, 2)
        XCTAssertEqual(saved.messages.map(\.id), first.messages.map(\.id))
        XCTAssertNil(saved.branches)
        XCTAssertEqual(saved.activeLeaf, first.messages.last?.id)
    }

    /// An older save that ends on a failed question: its transcript never
    /// took that question in, so a cut does not count it.
    @MainActor
    func testAnOlderSavesTrailingQuestionIsOutsideItsTranscript() throws {
        let json = """
        {"version":1,"id":"6F9F1C2A-1111-4C3B-9D7E-2B8A1C0D4E5F","createdAt":"2026-11-01T08:00:00Z",
         "updatedAt":"2026-11-01T08:01:00Z","unwrittenChange":false,
         "messages":[{"role":"user","text":"十月餐饮","toolCalls":[]},{"role":"assistant","text":"812 元","toolCalls":[]},
                     {"role":"user","text":"九月呢","toolCalls":[]}]}
        """
        let record = try Self.decoder.decode(LedgerAgentSavedConversation.self, from: Data(json.utf8))
        let restored = LedgerAgentConversation(restoring: record)
        XCTAssertEqual(restored.messages.map(\.outsideTranscript), [false, false, true])

        // A version 2 save says so itself.
        let saved = try XCTUnwrap(LedgerAgentConversation(restoring: record).saved())
        var noted = saved
        noted.messages = saved.messages.map { LedgerAgentSavedConversation.Message(id: $0.id, role: $0.role, text: $0.text) }
        XCTAssertEqual(LedgerAgentConversation(restoring: noted).messages.map(\.outsideTranscript), [false, false, false])
    }

    @MainActor
    func testVersion2RoundTripKeepsBranchesAndTheActiveLeaf() async throws {
        let conversation = LedgerAgentConversation()
        conversation.truncate = { transcript, _ in transcript + "-cut" }
        try await ask(conversation, "十月餐饮", reply: "812 元", transcript: "t1")
        try await ask(conversation, "九月呢", reply: "600 元", transcript: "t2")
        let firstAnswer = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(conversation.regenerate(firstAnswer.id, reporting: Self.reply("九月 601 元", transcript: "t3")),
                       .started)
        try await waitUntilSettled(conversation)

        let saved = try XCTUnwrap(conversation.saved())
        XCTAssertEqual(saved.version, 2)
        XCTAssertEqual(saved.branches?.map(\.message.text), ["600 元"])
        XCTAssertEqual(saved.branches?.first?.index, 0)
        XCTAssertEqual(saved.activeLeaf, conversation.messages.last?.id)
        let data = try Self.encoder.encode(saved)
        let decoded = try Self.decoder.decode(LedgerAgentSavedConversation.self, from: data)
        XCTAssertEqual(decoded.messages, saved.messages)
        XCTAssertEqual(decoded.branches, saved.branches)
        XCTAssertEqual(decoded.activeLeaf, saved.activeLeaf)

        let reopened = LedgerAgentConversation(restoring: decoded)
        XCTAssertEqual(reopened.messages.map(\.text), ["十月餐饮", "812 元", "九月呢", "九月 601 元"])
        XCTAssertEqual(reopened.thread, conversation.thread)
        let current = try XCTUnwrap(reopened.messages.last?.id)
        XCTAssertTrue(reopened.versions(of: current) == (1, 2))
    }

    // MARK: Regenerate and edit

    @MainActor
    func testRegenerateCutsTheTranscriptAndSwitchingBackFollowsTheFirstAnswer() async throws {
        let conversation = LedgerAgentConversation()
        let cuts = Recorder<String>()
        conversation.truncate = { transcript, drop in
            cuts.append("\(transcript) drop \(drop)")
            return "cut(\(transcript),\(drop))"
        }
        try await ask(conversation, "十月餐饮", reply: "812 元", transcript: "t1")
        try await ask(conversation, "九月呢", reply: "600 元", transcript: "t2")
        let firstAnswer = try XCTUnwrap(conversation.messages.last)

        let sent = Recorder<String>()
        let result = conversation.regenerate(firstAnswer.id, reporting: { message, history, _, _ in
            sent.append(message)
            sent.append(await conversation.transcript ?? "nil")
            return .init(ok: true, reply: "九月 601 元", transcript: "t3")
        })
        XCTAssertEqual(result, .started)
        try await waitUntilSettled(conversation)

        // The last question is dropped from the transcript and asked again.
        XCTAssertEqual(cuts.values, ["t2 drop 1"])
        XCTAssertEqual(sent.values, ["九月呢", "cut(t2,1)"])
        XCTAssertEqual(conversation.messages.map(\.text), ["十月餐饮", "812 元", "九月呢", "九月 601 元"])
        let second = try XCTUnwrap(conversation.messages.last)
        XCTAssertTrue(conversation.versions(of: second.id) == (1, 2))
        XCTAssertEqual(conversation.transcript, "t3")

        // Back to the first answer, with the transcript it ended on.
        XCTAssertEqual(conversation.switchBranch(second.id, direction: -1), .started)
        try await waitUntilSettled(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["十月餐饮", "812 元", "九月呢", "600 元"])
        XCTAssertTrue(conversation.versions(of: firstAnswer.id) == (0, 2))
        XCTAssertEqual(conversation.transcript, "t2")
        let next = Recorder<String>()
        conversation.send("八月呢", reporting: { _, _, _, _ in
            next.append(await conversation.transcript ?? "nil")
            return .init(ok: true, reply: "500 元", transcript: "t4")
        })
        try await waitUntilSettled(conversation)
        XCTAssertEqual(next.values, ["t2"])
        // Forward again shows the regenerated answer and its transcript.
        XCTAssertEqual(conversation.switchBranch(firstAnswer.id, direction: 1), .started)
        try await waitUntilSettled(conversation)
        XCTAssertEqual(conversation.messages.last?.text, "九月 601 元")
        XCTAssertEqual(conversation.transcript, "t3")
    }

    @MainActor
    func testEditingTheSecondOfFourQuestionsDropsTheLaterOnes() async throws {
        let conversation = LedgerAgentConversation()
        let cuts = Recorder<Int>()
        conversation.truncate = { _, drop in
            cuts.append(drop)
            return "cut-before-q2"
        }
        for number in 1...4 { try await ask(conversation, "问题\(number)", reply: "回答\(number)", transcript: "t\(number)") }
        let second = conversation.messages[2]
        XCTAssertEqual(conversation.questionNumber(second.id), 2)

        let sent = Recorder<String>()
        let result = conversation.editAndResend(second.id, newText: "问题二改", reporting: { message, history, _, _ in
            sent.append(message)
            sent.append(await conversation.transcript ?? "nil")
            return .init(ok: true, reply: "回答二改", transcript: "t5")
        })
        XCTAssertEqual(result, .started)
        try await waitUntilSettled(conversation)

        XCTAssertEqual(cuts.values, [3])
        XCTAssertEqual(sent.values, ["问题二改", "cut-before-q2"])
        XCTAssertEqual(conversation.messages.map(\.text), ["问题1", "回答1", "问题二改", "回答二改"])
        let edited = conversation.messages[2]
        XCTAssertTrue(conversation.versions(of: edited.id) == (1, 2))
        // Questions 3 and 4 stay reachable through the older version.
        XCTAssertEqual(conversation.switchBranch(edited.id, direction: -1), .started)
        try await waitUntilSettled(conversation)
        XCTAssertEqual(conversation.messages.map(\.text).filter { $0.hasPrefix("问题") }, ["问题1", "问题2", "问题3", "问题4"])
        XCTAssertEqual(conversation.transcript, "t4")
    }

    @MainActor
    func testWithoutATranscriptTheCutReplaysTheVisibleHistory() async throws {
        let conversation = LedgerAgentConversation()
        conversation.truncate = { _, _ in XCTFail("nothing to cut"); return "" }
        try await ask(conversation, "十月餐饮", reply: "812 元", transcript: nil)
        try await ask(conversation, "九月呢", reply: "600 元", transcript: nil)
        let histories = Recorder<[LedgerAgentTurnRequest.HistoryEntry]>()
        conversation.editAndResend(conversation.messages[2].id, newText: "八月呢", reporting: { _, history, _, _ in
            histories.append(history)
            let transcript = await conversation.transcript
            XCTAssertNil(transcript)
            return .init(ok: true, reply: "500 元")
        })
        try await waitUntilSettled(conversation)
        XCTAssertEqual(histories.values.first?.map(\.content), ["十月餐饮", "812 元"])
    }

    @MainActor
    func testACutThatFailsFallsBackToTheVisibleHistory() async throws {
        let conversation = LedgerAgentConversation()
        conversation.truncate = { _, _ in throw LedgerAgentError.failed("the transcript holds 1 user turns") }
        try await ask(conversation, "十月餐饮", reply: "812 元", transcript: "t1")
        try await ask(conversation, "九月呢", reply: "600 元", transcript: "t2")
        let sent = Recorder<String>()
        conversation.regenerate(conversation.messages[1].id, reporting: { _, history, _, _ in
            sent.append(await conversation.transcript ?? "nil")
            XCTAssertTrue(history.isEmpty)
            return .init(ok: true, reply: "813 元", transcript: "t3")
        })
        try await waitUntilSettled(conversation)
        XCTAssertEqual(sent.values, ["nil"])
    }

    @MainActor
    func testUnrecordedQuestionsAreNotCountedInTheCut() async throws {
        let conversation = LedgerAgentConversation()
        let cuts = Recorder<Int>()
        conversation.truncate = { transcript, drop in cuts.append(drop); return transcript }
        try await ask(conversation, "一", reply: "1", transcript: "t1")
        // A stop whose native loop never answers leaves its question out of
        // the transcript.
        conversation.send("二", reporting: { _, _, _, report in
            report(.live(.textDelta("部分")))
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            throw CancellationError()
        })
        for _ in 0..<200 where conversation.live?.text != "部分" { try await Task.sleep(nanoseconds: 2_000_000) }
        conversation.stop()
        XCTAssertEqual(conversation.messages[2].outsideTranscript, true)
        conversation.stopSettleTimeout = 0.05
        try await ask(conversation, "三", reply: "3", transcript: "t3")
        // Editing the second question cuts the third only.
        conversation.editAndResend(conversation.messages[2].id, newText: "二改",
                                   reporting: Self.reply("2", transcript: "t4"))
        try await waitUntilSettled(conversation)
        XCTAssertEqual(cuts.values, [1])
    }

    @MainActor
    func testAFailedRegenerateCanGoBackToTheAnswerItReplaced() async throws {
        let conversation = LedgerAgentConversation()
        conversation.truncate = { transcript, _ in transcript + "-cut" }
        try await ask(conversation, "十月餐饮", reply: "812 元", transcript: "t1")
        let question = conversation.messages[0]
        conversation.regenerate(conversation.messages[1].id, reporting: { _, _, _, _ in
            .init(ok: false, error: "503 overloaded")
        })
        try await waitUntilSettled(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["十月餐饮"])
        XCTAssertEqual(conversation.answersBeside(question.id), 1)

        // Retrying keeps the question in place, so the old answer stays a version.
        conversation.send("十月餐饮", reporting: Self.reply("813 元", transcript: "t2"))
        try await waitUntilSettled(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["十月餐饮", "813 元"])
        XCTAssertTrue(conversation.versions(of: conversation.messages[1].id) == (1, 2))

        conversation.regenerate(conversation.messages[1].id, reporting: { _, _, _, _ in
            .init(ok: false, error: "503 overloaded")
        })
        try await waitUntilSettled(conversation)
        XCTAssertEqual(conversation.showLatestAnswer(of: question.id), .started)
        try await waitUntilSettled(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["十月餐饮", "813 元"])
        XCTAssertEqual(conversation.phase, .idle)
    }

    /// A question is shared by every answer under it. A failed regenerate
    /// leaves it outside the cut transcript, but going back to the old
    /// answer brings back a transcript that holds it, so the next cut drops it.
    @MainActor
    func testGoingBackAfterAFailedRegenerateCutsTheQuestionAgain() async throws {
        let conversation = LedgerAgentConversation()
        let drops = Recorder<Int>()
        conversation.truncate = { transcript, drop in
            drops.append(drop)
            return transcript + "-cut"
        }
        try await ask(conversation, "十月餐饮", reply: "812 元", transcript: "t1")
        let question = conversation.messages[0]
        conversation.regenerate(conversation.messages[1].id, reporting: { _, _, _, _ in
            .init(ok: false, error: "503 overloaded")
        })
        try await waitUntilSettled(conversation)
        XCTAssertEqual(conversation.messages.last?.outsideTranscript, true)
        XCTAssertEqual(conversation.showLatestAnswer(of: question.id), .started)
        try await waitUntilSettled(conversation)
        XCTAssertEqual(conversation.transcript, "t1")
        XCTAssertEqual(conversation.messages.first?.outsideTranscript, false)

        conversation.regenerate(conversation.messages[1].id, reporting: Self.reply("813 元", transcript: "t2"))
        try await waitUntilSettled(conversation)
        XCTAssertEqual(drops.values, [1, 1])
    }

    /// Without what was noted on leaving (a transcript an earlier run saved),
    /// answered questions count as held and a trailing one does not; one a
    /// stop answered keeps its flag.
    func testMarkOutsideFallsBackToTheShapeOfThePath() {
        func message(_ role: LedgerAgentMessage.Role, outside: Bool = false, stopped: Bool = false) -> LedgerAgentMessage {
            LedgerAgentMessage(role: role, text: "", stopped: stopped, outsideTranscript: outside)
        }
        let original = [message(.user, outside: true), message(.assistant), message(.user, outside: true),
                        message(.assistant, stopped: true), message(.user)]
        var path = original
        LedgerAgentConversation.markOutside(&path, known: nil)
        XCTAssertEqual(path.map(\.outsideTranscript), [false, false, true, false, true])

        path = original
        LedgerAgentConversation.markOutside(&path, known: [original[4].id])
        XCTAssertEqual(path.map(\.outsideTranscript), [false, false, false, false, true])
    }

    /// A save during a cut (here the discarded draft's) neither pairs the cut
    /// transcript with the version being left nor loses that version's
    /// transcript, which a later save writes.
    @MainActor
    func testASaveDuringACutKeepsTheLeftVersionsTranscript() async throws {
        let ledger = FakeLedger()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.truncate = { transcript, _ in
            try await Task.sleep(nanoseconds: 20_000_000)
            return transcript + "-cut"
        }
        try await ask(conversation, "十月餐饮", reply: "812 元", transcript: "t1")
        conversation.send("把午饭都改一下", reporting: { _, _, _, report in
            report(.live(.textDelta("正在改")))
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            throw CancellationError()
        })
        for _ in 0..<200 where conversation.live?.text != "正在改" { try await Task.sleep(nanoseconds: 2_000_000) }
        conversation.stop()
        for _ in 0..<200 where conversation.saved()?.unwrittenChange != true { try await Task.sleep(nanoseconds: 2_000_000) }
        let left = try XCTUnwrap(conversation.messages.last?.id)
        let leftTranscript = conversation.transcript

        var taken: [UUID: String] = [:]
        var saves: [(texts: [String], transcript: String?)] = []
        conversation.onSettled = { settled in
            taken.merge(settled.takeUnsavedBranchTranscripts()) { $1 }
            saves.append((settled.messages.map(\.text), settled.transcript))
        }
        conversation.regenerate(conversation.messages[1].id, confirmed: true,
                                reporting: Self.reply("813 元", transcript: "t3"))
        XCTAssertTrue(conversation.takeUnsavedBranchTranscripts().isEmpty, "still on screen while the cut runs")
        try await waitUntilSettled(conversation)

        XCTAssertNotNil(leftTranscript)
        XCTAssertEqual(taken[left], leftTranscript)
        let cutSaves = saves.filter { $0.transcript?.hasSuffix("-cut") == true }
        XCTAssertFalse(cutSaves.isEmpty)
        XCTAssertTrue(cutSaves.allSatisfy { $0.texts == ["十月餐饮"] }, "\(cutSaves)")
    }

    /// Showing another version is not an answer arriving: the screen
    /// neither announces nor jumps for it.
    @MainActor
    func testAVersionChangeIsToldApartFromAnAnswer() async throws {
        let conversation = LedgerAgentConversation()
        conversation.truncate = { transcript, _ in transcript + "-cut" }
        try await ask(conversation, "十月餐饮", reply: "812 元", transcript: "t1")
        XCTAssertFalse(conversation.replacedByVersionChange)
        conversation.regenerate(conversation.messages[1].id, reporting: Self.reply("813 元", transcript: "t2"))
        try await waitUntilSettled(conversation)
        XCTAssertFalse(conversation.replacedByVersionChange)
        XCTAssertEqual(conversation.switchBranch(conversation.messages[1].id, direction: -1), .started)
        try await waitUntilSettled(conversation)
        XCTAssertEqual(conversation.messages.last?.text, "812 元")
        XCTAssertTrue(conversation.replacedByVersionChange)
        try await ask(conversation, "九月呢", reply: "600 元", transcript: "t3")
        XCTAssertFalse(conversation.replacedByVersionChange)
    }

    // MARK: Guards

    @MainActor
    func testActionsAreRefusedWhileAChangeIsPending() async throws {
        let ledger = FakeLedger()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.truncate = { transcript, _ in transcript }
        try await ask(conversation, "十月餐饮", reply: "812 元", transcript: "t1")
        conversation.send("午饭改成 26") { _, _, _ in .init(ok: true, reply: "改好了。", edited: true, transcript: "t2") }
        try await waitUntilSettled(conversation)
        XCTAssertEqual(conversation.pending?.status, .ready)
        XCTAssertFalse(conversation.canBranch)

        let answer = conversation.messages[1].id, question = conversation.messages[2].id
        XCTAssertEqual(conversation.regenerate(answer, reporting: Self.reply("x", transcript: nil)), .refused)
        XCTAssertEqual(conversation.editAndResend(question, newText: "改成 27", reporting: Self.reply("x", transcript: nil)),
                       .refused)
        XCTAssertEqual(conversation.messages.count, 4)
        XCTAssertFalse(conversation.isRunning)
    }

    @MainActor
    func testAWrittenAnswerAsksBeforeItIsReplaced() async throws {
        let ledger = FakeLedger()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.truncate = { transcript, _ in transcript }
        conversation.send("午饭改成 26") { _, _, _ in .init(ok: true, reply: "改好了。", edited: true, transcript: "t1") }
        try await waitUntilSettled(conversation)
        conversation.write()
        for _ in 0..<200 where conversation.pending != nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(conversation.messages[1].write)
        XCTAssertTrue(conversation.canBranch)

        let answer = conversation.messages[1].id
        let messages = Recorder<String>()
        let send: LedgerAgentConversation.SendReporting = { message, _, _, _ in
            messages.append(message)
            return .init(ok: true, reply: "改好了，26 元。", transcript: "t2")
        }
        XCTAssertEqual(conversation.regenerate(answer, reporting: send), .needsConfirmation(.written))
        XCTAssertFalse(conversation.isRunning)
        XCTAssertEqual(conversation.regenerate(answer, confirmed: true, reporting: send), .started)
        try await waitUntilSettled(conversation)
        // The model hears that the write stays; nothing is written again.
        XCTAssertTrue(messages.values.first?.contains("没有撤销") == true)
        XCTAssertTrue(messages.values.first?.hasSuffix("午饭改成 26") == true)
        let writes = await ledger.writes
        XCTAssertEqual(writes, 1)
        XCTAssertNil(conversation.pending)
    }

    @MainActor
    func testAStoppedTurnsDraftIsDiscardedOnlyAfterConfirmation() async throws {
        let ledger = FakeLedger()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.truncate = { transcript, _ in transcript }
        try await ask(conversation, "十月餐饮", reply: "812 元", transcript: "t1")
        conversation.send("把午饭都改一下", reporting: { _, _, _, report in
            report(.live(.textDelta("正在改")))
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            throw CancellationError()
        })
        for _ in 0..<200 where conversation.live?.text != "正在改" { try await Task.sleep(nanoseconds: 2_000_000) }
        conversation.stop()
        for _ in 0..<200 where conversation.saved()?.unwrittenChange != true { try await Task.sleep(nanoseconds: 2_000_000) }

        let stopped = conversation.messages[3].id
        XCTAssertEqual(conversation.regenerate(stopped, reporting: Self.reply("x", transcript: nil)),
                       .needsConfirmation(.unreviewedDraft))
        let messages = Recorder<String>()
        conversation.regenerate(stopped, confirmed: true, reporting: { message, _, _, _ in
            messages.append(message)
            return .init(ok: true, reply: "先不改了。", transcript: "t3")
        })
        try await waitUntilSettled(conversation)
        XCTAssertTrue(messages.values.first?.contains("用户放弃了上一轮的草稿改动") == true)
        XCTAssertNil(conversation.pending)
        XCTAssertEqual(conversation.saved()?.unwrittenChange, false)
        let opened = await ledger.opened
        XCTAssertEqual(opened, 2)
    }

    // MARK: Stored versions

    @MainActor
    func testSwitchingAfterReopeningLoadsTheStoredTranscript() async throws {
        let store = MemoryStore()
        let ledger = UUID()
        let sessions = LedgerAgentSessions()
        sessions.bind(ledger: ledger, storage: store.storage)
        let conversation = sessions.current
        conversation.truncate = { transcript, _ in transcript + "-cut" }
        try await ask(conversation, "十月餐饮", reply: "812 元", transcript: "t1")
        try await ask(conversation, "九月呢", reply: "600 元", transcript: "t2")
        let first = try XCTUnwrap(conversation.messages.last)
        conversation.regenerate(first.id, reporting: Self.reply("九月 601 元", transcript: "t3"))
        try await waitUntilSettled(conversation)
        let id = conversation.id
        try await waitFor { await store.branchTranscript(id, first.id) == "t2" }
        try await waitFor { await store.transcript(id) == "t3" }

        let reopened = LedgerAgentSessions()
        reopened.bind(ledger: ledger, storage: store.storage)
        try await waitFor { reopened.saved.first?.id == id }
        reopened.open(id)
        let restored = reopened.current
        try await waitFor { restored.transcript == "t3" }
        let shown = try XCTUnwrap(restored.messages.last?.id)
        XCTAssertEqual(restored.switchBranch(shown, direction: -1), .started)
        try await waitUntilSettled(restored)
        XCTAssertEqual(restored.messages.last?.text, "600 元")
        XCTAssertEqual(restored.transcript, "t2")

        // Deleting the conversation drops its version transcripts too.
        reopened.delete(id)
        try await waitFor { await store.branchCount(id) == 0 }
    }

    // MARK: Copy

    func testPlainTextDropsTheMarkdown() {
        let reply = """
        ## 十月餐饮

        共 **812 元**，见 [明细](ledger://search?q=餐饮)。

        - 午饭 `300` 元
        - 晚饭 512 元

        | 类别 | 金额 |
        | --- | --- |
        | 午饭 | 300 |

        ```
        2026-10-01 * "午饭"
        ```
        """
        XCTAssertEqual(LedgerAgentReplyText.plainText(reply), """
        十月餐饮

        共 812 元，见 明细。

        • 午饭 300 元
        • 晚饭 512 元

        类别\t金额
        午饭\t300

        2026-10-01 * "午饭"
        """)
    }

    // MARK: Fixtures

    @MainActor
    private func ask(_ conversation: LedgerAgentConversation, _ question: String, reply: String,
                     transcript: String?) async throws {
        let count = conversation.messages.count
        XCTAssertTrue(conversation.send(question, reporting: Self.reply(reply, transcript: transcript)))
        try await waitFor { !conversation.isRunning && conversation.messages.count == count + 2 }
    }

    private static func reply(_ text: String, transcript: String?) -> LedgerAgentConversation.SendReporting {
        { _, _, _, _ in .init(ok: true, reply: text, transcript: transcript) }
    }

    @MainActor
    private func waitUntilSettled(_ conversation: LedgerAgentConversation,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitFor({ !conversation.isRunning && !conversation.switching }, file: file, line: line)
    }

    @MainActor
    private func waitFor(_ condition: @escaping @MainActor () async -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never held", file: file, line: line)
    }

    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Value] = []
        var values: [Value] { lock.withLock { stored } }
        func append(_ value: Value) { lock.withLock { stored.append(value) } }
    }

    private actor FakeLedger {
        var opened = 0, writes = 0

        nonisolated var editor: LedgerAgentEditor {
            LedgerAgentEditor(
                open: { await self.open() },
                review: { _ in .init(id: UUID(), files: [.init(path: "main.bean", before: Data("a\n".utf8), after: Data("b\n".utf8))]) },
                write: { _, draft in await self.write(draft) },
                discard: { _, _ in await self.open() },
                close: { _ in },
                written: { _ in (UUID(), UUID()) })
        }

        private func open() -> LedgerAgentDraft {
            opened += 1
            return .init(id: UUID(), root: URL(fileURLWithPath: "/tmp/branch-draft-\(opened)"), baseRevisionID: UUID())
        }

        private func write(_ draft: LedgerAgentDraft) -> LedgerAgentDraft {
            writes += 1
            return .init(id: draft.id, root: draft.root, baseRevisionID: UUID())
        }
    }

    private actor MemoryStore {
        private var files: [UUID: Data] = [:]
        private var transcripts: [UUID: Data] = [:]
        private var branches: [UUID: [UUID: Data]] = [:]
        func save(_ id: UUID, _ data: Data) { files[id] = data }
        func load() -> [Data] { Array(files.values) }
        func remove(_ id: UUID) { files[id] = nil; transcripts[id] = nil; branches[id] = nil }
        func removeAll() { files = [:]; transcripts = [:]; branches = [:] }
        func saveTranscript(_ id: UUID, _ data: Data) { transcripts[id] = data }
        func transcript(_ id: UUID) -> String? { transcripts[id].map { String(decoding: $0, as: UTF8.self) } }
        func saveBranch(_ id: UUID, _ leaf: UUID, _ data: Data) { branches[id, default: [:]][leaf] = data }
        func branch(_ id: UUID, _ leaf: UUID) -> Data? { branches[id]?[leaf] }
        func branchTranscript(_ id: UUID, _ leaf: UUID) -> String? { branch(id, leaf).map { String(decoding: $0, as: UTF8.self) } }
        func branchCount(_ id: UUID) -> Int { branches[id]?.count ?? 0 }
        func prune(_ id: UUID, _ keep: Set<UUID>) { branches[id] = branches[id]?.filter { keep.contains($0.key) } }

        nonisolated var storage: LedgerAgentSessions.Storage {
            .init(save: { await self.save($0, $1) }, load: { await self.load() },
                  remove: { await self.remove($0) }, removeAll: { await self.removeAll() },
                  saveTranscript: { await self.saveTranscript($0, $1) },
                  loadTranscript: { await self.transcripts[$0] },
                  saveBranchTranscript: { await self.saveBranch($0, $1, $2) },
                  loadBranchTranscript: { await self.branch($0, $1) },
                  pruneBranchTranscripts: { await self.prune($0, $1) })
        }
    }

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
}
