import Foundation
import XCTest
@testable import LedgerMobile

/// The App settings the assistant may read and change: the snapshot it sends,
/// the sections it applies and the way back.
@MainActor
final class LedgerAgentAppSettingsTests: XCTestCase {
    /// The snapshot exactly as the native side takes it. The Go test
    /// (`server/mobileagent/app_settings_test.go`) holds the same JSON, so a
    /// field renamed on one side fails a test on the other.
    private static let wireJSON = """
    {
      "overview": {"sections": ["retention", "periodStats", "spendingTrend", "spendingCategories",
        "creditCards", "topPayees", "incomeBreakdown", "balanceSheet", "currencyExposure"]},
      "tabs": {"tabs": ["overview", "transactions", "accounts"]},
      "valuation": {"currency": "CNY"},
      "reminders": {
        "bookkeeping": {"enabled": true, "time": "21:30", "repeat": "daily", "days": [1, 2, 3, 4, 5, 6, 7],
          "skipsRecordedDays": true},
        "imports": {"enabled": false, "cadence": "weekly", "weekday": 1, "day": 1, "time": "20:00"}
      },
      "reports": {
        "weekly": {"enabled": false, "weekday": 2, "time": "09:00"},
        "monthly": {"enabled": false, "day": 1, "time": "09:00"},
        "importReminderBeforeReport": true,
        "firstWeekday": 2,
        "sections": [{"id": "overview", "visible": true}, {"id": "categories", "visible": true},
          {"id": "daily", "visible": true}, {"id": "largest", "visible": true},
          {"id": "coverage", "visible": true}, {"id": "assistant", "visible": true}]
      }
    }
    """

    private func defaults() throws -> UserDefaults {
        let suite = "LedgerAgentAppSettingsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    /// The defaults the sample snapshot was taken from: a 记账提醒 already on.
    private func seed(_ defaults: UserDefaults) {
        LedgerReminderSettings(bookkeeping: .init(isEnabled: true, time: .init(hour: 21, minute: 30),
                                                 repeats: .daily, skipsRecordedDays: true),
                              imports: .init()).save(to: defaults)
    }

    private func snapshot(_ defaults: UserDefaults) -> LedgerAgentAppSettings {
        LedgerAgentAppSettings.load(defaults: defaults, valuationCurrency: "CNY")
    }

    // MARK: The wire format

    func testSnapshotMatchesWhatTheNativeSideReads() throws {
        let defaults = try defaults()
        seed(defaults)
        let settings = snapshot(defaults)
        let decoded = try JSONDecoder().decode(LedgerAgentAppSettings.self, from: Data(Self.wireJSON.utf8))
        XCTAssertEqual(settings, decoded)

        // Re-encoding produces the same object: no key is missing or extra.
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? NSDictionary)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.wireJSON.utf8)) as? NSDictionary)
        XCTAssertTrue(encoded.isEqual(expected), "encoded \(encoded) != \(expected)")
    }

    func testSnapshotReadsTheValuesTheScreensWrite() throws {
        let defaults = try defaults()
        defaults.set(["spendingCategories", "retention", "topPayees"], forKey: LedgerAgentAppSettings.Keys.overviewSections)
        defaults.set(["overview", "search"], forKey: LedgerAgentAppSettings.Keys.compactTabs)
        var reports = LedgerReportSettings.load(from: defaults)
        reports.weekly.isEnabled = true
        reports.weekly.weekday = 1
        reports.monthly.day = .last
        reports.sections = LedgerReportSectionPreference.normalized([
            .init(section: .categories, isVisible: true),
            .init(section: .overview, isVisible: false),
        ])
        reports.save(to: defaults)
        let settings = snapshot(defaults)
        XCTAssertEqual(settings.overview.sections, ["spendingCategories", "retention", "topPayees"])
        XCTAssertEqual(settings.tabs.tabs, ["overview", "search"])
        XCTAssertTrue(settings.reports.weekly.enabled)
        XCTAssertEqual(settings.reports.weekly.weekday, 1)
        XCTAssertEqual(settings.reports.monthly.day, -1)
        XCTAssertEqual(settings.reports.sections.first?.id, "categories")
        XCTAssertEqual(settings.reports.sections.first?.visible, true)
        XCTAssertEqual(settings.reports.sections.count, LedgerReportSection.allCases.count)
    }

    func testCustomWeekdaysAndForeignCurrencyTravelAsTheirOwnValues() throws {
        let defaults = try defaults()
        LedgerReminderSettings(bookkeeping: .init(isEnabled: true, time: .init(hour: 22, minute: 0),
                                                 repeats: .custom([2, 4, 6])),
                              imports: .init(isEnabled: true, cadence: .monthly(.last),
                                             time: .init(hour: 8, minute: 5))).save(to: defaults)
        let settings = LedgerAgentAppSettings.load(defaults: defaults, valuationCurrency: "USD")
        XCTAssertEqual(settings.reminders.bookkeeping.repeatRule, "custom")
        XCTAssertEqual(settings.reminders.bookkeeping.days, [2, 4, 6])
        XCTAssertEqual(settings.reminders.imports.cadence, "monthly")
        XCTAssertEqual(settings.reminders.imports.day, -1)
        XCTAssertEqual(settings.reminders.imports.time, "08:05")
        XCTAssertEqual(settings.valuation.currency, "USD")

        // And back again: the plan rebuilds the app's own values.
        guard case let .reminders(reminders) = try settings.plan(for: .reminders, in: defaults) else { return XCTFail() }
        XCTAssertEqual(reminders.bookkeeping.repeats, .custom([2, 4, 6]))
        XCTAssertEqual(reminders.bookkeeping.time, LedgerReminderTime(hour: 22, minute: 0))
        XCTAssertEqual(reminders.imports.cadence, .monthly(.last))
    }

    func testUpdateDecodesTheChangedSectionsItKnowsAndDropsOthers() throws {
        let json = """
        {"ok":true,"reply":"好","appSettings":{"snapshot":\(Self.wireJSON),"changedSections":["reminders","theme"]}}
        """
        let response = try JSONDecoder().decode(LedgerAgentTurnResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.appSettings?.changedSections, [.reminders])
        XCTAssertEqual(response.appSettings?.snapshot.reminders.bookkeeping.time, "21:30")

        // A reply whose settings block is broken still arrives.
        let broken = #"{"ok":true,"reply":"好","appSettings":{"snapshot":{"overview":{}}}}"#
        let dropped = try JSONDecoder().decode(LedgerAgentTurnResponse.self, from: Data(broken.utf8))
        XCTAssertEqual(dropped.reply, "好")
        XCTAssertNil(dropped.appSettings)
    }

    func testTheRequestCarriesTheSnapshot() throws {
        let defaults = try defaults()
        seed(defaults)
        let request = LedgerAgentTurnRequest(turnId: "t", workspaceRoot: "/w", runtimeRoot: "/r", entrypoint: "main.bean",
            sensitiveUnlocked: true, provider: "anthropic", model: "claude-sonnet-4-5", apiKey: "k",
            history: [], message: "m", appSettings: snapshot(defaults))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let encoded = try XCTUnwrap(object["appSettings"] as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), Set(["overview", "tabs", "valuation", "reminders", "reports"]))
        let reminders = try XCTUnwrap(encoded["reminders"] as? [String: Any])
        let bookkeeping = try XCTUnwrap(reminders["bookkeeping"] as? [String: Any])
        XCTAssertEqual(bookkeeping["time"] as? String, "21:30")
        XCTAssertEqual(bookkeeping["repeat"] as? String, "daily")
        XCTAssertNil(bookkeeping["repeatRule"])
    }

    // MARK: Applying

    func testEachSectionApplies() async throws {
        let defaults = try defaults()
        seed(defaults)
        let store = FakeAppSettings(defaults: defaults)
        var target = snapshot(defaults)
        target.overview.sections = ["spendingCategories", "retention"]
        target.tabs.tabs = ["overview", "search"]
        target.valuation.currency = "hkd"
        target.reminders.bookkeeping.enabled = false
        target.reminders.bookkeeping.time = "22:00"
        target.reminders.bookkeeping.repeatRule = "weekdays"
        target.reminders.imports.enabled = true
        target.reminders.imports.cadence = "monthly"
        target.reminders.imports.day = 15
        target.reports.weekly.enabled = true
        target.reports.weekly.time = "18:30"
        target.reports.sections = target.reports.sections.map {
            .init(id: $0.id, visible: $0.id != "coverage")
        }
        let sections = LedgerAgentAppSettingsSection.allCases
        let result = await store.host.apply(target, sections)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.applied, sections)
        XCTAssertEqual(store.reschedules, 1)
        XCTAssertEqual(store.reportChanges, 1)

        let now = store.host.snapshot()
        XCTAssertEqual(now.overview.sections, ["spendingCategories", "retention"])
        XCTAssertEqual(now.tabs.tabs, ["overview", "search"])
        XCTAssertEqual(now.valuation.currency, "HKD")
        XCTAssertEqual(now.reminders.bookkeeping.time, "22:00")
        XCTAssertEqual(now.reminders.bookkeeping.days, [2, 3, 4, 5, 6])
        XCTAssertFalse(now.reminders.bookkeeping.enabled)
        XCTAssertTrue(now.reminders.imports.enabled)
        XCTAssertEqual(now.reminders.imports.cadence, "monthly")
        XCTAssertEqual(now.reminders.imports.day, 15)
        XCTAssertTrue(now.reports.weekly.enabled)
        XCTAssertEqual(now.reports.weekly.time, "18:30")
        XCTAssertEqual(now.reports.sections.first { $0.id == "coverage" }?.visible, false)
    }

    func testBadValuesAreRefusedSectionBySectionAndChangeNothing() async throws {
        let defaults = try defaults()
        seed(defaults)
        let store = FakeAppSettings(defaults: defaults)
        let before = store.host.snapshot()
        for (section, change) in badChanges() {
            var target = before
            change(&target)
            let result = await store.host.apply(target, [section])
            XCTAssertEqual(result.applied, [], "\(section) applied a bad value")
            XCTAssertEqual(result.failures.count, 1, "\(section) said nothing about \(result)")
            XCTAssertFalse(result.failures[0].isEmpty)
        }
        XCTAssertEqual(store.host.snapshot(), before)
        XCTAssertEqual(store.reschedules, 0)
        // One bad section does not stop the others in the same change.
        var target = before
        target.valuation.currency = "USD"
        target.reminders.bookkeeping.time = "25:00"
        let mixed = await store.host.apply(target, [.valuation, .reminders])
        XCTAssertEqual(mixed.applied, [.valuation])
        XCTAssertEqual(mixed.failures.count, 1)
        XCTAssertEqual(store.host.snapshot().valuation.currency, "USD")
        XCTAssertEqual(store.host.snapshot().reminders.bookkeeping.time, "21:30")
    }

    func testTheSameValuesWriteNothing() async throws {
        let defaults = try defaults()
        seed(defaults)
        let store = FakeAppSettings(defaults: defaults)
        let before = store.host.snapshot()
        // The sections a snapshot round trip produces are the values themselves.
        let result = await store.host.apply(before, LedgerAgentAppSettingsSection.allCases)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(store.host.snapshot(), before)
    }

    func testUndoOfASectionRestoresWhatWasThere() async throws {
        let defaults = try defaults()
        seed(defaults)
        let store = FakeAppSettings(defaults: defaults)
        let before = store.host.snapshot()
        var target = before
        target.reminders.bookkeeping.time = "22:00"
        target.overview.sections = ["retention"]
        let changed = await store.host.apply(target, [.reminders, .overview])
        XCTAssertEqual(changed.applied, [.reminders, .overview])
        XCTAssertNotEqual(store.host.snapshot(), before)

        let back = await store.host.apply(before, [.reminders, .overview])
        XCTAssertEqual(back.failures, [])
        XCTAssertEqual(store.host.snapshot(), before)
    }

    // MARK: In a conversation

    func testAnAnsweredTurnAppliesItsSettingsAndTheRowCanUndoThem() async throws {
        let defaults = try defaults()
        seed(defaults)
        let store = FakeAppSettings(defaults: defaults)
        let conversation = LedgerAgentConversation()
        conversation.appSettings = store.host
        let before = store.host.snapshot()

        var target = before
        target.reminders.bookkeeping.time = "22:00"
        target.reminders.bookkeeping.repeatRule = "weekdays"
        let update = LedgerAgentAppSettingsUpdate(snapshot: target, changedSections: [.reminders])
        conversation.send("提醒改到每天 22 点，只在工作日") { _, _, _ in
            .init(ok: true, reply: "已把记账提醒改到工作日 22:00。", appSettings: update)
        }
        try await waitUntilIdle(conversation)

        let answer = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(answer.settings?.sections, [.reminders])
        XCTAssertEqual(answer.settings?.titles, "提醒")
        XCTAssertEqual(answer.settings?.previous.reminders.bookkeeping.time, "21:30")
        XCTAssertEqual(store.host.snapshot().reminders.bookkeeping.time, "22:00")
        XCTAssertTrue(conversation.canUndoAppSettings(answer))

        conversation.undoAppSettings(answer)
        for _ in 0..<200 where conversation.messages.last?.settings?.undoneAt == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let undone = try XCTUnwrap(conversation.messages.last)
        XCTAssertNotNil(undone.settings?.undoneAt)
        XCTAssertFalse(conversation.canUndoAppSettings(undone))
        XCTAssertEqual(store.host.snapshot(), before)

        // The record survives a save and reopening.
        let saved = try XCTUnwrap(conversation.saved())
        XCTAssertNotNil(saved.messages.last?.settings?.undoneAt)

        // The model hears about the undo with the next question.
        conversation.send("现在呢") { message, _, _ in
            XCTAssertTrue(message.contains("撤销"))
            return .init(ok: true, reply: "提醒还是 21:30。")
        }
        try await waitUntilIdle(conversation)
    }

    func testAFailedTurnDropsWhatItChanged() async throws {
        let defaults = try defaults()
        seed(defaults)
        let store = FakeAppSettings(defaults: defaults)
        let conversation = LedgerAgentConversation()
        conversation.appSettings = store.host
        let before = store.host.snapshot()
        var target = before
        target.valuation.currency = "USD"
        let update = LedgerAgentAppSettingsUpdate(snapshot: target, changedSections: [.valuation])
        // A turn that failed after the tool ran still carries the change; the
        // shell must not apply it.
        conversation.send("用美元看") { _, _, _ in
            .init(ok: false, error: "模型服务拒绝了这次请求", appSettings: update)
        }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(store.host.snapshot(), before)
        XCTAssertNil(conversation.messages.last?.settings)
    }

    func testASectionThatDoesNotApplyIsToldToTheModelNextTurn() async throws {
        let defaults = try defaults()
        seed(defaults)
        let store = FakeAppSettings(defaults: defaults)
        let conversation = LedgerAgentConversation()
        conversation.appSettings = store.host
        let before = store.host.snapshot()
        var target = before
        target.reminders.bookkeeping.time = "9:00"
        let update = LedgerAgentAppSettingsUpdate(snapshot: target, changedSections: [.reminders])
        conversation.send("提醒改到 9 点") { _, _, _ in .init(ok: true, reply: "改好了。", appSettings: update) }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(store.host.snapshot(), before)
        XCTAssertNil(conversation.messages.last?.settings)

        conversation.send("好了吗") { message, _, _ in
            XCTAssertTrue(message.contains("没改成"))
            XCTAssertTrue(message.contains("HH:MM"))
            return .init(ok: true, reply: "没改成功。")
        }
        try await waitUntilIdle(conversation)
    }

    // MARK: Helpers

    private func badChanges() -> [(LedgerAgentAppSettingsSection, (inout LedgerAgentAppSettings) -> Void)] {
        [
            (.overview, { $0.overview.sections = [] }),
            (.overview, { $0.overview.sections = ["budget"] }),
            (.overview, { $0.overview.sections = ["retention", "retention"] }),
            (.tabs, { $0.tabs.tabs = [] }),
            (.tabs, { $0.tabs.tabs = ["settings"] }),
            (.tabs, { $0.tabs.tabs = ["overview", "search", "accounts", "transactions"] }),
            (.valuation, { $0.valuation.currency = "元" }),
            (.reminders, { $0.reminders.bookkeeping.time = "9:00" }),
            (.reminders, { $0.reminders.bookkeeping.time = "24:00" }),
            (.reminders, { $0.reminders.bookkeeping.repeatRule = "weekly" }),
            (.reminders, { $0.reminders.bookkeeping.repeatRule = "custom"; $0.reminders.bookkeeping.days = [] }),
            (.reminders, { $0.reminders.bookkeeping.repeatRule = "custom"; $0.reminders.bookkeeping.days = [0, 2] }),
            (.reminders, { $0.reminders.imports.cadence = "yearly" }),
            (.reminders, { $0.reminders.imports.cadence = "monthly"; $0.reminders.imports.day = 31 }),
            (.reminders, { $0.reminders.imports.cadence = "weekly"; $0.reminders.imports.weekday = 8 }),
            (.reports, { $0.reports.weekly.weekday = 8 }),
            (.reports, { $0.reports.firstWeekday = 3 }),
            (.reports, { $0.reports.monthly.day = 0 }),
            (.reports, { settings in
                let kept = Array(settings.reports.sections.prefix(2))
                settings.reports.sections = kept
            }),
            (.reports, { settings in
                let rest = Array(settings.reports.sections.dropFirst())
                settings.reports.sections = [.init(id: "summary", visible: true)] + rest
            }),
        ]
    }

    private func waitUntilIdle(_ conversation: LedgerAgentConversation) async throws {
        for _ in 0..<200 where conversation.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(conversation.isRunning)
    }
}

/// The settings of a test device: the same plan and validation the live host
/// runs, writing to a throwaway `UserDefaults` instead of the app's screens.
@MainActor
private final class FakeAppSettings {
    let defaults: UserDefaults
    var currency = "CNY"
    var reschedules = 0
    var reportChanges = 0

    init(defaults: UserDefaults) { self.defaults = defaults }

    var host: LedgerAgentAppSettingsHost {
        LedgerAgentAppSettingsHost(snapshot: {
            LedgerAgentAppSettings.load(defaults: self.defaults, valuationCurrency: self.currency)
        }, apply: { settings, sections in
            var result = LedgerAgentAppSettingsApply()
            for section in sections {
                do {
                    switch try settings.plan(for: section, in: self.defaults) {
                    case let .overview(values):
                        self.defaults.set(values.map(\.rawValue), forKey: LedgerAgentAppSettings.Keys.overviewSections)
                    case let .tabs(values):
                        self.defaults.set(values.map(\.rawValue), forKey: LedgerAgentAppSettings.Keys.compactTabs)
                    case let .valuation(code):
                        self.currency = code
                    case let .reminders(values):
                        values.save(to: self.defaults)
                        self.reschedules += 1
                    case let .reports(values):
                        values.save(to: self.defaults)
                        self.reportChanges += 1
                    }
                    result.applied.append(section)
                } catch {
                    result.failures.append(error.localizedDescription)
                }
            }
            return result
        })
    }
}
