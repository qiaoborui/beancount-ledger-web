#if !targetEnvironment(macCatalyst)
import ActivityKit
import SwiftUI
import WidgetKit

struct ImportIndexLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ImportIndexActivityAttributes.self) { context in
            let phase = displayPhase(context)
            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    statusMark(phase)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(phase))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LedgerWidgetColors.ink)
                        Text(detail(context))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(LedgerWidgetColors.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    statusBadge(phase)
                }
                phaseTrack(phase)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .activityBackgroundTint(LedgerWidgetColors.panel)
            .activitySystemActionForegroundColor(LedgerWidgetColors.cobalt)
            .widgetURL(URL(string: "ledger://imports"))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(context, phase: phase))
        } dynamicIsland: { context in
            let phase = displayPhase(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    statusMark(phase)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(badgeText(phase))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(phaseColor(phase))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(detail(context))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        phaseTrack(phase)
                    }
                }
            } compactLeading: {
                Image(systemName: symbol(phase))
                    .foregroundStyle(phaseColor(phase))
            } compactTrailing: {
                Text(compactText(phase))
                    .font(.system(size: 11, weight: .semibold))
            } minimal: {
                Image(systemName: symbol(phase))
                    .foregroundStyle(phaseColor(phase))
            }
            .widgetURL(URL(string: "ledger://imports"))
            .keylineTint(LedgerWidgetColors.cobalt)
        }
    }

    private enum DisplayPhase {
        case indexing
        case waiting
        case indexed
    }

    private func displayPhase(_ context: ActivityViewContext<ImportIndexActivityAttributes>) -> DisplayPhase {
        if context.state.phase == "indexed" { return .indexed }
        if context.isStale || context.state.phase == "waiting" { return .waiting }
        return .indexing
    }

    private func statusMark(_ phase: DisplayPhase) -> some View {
        Image(systemName: symbol(phase))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(phaseColor(phase))
            .frame(width: 30, height: 30)
            .background(phaseColor(phase).opacity(0.11))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func statusBadge(_ phase: DisplayPhase) -> some View {
        Text(badgeText(phase))
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(phaseColor(phase))
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(phaseColor(phase).opacity(0.10))
            .clipShape(Capsule())
    }

    private func phaseTrack(_ phase: DisplayPhase) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(phase == .indexed ? LedgerWidgetColors.success : LedgerWidgetColors.cobalt)
            Capsule()
                .fill(phase == .indexed ? LedgerWidgetColors.success : phaseColor(phase).opacity(0.24))
        }
        .frame(height: 3)
    }

    private func symbol(_ phase: DisplayPhase) -> String {
        switch phase {
        case .indexing: "arrow.triangle.2.circlepath"
        case .waiting: "clock.badge.exclamationmark"
        case .indexed: "checkmark"
        }
    }

    private func title(_ phase: DisplayPhase) -> String {
        switch phase {
        case .indexing: "正在建立索引"
        case .waiting: "等待状态确认"
        case .indexed: "索引已完成"
        }
    }

    private func badgeText(_ phase: DisplayPhase) -> String {
        switch phase {
        case .indexing: "1 / 2"
        case .waiting: "待确认"
        case .indexed: "2 / 2"
        }
    }

    private func compactText(_ phase: DisplayPhase) -> String {
        switch phase {
        case .indexing: "1/2"
        case .waiting: "待确认"
        case .indexed: "完成"
        }
    }

    private func phaseColor(_ phase: DisplayPhase) -> Color {
        switch phase {
        case .indexing: LedgerWidgetColors.cobalt
        case .waiting: LedgerWidgetColors.gold
        case .indexed: LedgerWidgetColors.success
        }
    }

    private func detail(_ context: ActivityViewContext<ImportIndexActivityAttributes>) -> String {
        let count = context.attributes.entryCount
        return count == 0
            ? "\(context.attributes.providerLabel)账单已归档"
            : "\(context.attributes.providerLabel) · \(count) 条交易"
    }

    private func accessibilityLabel(
        _ context: ActivityViewContext<ImportIndexActivityAttributes>,
        phase: DisplayPhase
    ) -> String {
        "\(title(phase))，\(detail(context))，进度\(badgeText(phase))"
    }
}
#endif
