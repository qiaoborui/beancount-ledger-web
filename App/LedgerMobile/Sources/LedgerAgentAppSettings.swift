import Foundation

// The App's own settings — the overview's blocks, the bottom tabs, the
// valuation currency, the reminders and the reports — are kept in
// `UserDefaults`, not in the ledger, so the file tools cannot reach them. The
// assistant reads them as one JSON snapshot per turn and changes them through
// the native settings tools; the shell applies the sections a turn changed and
// can put them back.
//
// The Go side (`server/mobileagent/app_settings.go`) is the other half of this
// wire format, and its guide and validation are the source of truth for what
// each field accepts: both files must be edited together.

/// One snapshot of the App settings, grouped the way the native tools take
/// them. Values are the raw ids the app stores, so a snapshot survives a build
/// that renames a title.
struct LedgerAgentAppSettings: Codable, Equatable, Sendable {
    struct Overview: Codable, Equatable, Sendable {
        /// The blocks the overview shows, in order; a block left out is hidden.
        var sections: [String]
    }

    struct Tabs: Codable, Equatable, Sendable {
        /// The tabs beside 更多, one to three of them.
        var tabs: [String]
    }

    struct Valuation: Codable, Equatable, Sendable {
        /// The currency amounts are converted to.
        var currency: String
    }

    struct Reminders: Codable, Equatable, Sendable {
        struct Bookkeeping: Codable, Equatable, Sendable {
            var enabled: Bool
            /// HH:MM, 24-hour.
            var time: String
            /// daily, weekdays or custom.
            var repeatRule: String
            /// `Calendar` numbering: 1 is Sunday. Follows `repeatRule` unless
            /// it is custom, which the native side enforces.
            var days: [Int]
            /// Skip today's reminder once the ledger has a transaction today.
            var skipsRecordedDays: Bool

            private enum CodingKeys: String, CodingKey {
                case enabled, time, skipsRecordedDays
                case repeatRule = "repeat"
                case days
            }
        }

        struct Imports: Codable, Equatable, Sendable {
            var enabled: Bool
            /// weekly or monthly.
            var cadence: String
            /// `Calendar` numbering: 1 is Sunday; used by a weekly cadence.
            var weekday: Int
            /// 1 to 28, or -1 for the month's last day; used by a monthly one.
            var day: Int
            /// HH:MM, 24-hour.
            var time: String
        }

        var bookkeeping: Bookkeeping
        var imports: Imports
    }

    struct Reports: Codable, Equatable, Sendable {
        struct Weekly: Codable, Equatable, Sendable {
            var enabled: Bool
            /// `Calendar` numbering: 1 is Sunday.
            var weekday: Int
            var time: String
        }

        struct Monthly: Codable, Equatable, Sendable {
            var enabled: Bool
            /// 1 to 28, or -1 for the month's last day.
            var day: Int
            var time: String
        }

        struct Section: Codable, Equatable, Sendable {
            var id: String
            var visible: Bool
        }

        var weekly: Weekly
        var monthly: Monthly
        /// Ask for a 导入账单 reminder the evening before every report.
        var importReminderBeforeReport: Bool
        /// `Calendar` numbering: 1 is Sunday.
        var firstWeekday: Int
        /// Every report section, in the order the report prints them.
        var sections: [Section]
    }

    var overview: Overview
    var tabs: Tabs
    var valuation: Valuation
    var reminders: Reminders
    var reports: Reports

    /// The keys the screens already write; the snapshot reads the same values.
    enum Keys {
        static let overviewSections = "ledger.mobile.overview-sections"
        static let compactTabs = "ledger.mobile.compact-tabs"
    }
}

/// A setting area the assistant may change. The title is what the chat calls
/// it in the row under an answer.
enum LedgerAgentAppSettingsSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case overview
    case tabs
    case valuation
    case reminders
    case reports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "首页布局")
        case .tabs: String(localized: "底部标签")
        case .valuation: String(localized: "估值币种")
        case .reminders: String(localized: "提醒")
        case .reports: String(localized: "周报月报")
        }
    }
}

/// A value that does not fit, said in words the model can act on.
struct LedgerAgentAppSettingsError: LocalizedError, Equatable {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

/// What one answer changed, and what the settings were before, so the row
/// under the answer can put them back.
struct LedgerAgentAppSettingsChange: Codable, Equatable, Sendable {
    /// The sections this answer changed.
    var sections: [LedgerAgentAppSettingsSection]
    /// The snapshot before the change. Undo writes back only `sections`.
    var previous: LedgerAgentAppSettings
    var undoneAt: Date? = nil

    /// 首页布局、提醒 — the sections as one line.
    var titles: String { sections.map(\.title).joined(separator: "、") }
}

/// The App settings a turn changed, as the native loop reports them.
struct LedgerAgentAppSettingsUpdate: Decodable, Equatable, Sendable {
    let snapshot: LedgerAgentAppSettings
    let changedSections: [LedgerAgentAppSettingsSection]

    init(snapshot: LedgerAgentAppSettings, changedSections: [LedgerAgentAppSettingsSection]) {
        self.snapshot = snapshot
        self.changedSections = changedSections
    }

    private enum CodingKeys: String, CodingKey { case snapshot, changedSections }

    /// A section this build does not know is dropped, not the whole change: the
    /// rest of the settings still apply.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try values.decode(LedgerAgentAppSettings.self, forKey: .snapshot)
        changedSections = (try values.decodeIfPresent([String].self, forKey: .changedSections) ?? [])
            .compactMap(LedgerAgentAppSettingsSection.init(rawValue:))
    }
}

/// What applying one change managed: the sections written and the ones that
/// did not fit, each failure said in the user's words.
struct LedgerAgentAppSettingsApply: Equatable, Sendable {
    var applied: [LedgerAgentAppSettingsSection] = []
    var failures: [String] = []

    var isEmpty: Bool { applied.isEmpty && failures.isEmpty }
}

/// A section's values worked out for the app, before anything is written, so a
/// value that does not fit fails the whole section instead of half of it.
enum LedgerAgentAppSettingsPlan {
    case overview([OverviewSection])
    case tabs([LedgerDestination])
    case valuation(String)
    case reminders(LedgerReminderSettings)
    case reports(LedgerReportSettings)
}

// MARK: - Reading

extension LedgerAgentAppSettings {
    /// The settings as the screens have them now.
    static func load(defaults: UserDefaults = .standard, valuationCurrency: String) -> Self {
        let reminders = LedgerReminderSettings.load(from: defaults)
        let reports = LedgerReportSettings.load(from: defaults)
        return LedgerAgentAppSettings(
            overview: .init(sections: overviewSections(defaults: defaults).map(\.rawValue)),
            tabs: .init(tabs: compactTabs(defaults: defaults).map(\.rawValue)),
            valuation: .init(currency: valuationCurrency),
            reminders: .init(bookkeeping: .init(enabled: reminders.bookkeeping.isEnabled,
                                               time: reminders.bookkeeping.time.text,
                                               repeatRule: Self.rawValue(of: reminders.bookkeeping.repeats),
                                               days: reminders.bookkeeping.repeats.days.sorted(),
                                               skipsRecordedDays: reminders.bookkeeping.skipsRecordedDays),
                              imports: .init(enabled: reminders.imports.isEnabled,
                                             cadence: Self.rawValue(of: reminders.imports.cadence),
                                             weekday: Self.weekday(of: reminders.imports.cadence),
                                             day: Self.day(of: reminders.imports.cadence),
                                             time: reminders.imports.time.text)),
            reports: .init(weekly: .init(enabled: reports.weekly.isEnabled, weekday: reports.weekly.weekday,
                                         time: reports.weekly.time.text),
                           monthly: .init(enabled: reports.monthly.isEnabled, day: Self.day(of: reports.monthly.day),
                                          time: reports.monthly.time.text),
                           importReminderBeforeReport: reports.remindsImportBeforeReport,
                           firstWeekday: reports.firstWeekday,
                           sections: LedgerReportSectionPreference.normalized(reports.sections).map {
                               .init(id: $0.section.rawValue, visible: $0.isVisible)
                           }))
    }

    static func overviewSections(defaults: UserDefaults = .standard) -> [OverviewSection] {
        guard let raw = defaults.stringArray(forKey: Keys.overviewSections) else { return OverviewSection.defaultSections }
        return OverviewSection.normalized(raw.compactMap(OverviewSection.init(rawValue:)))
    }

    static func compactTabs(defaults: UserDefaults = .standard) -> [LedgerDestination] {
        guard let raw = defaults.stringArray(forKey: Keys.compactTabs) else { return LedgerDestination.defaultCompactTabs }
        return LedgerDestination.migratedCompactTabs(raw.compactMap(LedgerDestination.init(rawValue:)))
    }

    private static func rawValue(of repeats: LedgerReminderRepeat) -> String {
        switch repeats {
        case .daily: "daily"
        case .weekdays: "weekdays"
        case .custom: "custom"
        }
    }

    private static func rawValue(of cadence: LedgerImportReminderCadence) -> String {
        switch cadence {
        case .weekly: "weekly"
        case .monthly: "monthly"
        }
    }

    private static func weekday(of cadence: LedgerImportReminderCadence) -> Int {
        if case let .weekly(weekday) = cadence { return weekday }
        return 1
    }

    private static func day(of cadence: LedgerImportReminderCadence) -> Int {
        if case let .monthly(day) = cadence { return day(of: day) }
        return 1
    }

    /// 1 to 28, or -1 for the month's last day. A day of 29 or more is stored
    /// by older builds; it is sent as the 28th, which every month has.
    private static func day(of day: LedgerReminderMonthDay) -> Int {
        switch day {
        case .last: -1
        case let .day(value): min(max(value, 1), 28)
        }
    }
}

// MARK: - Validation

extension LedgerAgentAppSettings {
    /// The values of one section, checked the way the screen checks them and
    /// worked out as the app's own types. Throws the first problem in the
    /// section, worded so the model can correct it.
    func plan(for section: LedgerAgentAppSettingsSection,
              in defaults: UserDefaults = .standard) throws -> LedgerAgentAppSettingsPlan {
        switch section {
        case .overview:
            guard !overview.sections.isEmpty else {
                throw LedgerAgentAppSettingsError(String(localized: "首页至少要显示一个分区；要恢复默认就把九个分区都列出来"))
            }
            var seen = Set<OverviewSection>()
            var values: [OverviewSection] = []
            for id in overview.sections {
                guard let value = OverviewSection(rawValue: id) else {
                    throw LedgerAgentAppSettingsError(String(localized: "首页没有叫 \(id) 的分区；可以填 \(Self.overviewIds)"))
                }
                guard seen.insert(value).inserted else {
                    throw LedgerAgentAppSettingsError(String(localized: "首页分区 \(id) 出现了两次"))
                }
                values.append(value)
            }
            return .overview(OverviewSection.normalized(values))

        case .tabs:
            let limit = LedgerDestination.compactTabLimit
            guard !tabs.tabs.isEmpty, tabs.tabs.count <= limit else {
                throw LedgerAgentAppSettingsError(String(localized: "底部标签要 \(1) 到 \(limit) 个"))
            }
            var seen = Set<LedgerDestination>()
            var values: [LedgerDestination] = []
            for id in tabs.tabs {
                guard let value = LedgerDestination(rawValue: id),
                      LedgerDestination.compactTabCandidates.contains(value) else {
                    throw LedgerAgentAppSettingsError(String(localized: "底部标签不能是 \(id)；可以填 \(Self.tabIds)"))
                }
                guard seen.insert(value).inserted else {
                    throw LedgerAgentAppSettingsError(String(localized: "底部标签 \(id) 出现了两次"))
                }
                values.append(value)
            }
            return .tabs(LedgerDestination.normalizedCompactTabs(values))

        case .valuation:
            let currency = valuation.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard currency.range(of: "^[A-Z][A-Z0-9._-]{0,22}[A-Z0-9]$", options: .regularExpression) != nil else {
                throw LedgerAgentAppSettingsError(String(localized: "估值币种要写成 CNY、USD、HKD 这样的三字母代码"))
            }
            return .valuation(currency)

        case .reminders:
            let bookkeeping = reminders.bookkeeping
            let time = try Self.time(bookkeeping.time, at: String(localized: "记账提醒的时间"))
            let repeats: LedgerReminderRepeat
            switch bookkeeping.repeatRule {
            case "daily": repeats = .daily
            case "weekdays": repeats = .weekdays
            case "custom":
                var days = Set<Int>()
                guard !bookkeeping.days.isEmpty else {
                    throw LedgerAgentAppSettingsError(String(localized: "自定义星期要列出至少一天，1 是周日、7 是周六"))
                }
                for day in bookkeeping.days {
                    guard (1...7).contains(day) else {
                        throw LedgerAgentAppSettingsError(String(localized: "星期 \(day) 不对；1 是周日，7 是周六"))
                    }
                    guard days.insert(day).inserted else {
                        throw LedgerAgentAppSettingsError(String(localized: "星期 \(day) 出现了两次"))
                    }
                }
                repeats = .custom(days)
            default:
                throw LedgerAgentAppSettingsError(String(localized: "记账提醒的重复方式只能是 daily（每天）、weekdays（工作日）或 custom（自定义星期）"))
            }
            let imports = reminders.imports
            let importTime = try Self.time(imports.time, at: String(localized: "导入提醒的时间"))
            let cadence: LedgerImportReminderCadence
            switch imports.cadence {
            case "weekly":
                guard (1...7).contains(imports.weekday) else {
                    throw LedgerAgentAppSettingsError(String(localized: "导入提醒的星期 \(imports.weekday) 不对；1 是周日，7 是周六"))
                }
                cadence = .weekly(weekday: imports.weekday)
            case "monthly":
                cadence = .monthly(day: try Self.monthDay(imports.day, at: String(localized: "导入提醒的日期")))
            default:
                throw LedgerAgentAppSettingsError(String(localized: "导入提醒只能是 weekly（每周）或 monthly（每月）"))
            }
            return .reminders(LedgerReminderSettings(
                bookkeeping: .init(isEnabled: bookkeeping.enabled, time: time, repeats: repeats,
                                   skipsRecordedDays: bookkeeping.skipsRecordedDays),
                imports: .init(isEnabled: imports.enabled, cadence: cadence, time: importTime)))

        case .reports:
            let weekly = reports.weekly
            let monthly = reports.monthly
            guard (1...7).contains(weekly.weekday) else {
                throw LedgerAgentAppSettingsError(String(localized: "周报的星期 \(weekly.weekday) 不对；1 是周日，7 是周六"))
            }
            guard reports.firstWeekday == 1 || reports.firstWeekday == 2 else {
                throw LedgerAgentAppSettingsError(String(localized: "一周从哪天开始只能是 1（周日）或 2（周一）"))
            }
            var seen = Set<LedgerReportSection>()
            var preferences: [LedgerReportSectionPreference] = []
            for item in reports.sections {
                guard let section = LedgerReportSection(rawValue: item.id) else {
                    throw LedgerAgentAppSettingsError(
                        String(localized: "报告没有叫 \(item.id) 的分区；要按顺序列出全部六项：\(Self.reportIds)"))
                }
                guard seen.insert(section).inserted else {
                    throw LedgerAgentAppSettingsError(String(localized: "报告分区 \(item.id) 出现了两次"))
                }
                preferences.append(.init(section: section, isVisible: item.visible))
            }
            for section in LedgerReportSection.allCases where !seen.contains(section) {
                throw LedgerAgentAppSettingsError(
                    String(localized: "报告分区缺少 \(section.rawValue)；要按顺序列出全部六项，不要的写 visible false"))
            }
            // Keep what the agent cannot change: the once-only offer flag.
            var value = LedgerReportSettings.load(from: defaults)
            value.weekly = .init(isEnabled: weekly.enabled, weekday: weekly.weekday,
                                 time: try Self.time(weekly.time, at: String(localized: "周报的时间")))
            value.monthly = .init(isEnabled: monthly.enabled,
                                  day: try Self.monthDay(monthly.day, at: String(localized: "月报的日期")),
                                  time: try Self.time(monthly.time, at: String(localized: "月报的时间")))
            value.remindsImportBeforeReport = reports.importReminderBeforeReport
            value.firstWeekday = reports.firstWeekday
            value.sections = LedgerReportSectionPreference.normalized(preferences)
            return .reports(value)
        }
    }

    /// HH:MM, 24-hour, exactly as the notifications take it.
    static func time(_ text: String, at field: String) throws -> LedgerReminderTime {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw LedgerAgentAppSettingsError(String(localized: "\(field)要写成 24 小时制的 HH:MM，例如 22:00"))
        }
        return LedgerReminderTime(hour: hour, minute: minute)
    }

    /// 1 to 28, which every month has, or -1 for the month's last day.
    static func monthDay(_ value: Int, at field: String) throws -> LedgerReminderMonthDay {
        if value == -1 { return .last }
        guard (1...28).contains(value) else {
            throw LedgerAgentAppSettingsError(String(localized: "\(field)要是 1 到 28 或 -1（当月最后一天）"))
        }
        return .day(value)
    }

    private static var overviewIds: String { OverviewSection.allCases.map(\.rawValue).joined(separator: "、") }
    private static var tabIds: String { LedgerDestination.compactTabCandidates.map(\.rawValue).joined(separator: "、") }
    private static var reportIds: String { LedgerReportSection.allCases.map(\.rawValue).joined(separator: "、") }
}

// MARK: - Applying

/// Where the App's settings live for one conversation: the snapshot a turn
/// sends, and the writes of the sections it changed.
struct LedgerAgentAppSettingsHost: Sendable {
    /// The settings as they are now.
    var snapshot: @MainActor @Sendable () -> LedgerAgentAppSettings
    /// Writes the listed sections of `settings` through the same setters the
    /// settings screens use, so their side effects (a rescheduled reminder, a
    /// ledger re-read in another currency) happen too.
    var apply: @MainActor @Sendable (LedgerAgentAppSettings, [LedgerAgentAppSettingsSection]) async
        -> LedgerAgentAppSettingsApply
}

#if os(iOS)
extension LedgerAgentAppSettingsHost {
    /// The live settings of this app. Only the domains with plain values are
    /// here: credentials, the privacy lock and the consent-gated import
    /// classifier stay in their own screens.
    @MainActor
    static func live(_ session: LedgerSession, defaults: UserDefaults = .standard) -> Self {
        Self(snapshot: {
            LedgerAgentAppSettings.load(defaults: defaults,
                valuationCurrency: session.ledger?.valuationCurrency ?? "CNY")
        }, apply: { settings, sections in
            var result = LedgerAgentAppSettingsApply()
            for section in sections {
                do {
                    switch try settings.plan(for: section, in: defaults) {
                    case let .overview(values):
                        session.setOverviewSections(values)
                    case let .tabs(values):
                        session.setCompactTabDestinations(values)
                    case let .valuation(currency):
                        // The currency is a display choice the session re-reads
                        // the ledger for; nothing else writes it.
                        await session.setValuationCurrency(currency)
                        guard session.ledger?.valuationCurrency == currency else {
                            throw LedgerAgentAppSettingsError(String(localized: "没能把估值币种改成 \(currency)"))
                        }
                    case let .reminders(values):
                        LedgerLocalReminders.shared.update { $0 = values }
                    case let .reports(values):
                        values.save(to: defaults)
                        LedgerReportReminders.settingsChanged()
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
#endif
