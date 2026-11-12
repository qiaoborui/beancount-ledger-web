import Foundation

// 周报 / 月报, as plain values and pure functions.
//
// Nothing here reads the ledger. The report page (`LedgerReportView`, app
// target) loads the period's totals through the existing local repository
// reads and hands them to these functions, which decide the periods, the
// comparison with the previous one, the category ranking, the blank days and
// what a shared receipt may contain. Reports are computed when the page opens,
// never in the background: the scheduled notification is only a reminder.

// MARK: - Periods

enum LedgerReportPeriodKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: String(localized: "周报")
        case .month: String(localized: "月报")
        case .custom: String(localized: "自定义")
        }
    }
}

/// One report's days, both ends inclusive, as `yyyy-MM-dd`.
struct LedgerReportPeriod: Equatable, Hashable, Sendable {
    let kind: LedgerReportPeriodKind
    let start: String
    let end: String
}

/// Period arithmetic in one calendar and week start. `firstWeekday` uses
/// `Calendar` numbering: 1 is Sunday, 2 Monday.
struct LedgerReportCalendar: Sendable {
    let calendar: Calendar
    let firstWeekday: Int

    init(calendar: Calendar = LedgerReportCalendar.defaultCalendar, firstWeekday: Int = 2) {
        self.calendar = calendar
        self.firstWeekday = (1...7).contains(firstWeekday) ? firstWeekday : 2
    }

    static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    func text(_ date: Date) -> String { formatter().string(from: date) }

    func day(_ text: String) -> Date? {
        guard text.count == 10 else { return nil }
        let formatter = formatter()
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return calendar.startOfDay(for: date)
    }

    func adding(days: Int, to text: String) -> String? {
        guard let date = day(text), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return self.text(moved)
    }

    func week(containing date: Date) -> LedgerReportPeriod {
        let today = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: today)
        let offset = (weekday - firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return LedgerReportPeriod(kind: .week, start: text(start), end: text(end))
    }

    func month(containing date: Date) -> LedgerReportPeriod {
        let components = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: components) ?? calendar.startOfDay(for: date)
        let days = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let end = calendar.date(byAdding: .day, value: days - 1, to: start) ?? start
        return LedgerReportPeriod(kind: .month, start: text(start), end: text(end))
    }

    /// The week or month that contains `date`. A custom period has no
    /// natural boundary, so it falls back to the week.
    func period(_ kind: LedgerReportPeriodKind, containing date: Date) -> LedgerReportPeriod {
        kind == .month ? month(containing: date) : week(containing: date)
    }

    /// The last complete week or month before `now`: what a report at `now` covers.
    func lastCompleted(_ kind: LedgerReportPeriodKind, at now: Date) -> LedgerReportPeriod {
        shifted(period(kind, containing: now), by: -1)
    }

    /// A custom period from two days in either order.
    func custom(_ first: String, _ second: String) -> LedgerReportPeriod? {
        guard let a = day(first), let b = day(second) else { return nil }
        return LedgerReportPeriod(kind: .custom, start: text(min(a, b)), end: text(max(a, b)))
    }

    func dayCount(_ period: LedgerReportPeriod) -> Int {
        guard let start = day(period.start), let end = day(period.end) else { return 0 }
        return (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }

    /// The period `steps` periods away: a week by seven days, a month by one
    /// calendar month, a custom range by its own length.
    func shifted(_ period: LedgerReportPeriod, by steps: Int) -> LedgerReportPeriod {
        guard steps != 0, let start = day(period.start) else { return period }
        switch period.kind {
        case .week:
            let moved = calendar.date(byAdding: .day, value: 7 * steps, to: start) ?? start
            return week(containing: moved)
        case .month:
            let moved = calendar.date(byAdding: .month, value: steps, to: start) ?? start
            return month(containing: moved)
        case .custom:
            let length = max(dayCount(period), 1)
            guard let newStart = adding(days: length * steps, to: period.start),
                  let newEnd = adding(days: length - 1, to: newStart) else { return period }
            return LedgerReportPeriod(kind: .custom, start: newStart, end: newEnd)
        }
    }

    func previous(_ period: LedgerReportPeriod) -> LedgerReportPeriod { shifted(period, by: -1) }

    /// The day after `end`, for the repository's end-exclusive reads.
    func endExclusive(_ period: LedgerReportPeriod) -> String {
        adding(days: 1, to: period.end) ?? period.end
    }

    func days(in period: LedgerReportPeriod) -> [String] {
        let count = dayCount(period)
        guard count > 0, count <= 3_700 else { return [] }
        return (0..<count).compactMap { adding(days: $0, to: period.start) }
    }

    /// The period a `ledger://report` link names, snapped to its week or month.
    func period(for target: LedgerReportRouteTarget) -> LedgerReportPeriod? {
        switch target.kind {
        case .week, .month:
            guard let start = day(target.start) else { return nil }
            return period(target.kind, containing: start)
        case .custom:
            guard let end = target.end else { return nil }
            return custom(target.start, end)
        }
    }

    /// 「2026年11月3日–9日」-style label in the user's locale.
    func label(_ period: LedgerReportPeriod, locale: Locale = .current) -> String {
        guard let start = day(period.start), let end = day(period.end) else { return "\(period.start) – \(period.end)" }
        if period.kind == .month {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("yMMMM")
            return formatter.string(from: start)
        }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateTemplate = "yMMMd"
        return formatter.string(from: start, to: end)
    }
}

// MARK: - Routes

/// What `ledger://report?period=week&start=YYYY-MM-DD` asks for.
struct LedgerReportRouteTarget: Equatable, Hashable, Sendable {
    let kind: LedgerReportPeriodKind
    let start: String
    /// Only for a custom range.
    let end: String?

    init(kind: LedgerReportPeriodKind, start: String, end: String? = nil) {
        self.kind = kind
        self.start = start
        self.end = kind == .custom ? end : nil
    }

    init(_ period: LedgerReportPeriod) {
        self.init(kind: period.kind, start: period.start, end: period.end)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "ledger"
        components.host = "report"
        var items = [URLQueryItem(name: "period", value: kind.rawValue), URLQueryItem(name: "start", value: start)]
        if let end { items.append(URLQueryItem(name: "end", value: end)) }
        components.queryItems = items
        return components.url ?? URL(string: "ledger://report")!
    }
}

// MARK: - Sections and settings

enum LedgerReportSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case overview
    case categories
    case daily
    case largest
    case coverage
    case assistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "概览")
        case .categories: String(localized: "支出构成")
        case .daily: String(localized: "每日支出")
        case .largest: String(localized: "最大几笔")
        case .coverage: String(localized: "记账情况")
        case .assistant: String(localized: "问账本助手")
        }
    }

    /// The assistant button has nothing to print.
    var appearsOnReceipt: Bool { self != .assistant }
}

struct LedgerReportSectionPreference: Codable, Equatable, Hashable, Identifiable, Sendable {
    var section: LedgerReportSection
    var isVisible: Bool

    var id: String { section.rawValue }

    static let defaults = LedgerReportSection.allCases.map { Self(section: $0, isVisible: true) }

    /// Every section exactly once, in the stored order, with any new section
    /// appended and shown.
    static func normalized(_ preferences: [Self]) -> [Self] {
        var seen = Set<LedgerReportSection>()
        var result = preferences.filter { seen.insert($0.section).inserted }
        for section in LedgerReportSection.allCases where !seen.contains(section) {
            result.append(Self(section: section, isVisible: true))
        }
        return result
    }
}

/// The user's 周报 / 月报 choices, kept in `UserDefaults` as one JSON value.
struct LedgerReportSettings: Codable, Equatable, Sendable {
    struct Weekly: Codable, Equatable, Sendable {
        var isEnabled = false
        /// `Calendar` numbering: 2 is Monday.
        var weekday = 2
        var time = LedgerReminderTime(hour: 9, minute: 0)
    }

    struct Monthly: Codable, Equatable, Sendable {
        var isEnabled = false
        var day: LedgerReminderMonthDay = .day(1)
        var time = LedgerReminderTime(hour: 9, minute: 0)
    }

    var weekly = Weekly()
    var monthly = Monthly()
    /// Ask for a 导入账单 reminder the evening before every report.
    var remindsImportBeforeReport = true
    /// `Calendar` numbering: 2 is Monday, 1 Sunday.
    var firstWeekday = 2
    var sections = LedgerReportSectionPreference.defaults
    /// The report page offers to turn 周报 on once.
    var hasOfferedWeekly = false

    static let defaultsKey = "ledger.reports.settings.v1"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case weekly, monthly, remindsImportBeforeReport, firstWeekday, sections, hasOfferedWeekly
    }

    /// Missing keys keep their defaults, so a later field never resets the rest.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        weekly = try values.decodeIfPresent(Weekly.self, forKey: .weekly) ?? Weekly()
        monthly = try values.decodeIfPresent(Monthly.self, forKey: .monthly) ?? Monthly()
        remindsImportBeforeReport = try values.decodeIfPresent(Bool.self, forKey: .remindsImportBeforeReport) ?? true
        let weekStart = try values.decodeIfPresent(Int.self, forKey: .firstWeekday) ?? 2
        firstWeekday = weekStart == 1 ? 1 : 2
        sections = LedgerReportSectionPreference.normalized(
            try values.decodeIfPresent([LedgerReportSectionPreference].self, forKey: .sections) ?? [])
        hasOfferedWeekly = try values.decodeIfPresent(Bool.self, forKey: .hasOfferedWeekly) ?? false
    }

    var anyEnabled: Bool { weekly.isEnabled || monthly.isEnabled }

    /// 「周报 · 月报」, 「周报」 or 「关闭」 for the settings row.
    var summary: String {
        switch (weekly.isEnabled, monthly.isEnabled) {
        case (true, true): String(localized: "周报 · 月报")
        case (true, false): String(localized: "周报")
        case (false, true): String(localized: "月报")
        case (false, false): String(localized: "关闭")
        }
    }

    var visibleSections: [LedgerReportSection] {
        LedgerReportSectionPreference.normalized(sections).filter(\.isVisible).map(\.section)
    }

    func reportCalendar(_ calendar: Calendar = LedgerReportCalendar.defaultCalendar) -> LedgerReportCalendar {
        LedgerReportCalendar(calendar: calendar, firstWeekday: firstWeekday)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Schedule

/// Turns report settings into the reminders #668's planner schedules.
enum LedgerReportSchedule {
    /// How many upcoming reports of each kind stay pending.
    static let occurrenceCount = 2
    /// The 导入账单 reminder before a report: the evening before, at this time.
    static let importReminderTime = LedgerReminderTime(hour: 20, minute: 0)

    static func reportDates(_ kind: LedgerReportPeriodKind, settings: LedgerReportSettings, after now: Date,
                            count: Int = occurrenceCount, calendar: Calendar) -> [Date] {
        switch kind {
        case .week:
            guard settings.weekly.isEnabled else { return [] }
            return LedgerReminderPlanner.weeklyDates(weekday: settings.weekly.weekday, time: settings.weekly.time,
                after: now, count: count, calendar: calendar)
        case .month:
            guard settings.monthly.isEnabled else { return [] }
            return LedgerReminderPlanner.monthlyDates(day: settings.monthly.day, time: settings.monthly.time,
                after: now, count: count, calendar: calendar)
        case .custom:
            return []
        }
    }

    /// The evening before `report` at `importReminderTime`.
    static func importReminderDate(before report: Date, calendar: Calendar) -> Date? {
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: report)),
              let date = LedgerReminderPlanner.at(importReminderTime, on: previousDay, calendar: calendar),
              date < report else { return nil }
        return date
    }

    /// The next report notifications and, when asked, the import reminders
    /// before them. The planner drops anything already past.
    static func contribution(settings: LedgerReportSettings, now: Date, calendar: Calendar) -> LedgerReminderContribution {
        let reportCalendar = settings.reportCalendar(calendar)
        var occurrences: [LedgerReminderOccurrence] = []
        var imports: [Date] = []
        for kind in [LedgerReportPeriodKind.week, .month] {
            for date in reportDates(kind, settings: settings, after: now, calendar: calendar) {
                occurrences.append(occurrence(kind, fireDate: date, reportCalendar: reportCalendar))
                if settings.remindsImportBeforeReport,
                   let importDate = importReminderDate(before: date, calendar: calendar), importDate > now {
                    imports.append(importDate)
                }
            }
        }
        return LedgerReminderContribution(occurrences: combiningSameMinute(occurrences), importReminderDates: imports)
    }

    /// The planner keeps one reminder per minute, so a weekly and a monthly
    /// report on the same minute become one notification that opens the
    /// monthly report and names both.
    static func combiningSameMinute(_ occurrences: [LedgerReminderOccurrence]) -> [LedgerReminderOccurrence] {
        var byMinute: [Int: LedgerReminderOccurrence] = [:]
        for occurrence in occurrences {
            let minute = Int(occurrence.fireDate.timeIntervalSince1970 / 60)
            guard let existing = byMinute[minute] else { byMinute[minute] = occurrence; continue }
            let monthly = existing.tag == LedgerReportPeriodKind.month.rawValue ? existing : occurrence
            byMinute[minute] = LedgerReminderOccurrence(kind: .report, fireDate: monthly.fireDate,
                title: String(localized: "周报和月报都好了"), body: monthly.body,
                categoryIdentifier: monthly.categoryIdentifier, url: monthly.url, tag: "week-month")
        }
        return byMinute.values.sorted { $0.fireDate < $1.fireDate }
    }

    /// 「上周的周报好了」 with no amount: the notification is scheduled ahead
    /// of time, before the period's spending is known.
    static func occurrence(_ kind: LedgerReportPeriodKind, fireDate: Date,
                           reportCalendar: LedgerReportCalendar) -> LedgerReminderOccurrence {
        let period = reportCalendar.lastCompleted(kind, at: fireDate)
        let title = kind == .month ? String(localized: "上个月的月报好了") : String(localized: "上周的周报好了")
        return LedgerReminderOccurrence(kind: .report, fireDate: fireDate, title: title,
            body: String(localized: "点开看看收支情况。"),
            categoryIdentifier: LedgerReminderNotification.plainCategory,
            url: LedgerReportRouteTarget(period).url, tag: kind.rawValue)
    }
}

// MARK: - Summary math

struct LedgerReportCategorySlice: Equatable, Hashable, Identifiable, Sendable {
    let label: String
    let amount: Int
    /// Of the period's positive category total, 0 to 1.
    let share: Double
    let isOther: Bool

    var id: String { isOther ? "\u{0}other" : label }
}

struct LedgerReportBucket: Equatable, Hashable, Identifiable, Sendable {
    /// First day of the bucket.
    let start: String
    let amount: Int
    let transactionCount: Int

    var id: String { start }
}

struct LedgerReportCoverage: Equatable, Sendable {
    /// Days of the period up to today.
    let elapsedDays: Int
    let recordedDays: Int
    let blankDays: [String]
}

struct LedgerReportLargestExpense: Equatable, Identifiable, Sendable {
    let transaction: LedgerTransaction
    let title: String
    let date: String
    let minorUnits: Int

    var id: String { "\(transaction.source.file):\(transaction.source.line):\(transaction.date)" }
}

enum LedgerReportMath {
    /// The change from `previous` to `current`, e.g. -0.12 for 12% less. nil
    /// when there is nothing to compare against.
    static func changeRatio(current: Int, previous: Int) -> Double? {
        guard previous != 0 else { return nil }
        return Double(current - previous) / Double(abs(previous))
    }

    /// The `limit` largest categories and one 「其他」 for the rest. Only
    /// positive amounts count; shares are of their total.
    static func ranking(_ items: [(label: String, amount: Int)], limit: Int = 5,
                        otherLabel: String = String(localized: "其他")) -> [LedgerReportCategorySlice] {
        var merged: [String: Int] = [:]
        for item in items where item.amount > 0 { merged[item.label, default: 0] += item.amount }
        let sorted = merged.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let total = sorted.reduce(0) { $0 + $1.value }
        guard total > 0 else { return [] }
        let keep = max(limit, 1)
        var slices = sorted.prefix(keep).map {
            LedgerReportCategorySlice(label: $0.key, amount: $0.value, share: Double($0.value) / Double(total), isOther: false)
        }
        if sorted.count > keep {
            let rest = sorted.dropFirst(keep).reduce(0) { $0 + $1.value }
            slices.append(LedgerReportCategorySlice(label: otherLabel, amount: rest,
                share: Double(rest) / Double(total), isOther: true))
        }
        return slices
    }

    /// Which days up to `today` have a transaction and which are blank. Days
    /// after today are neither, so a running period isn't full of gaps.
    static func coverage(_ period: LedgerReportPeriod, recordedDays: Set<String>, today: String,
                         calendar: LedgerReportCalendar) -> LedgerReportCoverage {
        let elapsed = calendar.days(in: period).filter { $0 <= today }
        let blank = elapsed.filter { !recordedDays.contains($0) }
        return LedgerReportCoverage(elapsedDays: elapsed.count, recordedDays: elapsed.count - blank.count, blankDays: blank)
    }

    /// Ranges longer than this chart by week instead of by day.
    static let dailyBucketLimit = 62

    /// The period's spending per day, or per week for long custom ranges.
    static func buckets(_ period: LedgerReportPeriod, daily: [String: (amount: Int, count: Int)],
                        calendar: LedgerReportCalendar) -> [LedgerReportBucket] {
        let days = calendar.days(in: period)
        if days.count <= dailyBucketLimit {
            return days.map { LedgerReportBucket(start: $0, amount: daily[$0]?.amount ?? 0, transactionCount: daily[$0]?.count ?? 0) }
        }
        var buckets: [LedgerReportBucket] = []
        var currentStart: String?
        var amount = 0
        var count = 0
        for day in days {
            guard let date = calendar.day(day) else { continue }
            let weekStart = calendar.week(containing: date).start
            let bucketStart = max(weekStart, period.start)
            if currentStart != bucketStart {
                if let currentStart { buckets.append(LedgerReportBucket(start: currentStart, amount: amount, transactionCount: count)) }
                currentStart = bucketStart
                amount = 0
                count = 0
            }
            amount += daily[day]?.amount ?? 0
            count += daily[day]?.count ?? 0
        }
        if let currentStart { buckets.append(LedgerReportBucket(start: currentStart, amount: amount, transactionCount: count)) }
        return buckets
    }

    /// The period's largest expenses. Only transactions in `currency` are
    /// ranked: there is no per-transaction conversion to compare others.
    static func largestExpenses(_ transactions: [LedgerTransaction], currency: String,
                                limit: Int = 5) -> [LedgerReportLargestExpense] {
        transactions.compactMap { transaction -> LedgerReportLargestExpense? in
            let presentation = TransactionPresentation(transaction: transaction)
            guard presentation.kind == .expense, !presentation.isRefund,
                  presentation.currency == currency, presentation.minorUnits > 0 else { return nil }
            return LedgerReportLargestExpense(transaction: transaction, title: presentation.title,
                date: transaction.date, minorUnits: presentation.minorUnits)
        }
        .sorted { $0.minorUnits != $1.minorUnits ? $0.minorUnits > $1.minorUnits : $0.date > $1.date }
        .prefix(max(limit, 0))
        .map { $0 }
    }
}

/// One period's report, ready to draw.
struct LedgerReportData: Equatable, Sendable {
    let period: LedgerReportPeriod
    let previousPeriod: LedgerReportPeriod
    let currency: String
    let income: Int
    let expense: Int
    let previousIncome: Int
    let previousExpense: Int
    let categories: [LedgerReportCategorySlice]
    let buckets: [LedgerReportBucket]
    let largest: [LedgerReportLargestExpense]
    let coverage: LedgerReportCoverage
    /// The transaction scan stopped at its cap, so 最大几笔 and 记账情况 may miss some.
    let isTruncated: Bool

    var net: Int { income - expense }
    var previousNet: Int { previousIncome - previousExpense }
    var expenseChange: Double? { LedgerReportMath.changeRatio(current: expense, previous: previousExpense) }
    var incomeChange: Double? { LedgerReportMath.changeRatio(current: income, previous: previousIncome) }
    var netChange: Double? { LedgerReportMath.changeRatio(current: net, previous: previousNet) }
}

// MARK: - Receipt

/// What the exported receipt leaves out. `amountsAllowed` is false while the
/// app hides amounts or the ledger is locked; then only shares can be printed.
struct LedgerReportReceiptOptions: Equatable, Hashable, Sendable {
    var hidesIncome = true
    var hidesNet = false
    var sharesOnly = false
    var hidesDetails = false
    var sections: Set<LedgerReportSection> = Set(LedgerReportSection.allCases.filter(\.appearsOnReceipt))

    func enforcing(amountsAllowed: Bool) -> Self {
        var options = self
        if !amountsAllowed { options.sharesOnly = true }
        return options
    }
}

/// The receipt's text, with hidden fields already removed, so neither the
/// image nor anything else can print them.
struct LedgerReportReceipt: Equatable, Sendable {
    struct Line: Equatable, Hashable, Sendable {
        let label: String
        let value: String
        /// 0 to 1 for a bar under the line, if any.
        var bar: Double?
    }

    struct Block: Equatable, Sendable {
        let section: LedgerReportSection
        let lines: [Line]
    }

    let title: String
    let periodLabel: String
    let blocks: [Block]
    let footer: String

    /// Every string the receipt prints.
    var printedText: [String] {
        [title, periodLabel, footer] + blocks.flatMap { [$0.section.title] + $0.lines.flatMap { [$0.label, $0.value] } }
    }

    static func build(_ data: LedgerReportData, options: LedgerReportReceiptOptions, periodLabel: String,
                      dayLabel: (String) -> String, generatedAt: String,
                      amountsAllowed: Bool) -> LedgerReportReceipt {
        let options = options.enforcing(amountsAllowed: amountsAllowed)
        let money: (Int) -> String = { MoneyText.format(minorUnits: $0, currency: data.currency) }
        let percent: (Double) -> String = { String(format: "%.0f%%", ($0 * 100).rounded()) }
        let change: (Double?) -> String = { ratio in
            guard let ratio else { return "—" }
            let arrow = ratio > 0 ? "↑" : ratio < 0 ? "↓" : "→"
            return arrow + percent(abs(ratio))
        }

        var blocks: [Block] = []
        for section in LedgerReportSection.allCases where section.appearsOnReceipt && options.sections.contains(section) {
            var lines: [Line] = []
            switch section {
            case .overview:
                if options.sharesOnly {
                    lines.append(Line(label: String(localized: "支出较上期"), value: change(data.expenseChange)))
                } else {
                    lines.append(Line(label: String(localized: "支出"), value: money(data.expense)))
                    lines.append(Line(label: String(localized: "较上期"), value: change(data.expenseChange)))
                    if !options.hidesIncome {
                        lines.append(Line(label: String(localized: "收入"), value: money(data.income)))
                    }
                    if !options.hidesNet {
                        lines.append(Line(label: String(localized: "结余"),
                            value: (data.net < 0 ? "−" : "") + money(abs(data.net))))
                    }
                }
            case .categories:
                lines = data.categories.map {
                    Line(label: $0.label, value: options.sharesOnly ? percent($0.share) : money($0.amount), bar: $0.share)
                }
            case .daily:
                let peak = max(data.buckets.map(\.amount).max() ?? 0, 1)
                lines = data.buckets.map {
                    Line(label: dayLabel($0.start), value: options.sharesOnly ? "" : money($0.amount),
                         bar: Double(max($0.amount, 0)) / Double(peak))
                }
            case .largest:
                lines = data.largest.enumerated().map { index, item in
                    let label = options.hidesDetails ? String(localized: "第 \(index + 1) 笔") : item.title
                    let value: String
                    if options.sharesOnly {
                        value = data.expense > 0 ? percent(Double(item.minorUnits) / Double(data.expense)) : ""
                    } else {
                        value = money(item.minorUnits)
                    }
                    return Line(label: options.hidesDetails ? label : "\(dayLabel(item.date)) \(label)", value: value)
                }
            case .coverage:
                lines.append(Line(label: String(localized: "有记录"),
                    value: String(localized: "\(data.coverage.recordedDays) / \(data.coverage.elapsedDays) 天")))
                if !data.coverage.blankDays.isEmpty {
                    lines.append(Line(label: String(localized: "空白"),
                        value: String(localized: "\(data.coverage.blankDays.count) 天")))
                }
            case .assistant:
                break
            }
            if !lines.isEmpty { blocks.append(Block(section: section, lines: lines)) }
        }
        let title = data.period.kind == .month ? String(localized: "Ledger 月报")
            : data.period.kind == .week ? String(localized: "Ledger 周报") : String(localized: "Ledger 收支报告")
        return LedgerReportReceipt(title: title, periodLabel: periodLabel, blocks: blocks,
            footer: String(localized: "生成于 \(generatedAt)"))
    }
}
