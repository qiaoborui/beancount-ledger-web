import Foundation

/// The shortcuts the 快捷入口 widget, the Control Center buttons and the
/// app icon's long-press menu offer. Each one is a `ledger://` link, so they
/// all go through `LedgerExternalRoute` like any other deep link: a protected
/// ledger is unlocked first and the action runs after that.
enum LedgerQuickLink: String, CaseIterable, Sendable {
    case agent
    case capture
    case record
    case sentence
    case search
    case imports

    var url: URL {
        switch self {
        case .agent: URL(string: "ledger://agent")!
        case .capture: URL(string: "ledger://capture")!
        case .record: URL(string: "ledger://record")!
        case .sentence: URL(string: "ledger://record?mode=sentence")!
        case .search: URL(string: "ledger://search")!
        case .imports: URL(string: "ledger://imports")!
        }
    }

    var title: String {
        switch self {
        case .agent: String(localized: "问账本助手")
        case .capture: String(localized: "拍票据")
        case .record: String(localized: "记一笔")
        case .sentence: String(localized: "一句话记账")
        case .search: String(localized: "搜索")
        case .imports: String(localized: "导入账单")
        }
    }

    /// The short label under a round button in the widget.
    var shortTitle: String {
        switch self {
        case .agent: String(localized: "助手")
        case .capture: String(localized: "拍票据")
        case .record: String(localized: "记一笔")
        case .sentence: String(localized: "一句话")
        case .search: String(localized: "搜索")
        case .imports: String(localized: "导入")
        }
    }

    var systemImage: String {
        switch self {
        case .agent: "sparkles"
        case .capture: "camera"
        case .record: "plus"
        case .sentence: "text.bubble"
        case .search: "magnifyingglass"
        case .imports: "tray.and.arrow.down"
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
