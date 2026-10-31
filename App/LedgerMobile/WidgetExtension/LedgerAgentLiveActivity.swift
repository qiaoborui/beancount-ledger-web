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
            HStack(spacing: 10) {
                mark(phase)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(phase))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LedgerWidgetColors.ink)
                    Text(context.state.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                trailing(context)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .activityBackgroundTint(LedgerWidgetColors.panel)
            .activitySystemActionForegroundColor(LedgerWidgetColors.cobalt)
            .widgetURL(URL(string: "ledger://agent"))
            .accessibilityElement(children: .combine)
        } dynamicIsland: { context in
            let phase = context.state.phase
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { mark(phase) }
                DynamicIslandExpandedRegion(.trailing) { trailing(context) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(phase)).font(.system(size: 13, weight: .semibold))
                        Text(context.state.detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: symbol(phase)).foregroundStyle(color(phase))
            } compactTrailing: {
                if phase == .running {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .frame(maxWidth: 40)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(color(phase)).opacity(phase == .answered ? 1 : 0)
                }
            } minimal: {
                Image(systemName: symbol(phase)).foregroundStyle(color(phase))
            }
            .widgetURL(URL(string: "ledger://agent"))
            .keylineTint(LedgerWidgetColors.cobalt)
        }
    }

    @ViewBuilder
    private func trailing(_ context: ActivityViewContext<LedgerAgentActivityAttributes>) -> some View {
        if context.state.phase == .running {
            Text(context.attributes.startedAt, style: .timer)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(LedgerWidgetColors.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 56)
        } else if context.state.steps > 0 {
            Text("\(context.state.steps) 步")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(LedgerWidgetColors.secondary)
        }
    }

    private func mark(_ phase: Phase) -> some View {
        Image(systemName: symbol(phase))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color(phase))
            .frame(width: 30, height: 30)
            .background(color(phase).opacity(0.11))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        case .running: LedgerWidgetColors.cobalt
        case .answered: LedgerWidgetColors.success
        case .review, .interrupted: LedgerWidgetColors.gold
        case .failed: LedgerWidgetColors.expense
        }
    }
}
#endif
