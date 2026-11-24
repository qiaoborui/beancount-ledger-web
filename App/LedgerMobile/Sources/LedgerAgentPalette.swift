#if os(iOS)
import SwiftUI

/// 账本助手's colours, taken from FlowDown rather than the ledger's paper:
/// a white page (#242424 at night), the system's label tones for text,
/// system separators, and FlowDown's teal accent for the user's bubble. The
/// rest of the app keeps its 配色方案; amounts and charts keep the ledger's
/// direction colours here too, so money reads the same everywhere.
///
/// The members mirror `BalancedPalette`, so a view moves over by its prefix.
enum LedgerAgentPalette {
    /// FlowDown's `Background` colour set.
    static let page = Color(uiColor: dynamic(light: 0xFFFFFF, dark: 0x242424))
    /// A control's or a chip's ground: the label at 5%, as FlowDown's
    /// buttons on the page are.
    static let sunken = Color(uiColor: dynamic(light: 0xF2F2F2, dark: 0x303030))
    static let card = Color(uiColor: dynamic(light: 0xFFFFFF, dark: 0x2C2C2C))
    static let well = Color(uiColor: dynamic(light: 0xEDEDED, dark: 0x363636))
    static let selected = Color(uiColor: dynamic(light: 0xEDEDED, dark: 0x363636))

    static let ink = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let meta = Color(uiColor: .secondaryLabel)
    static let rule = Color(uiColor: .separator)
    static let ruleStrong = Color(uiColor: .opaqueSeparator)
    static let edge = Color(uiColor: .systemGray3)

    /// FlowDown's `AccentColor`.
    static let accent = Color(uiColor: UIColor(red: 65 / 255, green: 190 / 255, blue: 171 / 255, alpha: 1))
    /// The user's bubble: FlowDown's accent at 10% to 15%, top to bottom.
    static var bubble: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.10), accent.opacity(0.15)],
                       startPoint: UnitPoint(x: 0.6, y: 0), endPoint: UnitPoint(x: 0.4, y: 1))
    }

    static let income = BalancedPalette.income
    static let expense = BalancedPalette.expense
    static let chartAccent = BalancedPalette.chartAccent
    static let chartIncome = BalancedPalette.chartIncome
    static let chartExpense = BalancedPalette.chartExpense
    static func chartSeries(_ index: Int) -> Color { BalancedPalette.chartSeries(index) }

    private static func dynamic(light: UInt, dark: UInt) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }
}
#endif
