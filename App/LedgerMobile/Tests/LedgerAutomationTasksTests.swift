import XCTest
@testable import LedgerMobile

final class LedgerAutomationTasksTests: XCTestCase {
    /// What the phone writes; server/internal/automation/task_test.go parses
    /// the same text, so both sides agree on the format.
    static let written = """
    ---
    name: "周报: 本周 #消费"
    schedule: weekly mon,thu 09:30
    timezone: Asia/Singapore
    enabled: false
    model: "auto/deepseek-flash"
    thinking: low
    audit: false
    ---

    总结本周。

    不要改账本。

    """

    func testWritesTheFormatTheHostReads() {
        let task = LedgerAutomationTask(id: "weekly", name: "周报: 本周 #消费",
                                        schedule: .init(kind: .weekly, hour: 9, minute: 30, weekdays: [2, 5]),
                                        timezone: "Asia/Singapore", enabled: false, model: "auto/deepseek-flash",
                                        thinking: "low", audit: false, prompt: "总结本周。\n\n不要改账本。\n")
        XCTAssertEqual(task.fileText, Self.written)
        XCTAssertEqual(try LedgerAutomationTask.parse(id: "weekly", text: task.fileText), task.trimmed)
    }

    func testReadsTheDocsExample() throws {
        let text = """
        ---
        name: 每日巡检
        schedule: daily 21:00
        timezone: Asia/Singapore
        enabled: true
        # model: 可选，覆盖默认模型
        thinking: low # 低
        audit: true
        ---

        看一下今天的巡检结果。
        """
        let task = try LedgerAutomationTask.parse(id: "daily-audit", text: text)
        XCTAssertEqual(task.name, "每日巡检")
        XCTAssertEqual(task.schedule, .init(kind: .daily, hour: 21, minute: 0))
        XCTAssertEqual(task.thinking, "low")
        XCTAssertTrue(task.enabled && task.audit)
        XCTAssertEqual(task.prompt, "看一下今天的巡检结果。")
    }

    func testRefusesWhatTheHostWouldSkip() {
        XCTAssertThrowsError(try LedgerAutomationTask.parse(id: "Bad", text: "---\nschedule: daily 21:00\n---\nx"))
        XCTAssertThrowsError(try LedgerAutomationTask.parse(id: "a", text: "schedule: daily 21:00\nx"))
        XCTAssertThrowsError(try LedgerAutomationTask.parse(id: "a", text: "---\nschedule: daily 25:00\n---\nx"))
        XCTAssertThrowsError(try LedgerAutomationTask.parse(id: "a", text: "---\nschedule: daily 21:00\ncron: x\n---\nx"))
        XCTAssertThrowsError(try LedgerAutomationTask.parse(id: "a", text: "---\nschedule: daily 21:00\n---\n  \n"))
    }

    func testScheduleTextRoundTrips() {
        for text in ["hourly", "hourly :15", "daily 07:05", "weekly mon,sun 21:00", "monthly 31 09:00"] {
            XCTAssertEqual(LedgerAutomationSchedule(text: text)?.text, text)
        }
        XCTAssertNil(LedgerAutomationSchedule(text: "weekly xyz 09:00"))
        XCTAssertNil(LedgerAutomationSchedule(text: "monthly 0 09:00"))
        XCTAssertEqual(LedgerAutomationSchedule(text: "weekly Monday,Thursday 09:00")?.weekdays, [2, 5])
    }

    func testNextSlot() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let formatter = ISO8601DateFormatter()
        // Tuesday 2026-11-17 13:44 in Singapore.
        let now = try XCTUnwrap(formatter.date(from: "2026-11-17T05:44:00Z"))
        func next(_ text: String) -> String? {
            LedgerAutomationSchedule(text: text)?.nextSlot(after: now, in: zone).map { formatter.string(from: $0) }
        }
        XCTAssertEqual(next("daily 21:00"), "2026-11-17T13:00:00Z")
        XCTAssertEqual(next("daily 09:00"), "2026-11-18T01:00:00Z")
        XCTAssertEqual(next("hourly :30"), "2026-11-17T06:30:00Z")
        XCTAssertEqual(next("weekly mon 09:00"), "2026-11-23T01:00:00Z")
        XCTAssertEqual(next("monthly 31 09:00"), "2026-11-30T01:00:00Z")
        XCTAssertEqual(next("monthly 1 09:00"), "2026-12-01T01:00:00Z")
    }

    func testNewIDsAvoidTakenFiles() {
        XCTAssertEqual(LedgerAutomationTask.newID(for: "daily-audit", taken: ["daily-audit"]), "daily-audit-2")
        XCTAssertEqual(LedgerAutomationTask.newID(for: "每日巡检", taken: []), "task")
        XCTAssertEqual(LedgerAutomationTask.newID(for: "Weekly Review!", taken: []), "weekly-review")
    }

    func testReadsTheFolderAndReportsBrokenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("automations")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.written.utf8).write(to: folder.appendingPathComponent("weekly.md"))
        try Data("oops".utf8).write(to: folder.appendingPathComponent("broken.md"))
        try Data("# notes".utf8).write(to: folder.appendingPathComponent("README.md"))
        let list = LedgerAutomationTaskList.read(workspace: root)
        XCTAssertEqual(list.tasks.map(\.id), ["weekly"])
        XCTAssertEqual(Array(list.problems.keys), ["broken"])
    }
}

private extension LedgerAutomationTask {
    /// As it reads back: the prompt without its trailing newline.
    var trimmed: LedgerAutomationTask {
        var copy = self
        copy.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}
