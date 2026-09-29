import AppIntents
import SwiftUI
import WidgetKit

struct LedgerAccountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Ledger 账户")
    static let defaultQuery = LedgerAccountEntityQuery()

    let id: String
    let label: String
    let currency: String
    let isLiability: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(label)",
            subtitle: "\(isLiability ? "负债" : "资产") · \(currency)"
        )
    }

    init(account: LedgerWidgetAccountSnapshot) {
        id = account.id
        label = account.label
        currency = account.currency
        isLiability = account.isLiability
    }
}

struct LedgerAccountEntityQuery: EntityQuery {
    func entities(for identifiers: [LedgerAccountEntity.ID]) async throws -> [LedgerAccountEntity] {
        let wanted = Set(identifiers)
        return accounts.filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [LedgerAccountEntity] {
        accounts
    }

    private var accounts: [LedgerAccountEntity] {
        (LedgerWidgetSnapshotStore.shared.load()?.accounts ?? []).map(LedgerAccountEntity.init)
    }
}

struct AccountWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择账户"
    static let description = IntentDescription("选择一个资产或负债账户显示余额。")

    @Parameter(title: "账户")
    var account: LedgerAccountEntity?
}

struct AccountBalanceEntry: TimelineEntry {
    let date: Date
    let snapshot: LedgerWidgetSnapshot?
    let selectedAccountID: String?

    var account: LedgerWidgetAccountSnapshot? {
        let accounts = snapshot?.accounts ?? []
        guard let selectedAccountID else { return nil }
        return accounts.first { $0.id == selectedAccountID }
    }
}

struct AccountBalanceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AccountBalanceEntry {
        AccountBalanceEntry(
            date: Date(),
            snapshot: .placeholder,
            selectedAccountID: LedgerWidgetSnapshot.placeholder.accounts.first?.id
        )
    }

    func snapshot(
        for configuration: AccountWidgetConfigurationIntent,
        in context: Context
    ) async -> AccountBalanceEntry {
        let snapshot = context.isPreview ? LedgerWidgetSnapshot.placeholder : LedgerWidgetSnapshotStore.shared.load()
        return AccountBalanceEntry(
            date: Date(),
            snapshot: snapshot,
            selectedAccountID: configuration.account?.id
        )
    }

    func timeline(
        for configuration: AccountWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<AccountBalanceEntry> {
        let now = Date()
        let result = await LedgerWidgetTimelineLoader.shared.load(now: now)
        let entry = AccountBalanceEntry(
            date: now,
            snapshot: result.snapshot,
            selectedAccountID: configuration.account?.id
        )
        return Timeline(
            entries: [entry],
            policy: .after(now.addingTimeInterval(result.refreshInterval))
        )
    }
}

struct AccountBalanceWidget: Widget {
    let kind = "LedgerAccountBalanceWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: AccountWidgetConfigurationIntent.self,
            provider: AccountBalanceProvider()
        ) { entry in
            AccountBalanceWidgetView(entry: entry)
        }
        .configurationDisplayName("账户余额")
        .description("选择一个账户，在桌面查看当前余额与统一估值。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct AccountBalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: AccountBalanceEntry
    var familyOverride: WidgetFamily?

    var body: some View {
        Group {
            if !redactionReasons.isEmpty {
                LedgerWidgetPrivacyView(title: "账户余额")
            } else if let account = entry.account, let snapshot = entry.snapshot {
                content(account, updated: snapshot.updatedAt)
            } else {
                LedgerWidgetUnavailableView(
                    title: entry.snapshot == nil ? "等待账户数据" : "选择一个账户",
                    detail: entry.snapshot == nil ? "打开 Ledger 并刷新一次" : "长按小组件并选择编辑小组件",
                    symbol: "building.columns")
            }
        }
        .widgetURL(entry.account.flatMap { LedgerWidgetNavigation.account($0, isRedacted: !redactionReasons.isEmpty) } ?? URL(string: "ledger://accounts"))
        .containerBackground(for: .widget) { LedgerWidgetColors.panel }
    }

    private func content(_ account: LedgerWidgetAccountSnapshot, updated: Date) -> some View {
        let medium = (familyOverride ?? family) == .systemMedium
        let style = LedgerWidgetVisualHelper.account(for: account)
        let amount = account.isLiability ? MoneyText.magnitude(account.balance) : account.balance
        return VStack(alignment: .leading, spacing: 6) {
            Text(account.label).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LedgerWidgetColors.ink).lineLimit(2)
            Spacer(minLength: 0)
            Text("\(account.isLiability ? "待还余额" : "资产余额") · \(account.currency)")
                .font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
            LedgerWidgetAmount(amount: amount, currency: account.currency, size: medium ? 29 : 23)
            if let valuation = account.valuation, account.currency != account.valuationCurrency {
                Text("估值 " + MoneyText.format(minorUnits: account.isLiability ? MoneyText.magnitude(valuation) : valuation, currency: account.valuationCurrency))
                    .font(.system(size: 10, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(LedgerWidgetColors.secondary)
            }
            Spacer(minLength: 0)
            LedgerWidgetFooter(label: style.groupLabel, date: updated, now: entry.date)
        }.privacySensitive()
    }
}

/// Encodes navigation data without placing account names in URL path segments.
enum LedgerWidgetNavigation {
    static func account(_ account: LedgerWidgetAccountSnapshot, isRedacted: Bool = false) -> URL? {
        var components = URLComponents()
        components.scheme = "ledger"
        components.host = "accounts"
        if !isRedacted {
            components.queryItems = [
                URLQueryItem(name: "account", value: account.account),
                URLQueryItem(name: "currency", value: account.currency)
            ]
        }
        return components.url
    }

    static func transactions(date: String? = nil, isRedacted: Bool = false) -> URL? {
        var components = URLComponents()
        components.scheme = "ledger"
        components.host = "transactions"
        if !isRedacted, let date {
            components.queryItems = [URLQueryItem(name: "date", value: date)]
        }
        return components.url
    }
}
