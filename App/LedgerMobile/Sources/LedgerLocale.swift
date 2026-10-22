import Foundation

/// Locale for every user-visible date, number, and amount.
///
/// Strings come from the String Catalog in the language iOS picked for the app
/// bundle. Formatting follows that same language with the device region, so an
/// English interface on a device set to another language does not mix in that
/// language's month names. Ledger data (dates, amounts, account names written
/// to `.bean` files) keeps `en_US_POSIX` and never goes through this locale.
enum LedgerLocale {
    /// Resolved once per launch; iOS restarts the app when its language changes.
    static let current: Locale = resolve()

    /// Chinese interfaces use 万/亿-based compact amounts; others use k/M/B.
    static var usesChineseNumberUnits: Bool {
        current.language.languageCode == .chinese
    }

    private static func resolve() -> Locale {
        // Unit tests and command-line tools run outside the app bundle; keep the
        // source-language formatting so their expectations stay deterministic.
        let bundleExtension = Bundle.main.bundleURL.pathExtension
        guard bundleExtension == "app" || bundleExtension == "appex" else {
            return Locale(identifier: "zh_CN")
        }
        guard let language = Bundle.main.preferredLocalizations.first else { return .autoupdatingCurrent }
        var components = Locale.Components(locale: .autoupdatingCurrent)
        components.languageComponents = Locale.Language.Components(identifier: language)
        return Locale(components: components)
    }
}

/// Localized date labels shared by lists, headers, and widgets.
enum LedgerDateLabel {
    /// "10月22日" / "Oct 22"
    static func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(LedgerLocale.current))
    }

    /// "2026年10月22日" / "Oct 22, 2026"
    static func yearMonthDay(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().locale(LedgerLocale.current))
    }

    /// "2026年10月" / "October 2026"
    static func yearMonth(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.wide).locale(LedgerLocale.current))
    }

    /// "10月" / "October"
    static func month(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).locale(LedgerLocale.current))
    }

    /// "3月" / "Mar" for a month number (1 = January).
    static func month(number: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = LedgerLocale.current
        let symbols = calendar.shortMonthSymbols
        return symbols[max(0, min(symbols.count - 1, number - 1))]
    }

    /// "周三" / "Wed"
    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(LedgerLocale.current))
    }

    /// Weekday label for a `Calendar` weekday number (1 = Sunday).
    static func weekday(number: Int) -> String {
        let symbols = shortWeekdaySymbols
        return symbols[max(0, min(symbols.count - 1, number - 1))]
    }

    /// "周日"…"周六" / "Sun"…"Sat", starting on Sunday like `Calendar.weekday`.
    static var shortWeekdaySymbols: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = LedgerLocale.current
        return calendar.shortWeekdaySymbols
    }

    /// "日"…"六" / "S"…"S", starting on Sunday.
    static var veryShortWeekdaySymbols: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = LedgerLocale.current
        return calendar.veryShortWeekdaySymbols
    }
}

/// The app's own language choice.
///
/// iOS shows its per-app language picker only when the device lists more than
/// one preferred language, so a device set to English alone has no way back to
/// Chinese. The app stores the choice as its own `AppleLanguages` default, which
/// iOS reads at the next launch.
enum LedgerAppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    private static let defaultsKey = "AppleLanguages"

    var id: String { rawValue }

    /// Language names stay in their own language so they read the same in every UI.
    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    /// Only the app's own domain counts; `UserDefaults.standard` would also
    /// return the device-wide list.
    static func current(in defaults: UserDefaults = .standard) -> LedgerAppLanguage {
        guard let identifier = Bundle.main.bundleIdentifier,
              let languages = defaults.persistentDomain(forName: identifier)?[defaultsKey] as? [String],
              let first = languages.first else { return .system }
        return allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
    }

    func apply(to defaults: UserDefaults = .standard) {
        if self == .system {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set([rawValue], forKey: Self.defaultsKey)
        }
    }
}
