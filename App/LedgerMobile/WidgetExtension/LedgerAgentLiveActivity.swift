#if !targetEnvironment(macCatalyst)
import ActivityKit
import SwiftUI
import WidgetKit

/// 账本助手 working while the app is away: the step it is on and how long it
/// has run, then how the turn ended. On iOS 26 the system's own progress for
/// the continued task takes this place; this shows where that is unavailable.
struct LedgerAgentLiveActivity: Widget {
    private typealias Phase = LedgerAgentActivityAttributes.ContentState.Phase

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LedgerAgentActivityAttributes.self) { context in
            let phase = context.state.phase
            LedgerGlassCard {
                LedgerLockBody(
                    header: String(localized: "账本助手"),
                    glyph: glyph(phase), color: color(phase),
                    title: title(phase), detail: context.state.detail, detailLines: 2
                ) {
                    trailing(context)
                } footer: {
                    EmptyView()
                }
            }
            .activityBackgroundTint(.clear)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "ledger://agent"))
            .accessibilityElement(children: .combine)
        } dynamicIsland: { context in
            let phase = context.state.phase
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { LedgerGlassBadge(glyph: glyph(phase), color: color(phase), size: 24, symbolSize: 12) }
                DynamicIslandExpandedRegion(.trailing) { trailing(context) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(phase))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(LedgerGlass.text)
                        Text(context.state.detail)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LedgerGlass.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            } compactLeading: {
                if phase == .running {
                    LedgerMark(accent: color(phase)).frame(width: 14, height: 14)
                } else {
                    Image(systemName: symbol(phase)).font(.system(size: 13, weight: .semibold)).foregroundStyle(color(phase))
                }
            } compactTrailing: {
                if phase == .running {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(LedgerGlass.text)
                        .frame(maxWidth: 40)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(color(phase)).opacity(phase == .answered ? 1 : 0)
                }
            } minimal: {
                if phase == .running {
                    LedgerMark(accent: color(phase)).frame(width: 15, height: 15)
                } else {
                    Image(systemName: symbol(phase)).foregroundStyle(color(phase))
                }
            }
            .widgetURL(URL(string: "ledger://agent"))
            .keylineTint(color(phase))
        }
    }

    @ViewBuilder
    private func trailing(_ context: ActivityViewContext<LedgerAgentActivityAttributes>) -> some View {
        if context.state.phase == .running {
            Text(context.attributes.startedAt, style: .timer)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(LedgerGlass.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 64)
        } else if context.state.steps > 0 {
            LedgerGlassPill(text: String(localized: "\(context.state.steps) 步"), color: LedgerGlass.secondary)
        }
    }

    private func mark(_ phase: Phase) -> some View {
        LedgerGlassBadge(glyph: glyph(phase), color: color(phase))
    }

    private func title(_ phase: Phase) -> String {
        switch phase {
        case .running: String(localized: "账本助手正在处理")
        case .answered: String(localized: "账本助手已回答")
        case .review: String(localized: "草稿改好了，等你确认")
        case .failed: String(localized: "账本助手没能完成")
        case .interrupted: String(localized: "账本助手被中断")
        }
    }

    /// Running shows the app's mark; how a turn ended keeps its symbol.
    private func glyph(_ phase: Phase) -> LedgerGlyph {
        phase == .running ? .mark : .symbol(symbol(phase))
    }

    private func symbol(_ phase: Phase) -> String {
        switch phase {
        case .running: "sparkles"
        case .answered: "checkmark"
        case .review: "doc.badge.ellipsis"
        case .failed: "exclamationmark.triangle"
        case .interrupted: "pause.circle"
        }
    }

    private func color(_ phase: Phase) -> Color {
        switch phase {
        case .running: LedgerGlass.gold
        case .answered: LedgerGlass.success
        case .review, .interrupted: LedgerGlass.warning
        case .failed: LedgerGlass.failure
        }
    }
}
#endif
