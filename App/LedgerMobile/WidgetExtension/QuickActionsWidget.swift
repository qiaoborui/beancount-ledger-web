import AppIntents
import SwiftUI
import WidgetKit

/// 快捷入口: a home screen widget with one wide button and round buttons
/// below it, in the shape of the Claude app's widget. Long-press → 编辑小组件
/// picks what each button opens: the assistant, 记一笔, 一句话记账, search or
/// any tab. It shows no ledger data, so it needs no snapshot and never has to
/// be hidden on a locked device; every button is a `ledger://` link and the
/// app asks for Face ID before the action runs.
enum QuickActionWidgetTarget: String, AppEnum {
    case agent, record, sentence, search, overview, transactions, accounts, imports
    case assets, incomeExpense, investments, currencies, query

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "快捷入口")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .agent: DisplayRepresentation(title: "问账本助手", image: .init(systemName: "sparkles")),
        .record: DisplayRepresentation(title: "记一笔", image: .init(systemName: "plus")),
        .sentence: DisplayRepresentation(title: "一句话记账", image: .init(systemName: "text.bubble")),
        .search: DisplayRepresentation(title: "搜索", image: .init(systemName: "magnifyingglass")),
        .overview: DisplayRepresentation(title: "概览", image: .init(systemName: "house")),
        .transactions: DisplayRepresentation(title: "交易", image: .init(systemName: "list.bullet")),
        .accounts: DisplayRepresentation(title: "账户", image: .init(systemName: "book.closed")),
        .imports: DisplayRepresentation(title: "导入", image: .init(systemName: "tray.and.arrow.down")),
        .assets: DisplayRepresentation(title: "资产分析", image: .init(systemName: "building.columns")),
        .incomeExpense: DisplayRepresentation(title: "收支", image: .init(systemName: "chart.bar.xaxis")),
        .investments: DisplayRepresentation(title: "投资", image: .init(systemName: "chart.pie")),
        .currencies: DisplayRepresentation(title: "货币", image: .init(systemName: "coloncurrencysign")),
        .query: DisplayRepresentation(title: "查询", image: .init(systemName: "cylinder.split.1x2")),
    ]

    var link: LedgerQuickLink { LedgerQuickLink(rawValue: rawValue) ?? .agent }
}

struct QuickActionsWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "快捷入口"
    static let description = IntentDescription("选择每个按钮打开的功能或页面。小号显示大按钮和前两个圆形按钮。")

    @Parameter(title: "大按钮", default: .agent) var primary: QuickActionWidgetTarget
    @Parameter(title: "按钮 1", default: .record) var first: QuickActionWidgetTarget
    @Parameter(title: "按钮 2", default: .search) var second: QuickActionWidgetTarget
    @Parameter(title: "按钮 3", default: .transactions) var third: QuickActionWidgetTarget
    @Parameter(title: "按钮 4", default: .accounts) var fourth: QuickActionWidgetTarget

    init() {}
}

struct QuickActionsEntry: TimelineEntry {
    let date: Date
    var primary: LedgerQuickLink = .agent
    var buttons: [LedgerQuickLink] = [.record, .search, .transactions, .accounts]

    init(date: Date) { self.date = date }

    init(date: Date, configuration: QuickActionsWidgetIntent) {
        self.date = date
        primary = configuration.primary.link
        buttons = [configuration.first, configuration.second, configuration.third, configuration.fourth].map(\.link)
    }
}

struct QuickActionsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry { QuickActionsEntry(date: Date()) }

    func snapshot(for configuration: QuickActionsWidgetIntent, in context: Context) async -> QuickActionsEntry {
        QuickActionsEntry(date: Date(), configuration: configuration)
    }

    func timeline(for configuration: QuickActionsWidgetIntent, in context: Context) async -> Timeline<QuickActionsEntry> {
        Timeline(entries: [QuickActionsEntry(date: Date(), configuration: configuration)], policy: .never)
    }
}

struct QuickActionsWidget: Widget {
    let kind = "LedgerQuickActionsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: QuickActionsWidgetIntent.self, provider: QuickActionsProvider()) { entry in
            QuickActionsWidgetView(entry: entry)
        }
        .configurationDisplayName("快捷入口")
        .description("一键问账本助手、记一笔，或打开任意页面。长按可编辑每个按钮。")
        .supportedFamilies(Self.families)
        .contentMarginsDisabled()
    }

    private static var families: [WidgetFamily] {
        #if targetEnvironment(macCatalyst)
        [.systemSmall, .systemMedium]
        #else
        [.systemSmall, .systemMedium, .accessoryCircular]
        #endif
    }
}

struct QuickActionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickActionsEntry
    var familyOverride: WidgetFamily?

    var body: some View {
        content
            // A tap outside the buttons opens the wide button's target.
            .widgetURL(entry.primary.url)
            .containerBackground(for: .widget) {
                if (familyOverride ?? family) == .accessoryCircular {
                    AccessoryWidgetBackground()
                } else {
                    LedgerWidgetColors.panel
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch familyOverride ?? family {
        case .accessoryCircular:
            Image(systemName: entry.primary.systemImage)
                .font(.system(size: 22, weight: .medium))
                .widgetAccentable()
                .accessibilityLabel(entry.primary.title)
        case .systemMedium:
            VStack(spacing: 10) {
                Link(destination: entry.primary.url) { primary(height: 58) }
                HStack(spacing: 10) {
                    ForEach(Array(entry.buttons.prefix(4).enumerated()), id: \.offset) { _, link in
                        Link(destination: link.url) { round(link, labelled: true) }
                    }
                }
            }
            .padding(14)
        default:
            VStack(spacing: 10) {
                Link(destination: entry.primary.url) { primary(height: 64) }
                HStack(spacing: 10) {
                    ForEach(Array(entry.buttons.prefix(2).enumerated()), id: \.offset) { _, link in
                        Link(destination: link.url) { round(link, labelled: false) }
                    }
                }
            }
            .padding(14)
        }
    }

    private func primary(height: CGFloat) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.primary.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LedgerWidgetColors.accent)
                .widgetAccentable()
            Text(entry.primary.shortTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LedgerWidgetColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Capsule(style: .continuous).fill(LedgerWidgetColors.raised))
        .contentShape(Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.primary.title)
    }

    private func round(_ link: LedgerQuickLink, labelled: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: link.systemImage)
                .font(.system(size: labelled ? 17 : 20, weight: .medium))
                .foregroundStyle(LedgerWidgetColors.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if labelled {
                Text(link.shortTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if labelled {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LedgerWidgetColors.raised)
            } else {
                Circle().fill(LedgerWidgetColors.raised)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(link.title)
    }
}

#if !targetEnvironment(macCatalyst)
/// Control Center, lock screen and Action button controls (iOS 18).
@available(iOS 18.0, *)
struct LedgerAgentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LedgerAgentControl") {
            ControlWidgetButton(action: OpenURLIntent(LedgerQuickLink.agent.url)) {
                Label("问账本助手", systemImage: LedgerQuickLink.agent.systemImage)
            }
        }
        .displayName("问账本助手")
        .description("打开 Ledger 的账本助手。")
    }
}

@available(iOS 18.0, *)
struct LedgerRecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LedgerRecordControl") {
            ControlWidgetButton(action: OpenURLIntent(LedgerQuickLink.record.url)) {
                Label("记一笔", systemImage: LedgerQuickLink.record.systemImage)
            }
        }
        .displayName("记一笔")
        .description("打开 Ledger 的记账表单。")
    }
}
#endif
