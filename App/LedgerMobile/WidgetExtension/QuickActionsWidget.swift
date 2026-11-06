import AppIntents
import SwiftUI
import WidgetKit

/// 快捷入口: a home screen widget with one large button for the assistant and
/// round buttons for the entries used most, in the shape of the Claude app's
/// widget. It shows no ledger data, so it needs no snapshot and never has to
/// be hidden on a locked device; every button is a `ledger://` link and the
/// app asks for Face ID before the action runs.
struct QuickActionsEntry: TimelineEntry {
    let date: Date
}

struct QuickActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry { QuickActionsEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) {
        completion(QuickActionsEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<QuickActionsEntry>) -> Void) {
        completion(Timeline(entries: [QuickActionsEntry(date: Date())], policy: .never))
    }
}

struct QuickActionsWidget: Widget {
    let kind = "LedgerQuickActionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickActionsProvider()) { _ in
            QuickActionsWidgetView()
        }
        .configurationDisplayName("快捷入口")
        .description("一键问账本助手、拍票据或记一笔。")
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
    var familyOverride: WidgetFamily?

    /// The small widget keeps the Claude layout: one wide button over two
    /// round ones. The medium one has room for four.
    static let smallLinks: [LedgerQuickLink] = [.capture, .record]
    static let mediumLinks: [LedgerQuickLink] = [.capture, .record, .sentence, .search]

    var body: some View {
        content
            // A tap outside the buttons, and every tap where the system does
            // not run the buttons' links, still opens the assistant.
            .widgetURL(LedgerQuickLink.agent.url)
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
            Image(systemName: LedgerQuickLink.agent.systemImage)
                .font(.system(size: 22, weight: .medium))
                .widgetAccentable()
                .accessibilityLabel(LedgerQuickLink.agent.title)
        case .systemMedium:
            VStack(spacing: 10) {
                QuickActionButton(link: .agent) { primary(height: 58) }
                HStack(spacing: 10) {
                    ForEach(Self.mediumLinks, id: \.self) { link in
                        QuickActionButton(link: link) { round(link, labelled: true) }
                    }
                }
            }
            .padding(14)
        default:
            VStack(spacing: 10) {
                QuickActionButton(link: .agent) { primary(height: 64) }
                HStack(spacing: 10) {
                    ForEach(Self.smallLinks, id: \.self) { link in
                        QuickActionButton(link: link) { round(link, labelled: false) }
                    }
                }
            }
            .padding(14)
        }
    }

    private func primary(height: CGFloat) -> some View {
        HStack(spacing: 10) {
            Image(systemName: LedgerQuickLink.agent.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LedgerWidgetColors.accent)
                .widgetAccentable()
            Text("问助手")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LedgerWidgetColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Capsule(style: .continuous).fill(LedgerWidgetColors.raised))
        .contentShape(Capsule(style: .continuous))
        .accessibilityLabel(LedgerQuickLink.agent.title)
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

/// One tap target in the widget. iOS 18 runs a button's `OpenURLIntent` in
/// every widget size; before that a small widget only follows `widgetURL`,
/// so `Link` is the best iOS 17 can do (it works in the medium widget).
private struct QuickActionButton<Content: View>: View {
    let link: LedgerQuickLink
    @ViewBuilder let label: () -> Content

    var body: some View {
        if #available(iOS 18.0, *) {
            Button(intent: OpenURLIntent(link.url)) { label() }
                .buttonStyle(.plain)
        } else {
            Link(destination: link.url) { label() }
        }
    }
}

#if !targetEnvironment(macCatalyst)
/// Control Center, lock screen and Action button controls for the same
/// shortcuts (iOS 18).
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
struct LedgerCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LedgerCaptureControl") {
            ControlWidgetButton(action: OpenURLIntent(LedgerQuickLink.capture.url)) {
                Label("拍票据", systemImage: LedgerQuickLink.capture.systemImage)
            }
        }
        .displayName("拍票据")
        .description("拍一张票据或账单，交给账本助手。")
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
