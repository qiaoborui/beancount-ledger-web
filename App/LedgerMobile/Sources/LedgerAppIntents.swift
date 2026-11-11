import AppIntents
import UIKit

enum LedgerShortcutPage: String, AppEnum {
    case overview, transactions, accounts, imports, search

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "账本页面")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .overview: "概览", .transactions: "流水", .accounts: "账户", .imports: "导入", .search: "搜索"
    ]
}

struct OpenLedgerPageIntent: AppIntent {
    static let title: LocalizedStringResource = "打开账本页面"
    static let description = IntentDescription("打开 Ledger 的指定页面。受保护的账本仍需在 App 中解锁。")
    static let openAppWhenRun = true
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "页面", default: .overview)
    var page: LedgerShortcutPage

    static var parameterSummary: some ParameterSummary { Summary("打开 \(\.$page)") }

    init() {}
    init(page: LedgerShortcutPage) { self.page = page }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LedgerShortcutNavigation.open(host: page.rawValue)
        return .result()
    }
}

struct SearchLedgerIntent: AppIntent {
    static let title: LocalizedStringResource = "搜索账本"
    static let description = IntentDescription("在 Ledger 中搜索流水、账户、标签和文件。结果仅在解锁后的 App 中显示。")
    static let openAppWhenRun = true
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "关键词", requestValueDialog: "想在账本中搜索什么？")
    var query: String

    static var parameterSummary: some ParameterSummary { Summary("在账本中搜索 \(\.$query)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LedgerShortcutNavigation.open(host: "search", queryItems: [URLQueryItem(name: "q", value: query)])
        return .result()
    }
}

struct AskLedgerAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "问账本助手"
    static let description = IntentDescription("打开 Ledger 的账本助手，用新对话问一个问题，比如「这个月花了多少」或「记一笔午饭 35」。受保护的账本仍需在 App 中解锁；改账前仍会先给你确认。")
    static let openAppWhenRun = true
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "问题", requestValueDialog: "想问账本助手什么？")
    var question: String

    static var parameterSummary: some ParameterSummary { Summary("问账本助手 \(\.$question)") }

    init() {}
    init(question: String) { self.question = question }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LedgerShortcutNavigation.open(host: "agent", queryItems: [URLQueryItem(name: "q", value: question)])
        return .result()
    }
}

enum LedgerShortcutNavigation {
    @MainActor
    static func open(host: String, queryItems: [URLQueryItem] = []) async throws {
        var components = URLComponents()
        components.scheme = "ledger"
        components.host = host
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url, await UIApplication.shared.open(url) else {
            throw NavigationError.unavailable
        }
    }

    enum NavigationError: Error, LocalizedError {
        case unavailable
        var errorDescription: String? { String(localized: "暂时无法打开 Ledger，请稍后重试。") }
    }
}

struct LedgerAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenLedgerPageIntent(),
            phrases: ["打开 \(.applicationName) 的 \(\.$page)", "在 \(.applicationName) 查看 \(\.$page)"],
            shortTitle: "打开账本页面",
            systemImageName: "book.closed"
        )
        AppShortcut(
            intent: AskLedgerAgentIntent(),
            phrases: ["问 \(.applicationName) 账本助手", "用 \(.applicationName) 问账本助手"],
            shortTitle: "问账本助手",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: RecordLedgerTransactionIntent(),
            phrases: ["用 \(.applicationName) 记一笔", "在 \(.applicationName) 记一笔", "\(.applicationName) 记账"],
            shortTitle: "记一笔",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: SearchLedgerIntent(),
            phrases: ["搜索 \(.applicationName)", "在 \(.applicationName) 搜索账本"],
            shortTitle: "搜索账本",
            systemImageName: "magnifyingglass"
        )
    }
}
