import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerReportTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private var monday: LedgerReportCalendar { LedgerReportCalendar(calendar: calendar, firstWeekday: 2) }
    private var sunday: LedgerReportCalendar { LedgerReportCalendar(calendar: calendar, firstWeekday: 1) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // 2026-11-12 is a Thursday.

    // MARK: Periods

    func testWeekFollowsTheChosenFirstWeekday() {
        XCTAssertEqual(monday.week(containing: date(2026, 11, 12)), LedgerReportPeriod(kind: .week, start: "2026-11-09", end: "2026-11-15"))
        XCTAssertEqual(sunday.week(containing: date(2026, 11, 12)), LedgerReportPeriod(kind: .week, start: "2026-11-08", end: "2026-11-14"))
        // A Sunday belongs to the week before when weeks start on Monday.
        XCTAssertEqual(monday.week(containing: date(2026, 11, 15, 23, 59)).start, "2026-11-09")
        XCTAssertEqual(sunday.week(containing: date(2026, 11, 15)).start, "2026-11-15")
    }

    func testWeekAcrossMonthAndYear() {
        XCTAssertEqual(monday.week(containing: date(2026, 12, 31)), LedgerReportPeriod(kind: .week, start: "2026-12-28", end: "2027-01-03"))
        XCTAssertEqual(monday.shifted(monday.week(containing: date(2026, 12, 31)), by: 1).start, "2027-01-04")
        XCTAssertEqual(monday.week(containing: date(2026, 10, 1)).start, "2026-09-28")
    }

    func testMonthBoundariesIncludingLeapFebruary() {
        XCTAssertEqual(monday.month(containing: date(2028, 2, 10)), LedgerReportPeriod(kind: .month, start: "2028-02-01", end: "2028-02-29"))
        XCTAssertEqual(monday.month(containing: date(2027, 2, 10)).end, "2027-02-28")
        XCTAssertEqual(monday.month(containing: date(2026, 11, 30)).end, "2026-11-30")
        XCTAssertEqual(monday.shifted(monday.month(containing: date(2026, 12, 5)), by: 1),
            LedgerReportPeriod(kind: .month, start: "2027-01-01", end: "2027-01-31"))
        XCTAssertEqual(monday.previous(monday.month(containing: date(2026, 3, 31))).end, "2026-02-28")
    }

    func testLastCompletedPeriodIsTheOneBeforeNow() {
        XCTAssertEqual(monday.lastCompleted(.week, at: date(2026, 11, 16, 9)),
            LedgerReportPeriod(kind: .week, start: "2026-11-09", end: "2026-11-15"))
        XCTAssertEqual(monday.lastCompleted(.month, at: date(2027, 1, 1, 9)),
            LedgerReportPeriod(kind: .month, start: "2026-12-01", end: "2026-12-31"))
        XCTAssertEqual(monday.lastCompleted(.month, at: date(2028, 3, 1, 9)).end, "2028-02-29")
    }

    func testCustomPeriodShiftsByItsOwnLength() {
        let period = monday.custom("2026-11-10", "2026-11-01")!
        XCTAssertEqual(period, LedgerReportPeriod(kind: .custom, start: "2026-11-01", end: "2026-11-10"))
        XCTAssertEqual(monday.dayCount(period), 10)
        XCTAssertEqual(monday.previous(period), LedgerReportPeriod(kind: .custom, start: "2026-10-22", end: "2026-10-31"))
        XCTAssertEqual(monday.endExclusive(period), "2026-11-11")
        XCTAssertNil(monday.custom("2026-02-30", "2026-03-01"))
    }

    func testRouteTargetSnapsToItsPeriod() {
        XCTAssertEqual(monday.period(for: LedgerReportRouteTarget(kind: .week, start: "2026-11-12")),
            LedgerReportPeriod(kind: .week, start: "2026-11-09", end: "2026-11-15"))
        XCTAssertEqual(monday.period(for: LedgerReportRouteTarget(kind: .month, start: "2026-11-12"))?.start, "2026-11-01")
        XCTAssertEqual(monday.period(for: LedgerReportRouteTarget(kind: .custom, start: "2026-11-01", end: "2026-11-03"))?.end, "2026-11-03")
    }

    // MARK: Schedule

    private func settings(weekly: Bool = true, monthly: Bool = false, monthDay: LedgerReminderMonthDay = .day(1),
                          importBefore: Bool = true) -> LedgerReportSettings {
        var settings = LedgerReportSettings()
        settings.weekly.isEnabled = weekly
        settings.monthly.isEnabled = monthly
        settings.monthly.day = monthDay
        settings.remindsImportBeforeReport = importBefore
        return settings
    }

    func testWeeklyReportOnMondayMorningWithImportReminderSundayEvening() {
        let contribution = LedgerReportSchedule.contribution(settings: settings(), now: date(2026, 11, 12, 10), calendar: calendar)
        XCTAssertEqual(contribution.occurrences.map(\.fireDate), [date(2026, 11, 16, 9), date(2026, 11, 23, 9)])
        XCTAssertEqual(contribution.importReminderDates, [date(2026, 11, 15, 20), date(2026, 11, 22, 20)])
        let first = contribution.occurrences[0]
        XCTAssertEqual(first.kind, .report)
        XCTAssertEqual(first.url, URL(string: "ledger://report?period=week&start=2026-11-09"))
        XCTAssertEqual(LedgerExternalRoute.parse(first.url), .report(LedgerReportRouteTarget(kind: .week, start: "2026-11-09")))
    }

    func testReportNotificationNeverCarriesAnAmount() {
        let contribution = LedgerReportSchedule.contribution(settings: settings(monthly: true), now: date(2026, 11, 12), calendar: calendar)
        for occurrence in contribution.occurrences {
            let text = occurrence.title + occurrence.body
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), text)
            XCTAssertFalse(text.contains("¥"))
        }
    }

    func testImportReminderCanBeTurnedOffAndPastOnesAreLeftOut() {
        XCTAssertTrue(LedgerReportSchedule.contribution(settings: settings(importBefore: false),
            now: date(2026, 11, 12), calendar: calendar).importReminderDates.isEmpty)
        // Sunday 21:00: tonight's reminder has passed, the report is still ahead.
        let late = LedgerReportSchedule.contribution(settings: settings(), now: date(2026, 11, 15, 21), calendar: calendar)
        XCTAssertEqual(late.occurrences.first?.fireDate, date(2026, 11, 16, 9))
        XCTAssertEqual(late.importReminderDates, [date(2026, 11, 22, 20)])
    }

    func testImportReminderBeforeReportReplacesTheUsersOwnNearby() {
        var reminders = LedgerReminderSettings()
        reminders.imports = .init(isEnabled: true, cadence: .weekly(weekday: 1), time: .init(hour: 21, minute: 0))
        let contribution = LedgerReportSchedule.contribution(settings: settings(), now: date(2026, 11, 12, 10), calendar: calendar)
        let plan = LedgerReminderPlanner.plan(settings: reminders, now: date(2026, 11, 12, 10), calendar: calendar,
            recordedToday: false, contributions: [contribution])
        let imports = plan.filter { $0.kind == .importBills }.map(\.fireDate)
        XCTAssertTrue(imports.contains(date(2026, 11, 15, 20)))
        XCTAssertFalse(imports.contains(date(2026, 11, 15, 21)))
    }

    func testMonthEndReportInFebruaryAndThirtyDayMonths() {
        let dates = LedgerReportSchedule.reportDates(.month, settings: settings(weekly: false, monthly: true, monthDay: .last),
            after: date(2027, 1, 31, 10), count: 3, calendar: calendar)
        XCTAssertEqual(dates, [date(2027, 2, 28, 9), date(2027, 3, 31, 9), date(2027, 4, 30, 9)])
        let leap = LedgerReportSchedule.reportDates(.month, settings: settings(weekly: false, monthly: true, monthDay: .last),
            after: date(2028, 2, 1), count: 1, calendar: calendar)
        XCTAssertEqual(leap, [date(2028, 2, 29, 9)])
        // A month-end report covers the last complete month, not the one ending that day.
        let occurrence = LedgerReportSchedule.occurrence(.month, fireDate: date(2027, 2, 28, 9), reportCalendar: monday)
        XCTAssertEqual(occurrence.url, URL(string: "ledger://report?period=month&start=2027-01-01"))
    }

    func testMonthlyReportOnAChosenDay() {
        let dates = LedgerReportSchedule.reportDates(.month, settings: settings(weekly: false, monthly: true, monthDay: .day(15)),
            after: date(2026, 11, 15, 9), count: 2, calendar: calendar)
        XCTAssertEqual(dates, [date(2026, 12, 15, 9), date(2027, 1, 15, 9)])
        XCTAssertTrue(LedgerReportSchedule.reportDates(.month, settings: settings(), after: date(2026, 11, 1), calendar: calendar).isEmpty)
    }

    // MARK: Settings

    func testSettingsRoundTripAndKeepDefaultsForMissingKeys() throws {
        var stored = settings(monthly: true, monthDay: .last)
        stored.firstWeekday = 1
        stored.sections = [LedgerReportSectionPreference(section: .largest, isVisible: false)]
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(LedgerReportSettings.self, from: data)
        XCTAssertEqual(decoded.monthly.day, .last)
        XCTAssertEqual(decoded.firstWeekday, 1)
        XCTAssertEqual(decoded.sections.first, LedgerReportSectionPreference(section: .largest, isVisible: false))
        XCTAssertEqual(decoded.sections.count, LedgerReportSection.allCases.count)
        XCTAssertFalse(decoded.visibleSections.contains(.largest))

        let partial = try JSONDecoder().decode(LedgerReportSettings.self, from: Data(#"{"firstWeekday":5}"#.utf8))
        XCTAssertEqual(partial.firstWeekday, 2)
        XCTAssertTrue(partial.remindsImportBeforeReport)
        XCTAssertFalse(partial.weekly.isEnabled)
        XCTAssertEqual(partial.weekly.weekday, 2)
        XCTAssertEqual(partial.weekly.time, LedgerReminderTime(hour: 9, minute: 0))
    }

    // MARK: Math

    func testChangeRatio() {
        XCTAssertEqual(LedgerReportMath.changeRatio(current: 88, previous: 100)!, -0.12, accuracy: 0.0001)
        XCTAssertEqual(LedgerReportMath.changeRatio(current: 150, previous: 100)!, 0.5, accuracy: 0.0001)
        XCTAssertNil(LedgerReportMath.changeRatio(current: 100, previous: 0))
        XCTAssertEqual(LedgerReportMath.changeRatio(current: -50, previous: -100)!, 0.5, accuracy: 0.0001)
    }

    func testRankingKeepsTopFiveAndMergesTheRestIntoOther() {
        let items: [(label: String, amount: Int)] = [
            ("餐饮", 500), ("交通", 300), ("购物", 200), ("娱乐", 100), ("住房", 80), ("医疗", 15), ("其他费用", 5),
            ("餐饮", 100), ("退款", -40), ("空", 0)
        ]
        let slices = LedgerReportMath.ranking(items, limit: 5, otherLabel: "其他")
        XCTAssertEqual(slices.map(\.label), ["餐饮", "交通", "购物", "娱乐", "住房", "其他"])
        XCTAssertEqual(slices.first?.amount, 600)
        XCTAssertEqual(slices.last?.amount, 20)
        XCTAssertEqual(slices.last?.isOther, true)
        XCTAssertEqual(slices.map(\.share).reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(LedgerReportMath.ranking([("A", 1), ("B", 1)], limit: 5).map(\.label), ["A", "B"])
        XCTAssertTrue(LedgerReportMath.ranking([("A", -1)]).isEmpty)
    }

    func testCoverageCountsOnlyDaysUpToToday() {
        let week = LedgerReportPeriod(kind: .week, start: "2026-11-09", end: "2026-11-15")
        let full = LedgerReportMath.coverage(week, recordedDays: ["2026-11-09", "2026-11-11", "2026-11-15", "2026-11-20"],
            today: "2026-11-20", calendar: monday)
        XCTAssertEqual(full.elapsedDays, 7)
        XCTAssertEqual(full.recordedDays, 3)
        XCTAssertEqual(full.blankDays, ["2026-11-10", "2026-11-12", "2026-11-13", "2026-11-14"])
        let running = LedgerReportMath.coverage(week, recordedDays: ["2026-11-09"], today: "2026-11-11", calendar: monday)
        XCTAssertEqual(running.elapsedDays, 3)
        XCTAssertEqual(running.blankDays, ["2026-11-10", "2026-11-11"])
    }

    func testBucketsByDayForMonthAndByWeekForLongRanges() {
        let month = LedgerReportPeriod(kind: .month, start: "2026-11-01", end: "2026-11-30")
        let daily = LedgerReportMath.buckets(month, daily: ["2026-11-03": (amount: 120, count: 2)], calendar: monday)
        XCTAssertEqual(daily.count, 30)
        XCTAssertEqual(daily[2], LedgerReportBucket(start: "2026-11-03", amount: 120, transactionCount: 2))
        let long = monday.custom("2026-09-01", "2026-11-30")!
        let weekly = LedgerReportMath.buckets(long, daily: ["2026-09-01": (amount: 10, count: 1), "2026-09-06": (amount: 5, count: 1),
            "2026-09-07": (amount: 7, count: 1)], calendar: monday)
        XCTAssertEqual(weekly.first, LedgerReportBucket(start: "2026-09-01", amount: 15, transactionCount: 2))
        XCTAssertEqual(weekly[1].start, "2026-09-07")
        XCTAssertEqual(weekly[1].amount, 7)
    }

    private func transaction(_ payee: String, _ date: String, _ amount: Int, currency: String = "CNY", line: Int) -> LedgerTransaction {
        LedgerTransaction(date: date, payee: payee, narration: "",
            postings: [LedgerPosting(account: "Expenses:Food", amount: amount, currency: currency),
                       LedgerPosting(account: "Assets:Cash", amount: -amount, currency: currency)],
            source: TransactionSource(file: "t.bean", line: line))
    }

    func testLargestExpensesRankTheValuationCurrencyOnly() {
        let rows = [
            transaction("咖啡", "2026-11-10", 3_000, line: 1),
            transaction("机票", "2026-11-11", 150_000, line: 2),
            transaction("东京", "2026-11-12", 999_999, currency: "JPY", line: 3),
            transaction("退款", "2026-11-12", -5_000, line: 4),
            transaction("晚饭", "2026-11-13", 12_000, line: 5),
        ]
        let largest = LedgerReportMath.largestExpenses(rows, currency: "CNY", limit: 2)
        XCTAssertEqual(largest.map(\.title), ["机票", "晚饭"])
        XCTAssertEqual(largest.first?.minorUnits, 150_000)
    }

    // MARK: Receipt

    private func report() -> LedgerReportData {
        let period = LedgerReportPeriod(kind: .week, start: "2026-11-09", end: "2026-11-15")
        return LedgerReportData(period: period, previousPeriod: monday.previous(period), currency: "CNY",
            income: 1_234_500, expense: 345_600, previousIncome: 1_000_000, previousExpense: 400_000,
            categories: LedgerReportMath.ranking([("餐饮", 200_000), ("交通", 145_600)]),
            buckets: LedgerReportMath.buckets(period, daily: ["2026-11-10": (amount: 345_600, count: 3)], calendar: monday),
            largest: LedgerReportMath.largestExpenses([transaction("神秘商户", "2026-11-10", 150_000, line: 1)], currency: "CNY"),
            coverage: LedgerReportMath.coverage(period, recordedDays: ["2026-11-10"], today: "2026-11-20", calendar: monday),
            isTruncated: false)
    }

    private func receipt(_ options: LedgerReportReceiptOptions, amountsAllowed: Bool = true) -> LedgerReportReceipt {
        LedgerReportReceipt.build(report(), options: options, periodLabel: "11月9日–15日", dayLabel: { $0 },
            generatedAt: "2026-11-16 09:00", amountsAllowed: amountsAllowed)
    }

    private func money(_ minorUnits: Int) -> String { MoneyText.format(minorUnits: minorUnits, currency: "CNY") }

    func testReceiptHidesIncomeByDefault() {
        let text = receipt(LedgerReportReceiptOptions()).printedText.joined(separator: "\n")
        XCTAssertFalse(text.contains(money(1_234_500)))
        XCTAssertTrue(text.contains(money(345_600)))
        XCTAssertFalse(text.contains("收入"))
    }

    func testReceiptHidesNetAndDetailsWhenAsked() {
        var options = LedgerReportReceiptOptions()
        options.hidesIncome = false
        let shown = receipt(options).printedText.joined(separator: "\n")
        XCTAssertTrue(shown.contains(money(1_234_500)))
        XCTAssertTrue(shown.contains(money(888_900)))
        XCTAssertTrue(shown.contains("神秘商户"))
        options.hidesNet = true
        options.hidesDetails = true
        let hidden = receipt(options).printedText.joined(separator: "\n")
        XCTAssertFalse(hidden.contains(money(888_900)))
        XCTAssertFalse(hidden.contains("结余"))
        XCTAssertFalse(hidden.contains("神秘商户"))
    }

    func testSharesOnlyReceiptPrintsNoAmountAtAll() {
        var options = LedgerReportReceiptOptions()
        options.hidesIncome = false
        options.sharesOnly = true
        let lines = receipt(options).printedText
        let data = report()
        let amounts = [data.income, data.expense, data.net, 200_000, 145_600, 150_000, 345_600]
        for line in lines {
            XCTAssertFalse(line.contains("¥"), line)
            XCTAssertFalse(line.contains("CNY"), line)
            for amount in amounts { XCTAssertFalse(line.contains(money(amount)), line) }
        }
        XCTAssertTrue(lines.contains("58%"))
    }

    func testHiddenAmountsForceSharesOnly() {
        var options = LedgerReportReceiptOptions()
        options.hidesIncome = false
        let locked = receipt(options, amountsAllowed: false)
        XCTAssertEqual(locked, receipt({ var o = options; o.sharesOnly = true; return o }()))
        XCTAssertFalse(locked.printedText.contains { $0.contains("¥") })
    }

    func testReceiptIncludesOnlyChosenSections() {
        var options = LedgerReportReceiptOptions()
        options.sections = [.categories]
        XCTAssertEqual(receipt(options).blocks.map(\.section), [.categories])
    }

    // MARK: Route

    func testReportRoutes() {
        XCTAssertEqual(LedgerExternalRoute.parse(URL(string: "ledger://report")!), .report(nil))
        XCTAssertEqual(LedgerExternalRoute.parse(URL(string: "ledger://report?period=month&start=2026-10-01")!),
            .report(LedgerReportRouteTarget(kind: .month, start: "2026-10-01")))
        XCTAssertEqual(LedgerExternalRoute.parse(URL(string: "ledger://report?period=custom&start=2026-10-01&end=2026-10-15")!),
            .report(LedgerReportRouteTarget(kind: .custom, start: "2026-10-01", end: "2026-10-15")))
        let custom = LedgerReportRouteTarget(kind: .custom, start: "2026-10-01", end: "2026-10-15")
        XCTAssertEqual(LedgerExternalRoute.parse(custom.url), .report(custom))
        XCTAssertTrue(LedgerExternalRoute.report(nil).opensReport)
        XCTAssertFalse(LedgerExternalRoute.record.opensReport)
        for raw in [
            "ledger://report?period=week", "ledger://report?start=2026-10-01", "ledger://report?period=year&start=2026-10-01",
            "ledger://report?period=week&start=2026-02-30", "ledger://report?period=week&start=2026-10-01&end=2026-10-02",
            "ledger://report?period=custom&start=2026-10-01", "ledger://report?period=custom&start=2026-10-15&end=2026-10-01",
            "ledger://report?period=custom&start=2000-01-01&end=2026-01-01",
            "ledger://report?period=week&start=2026-10-01&start=2026-10-08", "ledger://report?period=week&start=2026-10-01&x=1",
            "ledger://report/extra?period=week&start=2026-10-01"
        ] {
            XCTAssertNil(LedgerExternalRoute.parse(URL(string: raw)!), raw)
        }
    }
}
