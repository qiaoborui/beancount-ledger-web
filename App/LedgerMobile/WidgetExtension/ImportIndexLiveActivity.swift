#if !targetEnvironment(macCatalyst)
import ActivityKit
import SwiftUI
import WidgetKit

struct ImportIndexLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ImportIndexActivityAttributes.self) { context in
            let phase = displayPhase(context)
            LedgerGlassCard {
                LedgerLockBody(
                    header: String(localized: "账本"),
                    symbol: symbol(phase), color: phaseColor(phase),
                    title: title(phase), detail: detail(context)
                ) {
                    statusBadge(phase)
                } footer: {
                    progress(phase).padding(.top, 2)
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
                // The in-app island's row: hue disc, one-line title with a
                // quiet detail, the state word in the hue, then one track.
                DynamicIslandExpandedRegion(.leading) {
                    LedgerIslandDiscBadge(symbol: symbol(phase), color: phaseColor(phase))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(badgeText(phase))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(phaseColor(phase))
                        .padding(.trailing, 4)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(phase))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LedgerGlass.text)
                        Text(detail(context))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    progress(phase)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                }
            } compactLeading: {
                LedgerIslandDiscBadge(symbol: symbol(phase), color: phaseColor(phase), size: 18, symbolSize: 9)
            } compactTrailing: {
                Text(compactText(phase))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(phaseColor(phase))
            } minimal: {
                LedgerIslandDiscBadge(symbol: symbol(phase), color: phaseColor(phase), size: 18, symbolSize: 9)
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

    private func statusBadge(_ phase: DisplayPhase) -> some View {
        LedgerGlassPill(text: badgeText(phase), color: phaseColor(phase))
    }

    /// The import has two real stages, written to the ledger and indexed, so
    /// the one track sits halfway until the index lands. It never creeps on a
    /// timer: there is no measurable progress in between to show.
    private func progress(_ phase: DisplayPhase) -> some View {
        LedgerIslandProgressBar(fraction: phase == .indexed ? 1 : 0.5, color: phaseColor(phase))
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

    /// Imports are white in the in-app island too; only a stalled confirmation
    /// borrows the warm expense hue to ask for a look.
    private func phaseColor(_ phase: DisplayPhase) -> Color {
        switch phase {
        case .indexing, .indexed: LedgerIslandHue.neutral
        case .waiting: LedgerIslandHue.expense
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
