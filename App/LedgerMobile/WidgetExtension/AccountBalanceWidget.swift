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
            subtitle: "\(isLiability ? String(localized: "负债") : String(localized: "资产")) · \(currency)"
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

/// A locked device keeps this layout and masks the figures and the account
/// name; the widget URL drops the account then, too.
struct AccountBalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: AccountBalanceEntry
    var familyOverride: WidgetFamily?

    var body: some View {
        Group {
            if let account = entry.account, let snapshot = entry.snapshot {
                content(account, snapshot: snapshot)
            } else if entry.snapshot == nil {
                LedgerWidgetUnavailableView(title: String(localized: "账户余额"))
            } else {
                LedgerWidgetUnavailableView(
                    title: String(localized: "账户余额"),
                    reason: .message(String(localized: "选择一个账户"), detail: String(localized: "长按小组件并选择编辑小组件")))
            }
        }
        .widgetURL(entry.account.flatMap { LedgerWidgetNavigation.account($0, isRedacted: !redactionReasons.isEmpty) } ?? URL(string: "ledger://accounts"))
        .containerBackground(for: .widget) { LedgerWidgetColors.sunken }
    }

    private func content(_ account: LedgerWidgetAccountSnapshot, snapshot: LedgerWidgetSnapshot) -> some View {
        let tone = LedgerWidgetTone(renderingMode)
        let medium = (familyOverride ?? family) == .systemMedium
        let amount = account.isLiability ? MoneyText.magnitude(account.balance) : account.balance
        // Optional: net worth from rows already in the snapshot, single currency only.
        let netWorth = medium ? LedgerWidgetNetWorth.single(snapshot.accounts) : nil
        return VStack(alignment: .leading, spacing: 0) {
            LedgerWidgetHeader(title: account.label, detail: AccountBalanceGroup.label(for: account))
                .privacySensitive()
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(verbatim: account.currency)
                        if account.isLiability {
                            Text("负债")
                                .padding(.horizontal, 3)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(tone.ruleStrong, lineWidth: 0.5))
                        }
                    }.font(LedgerWidgetFont.text(10)).foregroundStyle(tone.meta)
                    LedgerWidgetAmount(amount: amount, currency: account.currency, size: 27)
                    if let valuation = account.valuation, account.currency != account.valuationCurrency {
                        Text(verbatim: "≈ " + MoneyText.format(minorUnits: account.isLiability ? MoneyText.magnitude(valuation) : valuation, currency: account.valuationCurrency))
                            .font(LedgerWidgetFont.text(15)).monospacedDigit().foregroundStyle(tone.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6).privacySensitive()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let netWorth {
                    Rectangle().fill(tone.rule).frame(width: 1).frame(maxHeight: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("净值").font(LedgerWidgetFont.text(10)).foregroundStyle(tone.meta)
                        LedgerWidgetAmount(amount: netWorth.net, currency: netWorth.currency, size: 15)
                    }.frame(maxWidth: 110, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            LedgerWidgetFooter(date: snapshot.updatedAt, now: entry.date)
        }
    }
}

/// The account's group, as the header detail.
enum AccountBalanceGroup {
    static func label(for account: LedgerWidgetAccountSnapshot) -> String {
        let name = "\(account.account) \(account.label) \(account.group)".lowercased()
        if account.isLiability || name.contains("credit") || name.contains("信用卡") {
            return String(localized: "信用卡")
        }
        if name.contains("cash") || name.contains("现金") { return String(localized: "现金资产") }
        if name.contains("invest") || name.contains("fund") || name.contains("stock") || name.contains("理财") || name.contains("基金") || name.contains("证券") {
            return String(localized: "投资理财")
        }
        if name.contains("loan") || name.contains("mortgage") || name.contains("借款") || name.contains("房贷") {
            return String(localized: "负债借贷")
        }
        return String(localized: "日常银行")
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
