import Foundation
import XCTest
@testable import LedgerMobile

/// The 账本助手 history list: names, pins, search, sharing, and the composer.
final class LedgerAgentConversationListTests: XCTestCase {
    func testTitlePrefersTheUserNameThenTheModelNameThenTheFirstQuestion() {
        var record = Self.record(question: "## 十月\n吃饭花了多少")
        XCTAssertEqual(record.title, "十月 吃饭花了多少")
        record.generatedTitle = "十月餐饮"
        XCTAssertEqual(record.title, "十月餐饮")
        record.customTitle = "  年终复盘  "
        XCTAssertEqual(record.title, "年终复盘")
        record.customTitle = "   "
        XCTAssertEqual(record.title, "十月餐饮")
    }

    func testSearchMatchesTheTitle() {
        var record = Self.record(question: "十月吃饭花了多少", answer: "共 812 元。")
        record.generatedTitle = "餐饮支出"
        XCTAssertTrue(record.matches("餐饮支出"))
        record.customTitle = "Year End"
        XCTAssertTrue(record.matches("year end"))
        XCTAssertTrue(record.matches("812"))
        XCTAssertFalse(record.matches("房租"))
    }

    func testRecordsSavedBeforeNamesAndPinsStillDecode() throws {
        let json = """
        {"version":1,"id":"11111111-1111-1111-1111-111111111111","createdAt":"2026-10-01T08:00:00Z",
         "updatedAt":"2026-10-01T08:01:00Z","unwrittenChange":false,
         "messages":[{"role":"user","text":"十月吃饭花了多少","toolCalls":[]},
                     {"role":"assistant","text":"共 812 元。","toolCalls":[]}]}
        """
        let record = try Self.decoder.decode(LedgerAgentSavedConversation.self, from: Data(json.utf8))
        XCTAssertEqual(record.version, 1)
        XCTAssertNil(record.customTitle)
        XCTAssertNil(record.pinnedAt)
        XCTAssertEqual(record.title, "十月吃饭花了多少")
    }

    func testPlainTextExportHasQuestionsAnswersAndFileNamesButNoReads() {
        var record = Self.record(question: "对一下这张账单", answer: "有 2 笔对不上。")
        record.messages[0].attachments = ["招行十月.csv", "截图.png"]
        record.messages[1].toolCalls = [LedgerAgentToolCall(name: "run_bql", isError: false)]
        record.generatedTitle = "十月对账"
        XCTAssertEqual(record.plainTextExport(), "十月对账\n\n问：对一下这张账单\n附件：招行十月.csv、截图.png\n\n答：有 2 笔对不上。")
    }

    func testPinnedConversationsComeFirstNewestPinOnTop() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12)))
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }
        var oldPin = Self.record(question: "旧置顶", updatedAt: day(-40))
        oldPin.pinnedAt = day(-1)
        var newPin = Self.record(question: "新置顶", updatedAt: day(-60))
        newPin.pinnedAt = day(0)
        let items = [Self.record(question: "今天", updatedAt: now), oldPin,
                     Self.record(question: "昨天", updatedAt: day(-1)),
                     Self.record(question: "三天前", updatedAt: day(-3)),
                     Self.record(question: "十天前", updatedAt: day(-10)), newPin,
                     Self.record(question: "上个月", updatedAt: day(-25))]
        let groups = LedgerAgentHistoryGroup.grouping(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.kind), [.pinned, .today, .yesterday, .week, .month, .earlier])
        XCTAssertEqual(groups.map { $0.items.map(\.title) },
                       [["新置顶", "旧置顶"], ["今天"], ["昨天"], ["三天前"], ["十天前"], ["上个月"]])
    }

    @MainActor
    func testRenameIsSavedAndReadBack() async throws {
        let store = MemoryStore()
        let sessions = LedgerAgentSessions()
        let ledger = UUID()
        sessions.bind(ledger: ledger, storage: store.storage)
        try await ask(sessions, "十月吃饭花了多少")
        let id = sessions.current.id
        sessions.rename(id, to: "  十月餐饮  ")
        XCTAssertEqual(sessions.saved.first?.title, "十月餐饮")
        XCTAssertEqual(sessions.title(of: sessions.current), "十月餐饮")

        // A later turn saves the conversation again without dropping the name.
        try await ask(sessions, "那十一月呢")
        XCTAssertEqual(sessions.saved.first?.customTitle, "十月餐饮")

        let reopened = LedgerAgentSessions()
        reopened.bind(ledger: ledger, storage: store.storage)
        try await waitFor { reopened.saved.first?.messages.count == 4 }
        XCTAssertEqual(reopened.saved.first?.title, "十月餐饮")
    }

    @MainActor
    func testClearingTheNameGivesBackTheGeneratedOne() async throws {
        let store = MemoryStore()
        let sessions = LedgerAgentSessions()
        let ledger = UUID()
        sessions.bind(ledger: ledger, storage: store.storage)
        try await ask(sessions, "十月吃饭花了多少")
        let id = sessions.current.id
        sessions.rename(id, to: "十月餐饮")
        sessions.rename(id, to: "  ")
        XCTAssertNil(sessions.saved.first?.customTitle)
        XCTAssertEqual(sessions.saved.first?.title, "十月吃饭花了多少")
        try await waitFor { await store.record(id)?.customTitle == nil }
    }

    @MainActor
    func testTheModelNameNeverReplacesTheUserName() async throws {
        let sessions = LedgerAgentSessions()
        sessions.bind(ledger: UUID(), storage: MemoryStore().storage)
        try await ask(sessions, "十月吃饭花了多少")
        try await ask(sessions, "那上周呢")
        let conversation = sessions.current
        sessions.rename(conversation.id, to: "我的名字")
        conversation.nameSession { _ in "模型起的名字" }
        try await waitFor { conversation.generatedTitle != nil }
        XCTAssertEqual(sessions.saved.first?.generatedTitle, "模型起的名字")
        XCTAssertEqual(sessions.saved.first?.customTitle, "我的名字")
        XCTAssertEqual(sessions.saved.first?.title, "我的名字")
        XCTAssertEqual(sessions.title(of: conversation), "我的名字")
    }

    @MainActor
    func testSavingTheShownAutomaticNameKeepsItAutomatic() async throws {
        let sessions = LedgerAgentSessions()
        sessions.bind(ledger: UUID(), storage: MemoryStore().storage)
        try await ask(sessions, "十月吃饭花了多少")
        try await ask(sessions, "那上周呢")
        let conversation = sessions.current
        sessions.rename(conversation.id, to: "十月吃饭花了多少 ", shown: sessions.title(of: conversation))
        XCTAssertNil(sessions.customTitle(of: conversation.id))
        conversation.nameSession { _ in "十月餐饮" }
        try await waitFor { conversation.generatedTitle != nil }
        XCTAssertEqual(sessions.title(of: conversation), "十月餐饮")

        // An edited name, or a user name saved again, is kept.
        sessions.rename(conversation.id, to: "十月餐饮复盘", shown: "十月餐饮")
        sessions.rename(conversation.id, to: "十月餐饮复盘", shown: "十月餐饮复盘")
        XCTAssertEqual(sessions.customTitle(of: conversation.id), "十月餐饮复盘")
    }

    @MainActor
    func testPinningPersistsAndPruningKeepsPinnedConversations() async throws {
        let store = MemoryStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var pinned = Self.record(question: "最早但置顶", updatedAt: base)
        pinned.pinnedAt = base
        await store.put(pinned)
        for index in 1..<LedgerAgentSessions.limit {
            await store.put(Self.record(question: "问题 \(index)", updatedAt: base.addingTimeInterval(Double(index) * 60)))
        }
        let oldest = Self.record(question: "最早没置顶", updatedAt: base.addingTimeInterval(1))
        await store.put(oldest)
        let sessions = LedgerAgentSessions()
        sessions.bind(ledger: UUID(), storage: store.storage)
        try await waitFor { sessions.saved.count == LedgerAgentSessions.limit + 1 }

        try await ask(sessions, "新问题")
        XCTAssertEqual(sessions.saved.count, LedgerAgentSessions.limit)
        XCTAssertTrue(sessions.saved.contains { $0.id == pinned.id })
        XCTAssertFalse(sessions.saved.contains { $0.id == oldest.id })
        try await waitFor { await store.count == LedgerAgentSessions.limit }

        // Unpinning is saved too, and does not move the conversation.
        sessions.setPinned(pinned.id, false)
        XCTAssertEqual(sessions.saved.first { $0.id == pinned.id }?.updatedAt, base)
        try await waitFor { await store.record(pinned.id)?.pinnedAt == nil }
        sessions.setPinned(sessions.current.id, true)
        XCTAssertNotNil(sessions.saved.first { $0.id == sessions.current.id }?.pinnedAt)
    }

    @MainActor
    func testUnsentTextStaysWithItsConversation() async throws {
        let sessions = LedgerAgentSessions()
        sessions.bind(ledger: UUID(), storage: MemoryStore().storage)
        try await ask(sessions, "十月吃饭花了多少")
        let first = sessions.current.id
        sessions.setUnsentText("那十一月", for: first)
        sessions.startNew()
        let second = sessions.current.id
        XCTAssertEqual(sessions.unsentText(for: second), "")
        sessions.setUnsentText("另一个问题", for: second)
        sessions.open(first)
        XCTAssertEqual(sessions.unsentText(for: first), "那十一月")
        XCTAssertEqual(sessions.unsentText(for: second), "另一个问题")
        sessions.setUnsentText("", for: first)
        XCTAssertEqual(sessions.unsentText(for: first), "")
        sessions.setUnsentText("草稿", for: first)
        sessions.delete(first)
        XCTAssertEqual(sessions.unsentText(for: first), "")
    }

    func testComposerSendsOnATrailingReturnOnly() {
        XCTAssertTrue(LedgerAgentComposer.submission(old: "上个月", new: "上个月\n") == ("上个月", true))
        // A newline typed in the middle stays.
        XCTAssertTrue(LedgerAgentComposer.submission(old: "上个月餐饮", new: "上个月\n餐饮") == ("上个月\n餐饮", false))
        // A pasted block of lines, even one ending in a newline, stays.
        XCTAssertTrue(LedgerAgentComposer.submission(old: "", new: "第一行\n第二行\n") == ("第一行\n第二行\n", false))
        XCTAssertTrue(LedgerAgentComposer.submission(old: "问", new: "问\n\n") == ("问\n\n", false))
        // Return in an empty field is still Return; the screen decides
        // whether there is anything to send.
        XCTAssertTrue(LedgerAgentComposer.submission(old: "", new: "\n") == ("", true))
        XCTAssertTrue(LedgerAgentComposer.submission(old: "", new: "") == ("", false))
        XCTAssertTrue(LedgerAgentComposer.submission(old: "上个月", new: "上个") == ("上个", false))
    }

    // MARK: Fixtures

    @MainActor
    private func ask(_ sessions: LedgerAgentSessions, _ question: String) async throws {
        let conversation = sessions.current
        let count = conversation.messages.count
        conversation.send(question) { _, _, _ in .init(ok: true, reply: "回答：" + question) }
        try await waitFor { !conversation.isRunning && conversation.messages.count == count + 2 }
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

    private static func record(question: String, answer: String? = nil,
                               updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> LedgerAgentSavedConversation {
        var messages = [LedgerAgentSavedConversation.Message(role: "user", text: question)]
        if let answer { messages.append(.init(role: "assistant", text: answer)) }
        return LedgerAgentSavedConversation(id: UUID(), createdAt: updatedAt, updatedAt: updatedAt, messages: messages)
    }

    fileprivate static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    fileprivate static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private actor MemoryStore {
        private var files: [UUID: Data] = [:]
        var count: Int { files.count }
        func save(_ id: UUID, _ data: Data) { files[id] = data }
        func load() -> [Data] { Array(files.values) }
        func remove(_ id: UUID) { files[id] = nil }
        func removeAll() { files = [:] }
        func put(_ record: LedgerAgentSavedConversation) {
            files[record.id] = try? LedgerAgentConversationListTests.encoder.encode(record)
        }
        func record(_ id: UUID) -> LedgerAgentSavedConversation? {
            files[id].flatMap { try? LedgerAgentConversationListTests.decoder.decode(LedgerAgentSavedConversation.self, from: $0) }
        }

        nonisolated var storage: LedgerAgentSessions.Storage {
            .init(save: { await self.save($0, $1) }, load: { await self.load() },
                  remove: { await self.remove($0) }, removeAll: { await self.removeAll() })
        }
    }
}
