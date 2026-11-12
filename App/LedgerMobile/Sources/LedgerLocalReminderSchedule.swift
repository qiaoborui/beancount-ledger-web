import Foundation

// Local reminders, as plain values and pure functions.
//
// Everything here decides *what* should be pending in the notification
// center; `LedgerLocalReminders` (app target) only hands the result to
// `UNUserNotificationCenter`. Every reminder is scheduled as a one-off
// `UNCalendarNotificationTrigger` for a concrete minute over a short horizon,
// and the whole set is rebuilt on every reschedule (foreground, ledger write,
// settings change). That lets 智能跳过 drop just today's 记账提醒, lets other
// features add reminders of their own, and keeps the count far below iOS's 64
// pending notifications.
//
// Other features (周报 / 月报) plug in through `LedgerReminderContribution`:
// they add their own occurrences and ask for 导入账单 reminders before them,
// which the planner merges with the user's own import reminder so the two never
// arrive together.

/// What a reminder is for. Also the priority when two fall on the same minute:
/// only the highest is kept.
enum LedgerReminderKind: String, Codable, CaseIterable, Sendable {
    case bookkeeping
    case importBills
    case report

    var priority: Int {
        switch self {
        case .bookkeeping: 0
        case .importBills: 1
        case .report: 2
        }
    }
}

/// A time of day in the device's calendar.
struct LedgerReminderTime: Codable, Equatable, Hashable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    var text: String { String(format: "%02d:%02d", hour, minute) }
}

/// A day of the month: 1 to 28, so every month has it, or the month's last day.
enum LedgerReminderMonthDay: Codable, Equatable, Hashable, Sendable {
    case day(Int)
    case last

    /// The day within a month that has `daysInMonth` days.
    func resolved(daysInMonth: Int) -> Int {
        switch self {
        case let .day(day): min(max(day, 1), min(28, daysInMonth))
        case .last: daysInMonth
        }
    }
}

/// Which days of the week a 记账提醒 fires on. Weekdays use `Calendar`
/// numbering: 1 is Sunday, 2 Monday … 7 Saturday.
enum LedgerReminderRepeat: Codable, Equatable, Hashable, Sendable {
    case daily
    case weekdays
    case custom(Set<Int>)

    var days: Set<Int> {
        switch self {
        case .daily: Set(1...7)
        case .weekdays: Set(2...6)
        case let .custom(days): days.filter { (1...7).contains($0) }
        }
    }
}

struct LedgerBookkeepingReminderSettings: Codable, Equatable, Sendable {
    var isEnabled = false
    var time = LedgerReminderTime(hour: 21, minute: 30)
    var repeats: LedgerReminderRepeat = .daily
    /// Skip today's reminder once the ledger has a transaction dated today.
    var skipsRecordedDays = true
}

enum LedgerImportReminderCadence: Codable, Equatable, Hashable, Sendable {
    /// `weekday` uses `Calendar` numbering (1 is Sunday).
    case weekly(weekday: Int)
    case monthly(LedgerReminderMonthDay)
}

struct LedgerImportReminderSettings: Codable, Equatable, Sendable {
    var isEnabled = false
    var cadence: LedgerImportReminderCadence = .weekly(weekday: 1)
    var time = LedgerReminderTime(hour: 20, minute: 0)
}

/// The user's reminder choices, kept in `UserDefaults` as one JSON value.
struct LedgerReminderSettings: Codable, Equatable, Sendable {
    var bookkeeping = LedgerBookkeepingReminderSettings()
    var imports = LedgerImportReminderSettings()

    static let defaultsKey = "ledger.reminders.settings.v1"

    var anyEnabled: Bool { bookkeeping.isEnabled || imports.isEnabled }

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

/// One notification to be pending: a concrete minute, its wording, and where a
/// tap on the notification itself goes. Action buttons come from the category.
struct LedgerReminderOccurrence: Equatable, Sendable, Identifiable {
    let kind: LedgerReminderKind
    let fireDate: Date
    let title: String
    let body: String
    let categoryIdentifier: String
    /// A `ledger://` link, opened through `LedgerExternalRoute`.
    let url: URL
    /// Distinguishes several reminders of one kind, e.g. 周报 and 月报.
    let tag: String

    init(kind: LedgerReminderKind, fireDate: Date, title: String, body: String,
         categoryIdentifier: String, url: URL, tag: String = "") {
        self.kind = kind
        self.fireDate = fireDate
        self.title = title
        self.body = body
        self.categoryIdentifier = categoryIdentifier
        self.url = url
        self.tag = tag
    }

    /// The notification request identifier. Every pending reminder carries
    /// `LedgerReminderNotification.identifierPrefix`, so a reschedule can
    /// replace exactly its own requests.
    var id: String {
        let minute = Int(fireDate.timeIntervalSince1970 / 60)
        let suffix = tag.isEmpty ? "" : "." + tag
        return LedgerReminderNotification.identifierPrefix + kind.rawValue + suffix + "." + String(minute)
    }
}

/// What another feature (周报 / 月报) adds to the reminder schedule.
struct LedgerReminderContribution: Equatable, Sendable {
    /// Its own notifications, e.g. 「上周的周报好了」.
    var occurrences: [LedgerReminderOccurrence]
    /// When a 导入账单 reminder should come before its own, e.g. the evening
    /// before a report. Merged with the user's import reminder: within
    /// `LedgerReminderPlanner.importMergeWindow` of one of these, the user's
    /// occurrence is dropped, so only one arrives.
    var importReminderDates: [Date]

    init(occurrences: [LedgerReminderOccurrence] = [], importReminderDates: [Date] = []) {
        self.occurrences = occurrences
        self.importReminderDates = importReminderDates
    }
}

/// Notification identifiers, categories, actions and the links they open.
enum LedgerReminderNotification {
    static let identifierPrefix = "ledger.reminder."
    static let thread = "ledger-reminder"

    static let bookkeepingCategory = "ledger.reminder.bookkeeping"
    static let importCategory = "ledger.reminder.import"
    /// For contributions that only need a tap, with no buttons.
    static let plainCategory = "ledger.reminder.plain"

    static let recordAction = "ledger.reminder.action.record"
    static let sentenceAction = "ledger.reminder.action.sentence"
    static let importAction = "ledger.reminder.action.import"

    static let urlKey = "ledger.reminder.url"

    static let recordURL = URL(string: "ledger://record")!
    static let sentenceURL = URL(string: "ledger://record?mode=sentence")!
    static let importsURL = URL(string: "ledger://imports")!

    static func isReminder(categoryIdentifier: String) -> Bool {
        categoryIdentifier.hasPrefix(identifierPrefix)
    }

    /// Where a tap goes: an action button's fixed page, else the link the
    /// notification carries. Only `ledger://` links are followed.
    static func url(forAction action: String, userInfo: [AnyHashable: Any]) -> URL? {
        switch action {
        case recordAction: return recordURL
        case sentenceAction: return sentenceURL
        case importAction: return importsURL
        default:
            guard let text = userInfo[urlKey] as? String, let url = URL(string: text),
                  url.scheme?.lowercased() == "ledger" else { return nil }
            return url
        }
    }
}

enum LedgerReminderPlanner {
    /// Leaves room under iOS's 64 for anything else the app schedules.
    static let maximumPending = 48
    /// 记账提醒 are scheduled day by day this far ahead. Every foreground visit
    /// and background sync extends it.
    static let bookkeepingHorizonDays = 14
    /// How many upcoming 导入账单 occurrences are kept pending.
    static let importOccurrenceCount = 3
    /// A user import reminder this close to a requested one is the same reminder.
    static let importMergeWindow: TimeInterval = 24 * 60 * 60

    /// Everything that should be pending after `now`, earliest first: at most
    /// one per minute and at most `maximumPending` in all.
    static func plan(settings: LedgerReminderSettings,
                     now: Date,
                     calendar: Calendar = .current,
                     recordedToday: Bool,
                     contributions: [LedgerReminderContribution] = []) -> [LedgerReminderOccurrence] {
        var all: [LedgerReminderOccurrence] = []
        if settings.bookkeeping.isEnabled {
            let skip = settings.bookkeeping.skipsRecordedDays && recordedToday
            all += bookkeepingDates(settings.bookkeeping, now: now, calendar: calendar, skippingToday: skip)
                .map(bookkeepingOccurrence)
        }
        let requested = contributions.flatMap(\.importReminderDates).filter { $0 > now }
        let user = settings.imports.isEnabled
            ? importDates(settings.imports, after: now, count: importOccurrenceCount, calendar: calendar) : []
        let merged = mergeImportDates(user: user, requested: requested)
        all += merged.map { importOccurrence($0.date, cadence: $0.requested ? nil : settings.imports.cadence) }
        all += contributions.flatMap(\.occurrences).filter { $0.fireDate > now }
        return limited(onePerMinute(all))
    }

    // MARK: Dates

    /// The days within the horizon on the reminder's weekdays, at its time.
    static func bookkeepingDates(_ settings: LedgerBookkeepingReminderSettings, now: Date,
                                 calendar: Calendar, skippingToday: Bool,
                                 horizonDays: Int = bookkeepingHorizonDays) -> [Date] {
        let weekdays = settings.repeats.days
        let today = calendar.startOfDay(for: now)
        return (0..<horizonDays).compactMap { offset -> Date? in
            guard offset > 0 || !skippingToday,
                  let day = calendar.date(byAdding: .day, value: offset, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let date = at(settings.time, on: day, calendar: calendar), date > now else { return nil }
            return date
        }
    }

    static func importDates(_ settings: LedgerImportReminderSettings, after now: Date,
                            count: Int, calendar: Calendar) -> [Date] {
        switch settings.cadence {
        case let .weekly(weekday): weeklyDates(weekday: weekday, time: settings.time, after: now, count: count, calendar: calendar)
        case let .monthly(day): monthlyDates(day: day, time: settings.time, after: now, count: count, calendar: calendar)
        }
    }

    /// The next `count` times on a weekday (1 is Sunday), strictly after `now`.
    static func weeklyDates(weekday: Int, time: LedgerReminderTime, after now: Date,
                            count: Int, calendar: Calendar) -> [Date] {
        guard (1...7).contains(weekday), count > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        var dates: [Date] = []
        var offset = 0
        while dates.count < count, offset < 7 * (count + 1) {
            if let day = calendar.date(byAdding: .day, value: offset, to: today),
               calendar.component(.weekday, from: day) == weekday,
               let date = at(time, on: day, calendar: calendar), date > now {
                dates.append(date)
            }
            offset += 1
        }
        return dates
    }

    /// The next `count` times on a day of the month, strictly after `now`.
    static func monthlyDates(day: LedgerReminderMonthDay, time: LedgerReminderTime, after now: Date,
                             count: Int, calendar: Calendar) -> [Date] {
        guard count > 0 else { return [] }
        let first = calendar.dateComponents([.year, .month], from: now)
        guard let monthStart = calendar.date(from: first) else { return [] }
        var dates: [Date] = []
        var offset = 0
        while dates.count < count, offset <= count + 1 {
            if let month = calendar.date(byAdding: .month, value: offset, to: monthStart),
               let days = calendar.range(of: .day, in: .month, for: month)?.count,
               let date = calendar.date(byAdding: .day, value: day.resolved(daysInMonth: days) - 1, to: month)
                .flatMap({ at(time, on: $0, calendar: calendar) }), date > now {
                dates.append(date)
            }
            offset += 1
        }
        return dates
    }

    /// Requested import reminders win: one within `window` of an earlier kept
    /// request is dropped, and so is a user occurrence within `window` of any
    /// kept request.
    static func mergeImportDates(user: [Date], requested: [Date],
                                 window: TimeInterval = importMergeWindow) -> [(date: Date, requested: Bool)] {
        var kept: [Date] = []
        for date in requested.sorted() where !kept.contains(where: { abs($0.timeIntervalSince(date)) < window }) {
            kept.append(date)
        }
        let users = user.filter { date in !kept.contains { abs($0.timeIntervalSince(date)) < window } }
        let all = kept.map { (date: $0, requested: true) } + users.map { (date: $0, requested: false) }
        return all.sorted { $0.date < $1.date }
    }

    static func at(_ time: LedgerReminderTime, on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        return calendar.date(from: components)
    }

    // MARK: Occurrences

    static func bookkeepingOccurrence(_ date: Date) -> LedgerReminderOccurrence {
        LedgerReminderOccurrence(kind: .bookkeeping, fireDate: date,
            title: String(localized: "今天的账记了吗？"),
            body: String(localized: "花一分钟，把今天的收支记下来。"),
            categoryIdentifier: LedgerReminderNotification.bookkeepingCategory,
            url: LedgerReminderNotification.recordURL)
    }

    /// `cadence` is nil for an import reminder another feature asked for.
    static func importOccurrence(_ date: Date, cadence: LedgerImportReminderCadence?) -> LedgerReminderOccurrence {
        let body: String
        switch cadence {
        case .weekly: body = String(localized: "把上周的微信 / 支付宝账单导进来吧。")
        case .monthly: body = String(localized: "把上个月的微信 / 支付宝账单导进来吧。")
        case nil: body = String(localized: "出报告前，把微信 / 支付宝账单导进来吧。")
        }
        return LedgerReminderOccurrence(kind: .importBills, fireDate: date,
            title: String(localized: "该导入账单了"), body: body,
            categoryIdentifier: LedgerReminderNotification.importCategory,
            url: LedgerReminderNotification.importsURL)
    }

    /// Of reminders on the same minute, only the highest-priority one stays.
    static func onePerMinute(_ occurrences: [LedgerReminderOccurrence]) -> [LedgerReminderOccurrence] {
        var best: [Int: LedgerReminderOccurrence] = [:]
        for occurrence in occurrences {
            let minute = Int(occurrence.fireDate.timeIntervalSince1970 / 60)
            if let current = best[minute], current.kind.priority >= occurrence.kind.priority { continue }
            best[minute] = occurrence
        }
        return best.values.sorted { $0.fireDate < $1.fireDate }
    }

    static func limited(_ occurrences: [LedgerReminderOccurrence]) -> [LedgerReminderOccurrence] {
        Array(occurrences.sorted { $0.fireDate < $1.fireDate }.prefix(maximumPending))
    }
}
