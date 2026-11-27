import Foundation

/// 配色方案: the surface and text tones every page is drawn in. Each scheme
/// has a light and a dark set and follows the system appearance; the user
/// picks one in 设置 › 外观. Income and expense text keeps the same hues in
/// every scheme; chart marks take the scheme's own `chart` colours.
///
/// This file is portable (no UIKit) so the package tests can check every
/// scheme's contrast. `BalancedPalette` turns the tokens into colours.
enum LedgerColorTheme: String, CaseIterable, Identifiable, Sendable {
    /// 素白: a near-white canvas with grey wells, monochrome ink, green only
    /// for income. The default since the 2026-11 modern theme.
    case clean
    /// The original Balanced ground: warm paper, warm near-black at night.
    case paper
    /// Pure white by day, true black by night, with neutral greys.
    case neutral
    /// A cool, faintly blue grey.
    case slate

    static let defaultTheme: LedgerColorTheme = .clean
    /// A new key for the modern theme, so everyone lands on 素白 once instead
    /// of keeping a scheme picked under the old look (`ledger.appearance.colorTheme`).
    static let defaultsKey = "ledger.appearance.theme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: String(localized: "素白")
        case .paper: String(localized: "暖纸")
        case .neutral: String(localized: "纯净")
        case .slate: String(localized: "冷灰")
        }
    }

    var detail: String {
        switch self {
        case .clean: String(localized: "干净的近白，夜间深黑，只用黑白灰")
        case .paper: String(localized: "米白纸感，夜间暖黑")
        case .neutral: String(localized: "纯白背景，夜间纯黑")
        case .slate: String(localized: "偏冷的浅灰，夜间蓝黑")
        }
    }

    func tokens(dark: Bool) -> LedgerThemeTokens {
        switch (self, dark) {
        case (.clean, false):
            LedgerThemeTokens(page: 0xFAFAFA, sunken: 0xF0F0F1, ink: 0x0B0B0C, secondary: 0x4A4A4F, meta: 0x6B6B71,
                              rule: 0xE8E8EA, ruleStrong: 0xD4D4D8, edge: 0x8A8A90, income: 0x0E7A45, expense: 0xC62F35,
                              card: 0xF0F0F1, well: 0xE5E5E7, selected: 0xE5E5E7,
                              chart: LedgerChartTokens(accent: 0x0B0B0C, income: 0x14995A, expense: 0xE5484D, series: [0x0B0B0C, 0xE5484D, 0x14995A, 0x3D6FE0, 0xB07612, 0x6B6B71]))
        case (.clean, true):
            LedgerThemeTokens(page: 0x0B0B0C, sunken: 0x19191B, ink: 0xF3F3F4, secondary: 0xC2C2C8, meta: 0x8E8E95,
                              rule: 0x1F1F21, ruleStrong: 0x34343A, edge: 0x707077, income: 0x34D27B, expense: 0xFF6369,
                              card: 0x19191B, well: 0x262628, selected: 0x252527,
                              chart: LedgerChartTokens(accent: 0xF3F3F4, income: 0x34D27B, expense: 0xFF6369, series: [0xF3F3F4, 0xFF6369, 0x34D27B, 0x6E9BFF, 0xE3A33B, 0x9A9AA1]))
        case (.paper, false):
            LedgerThemeTokens(page: 0xFBFAF8, sunken: 0xF1EFE9, ink: 0x14100C, secondary: 0x453E36, meta: 0x6F675A,
                              rule: 0xE2DED4, ruleStrong: 0xC8C2B4, edge: 0x88837A, income: 0x0D5346, expense: 0x96401F,
                              card: 0xFFFFFF, well: 0xF1EFE9, selected: 0xE6E2D9,
                              chart: LedgerChartTokens(accent: 0x14100C, income: 0x0D5346, expense: 0x96401F, series: [0x14100C, 0x96401F, 0x0D5346, 0xB07A1F, 0x4A6A8A, 0x7A4B6B]))
        case (.paper, true):
            LedgerThemeTokens(page: 0x121110, sunken: 0x1B1918, ink: 0xF6F3EE, secondary: 0xC4BCB0, meta: 0x9A9086,
                              rule: 0x2B2825, ruleStrong: 0x423C36, edge: 0x78746E, income: 0x4FBFAB, expense: 0xCF7A52,
                              card: 0x1B1918, well: 0x2B2825, selected: 0x1B1918,
                              chart: LedgerChartTokens(accent: 0xF6F3EE, income: 0x4FBFAB, expense: 0xCF7A52, series: [0xF6F3EE, 0xCF7A52, 0x4FBFAB, 0xD9A441, 0x8FA9C4, 0xB98AAE]))
        case (.neutral, false):
            LedgerThemeTokens(page: 0xFFFFFF, sunken: 0xF2F2F5, ink: 0x111113, secondary: 0x3C3C43, meta: 0x6B6B72,
                              rule: 0xE5E5EA, ruleStrong: 0xC7C7CC, edge: 0x86868C, income: 0x0D5346, expense: 0x96401F,
                              card: 0xF4F4F6, well: 0xE6E6EA, selected: 0xE5E5EA,
                              chart: LedgerChartTokens(accent: 0x007AFF, income: 0x248A3D, expense: 0xD70015, series: [0x007AFF, 0xFF9500, 0x34C759, 0xAF52DE, 0x30B0C7, 0xFF2D55]))
        case (.neutral, true):
            LedgerThemeTokens(page: 0x000000, sunken: 0x161618, ink: 0xF5F5F7, secondary: 0xC7C7CC, meta: 0x98989F,
                              rule: 0x262628, ruleStrong: 0x3A3A3C, edge: 0x76767C, income: 0x4FBFAB, expense: 0xCF7A52,
                              card: 0x161618, well: 0x2A2A2D, selected: 0x1C1C1F,
                              chart: LedgerChartTokens(accent: 0x0A84FF, income: 0x30D158, expense: 0xFF453A, series: [0x0A84FF, 0xFF9F0A, 0x30D158, 0xBF5AF2, 0x40C8E0, 0xFF375F]))
        case (.slate, false):
            LedgerThemeTokens(page: 0xF7F8FA, sunken: 0xECEFF3, ink: 0x0F1419, secondary: 0x38414D, meta: 0x5C6776,
                              rule: 0xDDE2E8, ruleStrong: 0xC4CBD4, edge: 0x7E8794, income: 0x0D5346, expense: 0x96401F,
                              card: 0xFFFFFF, well: 0xECEFF3, selected: 0xE1E5EB,
                              chart: LedgerChartTokens(accent: 0x3B5BDB, income: 0x0B7285, expense: 0xC2255C, series: [0x3B5BDB, 0x0B7285, 0xE8590C, 0x7048E8, 0x2B8A3E, 0xC2255C]))
        case (.slate, true):
            LedgerThemeTokens(page: 0x0F1115, sunken: 0x181B21, ink: 0xEEF1F5, secondary: 0xB8C0CC, meta: 0x8C96A4,
                              rule: 0x252A31, ruleStrong: 0x39404A, edge: 0x737C88, income: 0x4FBFAB, expense: 0xCF7A52,
                              card: 0x181B21, well: 0x252A31, selected: 0x181B21,
                              chart: LedgerChartTokens(accent: 0x748FFC, income: 0x3BC9DB, expense: 0xF06595, series: [0x748FFC, 0x3BC9DB, 0xFF922B, 0x9775FA, 0x51CF66, 0xF06595]))
        }
    }

    // MARK: Persistence

    static func stored(in defaults: UserDefaults = .standard) -> LedgerColorTheme {
        defaults.string(forKey: defaultsKey).flatMap(LedgerColorTheme.init(rawValue:)) ?? defaultTheme
    }

    func store(in defaults: UserDefaults = .standard) {
        if self == Self.defaultTheme {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(rawValue, forKey: Self.defaultsKey)
        }
    }

    // MARK: The scheme in use

    /// The scheme colours resolve against. Dynamic colours read it each time
    /// they resolve, from any thread, so it sits behind a lock rather than on
    /// the main actor. Starts from the saved choice.
    static var active: LedgerColorTheme {
        get { ActiveThemeBox.shared.value }
        set { ActiveThemeBox.shared.value = newValue }
    }

    // MARK: Web content

    /// The scheme as CSS variables, light and dark, for HTML the app renders
    /// (agent artifacts), so a page matches the ground it sits on.
    var css: String {
        func variables(_ t: LedgerThemeTokens) -> String {
            "--page:\(t.css(\.page));--sunken:\(t.css(\.sunken));--ink:\(t.css(\.ink));--secondary:\(t.css(\.secondary));"
                + "--meta:\(t.css(\.meta));--rule:\(t.css(\.rule));--rule-strong:\(t.css(\.ruleStrong));"
                + "--income:\(t.css(\.income));--expense:\(t.css(\.expense));"
        }
        return ":root{\(variables(tokens(dark: false)))--blue:#0A64D6;--orange:#C46A12;--purple:#7445B5;--teal:#147D86;color-scheme:light dark}\n"
            + "@media (prefers-color-scheme:dark){:root{\(variables(tokens(dark: true)))--blue:#5AA2FF;--orange:#F0A04B;--purple:#B48CF0;--teal:#4CC3C9}}"
    }
}

/// One scheme's tones for one appearance, as 0xRRGGBB.
struct LedgerThemeTokens: Equatable, Sendable {
    var page: UInt32
    var sunken: UInt32
    var ink: UInt32
    var secondary: UInt32
    var meta: UInt32
    /// Decorative hairlines.
    var rule: UInt32
    var ruleStrong: UInt32
    /// Control boundaries; must clear 3:1 against `page` and `sunken`.
    var edge: UInt32
    var income: UInt32
    var expense: UInt32
    /// Raised cards on the page (account groups).
    var card: UInt32
    /// An icon well inside a card.
    var well: UInt32
    /// A selected row on the sunken ground (the history drawer).
    var selected: UInt32
    /// Data marks in charts.
    var chart: LedgerChartTokens

    func value(_ token: LedgerThemeToken) -> UInt32 {
        switch token {
        case .page: page
        case .sunken: sunken
        case .ink: ink
        case .secondary: secondary
        case .meta: meta
        case .rule: rule
        case .ruleStrong: ruleStrong
        case .edge: edge
        case .income: income
        case .expense: expense
        case .card: card
        case .well: well
        case .selected: selected
        case .chartAccent: chart.accent
        case .chartIncome: chart.income
        case .chartExpense: chart.expense
        case let .chartSeries(index): chart.series[((index % chart.series.count) + chart.series.count) % chart.series.count]
        }
    }

    fileprivate func css(_ keyPath: KeyPath<LedgerThemeTokens, UInt32>) -> String {
        let hex = String(self[keyPath: keyPath], radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: max(0, 6 - hex.count)) + hex
    }
}

/// Chart colours. Paper keeps its ink-and-earth marks; the other schemes
/// bring their own accent, income/expense and series hues. They only need to
/// clear 3:1 against the ground as graphics, so they can be brighter than the
/// text tones.
struct LedgerChartTokens: Equatable, Sendable {
    /// The single-series mark: a balance line, a bar, the 留存 slab.
    var accent: UInt32
    var income: UInt32
    var expense: UInt32
    /// Multi-series charts take these in order.
    var series: [UInt32]
}

/// Names a token without a key path, so a `@Sendable` colour provider can
/// carry it.
enum LedgerThemeToken: Sendable, Hashable {
    case page, sunken, ink, secondary, meta, rule, ruleStrong, edge, income, expense, card, well, selected
    case chartAccent, chartIncome, chartExpense
    case chartSeries(Int)
}

private final class ActiveThemeBox: @unchecked Sendable {
    static let shared = ActiveThemeBox()
    private let lock = NSLock()
    private var stored: LedgerColorTheme?

    var value: LedgerColorTheme {
        get {
            lock.lock(); defer { lock.unlock() }
            if let stored { return stored }
            let loaded = LedgerColorTheme.stored()
            stored = loaded
            return loaded
        }
        set {
            lock.lock(); defer { lock.unlock() }
            stored = newValue
        }
    }
}

/// WCAG relative-luminance contrast between two 0xRRGGBB colours.
enum LedgerContrast {
    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
