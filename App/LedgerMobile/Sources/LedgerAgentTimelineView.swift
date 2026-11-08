#if os(iOS)
import SwiftUI

/// The steps behind an answer: reasoning blocks, groups of tool calls and the
/// text written between them, in the order they happened. The answer itself
/// is drawn after this by `LedgerAgentAnswer`.
struct LedgerAgentStepTimeline: View {
    let steps: [LedgerAgentStepRecord]
    var onAsk: (String) -> Void = { _ in }

    var body: some View {
        ForEach(LedgerAgentTimelineItem.items(steps)) { item in
            switch item {
            case let .thinking(index):
                LedgerAgentThinkingBlock(step: steps[index])
            case let .tools(indices):
                LedgerAgentToolTimeline(rows: indices.compactMap { index in steps[index].call.map { .init(id: index, call: $0) } })
            case let .text(index):
                LedgerAgentStreamingReply(text: steps[index].text, streaming: false, onAsk: onAsk)
            }
        }
    }
}

/// The running turn as it streams in. The reply grows at the bottom; rows
/// and blocks appear as the model reaches them.
struct LedgerAgentLiveTimeline: View {
    let turn: LedgerAgentLiveTurn
    let since: Date

    var body: some View {
        let items = LedgerAgentTimelineItem.items(turn.steps, answerTrails: true)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(items) { item in
                Group {
                    switch item {
                    case let .thinking(index):
                        LedgerAgentThinkingBlock(step: turn.steps[index], isLive: turn.isThinking(index))
                    case let .tools(indices):
                        LedgerAgentToolTimeline(rows: indices.compactMap { index in
                            turn.steps[index].call.map { .init(id: index, call: $0, isRunning: turn.running.contains(index)) }
                        }, startsExpanded: true)
                    case let .text(index):
                        LedgerAgentStreamingReply(text: turn.steps[index].text, streaming: false)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if let answer = LedgerAgentTimelineItem.answerIndex(turn.steps, answerTrails: true) {
                LedgerAgentStreamingReply(text: turn.steps[answer].text, streaming: true)
            }
            if turn.compacting {
                Text("正在压缩较早的对话…").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    .frame(maxWidth: .infinity)
            }
            footer
        }
        .ledgerAnimation(LedgerMotion.disclose, value: items.count)
        .accessibilityIdentifier("ledger-agent-live")
    }

    /// How long the turn has run, under whatever it is doing.
    private var footer: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini).tint(BalancedPalette.meta)
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text("\(max(Int(context.date.timeIntervalSince(since).rounded(.down)), 0)) 秒")
                    .balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在回答")
        .accessibilityIdentifier("ledger-agent-running")
    }
}

/// One reasoning block. Collapsed, it says how long the model thought, or,
/// while it still is, shows the line it is on; expanded, the whole text.
struct LedgerAgentThinkingBlock: View {
    let step: LedgerAgentStepRecord
    var isLive = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
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
            } else if isLive, let line = lastLine {
                Text(line).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    .lineLimit(1).truncationMode(.head)
                    .accessibilityHidden(true)
            }
        }
    }

    private var title: String {
        if isLive { return String(localized: "正在思考…") }
        guard let milliseconds = step.durationMs, milliseconds > 0 else { return String(localized: "思考过程") }
        return String(localized: "思考了 \(max(Int((Double(milliseconds) / 1000).rounded()), 1)) 秒")
    }

    private var lastLine: String? {
        step.text.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// A run of tool calls under one summary line. Each row says whether the
/// call is running, done or failed, and how long it took; a row expands to
/// what it was asked and the start of what came back.
struct LedgerAgentToolTimeline: View {
    struct Row: Identifiable {
        let id: Int
        let call: LedgerAgentToolCall
        var isRunning = false
    }

    let rows: [Row]
    @State private var expanded: Bool
    @State private var open: Set<Int> = []

    init(rows: [Row], startsExpanded: Bool = false) {
        self.rows = rows
        _expanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withLedgerAnimation(LedgerMotion.disclose) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(Self.summary(rows.map(\.call))).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BalancedPalette.edge)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "已展开" : "已收起")
            .accessibilityIdentifier("ledger-agent-tools")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        self.row(row).transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { BalancedPalette.ruleStrong.frame(width: 1) }
                .ledgerAnimation(LedgerMotion.disclose, value: rows.count)
            }
        }
    }

    private func row(_ row: Row) -> some View {
        let call = row.call
        let details = !row.isRunning && Self.hasDetails(call)
        let isOpen = details && open.contains(row.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withLedgerAnimation(LedgerMotion.disclose) {
                    if open.contains(row.id) { open.remove(row.id) } else { open.insert(row.id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    status(row).frame(width: 14)
                    Text(call.title).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let duration = Self.duration(call) {
                        Text(duration).balancedMono(size: 11).foregroundStyle(BalancedPalette.meta)
                    } else if call.isError {
                        Text("失败").balancedMono(size: 11).foregroundStyle(BalancedPalette.expense)
                    }
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!details)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(row))
            .accessibilityValue(details ? (isOpen ? "已展开" : "已收起") : "")
            if isOpen { self.details(call) }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
    }

    @ViewBuilder private func status(_ row: Row) -> some View {
        if row.isRunning {
            ProgressView().controlSize(.mini).tint(BalancedPalette.meta)
        } else if row.call.isError {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(BalancedPalette.expense)
        } else {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(BalancedPalette.meta)
        }
    }

    private func details(_ call: LedgerAgentToolCall) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = call.source ?? call.argumentsText {
                Text(source).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.secondary)
                    .textSelection(.enabled)
            }
            if call.isError, let error = Self.nonEmpty(call.errorText) {
                Text(error).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.expense)
                    .textSelection(.enabled)
            } else if let preview = Self.nonEmpty(call.preview) {
                Text(preview).balancedMono(size: 11).foregroundStyle(BalancedPalette.meta)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 22)
        .padding(.bottom, 6)
    }

    /// The group's header, in the words the answer has always used.
    static func summary(_ calls: [LedgerAgentToolCall]) -> String {
        let edits = calls.filter(\.editsDraft).count
        if edits == 0, calls.contains(where: { $0.name == "reconcile_attachment" }) {
            return String(localized: "读取附件和账本 \(calls.count) 次")
        }
        return edits == 0
            ? String(localized: "读取了账本 \(calls.count) 次")
            : String(localized: "调用了 \(calls.count) 次工具，改了草稿 \(edits) 处")
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

    private static func accessibilityLabel(_ row: Row) -> String {
        let state = row.isRunning ? String(localized: "进行中") : row.call.isError ? String(localized: "失败") : String(localized: "完成")
        return [row.call.title, state, duration(row.call)].compactMap { $0 }.joined(separator: "，")
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
    static let warningFraction = 0.8

    var body: some View {
        if let fraction = usage.fraction {
            let tint = fraction >= Self.warningFraction ? BalancedPalette.expense : BalancedPalette.meta
            let percent = Int((fraction * 100).rounded())
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
