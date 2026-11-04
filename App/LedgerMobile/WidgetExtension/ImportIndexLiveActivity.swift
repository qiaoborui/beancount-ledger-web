#if !targetEnvironment(macCatalyst)
import ActivityKit
import SwiftUI
import WidgetKit

struct ImportIndexLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ImportIndexActivityAttributes.self) { context in
            let phase = displayPhase(context)
            LedgerGlassCard {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        statusMark(phase)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(phase))
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(LedgerGlass.text)
                                .ledgerGlassTextShadow()
                            Text(detail(context))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(LedgerGlass.secondary)
                                .ledgerGlassTextShadow()
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        statusBadge(phase)
                    }
                    phaseTrack(phase)
                }
            }
            .activityBackgroundTint(.clear)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "ledger://imports"))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(context, phase: phase))
        } dynamicIsland: { context in
            let phase = displayPhase(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LedgerGlassBadge(symbol: symbol(phase), color: phaseColor(phase), size: 24, symbolSize: 12)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(badgeText(phase))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(phaseColor(phase))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title(phase))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(LedgerGlass.text)
                        Text(detail(context))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LedgerGlass.secondary)
                        phaseTrack(phase)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: symbol(phase))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(phaseColor(phase))
            } compactTrailing: {
                Text(compactText(phase))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(LedgerGlass.text)
            } minimal: {
                Image(systemName: symbol(phase))
                    .foregroundStyle(phaseColor(phase))
            }
            .widgetURL(URL(string: "ledger://imports"))
            .keylineTint(phaseColor(phase))
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
        LedgerGlassBadge(symbol: symbol(phase), color: phaseColor(phase))
    }

    private func statusBadge(_ phase: DisplayPhase) -> some View {
        LedgerGlassPill(text: badgeText(phase), color: phaseColor(phase))
    }

    private func phaseTrack(_ phase: DisplayPhase) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(phaseColor(phase))
            Capsule()
                .fill(phase == .indexed ? LedgerGlass.success : Color.white.opacity(0.18))
        }
        .frame(height: 4)
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
        case .indexing: String(localized: "正在建立索引")
        case .waiting: String(localized: "等待状态确认")
        case .indexed: String(localized: "索引已完成")
        }
    }

    /// Phase words, not a step counter: the activity has three states and no
    /// measurable progress, and a hard-coded "1 / 2" read as a promise the
    /// island could not keep. The words match the entry island's own.
    private func badgeText(_ phase: DisplayPhase) -> String {
        switch phase {
        case .indexing: String(localized: "写入中")
        case .waiting: String(localized: "待确认")
        case .indexed: String(localized: "已入库")
        }
    }

    private func compactText(_ phase: DisplayPhase) -> String {
        switch phase {
        case .indexing: String(localized: "写入中")
        case .waiting: String(localized: "待确认")
        case .indexed: String(localized: "完成")
        }
    }

    private func phaseColor(_ phase: DisplayPhase) -> Color {
        switch phase {
        case .indexing: LedgerGlass.gold
        case .waiting: LedgerGlass.warning
        case .indexed: LedgerGlass.success
        }
    }

    private func detail(_ context: ActivityViewContext<ImportIndexActivityAttributes>) -> String {
        let count = context.attributes.entryCount
        return count == 0
            ? String(localized: "\(context.attributes.providerLabel)账单已归档")
            : String(localized: "\(context.attributes.providerLabel) · \(count) 条交易")
    }

    private func accessibilityLabel(
        _ context: ActivityViewContext<ImportIndexActivityAttributes>,
        phase: DisplayPhase
    ) -> String {
        String(localized: "\(title(phase))，\(detail(context))，\(badgeText(phase))")
    }
}
#endif
