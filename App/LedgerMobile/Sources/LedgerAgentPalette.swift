#if os(iOS)
import SwiftUI

/// 账本助手's colours. Its surfaces follow the 配色方案 like every other
/// tab (暖纸, 纯净, 冷灰 and their night sets), since it sits beside 概览 in
/// the same bar now; text keeps the system's label tones and FlowDown's
/// teal accent stays for the few places that use it. Amounts and charts keep
/// the ledger's direction colours, so money reads the same everywhere.
///
/// The members mirror `BalancedPalette`, so a view moves over by its prefix.
enum LedgerAgentPalette {
    static let page = BalancedPalette.page
    /// A control's or a chip's ground, and the user's bubble.
    static let sunken = BalancedPalette.sunken
    static let card = BalancedPalette.card
    static let well = BalancedPalette.well
    static let selected = BalancedPalette.selected

    static let ink = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let meta = Color(uiColor: .secondaryLabel)
    static let rule = Color(uiColor: .separator)
    static let ruleStrong = Color(uiColor: .opaqueSeparator)
    static let edge = Color(uiColor: .systemGray3)

    /// The drawer's ground: the page colour throughout, without FlowDown's
    /// blue wash.
    static let groundTopUI = UIColor.ledgerThemed(.page)
    static let groundBottomUI = UIColor.ledgerThemed(.page)
    static var ground: LinearGradient {
        LinearGradient(colors: [Color(uiColor: groundTopUI), Color(uiColor: groundBottomUI)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// FlowDown's `AccentColor`.
    static let accent = Color(uiColor: UIColor(red: 65 / 255, green: 190 / 255, blue: 171 / 255, alpha: 1))
    /// The user's bubble: FlowDown's shape, in a neutral grey rather than
    /// its teal.
    static var bubble: LinearGradient {
        LinearGradient(colors: [sunken, sunken], startPoint: .top, endPoint: .bottom)
    }

    static let income = BalancedPalette.income
    static let expense = BalancedPalette.expense
    static let chartAccent = BalancedPalette.chartAccent
    static let chartIncome = BalancedPalette.chartIncome
    static let chartExpense = BalancedPalette.chartExpense
    static func chartSeries(_ index: Int) -> Color { BalancedPalette.chartSeries(index) }

}
#endif
