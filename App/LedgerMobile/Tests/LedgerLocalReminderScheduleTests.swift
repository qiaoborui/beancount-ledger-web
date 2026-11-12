import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerLocalReminderScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func bookkeeping(_ repeats: LedgerReminderRepeat = .daily, skips: Bool = true) -> LedgerReminderSettings {
        var settings = LedgerReminderSettings()
        settings.bookkeeping = .init(isEnabled: true, time: .init(hour: 21, minute: 30), repeats: repeats, skipsRecordedDays: skips)
        return settings
    }

    // 2026-11-12 is a Thursday.

    func testDailyReminderCoversTheHorizonStartingToday() {
        let plan = LedgerReminderPlanner.plan(settings: bookkeeping(), now: date(2026, 11, 12, 10),
            calendar: calendar, recordedToday: false)
        XCTAssertEqual(plan.count, LedgerReminderPlanner.bookkeepingHorizonDays)
        XCTAssertEqual(plan.first?.fireDate, date(2026, 11, 12, 21, 30))
        XCTAssertEqual(plan.last?.fireDate, date(2026, 11, 25, 21, 30))
        XCTAssertTrue(plan.allSatisfy { $0.kind == .bookkeeping && $0.url == LedgerReminderNotification.recordURL })
    }

    func testTodayIsLeftOutOnceItsTimeHasPassed() {
        let plan = LedgerReminderPlanner.plan(settings: bookkeeping(), now: date(2026, 11, 12, 21, 30),
            calendar: calendar, recordedToday: false)
        XCTAssertEqual(plan.first?.fireDate, date(2026, 11, 13, 21, 30))
        XCTAssertEqual(plan.count, LedgerReminderPlanner.bookkeepingHorizonDays - 1)
    }

    func testWeekdaysSkipTheWeekendAcrossWeeks() {
        let plan = LedgerReminderPlanner.plan(settings: bookkeeping(.weekdays), now: date(2026, 11, 12, 10),
            calendar: calendar, recordedToday: false)
        XCTAssertEqual(plan.count, 10)
        XCTAssertTrue(plan.allSatisfy { (2...6).contains(calendar.component(.weekday, from: $0.fireDate)) })
        XCTAssertTrue(plan.contains { $0.fireDate == date(2026, 11, 16, 21, 30) })
    }

    func testCustomWeekdays() {
        let plan = LedgerReminderPlanner.plan(settings: bookkeeping(.custom([1, 7, 9])), now: date(2026, 11, 12, 10),
            calendar: calendar, recordedToday: false)
        XCTAssertEqual(plan.map(\.fireDate), [
            date(2026, 11, 14, 21, 30), date(2026, 11, 15, 21, 30),
            date(2026, 11, 21, 21, 30), date(2026, 11, 22, 21, 30),
        ])
    }

    func testRecordedTodaySkipsOnlyTodayWhenSmartSkipIsOn() {
        let skipped = LedgerReminderPlanner.plan(settings: bookkeeping(), now: date(2026, 11, 12, 10),
            calendar: calendar, recordedToday: true)
        XCTAssertEqual(skipped.first?.fireDate, date(2026, 11, 13, 21, 30))
        XCTAssertEqual(skipped.count, LedgerReminderPlanner.bookkeepingHorizonDays - 1)

        let kept = LedgerReminderPlanner.plan(settings: bookkeeping(skips: false), now: date(2026, 11, 12, 10),
            calendar: calendar, recordedToday: true)
        XCTAssertEqual(kept.first?.fireDate, date(2026, 11, 12, 21, 30))
    }

    func testDisabledRemindersScheduleNothing() {
        XCTAssertTrue(LedgerReminderPlanner.plan(settings: LedgerReminderSettings(), now: date(2026, 11, 12),
            calendar: calendar, recordedToday: false).isEmpty)
    }

    func testWeeklyImportCrossesMonths() {
        let dates = LedgerReminderPlanner.weeklyDates(weekday: 1, time: .init(hour: 20, minute: 0),
            after: date(2026, 11, 12, 10), count: 4, calendar: calendar)
        XCTAssertEqual(dates, [date(2026, 11, 15, 20), date(2026, 11, 22, 20), date(2026, 11, 29, 20), date(2026, 12, 6, 20)])
        let atTheMinute = LedgerReminderPlanner.weeklyDates(weekday: 1, time: .init(hour: 20, minute: 0),
            after: date(2026, 11, 15, 20), count: 1, calendar: calendar)
        XCTAssertEqual(atTheMinute, [date(2026, 11, 22, 20)])
    }

    func testMonthlyImportCrossesTheYearAndHandlesMonthEnds() {
        let first = LedgerReminderPlanner.monthlyDates(day: .day(1), time: .init(hour: 9, minute: 0),
            after: date(2026, 11, 12), count: 3, calendar: calendar)
        XCTAssertEqual(first, [date(2026, 12, 1, 9), date(2027, 1, 1, 9), date(2027, 2, 1, 9)])

        let last = LedgerReminderPlanner.monthlyDates(day: .last, time: .init(hour: 9, minute: 0),
            after: date(2027, 1, 15), count: 4, calendar: calendar)
        XCTAssertEqual(last, [date(2027, 1, 31, 9), date(2027, 2, 28, 9), date(2027, 3, 31, 9), date(2027, 4, 30, 9)])

        let leap = LedgerReminderPlanner.monthlyDates(day: .last, time: .init(hour: 9, minute: 0),
            after: date(2028, 2, 1), count: 1, calendar: calendar)
        XCTAssertEqual(leap, [date(2028, 2, 29, 9)])

        let passedToday = LedgerReminderPlanner.monthlyDates(day: .day(12), time: .init(hour: 9, minute: 0),
            after: date(2026, 11, 12, 10), count: 1, calendar: calendar)
        XCTAssertEqual(passedToday, [date(2026, 12, 12, 9)])

        XCTAssertEqual(LedgerReminderMonthDay.day(31).resolved(daysInMonth: 31), 28)
    }

    func testRequestedImportRemindersReplaceNearbyUserOnes() {
        var settings = LedgerReminderSettings()
        settings.imports = .init(isEnabled: true, cadence: .weekly(weekday: 1), time: .init(hour: 20, minute: 0))
        let report = LedgerReminderContribution(importReminderDates: [
            date(2026, 11, 22, 9), date(2026, 11, 22, 12), // the second is the same reminder
            date(2026, 11, 10, 9), // already past
        ])
        let plan = LedgerReminderPlanner.plan(settings: settings, now: date(2026, 11, 12, 10),
            calendar: calendar, recordedToday: false, contributions: [report])
        XCTAssertEqual(plan.map(\.fireDate), [date(2026, 11, 15, 20), date(2026, 11, 22, 9), date(2026, 11, 29, 20)])
        XCTAssertTrue(plan.allSatisfy { $0.kind == .importBills && $0.url == LedgerReminderNotification.importsURL })
        XCTAssertNotEqual(plan[0].body, plan[1].body)
    }

    func testRequestedImportRemindersWorkWithoutTheUserReminder() {
        let plan = LedgerReminderPlanner.plan(settings: LedgerReminderSettings(), now: date(2026, 11, 12, 10),
            calendar: calendar, recordedToday: false,
            contributions: [.init(importReminderDates: [date(2026, 11, 15, 20)])])
        XCTAssertEqual(plan.map(\.fireDate), [date(2026, 11, 15, 20)])
    }

    func testOnlyOneReminderPerMinuteByPriority() {
        var settings = LedgerReminderSettings()
        settings.bookkeeping = .init(isEnabled: true, time: .init(hour: 20, minute: 0), repeats: .daily, skipsRecordedDays: true)
        settings.imports = .init(isEnabled: true, cadence: .weekly(weekday: 1), time: .init(hour: 20, minute: 0))
        let report = LedgerReminderOccurrence(kind: .report, fireDate: date(2026, 11, 22, 20), title: "周报",
            body: "", categoryIdentifier: LedgerReminderNotification.plainCategory,
            url: URL(string: "ledger://overview")!, tag: "week")
        let plan = LedgerReminderPlanner.plan(settings: settings, now: date(2026, 11, 12, 10),
            calendar: calendar, recordedToday: false, contributions: [.init(occurrences: [report])])
        XCTAssertEqual(plan.filter { $0.fireDate == date(2026, 11, 15, 20) }.map(\.kind), [.importBills])
        XCTAssertEqual(plan.filter { $0.fireDate == date(2026, 11, 22, 20) }.map(\.kind), [.report])
        XCTAssertEqual(plan.filter { $0.fireDate == date(2026, 11, 16, 20) }.map(\.kind), [.bookkeeping])
        XCTAssertEqual(Set(plan.map(\.id)).count, plan.count)
        XCTAssertTrue(plan.allSatisfy { $0.id.hasPrefix(LedgerReminderNotification.identifierPrefix) })
    }

    func testNeverMoreThanTheLimit() {
        let start = date(2026, 11, 12, 10)
        let many = (1...100).map {
            LedgerReminderOccurrence(kind: .report, fireDate: start.addingTimeInterval(Double($0) * 3600), title: "",
                body: "", categoryIdentifier: LedgerReminderNotification.plainCategory, url: LedgerReminderNotification.recordURL)
        }
        var settings = bookkeeping()
        settings.imports.isEnabled = true
        let plan = LedgerReminderPlanner.plan(settings: settings, now: start, calendar: calendar,
            recordedToday: false, contributions: [.init(occurrences: many)])
        XCTAssertEqual(plan.count, LedgerReminderPlanner.maximumPending)
        XCTAssertLessThanOrEqual(plan.count, 64)
        XCTAssertEqual(plan.map(\.fireDate), plan.map(\.fireDate).sorted())
    }

    func testActionsAndTapsOpenLedgerLinks() {
        typealias N = LedgerReminderNotification
        XCTAssertEqual(N.url(forAction: N.recordAction, userInfo: [:]), N.recordURL)
        XCTAssertEqual(N.url(forAction: N.sentenceAction, userInfo: [:]), N.sentenceURL)
        XCTAssertEqual(N.url(forAction: N.importAction, userInfo: [:]), N.importsURL)
        XCTAssertEqual(N.url(forAction: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: [N.urlKey: "ledger://imports"]), N.importsURL)
        XCTAssertNil(N.url(forAction: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: [N.urlKey: "https://example.com"]))
        XCTAssertNil(N.url(forAction: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: [:]))
        XCTAssertEqual(LedgerExternalRoute.parse(N.recordURL), .record)
        XCTAssertEqual(LedgerExternalRoute.parse(N.sentenceURL), .sentence)
        XCTAssertEqual(LedgerExternalRoute.parse(N.importsURL), .page(.imports))
        XCTAssertTrue(N.isReminder(categoryIdentifier: N.bookkeepingCategory))
        XCTAssertFalse(N.isReminder(categoryIdentifier: ""))
    }

    func testSettingsPersistAcrossLaunches() throws {
        let suite = "LedgerLocalReminderScheduleTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LedgerReminderSettings.load(from: defaults), LedgerReminderSettings())
        var settings = bookkeeping(.custom([2, 4]))
        settings.imports = .init(isEnabled: true, cadence: .monthly(.last), time: .init(hour: 8, minute: 5))
        settings.save(to: defaults)
        XCTAssertEqual(LedgerReminderSettings.load(from: defaults), settings)

        // A field missing from an older save keeps its default; the rest survive.
        defaults.set(Data(#"{"bookkeeping":{"isEnabled":true,"time":{"hour":7,"minute":15}}}"#.utf8),
                     forKey: LedgerReminderSettings.defaultsKey)
        let old = LedgerReminderSettings.load(from: defaults)
        XCTAssertTrue(old.bookkeeping.isEnabled)
        XCTAssertEqual(old.bookkeeping.time, LedgerReminderTime(hour: 7, minute: 15))
        XCTAssertTrue(old.bookkeeping.skipsRecordedDays)
        XCTAssertEqual(old.imports, LedgerImportReminderSettings())
    }
}
