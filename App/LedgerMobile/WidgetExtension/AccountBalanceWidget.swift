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

    init(entry: AccountBalanceEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    var body: some View {
        if let account = entry.account, let snapshot = entry.snapshot {
            Group {
                if (familyOverride ?? family) == .systemMedium {
                    medium(account, updatedAt: snapshot.updatedAt)
                } else {
                    small(account, updatedAt: snapshot.updatedAt)
                }
            }
            .widgetURL(LedgerWidgetNavigation.account(account, isRedacted: !redactionReasons.isEmpty))
            .containerBackground(for: .widget) { LedgerWidgetColors.panel }
        } else if entry.snapshot == nil {
            LedgerWidgetUnavailableView(
                title: "等待账户数据",
                detail: "打开 Ledger 并刷新一次",
                symbol: "building.columns"
            )
            .widgetURL(URL(string: "ledger://accounts"))
        } else {
            LedgerWidgetUnavailableView(
                title: "选择一个账户",
                detail: "长按小组件并选择编辑小组件",
                symbol: "slider.horizontal.3"
            )
            .widgetURL(URL(string: "ledger://accounts"))
        }
    }

    private func small(_ account: LedgerWidgetAccountSnapshot, updatedAt: Date) -> some View {
        let style = LedgerWidgetVisualHelper.account(for: account)
        return VStack(alignment: .leading, spacing: 0) {
            LedgerWidgetHeader(
                title: account.label,
                detail: account.isLiability ? "待还账单 · \(account.currency)" : "\(style.groupLabel) · \(account.currency)",
                systemName: style.icon,
                tint: style.tint
            )
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.isLiability ? "待还余额" : "当前余额")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
                Text(primaryAmount(account, narrow: true))
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(account.isLiability ? LedgerWidgetColors.expense : LedgerWidgetColors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .privacySensitive()
            }
            if let valuation = secondaryValuation(account, narrow: true) {
                Text("估值 \(valuation)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LedgerWidgetColors.gold)
                    .lineLimit(1)
                    .padding(.top, 3)
                    .privacySensitive()
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Text(style.groupLabel)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(style.tint)
                Text("·")
                    .foregroundStyle(LedgerWidgetColors.secondary)
                Text(LedgerWidgetText.updated(updatedAt, now: entry.date))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
            }
            .lineLimit(1)
        }
    }

    private func medium(_ account: LedgerWidgetAccountSnapshot, updatedAt: Date) -> some View {
        let style = LedgerWidgetVisualHelper.account(for: account)
        return HStack(spacing: 12) {
            // Left Hero Section
            VStack(alignment: .leading, spacing: 0) {
                LedgerWidgetHeader(
                    title: account.label,
                    detail: account.isLiability ? "负债账户" : "资产账户",
                    systemName: style.icon,
                    tint: style.tint
                )
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.isLiability ? "当前待还款" : "可用资产余额")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                    Text(primaryAmount(account, narrow: false))
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(account.isLiability ? LedgerWidgetColors.expense : LedgerWidgetColors.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .privacySensitive()
                }
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Circle()
                        .fill(account.isLiability ? LedgerWidgetColors.expense : LedgerWidgetColors.success)
                        .frame(width: 5, height: 5)
                    Text(account.isLiability ? "按期对账" : "账面在册")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                    Text("·")
                        .foregroundStyle(LedgerWidgetColors.secondary)
                    Text(LedgerWidgetText.updated(updatedAt, now: entry.date))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right Tactile Context Card
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("账户概况")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(LedgerWidgetColors.ink)
                    Spacer(minLength: 0)
                    Text(account.currency)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(style.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(style.tint.opacity(0.12))
                        .clipShape(Capsule())
                }

                if let valuation = secondaryValuation(account, narrow: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("统一估值 (\(account.valuationCurrency))")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(LedgerWidgetColors.secondary)
                        Text(valuation)
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(LedgerWidgetColors.gold)
                            .lineLimit(1)
                            .privacySensitive()
                    }
                    .padding(.top, 1)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("类别属性")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                    Text(style.groupLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerWidgetColors.ink)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                HStack(spacing: 2) {
                    Text("查看账本明细")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LedgerWidgetColors.cobalt)
            }
            .frame(width: 116, alignment: .leading)
            .widgetSubcard(cornerRadius: 10, padding: 8)
        }
    }

    private func primaryAmount(_ account: LedgerWidgetAccountSnapshot, narrow: Bool) -> String {
        let amount = account.isLiability ? MoneyText.magnitude(account.balance) : account.balance
        return narrow
            ? MoneyText.formatWidget(minorUnits: amount, currency: account.currency)
            : MoneyText.formatCompact(minorUnits: amount, currency: account.currency)
    }

    private func secondaryValuation(_ account: LedgerWidgetAccountSnapshot, narrow: Bool) -> String? {
        guard let valuation = account.valuation,
              account.currency != account.valuationCurrency else {
            return nil
        }
        let amount = account.isLiability ? MoneyText.magnitude(valuation) : valuation
        return narrow
            ? MoneyText.formatWidget(minorUnits: amount, currency: account.valuationCurrency)
            : MoneyText.formatCompact(minorUnits: amount, currency: account.valuationCurrency)
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
