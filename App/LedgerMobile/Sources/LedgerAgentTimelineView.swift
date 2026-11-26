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

/// The steps behind an answer laid out as FlowDown does, nothing folded
/// away: each run of reasoning and calls is a round under its own dim title
/// (`思考了 3 秒 · 读取了账本 2 次`), with every thought written out and
/// every call on a line of its own, and the text the model wrote between
/// rounds stands between them. The answer itself is drawn after this by
/// `LedgerAgentAnswer`.
struct LedgerAgentStepTimeline: View {
    let steps: [LedgerAgentStepRecord]
    /// How long the turn ran; nil in saves from before it was kept.
    var duration: TimeInterval? = nil
    var onAsk: (String) -> Void = { _ in }

    var body: some View {
        ForEach(LedgerAgentRound.blocks(steps)) { block in
            switch block {
            case let .round(indices):
                LedgerAgentRoundView(steps: steps, indices: indices)
            case let .text(index):
                LedgerAgentStreamingReply(text: steps[index].text, streaming: false, onAsk: onAsk)
            }
        }
    }
}

/// The running turn as it streams in, in the same rounds a saved answer
/// shows: the round under way has its title shimmer (`正在思考…`,
/// `正在执行工具…`), each new step and block fades in, thoughts and the
/// reply write on a glyph at a time, and a finished round's title settles
/// into what it did.
struct LedgerAgentLiveTimeline: View {
    let turn: LedgerAgentLiveTurn
    let since: Date
    /// When the stream last sent anything.
    let quietSince: Date
    /// The page is following the reply.
    var following = false
    /// The tallest the streamed turn has been.
    @State private var turnHeight: CGFloat = 0

    /// A stream quiet this long gets the hint to stop and send again.
    static let slowAfter: TimeInterval = 45

    var body: some View {
        // The reply keeps its place by its step's index as rounds follow it.
        let blocks = LedgerAgentRound.blocks(turn.steps, includesAnswer: true)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(blocks) { block in
                    Group {
                        switch block {
                        case let .round(indices):
                            // Equatable, like the text below: a frame of the
                            // stream redraws the block being written, not the
                            // rounds and text it already finished.
                            LedgerAgentRoundView(steps: turn.steps, indices: indices, running: turn.running,
                                                 isActive: block.id == blocks.last?.id, reveals: true)
                                .equatable()
                        case let .text(index):
                            LedgerAgentStreamingReply(text: turn.steps[index].text,
                                                      streaming: index == turn.steps.indices.last, reveals: true)
                                .equatable()
                        }
                    }
                    // Only the new block's opacity animates; nothing moves,
                    // so the page following the reply never races a slide.
                    .modifier(LedgerAgentFadeIn())
                }
            }
            // Streamed text only grows, but its Markdown does not (a table's
            // rows read as prose until the rule under the header arrives),
            // so the turn can come out a few points shorter. The page at the
            // bottom would drop by that much and be pushed back up on the
            // next frame; the turn keeps the tallest height it reached.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if height > turnHeight { turnHeight = height }
            }
            .frame(minHeight: turnHeight, alignment: .top)
            if turn.compacting {
                Text("正在压缩较早的对话…").balancedFont(size: 12.5).foregroundStyle(LedgerAgentPalette.meta)
                    .frame(maxWidth: .infinity)
            }
            footer
        }
        .accessibilityIdentifier("ledger-agent-live")
    }

    /// The same hints as before the stream began: the page can be left, and
    /// a stream gone quiet can be stopped and sent again.
    private var footer: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let slow = context.date.timeIntervalSince(quietSince) >= Self.slowAfter
            // Both hints are laid out and one is shown, so the longer slow
            // hint wrapping cannot grow the page and then shrink it.
            HStack(alignment: .top, spacing: 6) {
                // 豆豆 at the live edge: thinking while the model writes, the
                // magnifier while a tool runs.
                LedgerMascotView(state: turn.running.isEmpty ? .thinking : .tool, size: 24)
                    .offset(y: -3)
                ZStack(alignment: .topLeading) {
                    Text(Self.leaveHint).opacity(slow ? 0 : 1)
                    Text(Self.slowHint).opacity(slow ? 1 : 0)
                }
            }
            .balancedFont(size: 12.5).foregroundStyle(LedgerAgentPalette.meta)
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

/// One round of an answer: its title, then each thought in full and each
/// call on its line. How much is open follows 助手设置 › 显示; tapping the
/// title flips it for this round.
struct LedgerAgentRoundView: View, Equatable {
    /// What the round draws: its own steps, which of them run, and whether
    /// the turn is at work on it. The rest of the turn's steps do not count.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.indices == rhs.indices && lhs.isActive == rhs.isActive && lhs.reveals == rhs.reveals
            && lhs.indices.allSatisfy { index in
                lhs.steps.indices.contains(index) && rhs.steps.indices.contains(index)
                    && lhs.steps[index] == rhs.steps[index]
                    && lhs.running.contains(index) == rhs.running.contains(index)
            }
    }

    let steps: [LedgerAgentStepRecord]
    let indices: [Int]
    /// Calls still running, by step index.
    var running: Set<Int> = []
    /// The live turn is at work on this round.
    var isActive = false
    /// Thoughts write on a glyph at a time (the live turn).
    var reveals = false
    @AppStorage(LedgerAgentStepsDisplay.storageKey) private var display = LedgerAgentStepsDisplay.standard
    @State private var toggled = false
    @Environment(\.ledgerAgentFollowPause) private var followPause

    private var collapsed: Bool { (display == .folded) != toggled }

    private var title: String {
        LedgerAgentRound.title(steps, indices, isActive: isActive,
                               runningTool: isActive && indices.contains { running.contains($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                followPause?.pause()
                withLedgerAnimation(LedgerMotion.disclose) { toggled.toggle() }
            } label: {
                Text(title).balancedFont(size: 15).foregroundStyle(LedgerAgentPalette.meta)
                    .lineLimit(1).truncationMode(.tail)
                    // `正在思考…` settling into `思考了 2 秒` crossfades.
                    .contentTransition(.opacity)
                    .ledgerAnimation(.easeInOut(duration: 0.25), value: title)
                    .modifier(LedgerAgentShimmer(active: isActive))
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(collapsed ? "已收起" : "已展开")
            .accessibilityIdentifier("ledger-agent-process")
            if !collapsed {
                ForEach(indices, id: \.self) { index in
                    Group {
                        if let call = steps[index].call {
                            LedgerAgentToolRow(call: call, isRunning: running.contains(index), compact: true)
                        } else {
                            LedgerAgentThought(step: steps[index], reveals: reveals, folded: display != .expanded)
                        }
                    }
                    .modifier(LedgerAgentFadeIn(active: reveals))
                }
            }
        }
    }
}

/// Fades a block or a step in as it first appears in a streaming turn,
/// without animating its arrival. An opacity transition carrying its own
/// animation made the insertion an animated change: the rows under it slid
/// to their new places, and the list cell, sized by its hosting
/// configuration, grew over the same 0.3 s while the list had already moved
/// to the new end, so each new paragraph or tool call made the reply jump
/// and settle. Here the block takes its place at once and only its own
/// opacity changes, in a transaction of its own.
struct LedgerAgentFadeIn: ViewModifier {
    var active = true
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(!active || shown ? 1 : 0)
            .onAppear {
                guard active, !shown else { return }
                withLedgerAnimation(.easeInOut(duration: 0.3)) { shown = true }
            }
    }
}

/// A reasoning block written out in full, dim and small, as FlowDown lists
/// a thought under its round. Folded, it keeps to its latest line, which
/// changes as the model thinks on, and a tap opens the rest.
struct LedgerAgentThought: View {
    let step: LedgerAgentStepRecord
    var reveals = false
    var folded = false
    @State private var open = false
    @Environment(\.ledgerAgentFollowPause) private var followPause

    var body: some View {
        let text = step.redacted ? String(localized: "（模型的思考内容已加密）")
            : step.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            if folded && !open {
                Button {
                    followPause?.pause()
                    withLedgerAnimation(LedgerMotion.disclose) { open = true }
                } label: {
                    HStack(spacing: 4) {
                        Text(LedgerAgentRound.lastLine(text)).balancedFont(size: 13).foregroundStyle(LedgerAgentPalette.meta)
                            .lineLimit(1).truncationMode(.tail)
                            .contentTransition(.opacity)
                            .ledgerAnimation(.easeInOut(duration: 0.25), value: LedgerAgentRound.lastLine(text))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LedgerAgentPalette.meta)
                    }
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(text)
                .accessibilityHint("展开思考")
                .accessibilityIdentifier("ledger-agent-thinking")
            } else {
                Text(text).balancedFont(size: 13).foregroundStyle(LedgerAgentPalette.meta)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .modifier(LedgerAgentRevealText(text: text, active: reveals && !folded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ledger-agent-thinking")
            }
        }
    }
}

/// A band of light sweeping across a line whose work is under way, as
/// FlowDown's thinking title does: the text rests a little dimmed and the
/// band brightens it as it passes, sized to the text rather than the row so
/// it never spends most of its sweep on empty space. Off under Reduce
/// Motion and in UI test runs, where the line simply stays as it is.
private struct LedgerAgentShimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let period: TimeInterval = 1.6

    @ViewBuilder func body(content: Content) -> some View {
        if active && !reduceMotion && LedgerMotion.allowsAmbientMotion {
            content.mask {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.period) / Self.period
                    GeometryReader { proxy in
                        let band = max(proxy.size.width * 0.45, 48)
                        ZStack(alignment: .leading) {
                            Color.black.opacity(0.5)
                            LinearGradient(colors: [.black.opacity(0), .black, .black.opacity(0)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                .offset(x: -band + CGFloat(phase) * (proxy.size.width + band))
                        }
                    }
                }
            }
        } else {
            content
        }
    }
}

/// Fades a streaming block's new text in, a glyph at a time, as FlowDown's
/// replies do (`LedgerAgentRevealStore` keeps when each glyph appeared).
/// iOS 18 draws it through a `TextRenderer`; before that, under Reduce
/// Motion, in UI test runs, or once the reply is saved, text simply shows.
struct LedgerAgentRevealText: ViewModifier {
    let text: String
    let active: Bool
    @State private var store = LedgerAgentRevealStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            if active && !reduceMotion && LedgerMotion.allowsAmbientMotion {
                let now = Date.timeIntervalSinceReferenceDate
                let _ = store.note(text, now: now)
                // Ticks only while something may still be fading.
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: store.isSettled(now: now))) { context in
                    content.textRenderer(LedgerAgentRevealRenderer(store: store,
                                                                   tick: context.date.timeIntervalSinceReferenceDate))
                }
            } else {
                content
            }
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct LedgerAgentRevealRenderer: TextRenderer {
    let store: LedgerAgentRevealStore
    /// The frame being drawn; a new one redraws the fade.
    let tick: TimeInterval

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var glyphs = 0
        for line in layout {
            for run in line { glyphs += run.count }
        }
        let now = Date.timeIntervalSinceReferenceDate
        let appeared = store.appearances(glyphs: glyphs, now: now)
        func opacity(_ index: Int) -> Double {
            index < appeared.count ? LedgerAgentRevealStore.opacity(appeared: appeared[index], now: now) : 1
        }
        var index = 0
        for line in layout {
            for run in line {
                // Times grow along the text: a run whose last glyph is whole
                // is whole, and is drawn in one go.
                if run.isEmpty || opacity(index + run.count - 1) >= 1 {
                    context.draw(run)
                    index += run.count
                    continue
                }
                for glyph in run {
                    let alpha = opacity(index)
                    index += 1
                    if alpha >= 1 {
                        context.draw(glyph)
                    } else if alpha > 0 {
                        var faded = context
                        faded.opacity = alpha
                        faded.draw(glyph)
                    }
                }
            }
        }
    }
}

/// One tool call in an opened process line: whether it is running, done or
/// failed, how long it took, and the first lines of what came back (the
/// error when it failed). Tapped, it adds what it was asked and the result
/// in full, as far as the call kept it.
struct LedgerAgentToolRow: View {
    let call: LedgerAgentToolCall
    var isRunning = false
    /// One dim line under a round's title, as FlowDown lists a call: no
    /// status mark, time or result until it is opened, and only a failure
    /// or a stop said beside it.
    var compact = false
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
                        if !compact { status.frame(width: 14) }
                        Text(call.title).balancedFont(size: compact ? 13 : 13.5)
                            .foregroundStyle(compact ? LedgerAgentPalette.meta : LedgerAgentPalette.secondary)
                            .lineLimit(open ? nil : compact ? 1 : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if call.interrupted == true {
                            Text("已停止").balancedMono(size: 11).foregroundStyle(LedgerAgentPalette.meta)
                        } else if compact, !open {
                            if call.isError {
                                Text("失败").balancedMono(size: 11).foregroundStyle(LedgerAgentPalette.expense)
                            }
                        } else if let duration = Self.duration(call) {
                            Text(duration).balancedMono(size: 11).foregroundStyle(LedgerAgentPalette.meta)
                        } else if call.isError {
                            Text("失败").balancedMono(size: 11).foregroundStyle(LedgerAgentPalette.expense)
                        }
                    }
                    .frame(minHeight: compact ? 24 : 28)
                    if !compact, !open, !isRunning, let result = Self.result(call) {
                        Text(result.text).balancedMono(size: 11)
                            .foregroundStyle(result.isError ? LedgerAgentPalette.expense : LedgerAgentPalette.meta)
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
        .padding(.vertical, compact ? 0 : 6)
    }

    @ViewBuilder private var status: some View {
        if isRunning {
            ProgressView().controlSize(.mini).tint(LedgerAgentPalette.meta)
        } else if call.interrupted == true {
            Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).foregroundStyle(LedgerAgentPalette.meta)
        } else if call.isError {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(LedgerAgentPalette.expense)
        } else {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(LedgerAgentPalette.meta)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = call.source ?? call.argumentsText {
                Text(source).balancedMono(size: 11.5).foregroundStyle(LedgerAgentPalette.secondary)
                    .textSelection(.enabled)
            }
            if let result = Self.result(call) {
                Text(result.text).balancedMono(size: 11)
                    .foregroundStyle(result.isError ? LedgerAgentPalette.expense : LedgerAgentPalette.meta)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, compact ? 0 : 22)
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
/// it streams, a chart or visual still being written draws what it can and a
/// placeholder for the rest.
struct LedgerAgentStreamingReply: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.streaming == rhs.streaming && lhs.reveals == rhs.reveals
    }

    let text: String
    var streaming = true
    /// New text fades in (`LedgerAgentRevealText`): the live turn's text,
    /// never a saved answer's.
    var reveals = false
    var onAsk: (String) -> Void = { _ in }

    var body: some View {
        ForEach(Array(LedgerAgentReplyText.segments(text, ending: streaming ? .streaming : .finished).enumerated()), id: \.offset) { _, segment in
            // A paragraph already written is left alone while the next one
            // streams in.
            LedgerAgentReplyBlock(segment: segment, revealsNewText: reveals, onAsk: onAsk)
                .equatable()
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
            let tint = percent >= Self.warningPercent ? LedgerAgentPalette.expense : LedgerAgentPalette.meta
            Button { detailPresented = true } label: {
                HStack(spacing: 4) {
                    ZStack {
                        Circle().stroke(LedgerAgentPalette.meta.opacity(0.2), lineWidth: 2)
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
                    .balancedFont(size: 13).foregroundStyle(LedgerAgentPalette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}
#endif
