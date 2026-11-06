import Foundation

/// What the 快捷入口 widget, the Control Center buttons and the app icon's
/// long-press menu can open: the assistant, the two entry forms, search, or
/// any tab. Each one is a `ledger://` link, so they all go through
/// `LedgerExternalRoute` like any other deep link: a protected ledger is
/// unlocked first and the action runs after that.
enum LedgerQuickLink: String, CaseIterable, Sendable {
    case agent
    case record
    case sentence
    case search
    case overview
    case transactions
    case accounts
    case imports
    case assets
    case incomeExpense
    case investments
    case currencies
    case query

    var url: URL {
        switch self {
        case .agent: URL(string: "ledger://agent")!
        case .record: URL(string: "ledger://record")!
        case .sentence: URL(string: "ledger://record?mode=sentence")!
        case .search: URL(string: "ledger://search")!
        case .overview: URL(string: "ledger://overview")!
        case .transactions: URL(string: "ledger://transactions")!
        case .accounts: URL(string: "ledger://accounts")!
        case .imports: URL(string: "ledger://imports")!
        case .assets, .incomeExpense, .investments, .currencies, .query:
            URL(string: "ledger://page?name=" + rawValue)!
        }
    }

    var title: String {
        switch self {
        case .agent: String(localized: "问账本助手")
        case .record: String(localized: "记一笔")
        case .sentence: String(localized: "一句话记账")
        case .search: String(localized: "搜索")
        case .overview: String(localized: "概览")
        case .transactions: String(localized: "交易")
        case .accounts: String(localized: "账户")
        case .imports: String(localized: "导入")
        case .assets: String(localized: "资产分析")
        case .incomeExpense: String(localized: "收支")
        case .investments: String(localized: "投资")
        case .currencies: String(localized: "货币")
        case .query: String(localized: "查询")
        }
    }

    /// The short label for the wide button and under a round one.
    var shortTitle: String {
        switch self {
        case .agent: String(localized: "问助手")
        case .sentence: String(localized: "一句话")
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .agent: "sparkles"
        case .record: "plus"
        case .sentence: "text.bubble"
        case .search: "magnifyingglass"
        case .overview: "house"
        case .transactions: "list.bullet"
        case .accounts: "book.closed"
        case .imports: "tray.and.arrow.down"
        case .assets: "building.columns"
        case .incomeExpense: "chart.bar.xaxis"
        case .investments: "chart.pie"
        case .currencies: "coloncurrencysign"
        case .query: "cylinder.split.1x2"
        }
    }

    /// The `UIApplicationShortcutItem` type for the app icon's menu.
    var shortcutType: String { "com.qiaoborui.ledger.mobile.quick." + rawValue }

    init?(shortcutType: String) {
        let prefix = "com.qiaoborui.ledger.mobile.quick."
        guard shortcutType.hasPrefix(prefix) else { return nil }
        self.init(rawValue: String(shortcutType.dropFirst(prefix.count)))
    }
}
