#if os(iOS)
import SwiftUI

/// Stops the chat following a running turn. Opening a tool group, a row or
/// a reasoning block calls it, so what opened stays under the reader's
/// finger instead of being pushed up by the page tracking the reply.
struct LedgerAgentFollowPause: Sendable {
    let pause: @MainActor @Sendable () -> Void
}

private struct LedgerAgentFollowPauseKey: EnvironmentKey {
    static let defaultValue: LedgerAgentFollowPause? = nil
}

extension EnvironmentValues {
    var ledgerAgentFollowPause: LedgerAgentFollowPause? {
        get { self[LedgerAgentFollowPauseKey.self] }
        set { self[LedgerAgentFollowPauseKey.self] = newValue }
    }
}

/// The steps behind an answer: its process folded into one line
/// (`LedgerAgentProcessLine`), then any text written between steps. The
/// answer itself is drawn after this by `LedgerAgentAnswer`.
struct LedgerAgentStepTimeline: View {
    let steps: [LedgerAgentStepRecord]
    /// How long the turn ran; nil in saves from before it was kept.
    var duration: TimeInterval? = nil
    var onAsk: (String) -> Void = { _ in }

    var body: some View {
        if LedgerAgentProcess.hasSteps(steps) {
            LedgerAgentProcessLine(steps: steps,
                                   summary: LedgerAgentProcess.summary(steps, elapsed: duration.map { Int($0.rounded()) }))
        }
        ForEach(LedgerAgentProcess.textIndices(steps), id: \.self) { index in
            LedgerAgentStreamingReply(text: steps[index].text, streaming: false, onAsk: onAsk)
        }
    }
}

/// The running turn as it streams in: the process line, whose time and
/// counts tick while it stays one line, the one line of what is under way
/// right now, and the reply growing under them. Above the reply nothing
/// changes height while the turn runs unless the reader opens the line, so
/// the page following the reply never sees it shrink.
struct LedgerAgentLiveTimeline: View {
    let turn: LedgerAgentLiveTurn
    let since: Date
    /// When the stream last sent anything.
    let quietSince: Date
    /// The page is following the reply. New text then lands in place, with
    /// no slide or layout animation for the page's jump to the bottom to
    /// race; read back, it comes in as it always has.
    var following = false
    /// The tallest the streamed reply has been this turn.
    @State private var replyHeight: CGFloat = 0

    /// A stream quiet this long gets the hint to stop and send again.
    static let slowAfter: TimeInterval = 45

    var body: some View {
        // Every text step keeps its view by its index, so the reply keeps
        // its place when a tool or reasoning follows it.
        let texts = LedgerAgentProcess.textIndices(turn.steps, includesAnswer: true)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    LedgerAgentProcessLine(
                        steps: turn.steps,
                        summary: LedgerAgentProcess.summary(
                            turn.steps, elapsed: Int(context.date.timeIntervalSince(since).rounded(.down))),
                        running: turn.running,
                        thinking: Set(turn.steps.indices.filter { turn.isThinking($0) }),
                        isLive: true)
                }
                activityLine
            }
            if !texts.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(texts, id: \.self) { index in
                        LedgerAgentStreamingReply(text: turn.steps[index].text, streaming: index == turn.steps.indices.last)
                            .transition(following ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: 6)))
                    }
                }
                // Streamed text only grows, but its Markdown does not: `**`
                // and a backtick read as characters until they close, and
                // table rows as prose until the rule under the header
                // arrives, so the reply can come out a few points shorter.
                // The page at the bottom would drop by that much and be
                // pushed back up on the next delta; the reply keeps the
                // tallest height it reached instead.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if height > replyHeight { replyHeight = height }
                }
                .frame(minHeight: replyHeight, alignment: .top)
            }
            if turn.compacting {
                Text("正在压缩较早的对话…").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    .frame(maxWidth: .infinity)
            }
            footer
        }
        // Following, the value stands still, so new text is not animated.
        .ledgerAnimation(LedgerMotion.disclose, value: following ? -1 : texts.count)
        .accessibilityIdentifier("ledger-agent-live")
    }

    /// The call running or the reasoning's last line, one line always held
    /// (with a space before there is anything to say), keeping the last of
    /// them between steps.
    private var activityLine: some View {
        Text(activity ?? " ").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .accessibilityHidden(activity == nil)
            .accessibilityIdentifier("ledger-agent-activity")
    }

    /// The same hints as before the stream began: the page can be left, and
    /// a stream gone quiet can be stopped and sent again.
    private var footer: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let slow = context.date.timeIntervalSince(quietSince) >= Self.slowAfter
            // Both hints are laid out and one is shown, so the longer slow
            // hint wrapping cannot grow the page and then shrink it.
            ZStack(alignment: .topLeading) {
                Text(Self.leaveHint).opacity(slow ? 0 : 1)
                Text(Self.slowHint).opacity(slow ? 1 : 0)
            }
            .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("正在回答")
            .accessibilityValue([activity, slow ? Self.slowHint : Self.leaveHint].compactMap { $0 }.joined(separator: "，"))
        }
        .accessibilityIdentifier("ledger-agent-running")
    }

    private var activity: String? { turn.activity?.text }

    private static var leaveHint: String { String(localized: "可以离开这一页或切到后台，答完会通知你") }
    private static var slowHint: String { String(localized: "模型这一步比较慢。网络不好时可以点停止，再发一次。") }
}

/// An answer's reasoning and tool calls folded into one line, collapsed
/// until tapped, live and saved alike, so a long run of reads never pushes
/// the reply down the page and the running turn's line becomes the saved
/// answer's in the same place. Opened, it lists every step in order: each
/// reasoning block, and each call with how it went and the start of what
/// came back.
struct LedgerAgentProcessLine: View {
    let steps: [LedgerAgentStepRecord]
    let summary: String
    /// Calls still running, by step index.
    var running: Set<Int> = []
    /// The reasoning still streaming, by step index.
    var thinking: Set<Int> = []
    var isLive = false
    @State private var expanded = false
    @Environment(\.ledgerAgentFollowPause) private var followPause

    var body: some View {
        let indices = LedgerAgentProcess.indices(steps)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                followPause?.pause()
                withLedgerAnimation(LedgerMotion.disclose) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if isLive {
                            ProgressView().controlSize(.mini).tint(BalancedPalette.meta)
                        } else {
                            Image(systemName: "list.bullet").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(BalancedPalette.edge)
                        }
                    }
                    .frame(width: 16)
                    Text(summary).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BalancedPalette.edge)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(BalancedPalette.sunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(indices.isEmpty)
            .accessibilityLabel(summary)
            .accessibilityValue(indices.isEmpty ? "" : (expanded ? "已展开" : "已收起"))
            .accessibilityIdentifier("ledger-agent-process")
            if expanded, !indices.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(indices, id: \.self) { index in
                        Group {
                            if let call = steps[index].call {
                                LedgerAgentToolRow(call: call, isRunning: running.contains(index))
                            } else {
                                LedgerAgentThinkingBlock(step: steps[index], isLive: thinking.contains(index))
                            }
                        }
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { BalancedPalette.ruleStrong.frame(width: 1) }
                .padding(.leading, 8)
                .ledgerAnimation(LedgerMotion.disclose, value: indices.count)
            }
        }
    }
}

/// One reasoning block in an opened process line. Collapsed, it says how
/// long the model thought, or that it still is; expanded, the whole text.
struct LedgerAgentThinkingBlock: View {
    let step: LedgerAgentStepRecord
    var isLive = false
    @State private var expanded = false
    @Environment(\.ledgerAgentFollowPause) private var followPause

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                followPause?.pause()
                withLedgerAnimation(LedgerMotion.disclose) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BalancedPalette.edge)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "已展开" : "已收起")
            .accessibilityIdentifier("ledger-agent-thinking")
            if expanded {
                Text(step.redacted ? String(localized: "（模型的思考内容已加密）") : step.text)
                    .font(BalancedReading.font(size: 14.5)).foregroundStyle(BalancedPalette.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { BalancedPalette.ruleStrong.frame(width: 1) }
                    .padding(.bottom, 6)
            }
        }
    }

    private var title: String {
        if isLive { return String(localized: "正在思考…") }
        guard let milliseconds = step.durationMs, milliseconds > 0 else { return String(localized: "思考过程") }
        return String(localized: "思考了 \(max(Int((Double(milliseconds) / 1000).rounded()), 1)) 秒")
    }
}

/// One tool call in an opened process line: whether it is running, done or
/// failed, how long it took, and the first lines of what came back (the
/// error when it failed). Tapped, it adds what it was asked and the result
/// in full, as far as the call kept it.
struct LedgerAgentToolRow: View {
    let call: LedgerAgentToolCall
    var isRunning = false
    @State private var open = false
    @Environment(\.ledgerAgentFollowPause) private var followPause

    /// Result lines shown before the row is opened.
    private static let closedLines = 3

    var body: some View {
        let details = !isRunning && Self.hasDetails(call)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                followPause?.pause()
                withLedgerAnimation(LedgerMotion.disclose) { open.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        status.frame(width: 14)
                        Text(call.title).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary)
                            .lineLimit(open ? nil : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if call.interrupted == true {
                            Text("已停止").balancedMono(size: 11).foregroundStyle(BalancedPalette.meta)
                        } else if let duration = Self.duration(call) {
                            Text(duration).balancedMono(size: 11).foregroundStyle(BalancedPalette.meta)
                        } else if call.isError {
                            Text("失败").balancedMono(size: 11).foregroundStyle(BalancedPalette.expense)
                        }
                    }
                    .frame(minHeight: 28)
                    if !open, !isRunning, let result = Self.result(call) {
                        Text(result.text).balancedMono(size: 11)
                            .foregroundStyle(result.isError ? BalancedPalette.expense : BalancedPalette.meta)
                            .lineLimit(Self.closedLines)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 22)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!details)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(call, isRunning: isRunning))
            .accessibilityValue(details ? (open ? "已展开" : "已收起") : "")
            .accessibilityIdentifier("ledger-agent-tools")
            if open, details { self.details }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var status: some View {
        if isRunning {
            ProgressView().controlSize(.mini).tint(BalancedPalette.meta)
        } else if call.interrupted == true {
            Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).foregroundStyle(BalancedPalette.meta)
        } else if call.isError {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(BalancedPalette.expense)
        } else {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(BalancedPalette.meta)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = call.source ?? call.argumentsText {
                Text(source).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.secondary)
                    .textSelection(.enabled)
            }
            if let result = Self.result(call) {
                Text(result.text).balancedMono(size: 11)
                    .foregroundStyle(result.isError ? BalancedPalette.expense : BalancedPalette.meta)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 22)
        .padding(.bottom, 4)
    }

    /// What came back: the error for a failed call, else the start of the
    /// result.
    private static func result(_ call: LedgerAgentToolCall) -> (text: String, isError: Bool)? {
        if call.isError, let error = nonEmpty(call.errorText) { return (text: error, isError: true) }
        guard let preview = nonEmpty(call.preview) else { return nil }
        return (text: preview, isError: false)
    }

    private static func hasDetails(_ call: LedgerAgentToolCall) -> Bool {
        call.source != nil || call.argumentsText != nil || nonEmpty(call.preview) != nil || nonEmpty(call.errorText) != nil
    }

    private static func duration(_ call: LedgerAgentToolCall) -> String? {
        guard let milliseconds = call.durationMs, milliseconds > 0 else { return nil }
        if milliseconds < 1000 { return String(localized: "\(milliseconds) 毫秒") }
        let seconds = (Double(milliseconds) / 1000).formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(seconds) 秒")
    }

    private static func accessibilityLabel(_ call: LedgerAgentToolCall, isRunning: Bool) -> String {
        let state = isRunning ? String(localized: "进行中")
            : call.interrupted == true ? String(localized: "已停止")
            : call.isError ? String(localized: "失败") : String(localized: "完成")
        return [call.title, state, duration(call)].compactMap { $0 }.joined(separator: "，")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Reply text through the same Markdown blocks as a finished answer. While
/// it streams, a code fence that has not closed reads as prose.
struct LedgerAgentStreamingReply: View {
    let text: String
    var streaming = true
    var onAsk: (String) -> Void = { _ in }

    var body: some View {
        ForEach(Array(LedgerAgentReplyText.segments(text, streaming: streaming).enumerated()), id: \.offset) { _, segment in
            LedgerAgentReplyBlock(segment: segment, onAsk: onAsk)
        }
    }
}

/// How full the model's context is, as a small ring beside the model chips;
/// a tap says how many tokens of how many.
struct LedgerAgentContextMeter: View {
    let usage: LedgerAgentUsage
    @State private var detailPresented = false

    /// From here on the meter warns that the conversation is nearly full.
    static let warningPercent = 80

    var body: some View {
        if let fraction = usage.fraction {
            let percent = Int((fraction * 100).rounded())
            // From the percent shown, so "80%" is never drawn in the calm tint.
            let tint = percent >= Self.warningPercent ? BalancedPalette.expense : BalancedPalette.meta
            Button { detailPresented = true } label: {
                HStack(spacing: 4) {
                    ZStack {
                        Circle().stroke(BalancedPalette.meta.opacity(0.2), lineWidth: 2)
                        Circle().trim(from: 0, to: fraction)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 12, height: 12)
                    Text(verbatim: "\(percent)%").balancedMono(size: 11).foregroundStyle(tint)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "上下文已用 \(percent)%"))
            .accessibilityIdentifier("ledger-agent-context-meter")
            .popover(isPresented: $detailPresented) {
                Text("上下文已用 \(percent)% · \(usage.contextTokens.formatted()) / \(usage.contextWindow.formatted()) tokens")
                    .balancedFont(size: 13).foregroundStyle(BalancedPalette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}
#endif
