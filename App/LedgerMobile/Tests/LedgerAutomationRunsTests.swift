import XCTest
@testable import LedgerMobile

final class LedgerAutomationRunsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("automation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to path: String, in base: URL? = nil) throws {
        let url = (base ?? root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// run.json as ledger-automation writes it: Go times with nanoseconds
    /// and an offset.
    private func runJSON(id: String, slot: String, status: String = "ok", hasDraft: Bool = true) -> String {
        """
        {"version":1,"id":"\(id)","task":"daily-audit","taskName":"每日巡检","slot":"\(slot)",
         "startedAt":"2026-11-17T21:03:00.123456789+08:00","finishedAt":"2026-11-17T21:04:10.5Z",
         "commit":"abc","status":"\(status)","attempts":1,"conversationId":"0A1B2C3D-0000-4000-8000-000000000001",
         "summary":"有一笔重复的美团","findings":2,"newFindings":1,"hasDraft":\(hasDraft),
         "draftFiles":["2026/11.bean"],"model":"m","auditMs":12}
        """
    }

    func testReadsRunsNewestFirstAndSkipsStrangeDirectories() throws {
        try write(runJSON(id: "20261116T1300Z-daily-audit", slot: "2026-11-16T21:00:00+08:00"),
                  to: "runs/20261116T1300Z-daily-audit/run.json")
        try write(runJSON(id: "20261117T1300Z-daily-audit", slot: "2026-11-17T21:00:00+08:00", status: "degraded"),
                  to: "runs/20261117T1300Z-daily-audit/run.json")
        // A directory whose run.json names another run is not trusted.
        try write(runJSON(id: "other", slot: "2026-11-18T21:00:00+08:00"), to: "runs/mismatch/run.json")
        try write("not json", to: "runs/broken/run.json")

        let runs = LedgerAutomationRecords.runs(in: root)
        XCTAssertEqual(runs.map(\.id), ["20261117T1300Z-daily-audit", "20261116T1300Z-daily-audit"])
        XCTAssertEqual(runs[0].status, .degraded)
        XCTAssertEqual(runs[1].conversationID?.uuidString, "0A1B2C3D-0000-4000-8000-000000000001")
        XCTAssertEqual(runs[1].draftFiles, ["2026/11.bean"])
        XCTAssertEqual(runs[1].startedAt.timeIntervalSince1970, 1_794_920_580, accuracy: 1)
    }

    func testRunConversationOpensAsASavedConversation() throws {
        let id = "20261117T1300Z-daily-audit"
        try write("""
        {"version":1,"id":"0A1B2C3D-0000-4000-8000-000000000001","createdAt":"2026-11-17T13:03:00Z",
         "updatedAt":"2026-11-17T13:04:10Z","messages":[
           {"role":"user","text":"检查账本","toolCalls":[]},
           {"role":"assistant","text":"结论","toolCalls":[],"duration":70.5}],
         "unwrittenChange":false,"generatedTitle":"每日巡检 · 11-17 21:00","automationRun":"\(id)"}
        """, to: "runs/\(id)/conversation.json")
        try write("transcript", to: "runs/\(id)/transcript")

        let (record, transcript) = try XCTUnwrap(LedgerAutomationRecords.conversation(of: id, in: root))
        XCTAssertEqual(record.title, "每日巡检 · 11-17 21:00")
        XCTAssertEqual(record.automationRun, id)
        XCTAssertEqual(record.messages.map(\.text), ["检查账本", "结论"])
        XCTAssertEqual(transcript, Data("transcript".utf8))
        XCTAssertNil(LedgerAutomationRecords.conversation(of: "../\(id)", in: root))
    }

    func testDraftIsFoundOnlyForARunThatLeftOne() throws {
        let id = "20261117T1300Z-daily-audit"
        try write(runJSON(id: id, slot: "2026-11-17T21:00:00+08:00"), to: "runs/\(id)/run.json")
        let run = try XCTUnwrap(LedgerAutomationRecords.runs(in: root).first)
        XCTAssertNil(LedgerAutomationRecords.draft(of: run, in: root))
        try write("x", to: "runs/\(id)/draft/after/2026/11.bean")
        let draft = try XCTUnwrap(LedgerAutomationRecords.draft(of: run, in: root))
        XCTAssertEqual(draft.after.lastPathComponent, "after")
        XCTAssertTrue(draft.source.contains("每日巡检"))
    }

    func testNotificationLinkOpensTheRun() throws {
        let parse = { LedgerExternalRoute.parse(URL(string: $0)!) }
        XCTAssertEqual(parse("ledger://automation/run?id=20261117T1300Z-daily-audit"),
                       .automationRun("20261117T1300Z-daily-audit"))
        XCTAssertTrue(LedgerExternalRoute.automationRun("x").opensAgent)
        XCTAssertNil(parse("ledger://automation/run?id=../etc"))
        XCTAssertNil(parse("ledger://automation/run"))
        XCTAssertNil(parse("ledger://automation/other?id=a"))
        XCTAssertNil(parse("ledger://agent/run?q=a"))
    }

    // MARK: Carrying the draft over

    private actor DraftLedger {
        let root: URL
        var reviews = 0
        init(root: URL) { self.root = root }

        nonisolated var editor: LedgerAgentEditor {
            LedgerAgentEditor(
                open: { LedgerAgentDraft(id: UUID(), root: self.root, baseRevisionID: UUID()) },
                review: { try await self.review($0) },
                write: { _, draft in draft },
                discard: { _, draft in draft },
                close: { _ in })
        }

        private func review(_ draft: LedgerAgentDraft) throws -> LedgerAgentReview? {
            reviews += 1
            let after = try Data(contentsOf: draft.root.appendingPathComponent("main.bean"))
            return .init(id: UUID(), files: [.init(path: "main.bean", before: Data("a\nb\n".utf8), after: after)])
        }
    }

    @MainActor
    private func settle(_ conversation: LedgerAgentConversation) async {
        for _ in 0..<200 where conversation.switching { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @MainActor
    func testCloudDraftMergesOverTheLedgerAndWaitsForTheCard() async throws {
        let ledger = root.appendingPathComponent("draft")
        // The ledger gained a line at the end since the run read it, away
        // from the line the run changed.
        try write("a\nb\nc\nd\nz\n", to: "main.bean", in: ledger)
        let cloud = root.appendingPathComponent("cloud")
        try write("a\nb\nc\nd\n", to: "base/main.bean", in: cloud)
        try write("a\nB\nc\nd\n", to: "after/main.bean", in: cloud)
        try write("new\n", to: "after/added.bean", in: cloud)

        let fake = DraftLedger(root: ledger)
        let conversation = LedgerAgentConversation()
        XCTAssertTrue(conversation.adoptCloudDraft(.init(base: cloud.appendingPathComponent("base"),
                                                          after: cloud.appendingPathComponent("after"),
                                                          source: "定时任务「每日巡检」"),
                                                   editor: fake.editor))
        await settle(conversation)

        XCTAssertEqual(try String(contentsOf: ledger.appendingPathComponent("main.bean"), encoding: .utf8), "a\nB\nc\nd\nz\n")
        XCTAssertEqual(try String(contentsOf: ledger.appendingPathComponent("added.bean"), encoding: .utf8), "new\n")
        let pending = try XCTUnwrap(conversation.pending)
        XCTAssertEqual(pending.status, .ready)
        XCTAssertTrue(pending.holdReason?.contains("每日巡检") == true)
        XCTAssertFalse(pending.holdReason?.contains("main.bean") == true)
        let reviews = await fake.reviews
        XCTAssertEqual(reviews, 1)
    }

    @MainActor
    func testCloudDraftThatClashesWithTheLedgerIsAConflict() async throws {
        let ledger = root.appendingPathComponent("draft")
        try write("a\nX\n", to: "main.bean", in: ledger)
        let cloud = root.appendingPathComponent("cloud")
        try write("a\nb\n", to: "base/main.bean", in: cloud)
        try write("a\nB\n", to: "after/main.bean", in: cloud)

        let conversation = LedgerAgentConversation()
        conversation.adoptCloudDraft(.init(base: cloud.appendingPathComponent("base"),
                                           after: cloud.appendingPathComponent("after"), source: "定时任务"),
                                     editor: DraftLedger(root: ledger).editor)
        await settle(conversation)

        XCTAssertEqual(conversation.pending?.status, .conflict(["main.bean"]))
        XCTAssertEqual(try String(contentsOf: ledger.appendingPathComponent("main.bean"), encoding: .utf8), "a\nX\n")
    }
}
