#if !targetEnvironment(macCatalyst)
import ActivityKit
import SwiftUI
import WidgetKit

/// 账本助手 working while the app is away: the step it is on and how long it
/// has run, then how the turn ended. On iOS 26 the system's own progress for
/// the continued task takes this place; this shows where that is unavailable.
struct LedgerAgentLiveActivity: Widget {
    private typealias Phase = LedgerAgentActivityAttributes.ContentState.Phase

    /// Both compact sides take this width. On the iPhone 18 Pro simulator the
    /// system gave each side of the compact pill its content's width plus an
    /// inset of 3.0-3.7pt, so a 14pt mark beside a 24.7pt timer grew the pill
    /// 17pt to the leading side of the camera and 28.3pt to the trailing one:
    /// it read as off-centre, and the mark's ink ended on the camera's edge.
    /// Equal sides let the system centre the pill, the rule
    /// `LedgerIslandStage.compactWidth` follows for the in-app island by taking
    /// the wider of its two sides. The width is the longest `m:ss` timer at the
    /// compact font, 33.5pt, so it holds for the first hour and a longer
    /// `h:mm:ss` one scales down instead of widening the pill. The cost is a
    /// pill about 29pt wider than the lopsided one it replaces; a narrower side
    /// would scale the common timer to pay for it.
    private static let compactSide: CGFloat = 34

    /// The running timer's column, fixed rather than a maximum.
    ///
    /// A flexible `.frame(maxWidth:)` takes the width the expanded region
    /// proposes, and can end up narrower than the timer's own ideal width. The
    /// timer then draws into too little room and its last digit is cut by the
    /// region's edge, which is a straight line in blank space, not the island's
    /// rounded end: on a 402pt-wide phone at step 15 the island still left the
    /// timer about 12pt of clearance while 0:45 lost part of its 5. A fixed
    /// column reserves the room up front, so the region cannot under-report it:
    /// the frame sets the size `trailing` reports, which is the size the region
    /// lays out, so it reserves the same room inside `trailing` as it would
    /// wrapped around the region's content.
    ///
    /// The column belongs to the timer alone. How a turn ended shows a steps
    /// pill, which keeps its own width instead of sitting centred in 64pt.
    /// 64pt holds an h:mm:ss timer at the expanded font; the 0.6 scale floor on
    /// the timer covers anything longer.
    private static let timerColumn: CGFloat = 64

    /// The subtitle gets two lines and then a tail ellipsis, so a longer step
    /// is shortened rather than run past the room the island gives it.
    private static let detailLines = 2

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LedgerAgentActivityAttributes.self) { context in
            let phase = context.state.phase
            LedgerGlassCard {
                LedgerLockBody(
                    header: String(localized: "账本助手"),
                    glyph: glyph(phase), color: color(phase),
                    title: title(phase), detail: context.state.detail, detailLines: LedgerAgentLiveActivity.detailLines
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
                DynamicIslandExpandedRegion(.leading) {
                    LedgerGlassBadge(glyph: glyph(phase), color: color(phase), size: 24, symbolSize: 12)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    trailing(context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(phase))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(LedgerGlass.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(context.state.detail)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LedgerGlass.secondary)
                            .lineLimit(LedgerAgentLiveActivity.detailLines)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            } compactLeading: {
                if phase == .running {
                    LedgerMark(accent: color(phase))
                        .frame(width: 14, height: 14)
                        .frame(width: LedgerAgentLiveActivity.compactSide)
                } else {
                    Image(systemName: symbol(phase))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color(phase))
                        .frame(width: LedgerAgentLiveActivity.compactSide)
                }
            } compactTrailing: {
                if phase == .running {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(LedgerGlass.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: LedgerAgentLiveActivity.compactSide)
                } else {
                    Image(systemName: "checkmark")
                        .foregroundStyle(color(phase))
                        .opacity(phase == .answered ? 1 : 0)
                        .frame(width: LedgerAgentLiveActivity.compactSide)
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
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.trailing)
                .frame(width: LedgerAgentLiveActivity.timerColumn, alignment: .trailing)
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
