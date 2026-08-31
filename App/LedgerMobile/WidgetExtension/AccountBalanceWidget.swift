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
        let entry = AccountBalanceEntry(
            date: now,
            snapshot: LedgerWidgetSnapshotStore.shared.load(),
            selectedAccountID: configuration.account?.id
        )
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(30 * 60)))
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
            .widgetURL(URL(string: "ledger://accounts"))
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
        VStack(alignment: .leading, spacing: 0) {
            LedgerWidgetHeader(
                title: account.label,
                detail: account.isLiability ? "待还" : "账户余额"
            )
            Spacer(minLength: 8)
            Text(primaryAmount(account, narrow: true))
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(account.isLiability ? LedgerWidgetColors.expense : LedgerWidgetColors.ink)
                .lineLimit(1)
                .privacySensitive()
            if let valuation = secondaryValuation(account, narrow: true) {
                Text("估值 \(valuation)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LedgerWidgetColors.secondary)
                    .lineLimit(1)
                    .padding(.top, 4)
                    .privacySensitive()
            }
            Spacer(minLength: 4)
            Text(LedgerWidgetText.updated(updatedAt, now: entry.date))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LedgerWidgetColors.secondary)
        }
    }

    private func medium(_ account: LedgerWidgetAccountSnapshot, updatedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                LedgerWidgetHeader(
                    title: account.label,
                    detail: account.isLiability ? "负债账户" : "资产账户"
                )
                Text(account.currency)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.cobalt)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(LedgerWidgetColors.tag)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 8)
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.isLiability ? "当前待还" : "当前余额")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                    Text(primaryAmount(account, narrow: false))
                        .font(.system(size: 29, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(account.isLiability ? LedgerWidgetColors.expense : LedgerWidgetColors.ink)
                        .lineLimit(1)
                        .privacySensitive()
                }
                Spacer(minLength: 8)
                if let valuation = secondaryValuation(account, narrow: false) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("统一估值")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LedgerWidgetColors.secondary)
                        Text(valuation)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(LedgerWidgetColors.gold)
                            .lineLimit(1)
                            .privacySensitive()
                    }
                }
            }
            Spacer(minLength: 6)
            Text(LedgerWidgetText.updated(updatedAt, now: entry.date))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LedgerWidgetColors.secondary)
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
