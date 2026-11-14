import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif

/// One read the on-device Agent made while answering.
struct LedgerAgentToolCall: Codable, Equatable, Sendable {
    let name: String
    var arguments: BQLCell? = nil
    var isError: Bool
    /// The provider's id for the call, which pairs its start with its end.
    /// The fields from here on are absent in older saves and cores.
    var callId: String? = nil
    /// How long the tool ran; nil when it did not run.
    var durationMs: Int? = nil
    /// The start of the tool's result.
    var preview: String? = nil
    /// What went wrong, for a call that failed.
    var errorText: String? = nil
    /// The user stopped the turn while the call ran, so it never finished.
    var interrupted: Bool? = nil

    /// The row title, in the words of the design: what was read, then the range
    /// or search term when the arguments carry one.
    var title: String {
        if let remote = LedgerAgentMCPToolName.split(name) {
            // The server's own name, when this launch has read the saved list.
            return (LedgerAgentMCPServerIndex.shared.name(for: remote.server) ?? remote.server) + " · " + remote.tool
        }
        let base: String = switch name {
        case "get_ledger_summary": String(localized: "汇总")
        case "search_transactions": String(localized: "搜索流水")
        case "run_bql": String(localized: "BQL 查询")
        case "validate_bql": String(localized: "校验 BQL")
        case "get_bql_capabilities": String(localized: "BQL 能力")
        case "get_accounts": String(localized: "账户")
        case "list_files": String(localized: "列出文件")
        case "read_file": String(localized: "读取文件")
        case "edit_file": String(localized: "修改文件")
        case "write_file": String(localized: "写入草稿")
        case "bean_check": String(localized: "校验账本")
        case "list_attachments": String(localized: "查看附件")
        case "read_attachment": String(localized: "读取附件")
        case "reconcile_attachment": String(localized: "对账")
        case "view_attachment_image": String(localized: "查看图片")
        case "save_attachment": String(localized: "附件存入账本")
        case "move_file": String(localized: "移动文件")
        case "copy_file": String(localized: "复制文件")
        case "delete_file": String(localized: "删除文件")
        case "grep_files": String(localized: "搜索文件")
        case "draft_changes": String(localized: "查看草稿改动")
        case "ask_user": String(localized: "向你提问")
        case "set_ledger_profile": String(localized: "设置账本")
        case "upsert_account", "remove_account": String(localized: "整理账户")
        case "replace_categories", "upsert_category", "remove_category": String(localized: "整理分类")
        case "present_onboarding_plan": String(localized: "生成开账方案")
        case "list_saved_conversations": String(localized: "查看历史对话")
        case "read_saved_conversation": String(localized: "读取历史对话")
        case "edit_memory": String(localized: "更新记忆")
        case "write_memory": String(localized: "整理记忆")
        default: name
        }
        if name == "get_ledger_summary", let start = argument("start"), let end = argument("end") {
            return base + " · " + String(localized: "\(Self.shortDate(start)) 至 \(Self.shortDate(end))")
        }
        if name == "search_transactions", let query = argument("query") { return base + " · " + query }
        if ["read_file", "edit_file", "write_file", "delete_file", "save_attachment"].contains(name), let path = argument("path") {
            return base + " · " + path
        }
        if ["upsert_account", "remove_account", "upsert_category", "remove_category"].contains(name), let item = argument("name") {
            return base + " · " + item
        }
        if name == "grep_files", let pattern = argument("pattern") { return base + " · " + pattern }
        if name == "list_files", let pattern = argument("pattern") { return base + " · " + pattern }
        if name == "move_file" || name == "copy_file", let from = argument("from"), let to = argument("to") { return base + " · " + from + " → " + to }
        if name == "reconcile_attachment", let accounts = arrayArgument("accounts") { return base + " · " + accounts.joined(separator: "、") }
        if ["read_attachment", "view_attachment_image"].contains(name), let id = argument("id") { return base + " · " + id }
        return base
    }

    /// BQL text shown under the row, for the two tools that take one.
    var source: String? {
        guard name == "run_bql" || name == "validate_bql" else { return nil }
        return argument("query")
    }

    /// The arguments as compact JSON, for an expanded timeline row of a tool
    /// without BQL; nil when there are none.
    var argumentsText: String? {
        guard source == nil, let arguments, arguments != .null, arguments != .object([:]) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(arguments)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The tool counts as an edit of the draft in the timeline's summary.
    var editsDraft: Bool {
        ["edit_file", "write_file", "move_file", "copy_file", "delete_file", "save_attachment"].contains(name) && !isError
            && interrupted != true
    }

    private func arrayArgument(_ key: String) -> [String]? {
        guard case let .object(values)? = arguments, case let .array(items)? = values[key] else { return nil }
        let strings = items.compactMap { item -> String? in if case let .string(value) = item { value } else { nil } }
        return strings.isEmpty ? nil : strings
    }

    private func argument(_ key: String) -> String? {
        guard case let .object(values)? = arguments, case let .string(value)? = values[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `2026-10-01` → `10-01`; anything else is shown as given.
    private static func shortDate(_ value: String) -> String {
        value.count == 10 && value.dropFirst(4).first == "-" ? String(value.dropFirst(5)) : value
    }
}

/// One piece of a turn, in the order it happened: a reasoning block, a run of
/// reply text, or a tool call. Saved with the answer, so a reopened
/// conversation draws the same timeline.
struct LedgerAgentStepRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case thinking, text, tool }
    let kind: Kind
    /// The reasoning or the reply; empty for a tool and for redacted reasoning.
    var text = ""
    /// How long the reasoning took; a tool's own time is on its call.
    var durationMs: Int? = nil
    /// The provider sent the reasoning encrypted, so there is nothing to show.
    var redacted = false
    var call: LedgerAgentToolCall? = nil

    init(kind: Kind, text: String = "", durationMs: Int? = nil, redacted: Bool = false, call: LedgerAgentToolCall? = nil) {
        self.kind = kind
        self.text = text
        self.durationMs = durationMs
        self.redacted = redacted
        self.call = call
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, durationMs, redacted, call
        // The native response lists a tool step's call fields flat.
        case callId, name, arguments, isError, preview, errorText
    }

    /// Reads both the saved shape, with the call nested, and the native
    /// response's, with the call's fields beside `kind`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        redacted = try container.decodeIfPresent(Bool.self, forKey: .redacted) ?? false
        let duration = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        if let nested = try container.decodeIfPresent(LedgerAgentToolCall.self, forKey: .call) {
            call = nested
            durationMs = duration
        } else if kind == .tool {
            let name = try container.decode(String.self, forKey: .name)
            call = LedgerAgentToolCall(
                name: name, arguments: try? container.decodeIfPresent(BQLCell.self, forKey: .arguments),
                isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false,
                callId: try container.decodeIfPresent(String.self, forKey: .callId), durationMs: duration,
                preview: try container.decodeIfPresent(String.self, forKey: .preview),
                errorText: try container.decodeIfPresent(String.self, forKey: .errorText))
        } else {
            durationMs = duration
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if !text.isEmpty { try container.encode(text, forKey: .text) }
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
        if redacted { try container.encode(true, forKey: .redacted) }
        try container.encodeIfPresent(call, forKey: .call)
    }
}

/// The tokens of a turn: input, output and cache counts summed over its model
/// messages, and how full the context was at the last one.
struct LedgerAgentUsage: Codable, Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var contextTokens = 0
    var contextWindow = 0

    init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, contextTokens: Int = 0,
         contextWindow: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.contextTokens = contextTokens; self.contextWindow = contextWindow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try container.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheWrite = try container.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens) ?? 0
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 0
    }

    /// How much of the model's context the conversation fills, from 0 to 1;
    /// nil while either side is unknown.
    var fraction: Double? {
        guard contextWindow > 0, contextTokens > 0 else { return nil }
        return min(Double(contextTokens) / Double(contextWindow), 1)
    }
}

/// One streamed event of a running turn, beyond the model and tool steps the
/// Live Activity counts.
enum LedgerAgentLiveEvent: Equatable, Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case thinkingEnd(durationMs: Int?, redacted: Bool)
    case toolStart(LedgerAgentToolCall)
    case toolEnd(LedgerAgentToolCall)
    case usage(LedgerAgentUsage)
    case compactionStart
    case compactionEnd(summarizedTurns: Int?)
}

/// The running turn as it streams in: reasoning, reply text and tool calls in
/// the order they happened. Built by `apply`, one event at a time.
struct LedgerAgentLiveTurn: Equatable, Sendable {
    private(set) var steps: [LedgerAgentStepRecord] = []
    /// The tool calls started but not ended, by index into `steps`.
    private(set) var running: Set<Int> = []
    private(set) var usage: LedgerAgentUsage?
    /// Older turns are being summarized so the conversation fits.
    private(set) var compacting = false
    private(set) var compacted = false
    /// The reasoning block still streaming, by index into `steps`.
    private var openThinking: Int?
    /// What the turn is doing, for the one line under the live timeline: the
    /// reasoning streaming, or the call running. Between them it keeps the
    /// last one, so the line never blanks; nil until either has happened.
    private(set) var activity: LedgerAgentLiveActivity?

    /// The reply so far: the text of the latest model message that wrote
    /// any, which is what a stop keeps.
    var text: String { steps.last { $0.kind == .text }?.text ?? "" }

    /// Whether the reasoning block at `index` is still streaming.
    func isThinking(_ index: Int) -> Bool { openThinking == index }

    var isEmpty: Bool { steps.isEmpty }

    /// The steps as a stopped turn keeps them: a call still running is
    /// marked unfinished rather than drawn as done.
    var stoppedSteps: [LedgerAgentStepRecord] {
        var steps = steps
        for index in running where steps.indices.contains(index) { steps[index].call?.interrupted = true }
        return steps
    }

    mutating func apply(_ event: LedgerAgentLiveEvent) {
        defer { if let current = currentActivity { activity = current } }
        switch event {
        case let .thinkingDelta(text):
            if let open = openThinking {
                steps[open].text += text
            } else {
                steps.append(.init(kind: .thinking, text: text))
                openThinking = steps.count - 1
            }
        case let .thinkingEnd(durationMs, redacted):
            if let open = openThinking {
                steps[open].durationMs = durationMs
                steps[open].redacted = redacted
            } else {
                // Redacted reasoning streams nothing before its end.
                steps.append(.init(kind: .thinking, durationMs: durationMs, redacted: redacted))
            }
            openThinking = nil
        case let .textDelta(text):
            openThinking = nil
            if steps.last?.kind == .text {
                steps[steps.count - 1].text += text
            } else {
                steps.append(.init(kind: .text, text: text))
            }
        case let .toolStart(call):
            openThinking = nil
            guard index(of: call) == nil else { return }
            steps.append(.init(kind: .tool, call: call))
            running.insert(steps.count - 1)
        case let .toolEnd(call):
            openThinking = nil
            guard let index = index(of: call), var known = steps[index].call else {
                steps.append(.init(kind: .tool, call: call))
                return
            }
            known.isError = call.isError
            known.durationMs = call.durationMs
            known.preview = call.preview
            known.errorText = call.errorText
            if known.arguments == nil { known.arguments = call.arguments }
            steps[index].call = known
            running.remove(index)
        case let .usage(usage):
            self.usage = usage
        case .compactionStart:
            compacting = true
        case .compactionEnd:
            compacting = false
            compacted = true
        }
    }

    private func index(of call: LedgerAgentToolCall) -> Int? {
        guard let id = call.callId, !id.isEmpty else { return nil }
        return steps.lastIndex { $0.call?.callId == id }
    }

    /// What is under way right now; nil between steps. Reasoning that is
    /// still open came after every call started, since a call ends it.
    private var currentActivity: LedgerAgentLiveActivity? {
        if let open = openThinking, steps.indices.contains(open) {
            return .thinking(line: Self.lastLine(steps[open].text))
        }
        if let latest = running.max(), steps.indices.contains(latest), let call = steps[latest].call {
            return .tool(title: call.title, others: running.count - 1)
        }
        return nil
    }

    /// The last line of `text` with anything on it, trimmed; found from the
    /// end, since it runs on every reasoning delta.
    static func lastLine(_ text: String) -> String? {
        var end = text.endIndex
        repeat {
            let start = text[..<end].lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
            let line = text[start..<end].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
            // Step back over the line break in front of this line.
            end = start > text.startIndex ? text.index(before: start) : start
        } while end > text.startIndex
        return nil
    }
}

/// What a running turn is doing, as the live timeline's footer says it.
enum LedgerAgentLiveActivity: Equatable, Sendable {
    /// The latest call started and still running, with how many others run
    /// beside it.
    case tool(title: String, others: Int)
    /// The reasoning streaming, by its last line; nil before it has one or
    /// when it streams none.
    case thinking(line: String?)

    var text: String {
        switch self {
        case .tool(let title, 0): return title
        case let .tool(title, others): return String(localized: "\(title) 等 \(others + 1) 个调用")
        case let .thinking(line?): return String(localized: "正在思考：\(line)")
        case .thinking(nil): return String(localized: "正在思考…")
        }
    }
}

/// Whether the chat page has anything to scroll. Content shorter than the
/// page rests at the top, and following the reply must leave it there: a
/// scroll to the bottom anchor of content that fits asks for an offset the
/// page cannot hold, so the whole conversation moves and springs back on
/// every update.
enum LedgerAgentScrollFit {
    /// Rounding slack, in points.
    static let tolerance = 1.0

    /// The content, with the insets the page keeps clear above and below it
    /// (the top bar, the composer, the keyboard), is taller than the page.
    static func overflows(contentHeight: Double, topInset: Double = 0, bottomInset: Double = 0,
                          viewportHeight: Double) -> Bool {
        guard viewportHeight > 0 else { return false }
        return contentHeight + topInset + bottomInset > viewportHeight + tolerance
    }
}

/// An answer's process, the reasoning and tool calls behind it, folded into
/// one line above the reply: how long the turn ran and what it did, counted
/// in the words the tool groups have always used. The line opens to every
/// step in order; the reply's own text stays out of it.
enum LedgerAgentProcess {
    /// The steps the line folds, in order: reasoning and tool calls.
    static func indices(_ steps: [LedgerAgentStepRecord]) -> [Int] {
        steps.indices.filter { steps[$0].kind != .text }
    }

    /// The text steps drawn under the line, in order. `includesAnswer` keeps
    /// the last one too, for the live turn, which draws its reply itself.
    static func textIndices(_ steps: [LedgerAgentStepRecord], includesAnswer: Bool = false) -> [Int] {
        LedgerAgentTimelineItem.items(steps, includesAnswer: includesAnswer).compactMap { item in
            guard case let .text(index) = item else { return nil }
            return index
        }
    }

    static func hasSteps(_ steps: [LedgerAgentStepRecord]) -> Bool {
        steps.contains { $0.kind != .text }
    }

    /// The folded line: `已运行 1 分 40 秒 · 思考了 12 秒 · 读取了账本 6 次`.
    /// `elapsed` is nil for an answer saved without its duration.
    static func summary(_ steps: [LedgerAgentStepRecord], elapsed: Int?) -> String {
        var parts: [String] = []
        if let elapsed { parts.append(String(localized: "已运行 \(duration(seconds: elapsed))")) }
        let thought = steps.filter { $0.kind == .thinking }.compactMap(\.durationMs).reduce(0, +)
        if thought > 0 {
            parts.append(String(localized: "思考了 \(max(Int((Double(thought) / 1000).rounded()), 1)) 秒"))
        }
        let calls = steps.compactMap(\.call)
        if !calls.isEmpty { parts.append(toolSummary(calls)) }
        return parts.isEmpty ? String(localized: "思考过程") : parts.joined(separator: " · ")
    }

    /// `12 秒`, or `1 分 40 秒` from a minute on.
    static func duration(seconds: Int) -> String {
        let seconds = max(seconds, 0)
        guard seconds >= 60 else { return String(localized: "\(seconds) 秒") }
        return String(localized: "\(seconds / 60) 分 \(seconds % 60) 秒")
    }

    /// The tool calls, in the words the answer has always used.
    static func toolSummary(_ calls: [LedgerAgentToolCall]) -> String {
        let edits = calls.filter(\.editsDraft).count
        if edits == 0, calls.contains(where: { $0.name == "reconcile_attachment" }) {
            return String(localized: "读取附件和账本 \(calls.count) 次")
        }
        return edits == 0
            ? String(localized: "读取了账本 \(calls.count) 次")
            : String(localized: "调用了 \(calls.count) 次工具，改了草稿 \(edits) 处")
    }
}

/// A turn's steps as the timeline draws them: each reasoning block, each run
/// of adjacent tool calls as one group, and the text between them, in order.
/// The answer is drawn last by the reply itself, so its text step is left out.
enum LedgerAgentTimelineItem: Equatable, Identifiable, Sendable {
    case thinking(index: Int)
    case tools(indices: [Int])
    case text(index: Int)

    var id: Int {
        switch self {
        case let .thinking(index), let .text(index): index
        case let .tools(indices): indices.first ?? -1
        }
    }

    /// `answerTrails` leaves the last text step out only when nothing came
    /// after it, as while a turn is still running; otherwise the last text
    /// step is the answer wherever it fell. `includesAnswer` leaves nothing
    /// out, for the live turn, whose reply keeps its place as tools follow it.
    static func items(_ steps: [LedgerAgentStepRecord], answerTrails: Bool = false,
                      includesAnswer: Bool = false) -> [LedgerAgentTimelineItem] {
        let answer = includesAnswer ? nil : answerIndex(steps, answerTrails: answerTrails)
        var items: [LedgerAgentTimelineItem] = []
        for (index, step) in steps.enumerated() where index != answer {
            switch step.kind {
            case .thinking: items.append(.thinking(index: index))
            case .text:
                guard !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                items.append(.text(index: index))
            case .tool:
                if case var .tools(indices)? = items.last {
                    indices.append(index)
                    items[items.count - 1] = .tools(indices: indices)
                } else {
                    items.append(.tools(indices: [index]))
                }
            }
        }
        return items
    }

    /// The step that is the answer, drawn after the items.
    static func answerIndex(_ steps: [LedgerAgentStepRecord], answerTrails: Bool = false) -> Int? {
        let lastText = steps.lastIndex { $0.kind == .text }
        return answerTrails ? (lastText == steps.indices.last ? lastText : nil) : lastText
    }
}

/// A question the model put to the user with `ask_user`, shown as a card of
/// choices under its reply. The pick is sent as the next question.
struct LedgerAgentAsk: Codable, Equatable, Sendable {
    let question: String
    let options: [String]
    var multiple: Bool? = nil

    var allowsMultiple: Bool { multiple == true }

    /// The question sent for the picked options, in the card's order.
    func answer(_ picked: Set<String>) -> String {
        options.filter(picked.contains).joined(separator: "、")
    }
}

/// A change this conversation wrote to the ledger: the generation it was
/// written on (`parent`) and the one it made (`revision`), so it can be
/// undone later by reversing exactly that commit.
struct LedgerAgentWriteRecord: Codable, Equatable, Sendable {
    let parent: UUID
    let revision: UUID
    let files: [String]
    let writtenAt: Date
    var undoneAt: Date? = nil
}

/// One visible message. Tool reads hang off the assistant reply they led to.
struct LedgerAgentMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    /// Saved with the message, so a version of the conversation can name it
    /// across reopening.
    var id = UUID()
    let role: Role
    var text: String
    var toolCalls: [LedgerAgentToolCall] = []
    var duration: TimeInterval? = nil
    /// Names of the files sent with a question.
    var attachments: [String] = []
    /// The turn behind this answer changed the ledger's memory.md.
    var rememberedMemory = false
    /// The choices the reply asks the user to pick from.
    var ask: LedgerAgentAsk? = nil
    /// The change written to the ledger after this reply.
    var write: LedgerAgentWriteRecord? = nil
    /// The reasoning, text and tool calls behind the reply, in order; empty
    /// for replies from older builds, which show `toolCalls` alone.
    var steps: [LedgerAgentStepRecord] = []
    /// The user stopped the turn; the text is what it had written by then.
    var stopped = false
    var usage: LedgerAgentUsage? = nil
    /// The turn summarized older turns before it answered.
    var compacted = false
    /// The conversation's transcript does not hold this question: it is
    /// still running, it failed, or it was stopped and no transcript came
    /// back for it. Cutting the transcript back for a regenerate or an edit
    /// counts only the questions it holds.
    var outsideTranscript = false
    /// The App settings this answer changed, and what they were before, so the
    /// row under it can put them back.
    var settings: LedgerAgentAppSettingsChange? = nil
}

/// The provider and model a turn uses. The key travels separately.
struct LedgerAgentModelChoice: Codable, Equatable, Sendable {
    /// A user-supplied server that speaks one of the supported protocols.
    struct CustomEndpoint: Codable, Equatable, Sendable {
        enum API: String, Codable, CaseIterable, Identifiable, Sendable {
            case openAICompletions = "openai-completions"
            case openAIResponses = "openai-responses"
            case anthropicMessages = "anthropic-messages"
            var id: String { rawValue }
            var title: String {
                switch self {
                case .openAICompletions: "OpenAI Chat Completions"
                case .openAIResponses: "OpenAI Responses"
                case .anthropicMessages: "Anthropic Messages"
                }
            }
        }
        var api: API = .openAICompletions
        var baseURL = ""

        /// An http(s) URL with a host and no credentials, as the native side
        /// requires; checked here so the screen can say so before a turn.
        var isValid: Bool {
            guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host?.isEmpty == false, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { return false }
            return true
        }
    }

    static let customProvider = "custom"

    var provider: String
    var model: String
    var custom: CustomEndpoint? = nil

    var isCustom: Bool { provider == Self.customProvider }

    /// Whether the choice names a model a turn can call.
    var isComplete: Bool {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !isCustom || custom?.isValid == true
    }
}

/// Providers and models the native loop knows, as `ModelCatalogJSON` lists
/// them. Builds without the native core fall back to a single entry.
struct LedgerAgentCatalog: Decodable, Sendable {
    struct Model: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        /// The native catalog's levels, least to most; nil from older cores.
        var thinkingLevels: [String]? = nil

        var thinking: [LedgerAgentThinking] {
            let levels = (thinkingLevels ?? []).compactMap(LedgerAgentThinking.init(rawValue:))
            return levels.isEmpty ? [.off] : levels
        }
    }
    struct Provider: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let models: [Model]
    }
    let providers: [Provider]

    static let fallback = LedgerAgentCatalog(providers: [
        .init(id: "anthropic", title: "Anthropic", models: [.init(id: "claude-sonnet-4-5", title: "Claude Sonnet 4.5")]),
        .init(id: LedgerAgentModelChoice.customProvider, title: "自定义", models: []),
    ])

    static let native: LedgerAgentCatalog = {
        #if canImport(LedgerCore)
        if let catalog = try? JSONDecoder().decode(LedgerAgentCatalog.self, from: Data(MobileagentModelCatalogJSON().utf8)),
           !catalog.providers.isEmpty {
            return catalog
        }
        #endif
        return fallback
    }()

    func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }

    func modelTitle(_ choice: LedgerAgentModelChoice) -> String {
        provider(choice.provider)?.models.first { $0.id == choice.model }?.title ?? choice.model
    }
}

/// How hard the model reasons before answering. Each model accepts some of
/// these; a choice it does not accept falls to the nearest one it does.
enum LedgerAgentThinking: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, minimal, low, medium, high, xhigh, max

    static let `default` = LedgerAgentThinking.medium
    /// What a custom endpoint is offered: it cannot say what it supports.
    static let custom: [LedgerAgentThinking] = [.off, .minimal, .low, .medium, .high]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "关")
        case .minimal: String(localized: "最少")
        case .low: String(localized: "低")
        case .medium: String(localized: "中")
        case .high: String(localized: "高")
        case .xhigh: String(localized: "超高")
        case .max: String(localized: "最大")
        }
    }

    var hint: String? {
        switch self {
        case .off: String(localized: "不思考，直接回答和调用工具")
        case .low: String(localized: "简单查询")
        case .medium: String(localized: "大多数查账和单笔修改")
        case .high: String(localized: "跨多个文件的批量修改")
        case .minimal, .xhigh, .max: nil
        }
    }

    /// The supported level nearest to this one: the next stronger, else the
    /// next weaker, as the native loop clamps.
    func clamped(to supported: [LedgerAgentThinking]) -> LedgerAgentThinking {
        guard !supported.contains(self) else { return self }
        let all = Self.allCases, index = all.firstIndex(of: self) ?? 0
        if let stronger = all[index...].first(where: supported.contains) { return stronger }
        return all[..<index].last(where: supported.contains) ?? supported.first ?? .off
    }
}

/// A model the provider says the key can call, from `ListModelsJSON`.
struct LedgerAgentListedModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var thinkingLevels: [String]? = nil
    /// The native catalog describes it; otherwise its levels are assumed.
    var known = false
    /// Its context in tokens, from the provider's list or else the catalog;
    /// nil when neither says.
    var contextWindow: Int? = nil
    /// The most it may write in one reply, from the provider's list; nil
    /// when the list does not say.
    var maxOutputTokens: Int? = nil

    var thinking: [LedgerAgentThinking] {
        let levels = (thinkingLevels ?? []).compactMap(LedgerAgentThinking.init(rawValue:))
        return levels.isEmpty ? LedgerAgentThinking.custom : levels
    }
}

/// The blocking JSON boundary to the native model list. Tests substitute it.
struct LedgerAgentModelLister: Sendable {
    private struct Request: Encodable {
        let version = 1
        let provider: String
        let apiKey: String
        let custom: LedgerAgentModelChoice.CustomEndpoint?
    }
    private struct Response: Decodable {
        let ok: Bool
        var models: [LedgerAgentListedModel] = []
        var error: String?
    }

    var run: @Sendable (Data) async throws -> Data

    static let native = LedgerAgentModelLister(run: { request in
        #if canImport(LedgerCore)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Data(MobileagentListModelsJSON(String(decoding: request, as: UTF8.self)).utf8))
            }
        }
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    })

    /// The provider's models for this key, in the order it lists them.
    func models(for choice: LedgerAgentModelChoice, apiKey: String) async throws -> [LedgerAgentListedModel] {
        let request = Request(provider: choice.provider, apiKey: apiKey, custom: choice.isCustom ? choice.custom : nil)
        let response = try JSONDecoder().decode(Response.self, from: try await run(try JSONEncoder().encode(request)))
        guard response.ok else { throw LedgerAgentError.classify(response.error ?? String(localized: "拉取模型列表失败")) }
        return response.models
    }
}

/// The wire request of `RunTurnJSON`. The native decoder rejects unknown
/// fields, so this lists exactly what the Go side accepts.
struct LedgerAgentTurnRequest: Encodable, Sendable {
    struct HistoryEntry: Encodable, Equatable, Sendable { let role: String; let content: String }
    let version = 1
    let turnId: String
    let workspaceRoot: String
    let runtimeRoot: String
    let entrypoint: String
    var modelHandle: String?
    let sensitiveUnlocked: Bool
    let provider: String
    let model: String
    let apiKey: String
    var custom: LedgerAgentModelChoice.CustomEndpoint? = nil
    var thinking: String? = nil
    let history: [HistoryEntry]
    let message: String
    /// The private ledger copy this turn may edit; nil keeps the turn read-only.
    var scratchRoot: String? = nil
    /// What the previous answered turn returned, sent back unchanged so the
    /// model sees its earlier tool results and the provider can serve the
    /// unchanged prefix from its prompt cache. Replaces `history` when set.
    var transcript: String? = nil
    /// Keys the provider's prompt cache to the conversation.
    var conversationId: String? = nil
    /// Every file of the conversation; those sent with this question are new.
    var attachments: [LedgerAgentAttachment.Payload]? = nil
    /// The ledger's memory.md; nil turns memory off for the turn.
    var memoryPath: String? = nil
    /// Asks for the reply, the reasoning and each tool's start and end as
    /// they happen, beside the model and tool steps.
    var streamEvents: Bool? = nil
    /// The ledger an onboarding conversation is drafting. Such a turn takes
    /// no ledger: the roots and entrypoint stay empty.
    var onboarding: LedgerOnboardingState? = nil
    /// The device's calendar day, yyyy-MM-dd: Go on iOS keeps time in UTC,
    /// so an onboarding turn takes "today" from here.
    var today: String? = nil
    /// The model's context in tokens as the provider's list gave it; nil
    /// keeps the native catalog's window, or a common one.
    var contextWindow: Int? = nil
    /// The model's reply limit as the provider's list gave it. The native side
    /// applies it only to a model its catalog does not describe, a custom
    /// endpoint's included; nil keeps the common limit.
    var maxOutputTokens: Int? = nil
    /// The skills the user turned off: no turn lists or loads them. nil when
    /// nothing is off, so the request is unchanged for anyone who never
    /// touched the 技能 page.
    var disabledSkills: [String]? = nil
    /// The App's own settings (home page, tabs, valuation, reminders,
    /// reports), so the native settings tools can read and change them. The
    /// turn answers with the ones it changed. Nil turns them off.
    var appSettings: LedgerAgentAppSettings? = nil
    /// The user's remote MCP servers whose tools this turn may call, each with
    /// the token the Keychain holds as a header; nil when none are enabled.
    /// Appended last so the cached prompt prefix of an earlier build stays.
    var mcpServers: [LedgerAgentMCPServer.Payload]? = nil
}

struct LedgerAgentTurnResponse: Decodable, Sendable {
    let ok: Bool
    var reply: String? = nil
    var toolCalls: [LedgerAgentToolCall] = []
    var error: String? = nil
    var cancelled: Bool? = nil
    var modelUnavailable: Bool? = nil
    /// The turn wrote to its scratch copy, even if it then failed.
    var edited = false
    /// The whole conversation as the model saw it, for the next turn. Only
    /// an answered turn has one.
    var transcript: String? = nil
    /// The turn rewrote memory.md, even if it then failed.
    var memoryUpdated = false
    /// Choices the model asked the user to pick from; the reply repeats the
    /// question.
    var ask: LedgerAgentAsk? = nil
    /// The reasoning, text and tool calls of the turn, in order; empty from
    /// older cores.
    var steps: [LedgerAgentStepRecord] = []
    /// The turn's tokens; nil when no model message ended.
    var usage: LedgerAgentUsage? = nil
    /// "aborted" for a turn the user stopped. A stopped turn still returns
    /// what it wrote so far as `reply`, and a transcript the next question can
    /// follow unless the model had said nothing yet.
    var stopReason: String? = nil
    /// The turn summarized older turns of its transcript to fit.
    var compacted = false
    /// The onboarding draft as the turn left it; only an onboarding turn that
    /// answered or was stopped has one.
    var onboarding: LedgerOnboardingState? = nil
    /// The App settings a turn changed, with the sections it changed; nil when
    /// it changed none. A failed or stopped turn never carries one.
    var appSettings: LedgerAgentAppSettingsUpdate? = nil

    private enum CodingKeys: String, CodingKey {
        case ok, reply, toolCalls, error, cancelled, modelUnavailable, edited, transcript, memoryUpdated, ask
        case steps, usage, stopReason, compacted, onboarding, appSettings
    }
    init(ok: Bool, reply: String? = nil, toolCalls: [LedgerAgentToolCall] = [], error: String? = nil,
         cancelled: Bool? = nil, modelUnavailable: Bool? = nil, edited: Bool = false, transcript: String? = nil,
         memoryUpdated: Bool = false, ask: LedgerAgentAsk? = nil, steps: [LedgerAgentStepRecord] = [],
         usage: LedgerAgentUsage? = nil, stopReason: String? = nil, compacted: Bool = false,
         appSettings: LedgerAgentAppSettingsUpdate? = nil) {
        self.ok = ok; self.reply = reply; self.toolCalls = toolCalls; self.error = error
        self.cancelled = cancelled; self.modelUnavailable = modelUnavailable; self.edited = edited
        self.transcript = transcript; self.memoryUpdated = memoryUpdated; self.ask = ask
        self.steps = steps; self.usage = usage; self.stopReason = stopReason; self.compacted = compacted
        self.appSettings = appSettings
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        reply = try container.decodeIfPresent(String.self, forKey: .reply)
        toolCalls = try container.decodeIfPresent([LedgerAgentToolCall].self, forKey: .toolCalls) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
        cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled)
        modelUnavailable = try container.decodeIfPresent(Bool.self, forKey: .modelUnavailable)
        edited = try container.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        memoryUpdated = try container.decodeIfPresent(Bool.self, forKey: .memoryUpdated) ?? false
        // A malformed card is dropped; the reply still carries the question.
        ask = try? container.decodeIfPresent(LedgerAgentAsk.self, forKey: .ask)
        // A step of a kind this build does not know is left out, not the reply.
        steps = (try? container.decodeIfPresent([Lossy<LedgerAgentStepRecord>].self, forKey: .steps))?
            .compactMap(\.value) ?? []
        usage = try? container.decodeIfPresent(LedgerAgentUsage.self, forKey: .usage)
        stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
        compacted = try container.decodeIfPresent(Bool.self, forKey: .compacted) ?? false
        onboarding = try container.decodeIfPresent(LedgerOnboardingState.self, forKey: .onboarding)
        // A change this build cannot read is dropped; the reply still stands.
        appSettings = try? container.decodeIfPresent(LedgerAgentAppSettingsUpdate.self, forKey: .appSettings)
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}

enum LedgerAgentError: LocalizedError, Equatable {
    case notConfigured
    case invalidKey(String)
    case failed(String)
    /// The system took back the app's background time before the turn ended.
    case interrupted

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "请先设置模型与 API Key")
        case .invalidKey: String(localized: "API Key 无效或已过期")
        case let .failed(message): message
        case .interrupted: String(localized: "App 在后台的时间用完了，这次回答被中断")
        }
    }

    /// The provider's own words, shown under the headline.
    var detail: String? {
        switch self {
        case .notConfigured, .interrupted: nil
        case let .invalidKey(message), let .failed(message): message
        }
    }

    /// The one-line headline above the provider's words: what kind of
    /// failure this is, so the user knows whether a retry will help.
    var headline: String {
        switch self {
        case .notConfigured, .interrupted: return localizedDescription
        case .invalidKey: return String(localized: "API Key 无效或已过期")
        case let .failed(message):
            let lowered = message.lowercased()
            func has(_ words: [String]) -> Bool { words.contains { lowered.contains($0) } }
            if has(["没有任何响应", "超过", "太久", "timeout", "timed out", "deadline", "stalled", "超时"]) {
                return String(localized: "模型服务长时间没有响应")
            }
            if has(["429", "rate limit", "rate_limit", "too many requests", "quota", "insufficient_quota", "余额"]) {
                return String(localized: "模型服务限流或额度不足")
            }
            if has(["500", "502", "503", "504", "529", "overloaded", "unavailable", "bad gateway"]) {
                return String(localized: "模型服务暂时不可用")
            }
            if has(["connection", "network", "no such host", "eof", "broken pipe", "tls", "dial tcp", "terminated", "offline"]) {
                return String(localized: "网络连接出了问题")
            }
            if has(["没有给出文字回答", "没有返回回答", "长度上限", "工具的次数太多"]) {
                return String(localized: "这次没有得到回答")
            }
            return String(localized: "模型服务拒绝了这次请求")
        }
    }

    /// Provider errors arrive as text; an auth failure is the one the screen
    /// offers a direct fix for.
    static func classify(_ message: String) -> LedgerAgentError {
        let lowered = message.lowercased()
        let auth = ["401", "403", "unauthorized", "invalid x-api-key", "invalid api key", "invalid_api_key",
                    "authentication", "permission denied"]
        return auth.contains { lowered.contains($0) } ? .invalidKey(message) : .failed(message)
    }
}

/// The blocking JSON boundary to the native Agent loop. Tests substitute it.
struct LedgerAgentRunner: Sendable {
    var run: @Sendable (Data) async throws -> Data
    var cancel: @Sendable (String) -> Void
    /// Cuts a transcript back for a regenerate or an edit: the transcript,
    /// and how many of the last questions it holds to drop, with everything
    /// after the first of them. Counting from the end, not the front, keeps
    /// the cut right when the transcript lost its oldest turns. Throws when
    /// the transcript holds fewer questions, so a stale context is never
    /// resent.
    var truncate: @Sendable (String, Int) async throws -> String = { _, _ in throw LocalLedgerError.runtimeUnavailable }

    /// The native loop stops a turn after ten minutes on its own. If it has
    /// still not returned this long after that, the screen stops waiting.
    static let nativeDeadline: TimeInterval = 11 * 60

    static let native = LedgerAgentRunner(run: { request in
        #if canImport(LedgerCore)
        // A turn blocks for as long as the model takes; keep it off the
        // cooperative pool. The deadline is the last line of defence: the
        // screen must never wait forever, even on a call that never returns.
        let turnID = (try? JSONDecoder().decode(TurnID.self, from: request))?.turnId ?? ""
        return try await withDeadline(nativeDeadline, onTimeout: { MobileagentCancelTurn(turnID) }) {
            Data(MobileagentRunTurnJSON(String(decoding: request, as: UTF8.self)).utf8)
        }
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    }, cancel: { turnID in
        #if canImport(LedgerCore)
        MobileagentCancelTurn(turnID)
        #endif
    }, truncate: { transcript, dropUserTurns in
        #if canImport(LedgerCore)
        let request = try JSONEncoder().encode(TruncateRequest(transcript: transcript, dropUserTurns: dropUserTurns))
        let data = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Data(MobileagentTruncateTranscriptJSON(String(decoding: request, as: UTF8.self)).utf8))
            }
        }
        let response = try JSONDecoder().decode(TruncateResponse.self, from: data)
        guard response.ok, let cut = response.transcript else {
            throw LedgerAgentError.failed(response.error ?? String(localized: "没能截短对话记录"))
        }
        return cut
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    })

    private struct TurnID: Decodable { let turnId: String }

    /// The wire request of `TruncateTranscriptJSON`; the native decoder
    /// rejects unknown fields.
    private struct TruncateRequest: Encodable {
        let version = 1
        let transcript: String
        let dropUserTurns: Int
    }

    private struct TruncateResponse: Decodable {
        let ok: Bool
        var transcript: String?
        var error: String?
    }

    /// Runs a blocking call on a global queue and returns its result, or
    /// throws once `seconds` pass first. The call keeps its thread until it
    /// returns; its late result is dropped.
    static func withDeadline(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void,
                             _ work: @escaping @Sendable () -> Data) async throws -> Data {
        let gate = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            gate.set(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                gate.resume(with: .success(work()))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                if gate.resume(with: .failure(LedgerAgentError.failed(String(localized: "这一轮等了太久还没有结束，已经放弃等待。点重试再问一次。")))) {
                    onTimeout()
                }
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        func set(_ continuation: CheckedContinuation<Data, Error>) { lock.withLock { self.continuation = continuation } }
        /// True when this call was the one that resumed.
        @discardableResult
        func resume(with result: Result<Data, Error>) -> Bool {
            let pending: CheckedContinuation<Data, Error>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
            return pending != nil
        }
    }
}

/// What a running turn is doing now, as the native loop reports it: a request
/// to the model, or a tool it started.
struct LedgerAgentStep: Equatable, Sendable {
    /// `preparing` is the app's own work before the native loop sends its
    /// first event: copying the draft, loading the ledger, starting the loop.
    /// On a conversation's first question that can take a while on a large
    /// ledger, and without it the screen showed nothing changing.
    ///
    /// `live` carries a streamed event (reply or reasoning text, a tool's
    /// start or end, usage) on the same path. It is not a step: the
    /// conversation draws it, and the Live Activity never counts it.
    enum Kind: String, Sendable { case model, tool, preparing, live }
    let kind: Kind
    var call: LedgerAgentToolCall? = nil
    var detail: String? = nil
    var live: LedgerAgentLiveEvent? = nil

    static func live(_ event: LedgerAgentLiveEvent) -> LedgerAgentStep { .init(kind: .live, live: event) }

    static func preparing(_ detail: String) -> LedgerAgentStep { .init(kind: .preparing, detail: detail) }
    static var copyingDraft: LedgerAgentStep { .preparing(String(localized: "正在准备账本草稿")) }
    static var loadingLedger: LedgerAgentStep { .preparing(String(localized: "正在加载账本")) }
    static var startingLoop: LedgerAgentStep { .preparing(String(localized: "正在连接模型")) }

    var title: String {
        switch kind {
        case .preparing: return detail ?? String(localized: "正在准备")
        case .tool: return call?.title ?? String(localized: "正在思考")
        case .model, .live: return String(localized: "正在思考")
        }
    }

    /// One event of the native loop; nil for a version or kind this build
    /// does not know.
    static func decode(_ json: String) -> LedgerAgentStep? {
        struct Event: Decodable {
            let version: Int
            let kind: String
            var name: String?
            var arguments: BQLCell?
            var callId: String?
            var text: String?
            var durationMs: Int?
            var redacted: Bool?
            var isError: Bool?
            var preview: String?
            var errorText: String?
            var usage: LedgerAgentUsage?
            var summarizedTurns: Int?
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(json.utf8)), event.version == 1 else { return nil }
        let name = event.name.flatMap { $0.isEmpty ? nil : $0 }
        switch event.kind {
        case "model": return .init(kind: .model)
        case "tool":
            guard let name else { return nil }
            return .init(kind: .tool, call: .init(name: name, arguments: event.arguments, isError: false))
        case "text_delta":
            guard let text = event.text, !text.isEmpty else { return nil }
            return .live(.textDelta(text))
        case "thinking_delta":
            guard let text = event.text, !text.isEmpty else { return nil }
            return .live(.thinkingDelta(text))
        case "thinking_end":
            return .live(.thinkingEnd(durationMs: event.durationMs, redacted: event.redacted ?? false))
        case "tool_start":
            guard let name else { return nil }
            return .live(.toolStart(.init(name: name, arguments: event.arguments, isError: false, callId: event.callId)))
        case "tool_end":
            guard let name else { return nil }
            return .live(.toolEnd(.init(name: name, arguments: event.arguments, isError: event.isError ?? false,
                                        callId: event.callId, durationMs: event.durationMs,
                                        preview: event.preview, errorText: event.errorText)))
        case "usage":
            guard let usage = event.usage else { return nil }
            return .live(.usage(usage))
        case "compaction_start": return .live(.compactionStart)
        case "compaction_end": return .live(.compactionEnd(summarizedTurns: event.summarizedTurns))
        default: return nil
        }
    }
}

/// Routes the native loop's step events to the turn that asked for them.
/// Events arrive on a Go goroutine's thread, in order for each turn.
enum LedgerAgentSteps {
    typealias Handler = @Sendable (LedgerAgentStep) -> Void

    static func observe(_ turnID: String, _ handler: @escaping Handler) {
        _ = installed
        handlers.set(turnID, handler)
    }

    static func stop(_ turnID: String) { handlers.set(turnID, nil) }

    static func deliver(turnID: String, json: String) {
        guard let handler = handlers.get(turnID), let step = LedgerAgentStep.decode(json) else { return }
        handler(step)
    }

    private static let handlers = Handlers()

    private static let installed: Void = {
        #if canImport(LedgerCore)
        MobileagentSetObserver(Bridge())
        #endif
    }()

    private final class Handlers: @unchecked Sendable {
        private let lock = NSLock()
        private var byTurn: [String: Handler] = [:]
        func get(_ turnID: String) -> Handler? { lock.withLock { byTurn[turnID] } }
        func set(_ turnID: String, _ handler: Handler?) { lock.withLock { byTurn[turnID] = handler } }
    }

    #if canImport(LedgerCore)
    private final class Bridge: NSObject, MobileagentObserverProtocol {
        func event(_ turnID: String?, eventJSON: String?) {
            LedgerAgentSteps.deliver(turnID: turnID ?? "", json: eventJSON ?? "")
        }
    }
    #endif
}

/// What became of a turn, for whatever keeps it alive and reports it while
/// the app is away from the screen.
enum LedgerAgentTurnEnding: Equatable, Sendable {
    case answered(String)
    /// The reply, and how many files the change card shows.
    case changeReady(String, files: Int)
    case failed(String)
    case interrupted
    case stopped
}

/// Holds a running turn in the background and reports how it ends. The
/// conversation tells it each transition; it may call `interrupt()` when the
/// system wants the time back.
@MainActor
protocol LedgerAgentLifecycle: AnyObject {
    func turnStarted(question: String, conversation: LedgerAgentConversation)
    func turnStepped(_ step: LedgerAgentStep, count: Int)
    func turnEnded(_ ending: LedgerAgentTurnEnding)
    /// Whether iOS suspended the app while the running turn was out, so a
    /// failure it reports is a dead connection rather than the model's answer.
    var turnWasSuspended: Bool { get }
}

extension LedgerAgentLifecycle {
    var turnWasSuspended: Bool { false }
}

/// Turns the visible conversation into the history the next turn replays.
/// Only answered exchanges are sent, newest last, within a small budget so a
/// long chat does not resend everything.
enum LedgerAgentHistory {
    static let maximumMessages = 12
    static let maximumBytes = 24_000

    static func entries(from messages: [LedgerAgentMessage]) -> [LedgerAgentTurnRequest.HistoryEntry] {
        var pairs: [[LedgerAgentTurnRequest.HistoryEntry]] = []
        var pendingUser: LedgerAgentMessage?
        for message in messages {
            switch message.role {
            case .user: pendingUser = message
            case .assistant:
                // An empty reply is not worth replaying, and providers reject
                // an empty assistant turn.
                guard let user = pendingUser,
                      !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                pairs.append([.init(role: "user", content: user.text), .init(role: "assistant", content: message.text)])
                pendingUser = nil
            }
        }
        var kept: [[LedgerAgentTurnRequest.HistoryEntry]] = []
        var bytes = 0
        for pair in pairs.reversed() {
            let size = pair.reduce(0) { $0 + $1.content.utf8.count }
            guard kept.count * 2 + 2 <= maximumMessages, bytes + size <= maximumBytes else { break }
            kept.insert(pair, at: 0)
            bytes += size
        }
        return kept.flatMap { $0 }
    }
}

/// The private copy of the ledger one conversation lets the Agent edit. It
/// starts as the committed generation `baseRevisionID` names.
struct LedgerAgentDraft: Equatable, Sendable {
    let id: UUID
    let root: URL
    let baseRevisionID: UUID
}

/// What the draft amounts to against the committed ledger, ready to write.
/// `id` names the prepared change the repository holds for the commit.
struct LedgerAgentReview: Equatable, Sendable {
    let id: UUID
    let files: [LedgerAgentFileDiff]
    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

enum LedgerAgentEditError: LocalizedError, Equatable {
    /// The ledger was committed to since the draft was copied, and those
    /// commits changed the same lines (or the same binary file) as the draft.
    case conflict([String])
    /// The draft does not pass the app's own Beancount validation.
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .conflict(paths): String(localized: "账本在对话期间有了新的改动，和草稿改到了同一处：\(paths.joined(separator: "、"))")
        case let .invalid(message): message
        }
    }
}

/// The ledger side of editing: the draft copy, the change it amounts to, and
/// the existing validated commit. Tests substitute it.
struct LedgerAgentEditor: Sendable {
    var open: @Sendable () async throws -> LedgerAgentDraft
    /// nil when the draft equals the committed ledger. A draft copied from an
    /// older generation is merged onto the current one first.
    var review: @Sendable (LedgerAgentDraft) async throws -> LedgerAgentReview?
    /// Commits the reviewed change and returns the draft rebased on it.
    var write: @Sendable (LedgerAgentReview, LedgerAgentDraft) async throws -> LedgerAgentDraft
    /// Drops the change and returns a fresh copy of the current ledger.
    var discard: @Sendable (LedgerAgentReview?, LedgerAgentDraft) async throws -> LedgerAgentDraft
    var close: @Sendable (LedgerAgentDraft) async -> Void
    /// Carries the draft's changes over commits made since it was copied, so
    /// a turn sees the current ledger. Files whose changes conflict take the
    /// ledger's content and are returned, so the model can redo them. The
    /// draft comes back unchanged when the ledger has not moved.
    var rebase: @Sendable (LedgerAgentDraft) async throws -> (LedgerAgentDraft, dropped: [String]) = { ($0, []) }
    /// The generations a reviewed change was written on and made, once
    /// `write` committed it; nil when it is not known.
    var written: @Sendable (LedgerAgentReview) async -> (parent: UUID, revision: UUID)? = { _ in nil }
    /// Reverses a written change on top of the current ledger, as a new
    /// validated commit. Throws `.conflict` when later commits changed the
    /// same lines.
    var undo: @Sendable (LedgerAgentWriteRecord) async throws -> Void = { _ in
        throw LedgerAgentEditError.invalid(String(localized: "这个账本不支持撤销"))
    }
}

/// The change card under the conversation.
struct LedgerAgentPendingEdit: Equatable {
    enum Status: Equatable {
        case ready
        case invalid(String)
        case conflict([String])
        case writing
        case failed(String)
    }
    var review: LedgerAgentReview?
    var status: Status
    /// Why the change waits for the card's button rather than being written
    /// at once, said above the validation result; nil for the everyday
    /// changes the write policy commits on its own, and for 每次确认.
    var holdReason: String? = nil
}

/// One conversation behind the Agent screen. A validated change is written
/// through the write policy (tiered by default), and one the policy holds
/// back waits for the change card's confirmation. `LedgerAgentSessions` keeps
/// it beyond the screen, so a turn keeps running when the user leaves the
/// page or the app, and saves it after every settled turn.
@MainActor
final class LedgerAgentConversation: ObservableObject {
    let id: UUID
    let createdAt: Date

    enum Phase: Equatable {
        case idle
        case running(since: Date)
        case failed(LedgerAgentError, question: String)
    }

    /// The version on screen: the active path of `thread`, which follows
    /// every change made here.
    @Published private(set) var messages: [LedgerAgentMessage] = [] {
        didSet {
            thread.adopt(messages)
            replacedByVersionChange = showingVersion
        }
    }
    /// The last change to `messages` showed another version rather than a
    /// question or an answer, so the screen neither announces nor jumps.
    private(set) var replacedByVersionChange = false
    private var showingVersion = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pending: LedgerAgentPendingEdit?
    /// The last change written from this conversation, until the next turn.
    @Published private(set) var written: LedgerAgentReview?
    /// The message whose written change is being undone.
    @Published private(set) var undoing: UUID?
    /// The message whose App settings change is being undone.
    @Published private(set) var undoingSettings: UUID?
    /// Why the last undo did not go through, for the message it was asked on.
    @Published private(set) var undoFailure: UndoFailure?

    struct UndoFailure: Equatable {
        let message: UUID
        let text: String
    }
    /// What the running turn is doing now; nil before its first event.
    @Published private(set) var step: LedgerAgentStep?
    /// The running turn as it streams in; nil before its first streamed
    /// event, and from cores that do not stream. Text arrives at most every
    /// `liveInterval`, so a fast model does not redraw the page per token.
    @Published private(set) var live: LedgerAgentLiveTurn?
    /// How full the model's context was at the latest turn, for the meter.
    @Published private(set) var usage: LedgerAgentUsage?
    /// Everything the model saw and said so far, tool results included, as
    /// the last answered turn returned it. The next turn sends it back so
    /// follow-ups build on earlier reads; nil until a turn is answered (and
    /// for a conversation saved by an older build, which replays its visible
    /// history instead). A failed or stopped turn leaves it as it was.
    private(set) var transcript: String? {
        didSet { if transcript != nil { clearsStoredTranscript = false } }
    }
    /// When the running turn last reported a step, or started.
    private(set) var stepSince: Date?
    private(set) var stepCount = 0
    /// Shown above a reopened conversation whose change was never written.
    private(set) var restoredNotice: String?
    /// Files the model can read: sent with an earlier question, or with the
    /// one now running.
    @Published private(set) var attachments: [LedgerAgentAttachment] = []
    /// Files picked for the next question, shown above the composer.
    @Published private(set) var staged: [LedgerAgentAttachment] = []
    /// What the user will most likely say next, shown faintly in the
    /// composer; nil until predicted after an answer.
    @Published private(set) var nextSuggestion: String?
    /// The recap at the bottom of the conversation, and whether one is
    /// being written.
    @Published private(set) var recap: LedgerAgentRecap?
    @Published private(set) var recapping = false
    @Published private(set) var recapError: String?
    /// The name the model gave the conversation, saved with it; nil until the
    /// conversation has enough answers to be named, or when the user turned
    /// assists off.
    @Published private(set) var generatedTitle: String?
    /// Reopened from the history, so the screen recaps it on arrival.
    private(set) var restored = false
    /// Attached files no answered turn has told the model about yet; they
    /// stay new until a turn answers, so a retry announces them again.
    private(set) var unannounced: Set<String> = []
    /// Told when a turn, a write or a discard settles, so the conversation
    /// can be saved.
    var onSettled: ((LedgerAgentConversation) -> Void)?
    /// True while the Agent screen shows this conversation.
    var isOnScreen = false
    /// How a validated change reaches the ledger. Set from 助手设置 before
    /// each turn; conflicts and failed validation still stop for the user.
    var writePolicy = LedgerAgentWritePolicy.tiered
    weak var lifecycle: LedgerAgentLifecycle?
    private var task: Task<Void, Never>?
    /// A stopped or interrupted turn may have edited the draft without a card
    /// showing it, so the next turn reviews the draft even if it edits nothing.
    private var draftUnreviewed = false
    private var draft: LedgerAgentDraft?
    /// Told to the model with the next question, so it knows what became of
    /// the change it proposed.
    private var note: String?
    /// Bumped by `reset`, so work started before it does not land after it.
    private var epoch = 0
    /// Set when a turn was cut short by the system rather than by the model
    /// or the user, so coming back to the app can send it again on its own.
    private(set) var resumable = false
    /// Resumes in a row without an answer; a turn that keeps getting cut
    /// short waits for the user's retry instead of looping.
    private var resumes = 0
    static let maximumResumes = 2
    private var reopening: Task<LedgerAgentDraft?, Never>?
    var editor: LedgerAgentEditor?
    /// Reads the App settings a turn sends and writes the sections it changed;
    /// nil leaves the settings tools off, as in a test or a preview.
    var appSettings: LedgerAgentAppSettingsHost?
    /// Every streamed event so far; `live` is this as last published.
    private var liveDraft: LedgerAgentLiveTurn?
    private var livePublishedAt: Date?
    private var liveFlush: Task<Void, Never>?
    static let liveInterval: TimeInterval = 0.08

    /// A turn the user stopped whose native loop has not returned yet. It
    /// still brings back the authoritative partial reply and a transcript
    /// that includes it, and the next question waits briefly for them.
    private struct Stopping {
        let started: Date
        let question: UUID?
        /// The partial reply shown at once when the user stopped.
        let message: UUID?
        /// The note and the new files the stopped question was sent with;
        /// its transcript tells the model about these, and no others.
        let note: String?
        let unannounced: Set<String>
        /// A newer question stopped waiting for it and went on with the
        /// older transcript, so its late transcript is no longer the one to
        /// follow.
        var stale = false
    }
    private var stopping: Stopping?
    /// How long a new question waits for a stopped turn to return.
    var stopSettleTimeout: TimeInterval = 3

    /// Every version of the conversation: regenerated answers and edited
    /// questions branch off where they were asked.
    private(set) var thread = LedgerAgentThread()
    /// A regenerate, an edit or a switch is cutting the transcript back or
    /// loading another version's; nothing else starts until it lands.
    @Published private(set) var switching = false
    /// The transcripts of versions not on screen, by their last message.
    private var branchTranscripts: [UUID: String] = [:]
    /// The questions each of those transcripts does not hold. A question is
    /// shared by every answer under it, so its `outsideTranscript` follows
    /// the version on screen and is put back from here on a switch.
    private var branchOutside: [UUID: Set<UUID>] = [:]
    private var unsavedBranchTranscripts: Set<UUID> = []
    /// Reads a version's transcript an earlier run saved; set by the sessions.
    var loadBranchTranscript: (@Sendable (UUID) async -> String?)?
    /// Cuts the transcript back for a regenerate or an edit. Tests substitute it.
    var truncate: @Sendable (String, Int) async throws -> String = LedgerAgentRunner.native.truncate
    /// A version change left no transcript, so the one saved for the version
    /// that was on screen no longer applies and is cleared on the next save.
    private(set) var clearsStoredTranscript = false
    /// A version change since reopening: the transcript saved with the
    /// record belongs to a version no longer on screen.
    private var branchedSinceRestore = false

    var isRunning: Bool { if case .running = phase { true } else { false } }
    var isWriting: Bool { pending?.status == .writing }

    typealias Send = @Sendable (_ message: String, _ history: [LedgerAgentTurnRequest.HistoryEntry],
                                _ draft: URL?) async throws -> LedgerAgentTurnResponse
    typealias SendReporting = @Sendable (_ message: String, _ history: [LedgerAgentTurnRequest.HistoryEntry],
                                         _ draft: URL?, _ report: @escaping LedgerAgentSteps.Handler) async throws
        -> LedgerAgentTurnResponse

    init(id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
    }

    /// Reopens a saved conversation. Its draft is gone; a change it never
    /// wrote is dropped, and both the screen and the model are told so.
    convenience init(restoring saved: LedgerAgentSavedConversation) {
        self.init(id: saved.id, createdAt: saved.createdAt)
        thread = saved.thread()
        messages = thread.activePath
        usage = messages.last { $0.usage != nil }?.usage
        attachments = saved.attachments ?? []
        recap = saved.recap
        generatedTitle = saved.generatedTitle
        restored = true
        if saved.unwrittenChange {
            restoredNotice = String(localized: "上次的草稿改动没有写入，重新打开后已放弃。需要的话让助手重新改一次。")
            note = String(localized: "（系统提示：这是重新打开的旧对话，之前草稿里没有写入的改动已经放弃，账本以当前内容为准。）")
        }
    }

    /// Takes the transcript saved with a reopened conversation, unless a turn
    /// has already answered without it.
    func adoptTranscript(_ saved: String) {
        guard transcript == nil, !saved.isEmpty, !branchedSinceRestore else { return }
        transcript = saved
    }

    /// Opens the conversation with a greeting the app wrote, not the model:
    /// AI 开账 sums up the ledger it just made and offers next steps to tap.
    /// No turn is spent on it, and the greeting stays out of the transcript
    /// the model reads until the first real question follows it.
    func greet(_ opening: LedgerAgentOpening) {
        guard messages.isEmpty, !isRunning else { return }
        messages = [LedgerAgentMessage(role: .assistant, text: opening.text, ask: opening.ask)]
        // The card already names the steps, so the greeting alone need not
        // spend a prediction request for the composer's hint.
        nextSuggestion = opening.steps.first
    }

    /// What to save, or nil while nothing has been asked.
    func saved(at date: Date = Date()) -> LedgerAgentSavedConversation? {
        guard !messages.isEmpty else { return nil }
        let branches = thread.branches.map {
            LedgerAgentSavedConversation.Branch(parent: $0.parentID, index: $0.index, message: .init($0.message))
        }
        return LedgerAgentSavedConversation(
            version: 2, id: id, createdAt: createdAt, updatedAt: date,
            messages: messages.map(LedgerAgentSavedConversation.Message.init),
            unwrittenChange: pending?.review != nil || draftUnreviewed,
            attachments: attachments.isEmpty ? nil : attachments,
            recap: recap,
            generatedTitle: generatedTitle,
            branches: branches.isEmpty ? nil : branches,
            activeLeaf: thread.activeLeaf)
    }

    /// Every file, attached or staged, for the id of the next one.
    var allAttachments: [LedgerAgentAttachment] { attachments + staged }

    var canAttach: Bool { allAttachments.count < LedgerAgentAttachments.maximumCount && !isWriting }

    func stage(_ attachment: LedgerAgentAttachment) {
        guard !allAttachments.contains(where: { $0.id == attachment.id }) else { return }
        staged.append(attachment)
    }

    func unstage(_ id: String) {
        staged.removeAll { $0.id == id }
    }

    /// What the next turn sends: every file, with the staged and the not yet
    /// announced ones marked new.
    func attachmentPayloads(in directory: URL) -> [LedgerAgentAttachment.Payload] {
        allAttachments.map { $0.payload(in: directory, isNew: unannounced.contains($0.id) || staged.contains($0)) }
    }

    /// What a turn that is starting sends: the files that went with a
    /// question, with the not yet announced ones marked new. A file staged
    /// while the turn waited for its draft is for the next question.
    func turnAttachmentPayloads(in directory: URL) -> [LedgerAgentAttachment.Payload] {
        attachments.map { $0.payload(in: directory, isNew: unannounced.contains($0.id)) }
    }

    private struct Outcome: Sendable {
        let response: LedgerAgentTurnResponse
        let draft: LedgerAgentDraft?
        let review: Result<LedgerAgentReview?, Error>?
        /// The App settings the turn changed, once they applied.
        var settingsChange: LedgerAgentAppSettingsChange? = nil
        /// Why part of them did not apply, for the next turn.
        var settingsFailure: String? = nil
    }

    /// Starts a turn. The question shows at once; the reply, or the failure,
    /// replaces the running state when the turn ends. A turn that edited the
    /// draft is reviewed before the running state ends. False when the turn
    /// could not start, so the composer keeps the question.
    @discardableResult
    func send(_ raw: String, using send: @escaping Send) -> Bool {
        self.send(raw, reporting: { message, history, draft, _ in try await send(message, history, draft) })
    }

    /// Starts a turn whose native loop reports each step it takes.
    @discardableResult
    func send(_ raw: String, reporting send: @escaping SendReporting) -> Bool {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isRunning, !isWriting, !switching else { return false }
        var sentFiles: [String] = []
        if case let .failed(_, previous) = phase, let last = messages.last, last.role == .user, last.text == previous {
            if question == previous {
                // Asked again as it was: the question keeps its place, and the
                // answers a failed regenerate left under it stay its versions.
                takeStaged(into: messages.count - 1)
                begin(question, using: send)
                return true
            }
            if !thread.children(of: last.id).isEmpty, thread.fork(atUser: last.id, newText: question) != nil {
                // Other words for a question that has answers: a version beside it.
                messages = thread.activePath
                takeStaged(into: messages.count - 1)
                begin(question, using: send)
                return true
            }
            messages.removeLast()
            thread.remove(last.id)
            sentFiles = last.attachments
        }
        messages.append(.init(role: .user, text: question, attachments: sentFiles))
        takeStaged(into: messages.count - 1)
        begin(question, using: send)
        return true
    }

    /// The staged files go with the question at `index`.
    private func takeStaged(into index: Int) {
        guard !staged.isEmpty else { return }
        messages[index].attachments += staged.map(\.name)
        unannounced.formUnion(staged.map(\.id))
        attachments += staged
        staged = []
    }

    /// Runs a turn for the question the conversation ends on.
    private func begin(_ question: String, using send: @escaping SendReporting) {
        let history = LedgerAgentHistory.entries(from: messages)
        // Not in the transcript until a turn that holds it answers.
        let questionID = messages.last?.id
        if let last = messages.indices.last { messages[last].outsideTranscript = true }
        written = nil
        nextSuggestion = nil
        let started = Date()
        phase = .running(since: started)
        step = nil
        clearLive()
        stepSince = started
        stepCount = 0
        let editor = editor, existing = draft, reopening = reopening, unreviewed = draftUnreviewed
        let hadChange = pending != nil, settleTimeout = stopSettleTimeout
        let settingsHost = appSettings, settingsBefore = appSettings?.snapshot()
        let report: LedgerAgentSteps.Handler = { [weak self] step in
            Task { @MainActor in self?.advance(step, started: started) }
        }
        resumable = false
        lifecycle?.turnStarted(question: question, conversation: self)
        task = Task { [weak self] in
            // A turn stopped a moment ago may still bring back its partial
            // reply and the transcript this question should follow.
            let deadline = Date().addingTimeInterval(settleTimeout)
            while self?.stopping != nil, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            // Gave up waiting: this question follows the older transcript,
            // and what it builds must not be replaced when the stopped turn
            // returns late.
            if let self, let stopped = self.stopping, stopped.started != started { self.stopping?.stale = true }
            // Read after the wait, which may have settled the note.
            let message = (self?.note).map { $0 + "\n\n" + question } ?? question
            let outcome: Result<Outcome, Error>
            do {
                // A copy that cannot be made leaves the turn read-only.
                var draft = existing
                if draft == nil, reopening != nil || editor != nil { report(.copyingDraft) }
                if draft == nil, let reopening { draft = await reopening.value }
                if draft == nil, let editor { draft = try? await editor.open() }
                // The ledger may have moved on since the draft was copied (a
                // change written by hand, a sync, an import): carry the draft
                // over it, so the turn reads the current ledger.
                var message = message
                // A change card drawn against the older ledger is drawn again.
                var redraw = false
                if let editor, let copied = draft, let rebased = try? await editor.rebase(copied) {
                    draft = rebased.0
                    redraw = rebased.0.baseRevisionID != copied.baseRevisionID && (hadChange || !rebased.dropped.isEmpty)
                    if !rebased.dropped.isEmpty {
                        let files = rebased.dropped.joined(separator: "、")
                        message = String(localized: "（系统提示：账本在草稿之后有了新的改动，和你在这些文件里的修改冲突：\(files)。这些文件已恢复为账本当前的内容，你之前对它们的修改需要重新做。）")
                            + "\n\n" + message
                    }
                }
                let response = try await send(message, history, draft?.root, report)
                // Only an answered turn applies: a failed or stopped one drops
                // what it changed, like a change card it never finished.
                var settingsChange: LedgerAgentAppSettingsChange?
                var settingsFailure: String?
                if response.ok, let update = response.appSettings, !update.changedSections.isEmpty {
                    if let settingsHost, let settingsBefore {
                        let applied = await settingsHost.apply(update.snapshot, update.changedSections)
                        if !applied.applied.isEmpty {
                            settingsChange = LedgerAgentAppSettingsChange(sections: applied.applied,
                                                                         previous: settingsBefore)
                        }
                        if !applied.failures.isEmpty {
                            settingsFailure = applied.failures.joined(separator: "；")
                        }
                    } else {
                        settingsFailure = String(localized: "这台设备上没有可用的 App 设置")
                    }
                }
                var review: Result<LedgerAgentReview?, Error>?
                // A stopped turn leaves its draft for the next turn to review.
                if response.cancelled != true, response.edited || unreviewed || redraw, let editor, let draft {
                    do { review = .success(try await editor.review(draft)) } catch { review = .failure(error) }
                }
                outcome = .success(.init(response: response, draft: draft, review: review,
                                         settingsChange: settingsChange, settingsFailure: settingsFailure))
            } catch { outcome = .failure(error) }
            self?.finish(outcome, question: question, questionID: questionID, started: started)
        }
    }

    // MARK: Versions

    /// Regenerating, editing and switching versions wait while a turn runs,
    /// a version loads, or a change is on the card or being written: the user
    /// writes or discards it first, so a change never follows the user onto
    /// another version.
    var canBranch: Bool { !isRunning && !isWriting && !switching && pending == nil && undoing == nil }

    /// Where `id` stands among the versions at its place, from 0.
    func versions(of id: UUID) -> (index: Int, count: Int) { thread.siblings(of: id) }

    /// How many answers sit under the question `id` when it ends the
    /// conversation without one: a regenerate that failed or stopped before
    /// replying. 0 otherwise.
    func answersBeside(_ questionID: UUID) -> Int {
        guard messages.last?.id == questionID, messages.last?.role == .user else { return 0 }
        return thread.children(of: questionID).count
    }

    /// The question's number on screen, from 1.
    func questionNumber(_ id: UUID) -> Int? { thread.userTurnIndex(of: id).map { $0 + 1 } }

    /// Asks the question behind `answerID` again for another answer. The
    /// transcript is cut back to before the question, so the model answers
    /// as if for the first time; the old answer, and what followed it, stay
    /// a version to switch back to. The question's files are sent again.
    @discardableResult
    func regenerate(_ answerID: UUID, confirmed: Bool = false,
                    reporting send: @escaping SendReporting) -> LedgerAgentBranchResult {
        guard canBranch, let index = messages.firstIndex(where: { $0.id == answerID }),
              messages[index].role == .assistant,
              let questionIndex = messages[..<index].lastIndex(where: { $0.role == .user }) else { return .refused }
        let question = messages[questionIndex]
        let warning = warning(replacing: messages[(questionIndex + 1)...])
        if !warning.isEmpty, !confirmed { return .needsConfirmation(warning) }
        cut(dropping: recordedQuestions(in: messages[questionIndex...]), warning: warning) { [weak self] in
            guard let self else { return nil }
            self.thread.rewind(to: question.id)
            self.messages = self.thread.activePath
            return question
        } then: { [weak self] question in
            guard let self else { return }
            self.reannounce(question)
            self.begin(question.text, using: send)
        }
        return .started
    }

    /// Sends `newText` in place of the question `questionID`, as a version
    /// beside it. The transcript is cut back to before the question; the
    /// old question and everything after it stay a version to switch back
    /// to. Staged files go with the edited question, as from the composer.
    @discardableResult
    func editAndResend(_ questionID: UUID, newText: String, confirmed: Bool = false,
                       reporting send: @escaping SendReporting) -> LedgerAgentBranchResult {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canBranch, !text.isEmpty, let index = messages.firstIndex(where: { $0.id == questionID }),
              messages[index].role == .user else { return .refused }
        // A failed question nothing hangs under is simply asked again in
        // other words, as the composer does after a failure.
        if index == messages.count - 1, case .failed = phase, thread.children(of: questionID).isEmpty {
            return self.send(text, reporting: send) ? .started : .refused
        }
        let warning = warning(replacing: messages[index...])
        if !warning.isEmpty, !confirmed { return .needsConfirmation(warning) }
        cut(dropping: recordedQuestions(in: messages[index...]), warning: warning) { [weak self] in
            guard let self, let edited = self.thread.fork(atUser: questionID, newText: text) else { return nil }
            self.messages = self.thread.activePath
            return edited
        } then: { [weak self] edited in
            guard let self else { return }
            self.reannounce(edited)
            self.takeStaged(into: self.messages.count - 1)
            self.begin(text, using: send)
        }
        return .started
    }

    /// Shows the version `direction` places before (-1) or after (+1) the
    /// message `messageID`, with that version's transcript, so the next
    /// question continues from it.
    @discardableResult
    func switchBranch(_ messageID: UUID, direction: Int, confirmed: Bool = false) -> LedgerAgentBranchResult {
        guard canBranch, messages.contains(where: { $0.id == messageID }),
              let target = thread.sibling(of: messageID, offset: direction) else { return .refused }
        return show(target, from: messageID, confirmed: confirmed)
    }

    /// Back to the latest answer under the question `questionID`, which ends
    /// the conversation after a regenerate that failed or stopped early.
    @discardableResult
    func showLatestAnswer(of questionID: UUID, confirmed: Bool = false) -> LedgerAgentBranchResult {
        guard canBranch, answersBeside(questionID) > 0, let answer = thread.children(of: questionID).last else {
            return .refused
        }
        return show(answer, from: nil, confirmed: confirmed)
    }

    /// The other versions' transcripts not saved yet, by their last message.
    /// A version still on screen, such as the one a cut is leaving while it
    /// runs, stays queued for a later save.
    func takeUnsavedBranchTranscripts() -> [UUID: String] {
        let leaves = thread.inactiveLeaves
        let taken: [UUID: String] = unsavedBranchTranscripts.reduce(into: [:]) { result, leaf in
            if leaves.contains(leaf), let transcript = branchTranscripts[leaf] { result[leaf] = transcript }
        }
        unsavedBranchTranscripts.subtract(taken.keys)
        return taken
    }

    private func show(_ target: UUID, from messageID: UUID?, confirmed: Bool) -> LedgerAgentBranchResult {
        let start = messageID.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.count
        let warning = warning(replacing: messages[start...])
        if !warning.isEmpty, !confirmed { return .needsConfirmation(warning) }
        leaveVersion()
        let leaf = thread.newestLeaf(under: target)
        let known = branchTranscripts[leaf], outside = branchOutside[leaf]
        let load = loadBranchTranscript, epoch = epoch
        switching = true
        Task { [weak self] in
            var arriving = known
            if arriving == nil, let load { arriving = await load(leaf) }
            guard let self, self.epoch == epoch else { return }
            self.switching = false
            self.thread.switchTo(sibling: target)
            var path = self.thread.activePath
            Self.markOutside(&path, known: outside)
            self.showingVersion = true
            self.messages = path
            self.showingVersion = false
            self.transcript = arriving
            self.enterVersion(warning, switched: true)
            // The failure belonged to the version left behind.
            if case .failed = self.phase { self.phase = .idle }
            self.resumable = false
            self.onSettled?(self)
        }
        return .started
    }

    /// Cuts the transcript back by its last `drop` questions, then `apply`s
    /// the new version. Without a transcript, or when it cannot be cut, the
    /// next turn replays the visible history instead of a stale context.
    /// The thread is rewound before the cut transcript is taken, so a save
    /// on the way (a discarded draft, a recap landing) never pairs the cut
    /// transcript with the version being left.
    private func cut(dropping drop: Int, warning: LedgerAgentBranchWarning,
                     rewind: @escaping @MainActor () -> LedgerAgentMessage?,
                     then start: @escaping @MainActor (LedgerAgentMessage) -> Void) {
        leaveVersion()
        let source = transcript, truncate = truncate, epoch = epoch
        switching = true
        Task { [weak self] in
            var cut = source
            if let source, drop > 0 { cut = try? await truncate(source, drop) }
            guard let self, self.epoch == epoch else { return }
            self.switching = false
            guard let question = rewind() else { return }
            // The cut transcript does not hold the question about to be asked.
            if let last = self.messages.indices.last { self.messages[last].outsideTranscript = true }
            self.transcript = cut
            self.enterVersion(warning, switched: false)
            start(question)
        }
    }

    /// Keeps the transcript of the version being left, under its last
    /// message, with the questions it does not hold. A stop still settling
    /// belonged to it: its partial reply stays as shown, and its late
    /// transcript is not adopted.
    private func leaveVersion() {
        stopping = nil
        branchedSinceRestore = true
        if let leaf = thread.activeLeaf, thread.children(of: leaf).isEmpty, let transcript {
            branchTranscripts[leaf] = transcript
            branchOutside[leaf] = Set(messages.filter { $0.role == .user && $0.outsideTranscript }.map(\.id))
            unsavedBranchTranscripts.insert(leaf)
        }
    }

    /// Puts back which questions of a version's path its transcript does
    /// not hold. `known` is what was noted when the version was left in this
    /// run. Without it (a transcript an earlier run saved), a question
    /// answered without a stop is held, one the version ends on is not, and
    /// one a stop answered keeps the flag it was saved with.
    nonisolated static func markOutside(_ path: inout [LedgerAgentMessage], known: Set<UUID>?) {
        for index in path.indices where path[index].role == .user {
            if let known {
                path[index].outsideTranscript = known.contains(path[index].id)
            } else if index == path.count - 1 {
                path[index].outsideTranscript = true
            } else if path[index + 1].role == .assistant, !path[index + 1].stopped {
                path[index].outsideTranscript = false
            }
        }
    }

    /// What the model and the screen are told once another version shows.
    private func enterVersion(_ warning: LedgerAgentBranchWarning, switched: Bool) {
        // The draft may hold edits from the turns left behind: start it
        // again from the ledger through the usual discard, so the next turn
        // copies the ledger as it is.
        if warning.contains(.unreviewedDraft) { discard() }
        var notes: [String] = []
        if warning.contains(.written) {
            notes.append(String(localized: "（系统提示：用户换掉了之前的一些回答。那些回答写入账本的改动没有撤销，仍在账本里，以账本当前内容为准。）"))
        }
        if switched {
            notes.append(String(localized: "（系统提示：用户切换到了这段对话的另一个版本。这个版本里提议过但没有写入的改动不在草稿里，草稿和账本以当前内容为准。）"))
        }
        for added in notes { note = note.map { $0 + "\n" + added } ?? added }
        if transcript == nil { clearsStoredTranscript = true }
        written = nil
        nextSuggestion = nil
        restoredNotice = nil
        // A recap of another version would describe what is no longer shown.
        recap = nil
        recapError = nil
        usage = messages.last { $0.usage != nil }?.usage
    }

    /// Changes that would be replaced: written answers among them, and edits
    /// a stopped turn may have left in the draft.
    private func warning(replacing replaced: ArraySlice<LedgerAgentMessage>) -> LedgerAgentBranchWarning {
        var warning: LedgerAgentBranchWarning = []
        if replaced.contains(where: { $0.write != nil && $0.write?.undoneAt == nil }) { warning.insert(.written) }
        if draftUnreviewed, draft != nil { warning.insert(.unreviewedDraft) }
        return warning
    }

    /// The questions from the start of `slice` on that the transcript holds.
    private func recordedQuestions(in slice: ArraySlice<LedgerAgentMessage>) -> Int {
        slice.filter { $0.role == .user && !$0.outsideTranscript }.count
    }

    /// The cut transcript no longer holds the question's files, so they are
    /// new again.
    private func reannounce(_ question: LedgerAgentMessage) {
        unannounced.formUnion(attachments.filter { question.attachments.contains($0.name) }.map(\.id))
    }

    // MARK: Suggestions and recap

    typealias Assist<Output> = @Sendable (_ history: [LedgerAgentTurnRequest.HistoryEntry]) async throws -> Output

    /// Answers so far; a recap needs at least `LedgerAgentRecap.minimumAnswers`.
    var answerCount: Int { messages.filter { $0.role == .assistant }.count }

    /// The recap covers every message on screen.
    var recapIsCurrent: Bool { recap?.messageCount == messages.count }

    /// Whether a recap could say something the screen does not.
    var wantsRecap: Bool { answerCount >= LedgerAgentRecap.minimumAnswers && !recapIsCurrent && !isRunning }

    /// The visible conversation, for the small requests around it.
    var visibleHistory: [LedgerAgentTurnRequest.HistoryEntry] {
        messages.map { .init(role: $0.role.rawValue, content: $0.text) }
    }

    /// Predicts the next question after the last answer. A result that
    /// arrives after anything else happened is dropped.
    func predictNext(using suggest: @escaping Assist<[String]>) {
        guard messages.last?.role == .assistant, !isRunning, nextSuggestion == nil else { return }
        let epoch = epoch, count = messages.count, history = visibleHistory
        Task { [weak self] in
            let next = try? await suggest(history).first
            guard let self, self.epoch == epoch, self.messages.count == count, !self.isRunning else { return }
            self.nextSuggestion = next
        }
    }

    /// Answers a conversation needs before the model may name it: one
    /// exchange is still the question it opened with, two say what it is
    /// about.
    static let minimumNamingAnswers = 2
    /// How often one conversation asks for a name before it keeps its first
    /// question, so a model that keeps failing is not asked forever.
    static let maximumNamingAttempts = 3
    /// How many times this conversation has asked for a name, the answers it
    /// saw then, and whether a request is out; a failed request is retried on
    /// a later answer, never on the same one again.
    private var namingAttempts = 0
    private var namedAnswers: Int?
    private var naming = false

    /// Whether a naming request should go out now: the conversation has no
    /// name yet, it is not running a turn, it has at least two answers, it has
    /// tries left, and it is not the conversation the last request saw.
    static func shouldName(answerCount: Int, generatedTitle: String?, isRunning: Bool,
                           attempts: Int, namedAnswers: Int?) -> Bool {
        guard generatedTitle == nil, !isRunning, attempts < maximumNamingAttempts,
              answerCount >= minimumNamingAnswers else { return false }
        return namedAnswers != answerCount
    }

    /// Names the conversation from its first two exchanges; the name is saved
    /// with the conversation and shown in the history list. A request that
    /// fails is retried on the next answer, up to `maximumNamingAttempts`
    /// tries, and an unnamed conversation keeps its first question as its
    /// name.
    func nameSession(using write: @escaping Assist<String>) {
        guard !naming, Self.shouldName(answerCount: answerCount, generatedTitle: generatedTitle,
                                      isRunning: isRunning, attempts: namingAttempts,
                                      namedAnswers: namedAnswers) else { return }
        naming = true
        namingAttempts += 1
        namedAnswers = answerCount
        let epoch = epoch, history = visibleHistory
        Task { [weak self] in
            let name = try? await write(history)
            guard let self else { return }
            self.naming = false
            guard self.epoch == epoch, let name, !name.isEmpty, self.generatedTitle == nil else { return }
            self.generatedTitle = name
            self.onSettled?(self)
        }
    }

    /// Writes a recap of the conversation for its bottom; it is saved with
    /// the conversation.
    func summarize(using write: @escaping Assist<String>) {
        guard !recapping, !isRunning, !messages.isEmpty else { return }
        let epoch = epoch, count = messages.count, history = visibleHistory
        recapping = true
        recapError = nil
        Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await write(history)) } catch { result = .failure(error) }
            guard let self, self.epoch == epoch else { return }
            self.recapping = false
            switch result {
            case let .success(text):
                self.recap = LedgerAgentRecap(text: text, messageCount: count, createdAt: Date())
                self.onSettled?(self)
            case let .failure(error):
                self.recapError = error.localizedDescription
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        resumable = false
        resumes = 0
        guard case let .running(started) = phase else { return }
        // A stopped question stays visible. What the reply had said so far
        // stays too, marked stopped, so the page does not flash empty; the
        // native loop's own partial replaces it when it returns.
        let question = messages.last { $0.role == .user }?.id
        var partial: UUID?
        let turn = liveDraft
        if let turn, Self.hasText(turn.text) {
            let message = LedgerAgentMessage(role: .assistant, text: turn.text, duration: Date().timeIntervalSince(started),
                                             steps: turn.stoppedSteps, stopped: true, usage: turn.usage)
            messages.append(message)
            partial = message.id
        }
        stopping = Stopping(started: started, question: question, message: partial, note: note, unannounced: unannounced)
        phase = .idle
        endRunning(.stopped)
    }

    /// Takes what a stopped turn's native loop returned: its partial reply
    /// replaces the one shown at the stop, or is added when none was, and its
    /// transcript, which ends on that reply, is what the next question sends,
    /// unless a newer question already went on without it.
    private func settleStop(_ response: LedgerAgentTurnResponse, _ stopped: Stopping) {
        stopping = nil
        guard response.cancelled == true else { return }
        let reply = (response.reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = stopped.message, let index = messages.firstIndex(where: { $0.id == id }) {
            if !reply.isEmpty { messages[index].text = reply }
            if !response.steps.isEmpty { messages[index].steps = response.steps }
            if let usage = response.usage { messages[index].usage = usage }
        } else if !reply.isEmpty {
            // Right after its question, even if another question followed.
            let at = stopped.question.flatMap { id in messages.firstIndex { $0.id == id } }.map { $0 + 1 } ?? messages.count
            messages.insert(.init(role: .assistant, text: reply, toolCalls: response.toolCalls, steps: response.steps,
                                  stopped: true, usage: response.usage), at: at)
        }
        if !stopped.stale {
            if let usage = response.usage, usage.fraction != nil { self.usage = usage }
            // Only what the stopped question carried is now told; a note or
            // a file that came after it is still for the next question.
            if let next = response.transcript, !next.isEmpty {
                transcript = next
                if note == stopped.note { note = nil }
                unannounced.subtract(stopped.unannounced)
                markRecorded(stopped.question)
            }
        }
        onSettled?(self)
    }

    /// The transcript of a turn the native loop stopped already holds its
    /// question, its files and any note sent with it.
    private func adoptStopped(_ response: LedgerAgentTurnResponse, question: UUID?) {
        if let usage = response.usage, usage.fraction != nil { self.usage = usage }
        guard let next = response.transcript, !next.isEmpty else { return }
        transcript = next
        note = nil
        unannounced = []
        markRecorded(question)
    }

    /// The transcript now holds the question `id`.
    private func markRecorded(_ id: UUID?) {
        guard let id, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].outsideTranscript = false
    }

    /// Ends the running turn because the app is losing its background time.
    /// The question comes back for a retry; the draft keeps what the turn
    /// already changed, and the next turn is told so.
    func interrupt() {
        guard isRunning else { return }
        task?.cancel()
        task = nil
        let question = messages.last { $0.role == .user }?.text ?? ""
        markInterrupted(question: question)
    }

    private func markInterrupted(question: String) {
        phase = .failed(.interrupted, question: question)
        resumable = resumes < Self.maximumResumes
        if draft != nil {
            note = String(localized: "（系统提示：上一轮回答被系统中断，草稿里可能已有部分改动；继续之前请先查看草稿的现状。）")
        }
        endRunning(.interrupted)
    }

    /// The question of a turn the system cut short, once, for the screen to
    /// send again when the user is back; nil when there is nothing to resume.
    func takeResumableQuestion() -> String? {
        guard resumable, case let .failed(.interrupted, question) = phase, !question.isEmpty else { return nil }
        resumable = false
        resumes += 1
        return question
    }

    private func advance(_ step: LedgerAgentStep, started: Date) {
        guard case let .running(since) = phase, since == started else { return }
        if step.kind == .live {
            if let event = step.live { receive(event) }
            return
        }
        stepSince = Date()
        self.step = step
        if step.kind != .preparing { stepCount += 1 }
        lifecycle?.turnStepped(step, count: stepCount)
    }

    /// Folds a streamed event into the running turn. Text and reasoning
    /// deltas are published at most every `liveInterval`; anything else at
    /// once, with whatever text it follows.
    private func receive(_ event: LedgerAgentLiveEvent) {
        var turn = liveDraft ?? LedgerAgentLiveTurn()
        turn.apply(event)
        liveDraft = turn
        if case let .usage(usage) = event, usage.fraction != nil { self.usage = usage }
        // The stream is not quiet; the live footer's slow hint counts from here.
        stepSince = Date()
        switch event {
        case .textDelta, .thinkingDelta:
            let wait = Self.liveInterval - Date().timeIntervalSince(livePublishedAt ?? .distantPast)
            guard wait > 0 else { return publishLive() }
            guard liveFlush == nil else { return }
            liveFlush = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.publishLive()
            }
        default:
            publishLive()
        }
    }

    private func publishLive() {
        liveFlush?.cancel()
        liveFlush = nil
        livePublishedAt = Date()
        live = liveDraft
    }

    private func clearLive() {
        liveFlush?.cancel()
        liveFlush = nil
        livePublishedAt = nil
        liveDraft = nil
        live = nil
    }

    private func endRunning(_ ending: LedgerAgentTurnEnding) {
        if ending == .stopped || ending == .interrupted, draft != nil { draftUnreviewed = true }
        step = nil
        clearLive()
        stepSince = nil
        restoredNotice = nil
        lifecycle?.turnEnded(ending)
        onSettled?(self)
    }

    func reset() {
        task?.cancel()
        task = nil
        if isRunning { lifecycle?.turnEnded(.stopped) }
        resumable = false
        resumes = 0
        step = nil
        clearLive()
        stopping = nil
        usage = nil
        restoredNotice = nil
        draftUnreviewed = false
        thread = LedgerAgentThread()
        messages = []
        switching = false
        branchTranscripts = [:]
        branchOutside = [:]
        unsavedBranchTranscripts = []
        branchedSinceRestore = false
        phase = .idle
        pending = nil
        written = nil
        undoingSettings = nil
        note = nil
        transcript = nil
        clearsStoredTranscript = false
        attachments = []
        staged = []
        unannounced = []
        nextSuggestion = nil
        recap = nil
        recapping = false
        recapError = nil
        generatedTitle = nil
        namingAttempts = 0
        namedAnswers = nil
        naming = false
        epoch += 1
        if let editor {
            let draft = draft, reopening = reopening
            Task {
                if let draft { await editor.close(draft) }
                if let reopened = await reopening?.value { await editor.close(reopened) }
            }
        }
        draft = nil
        reopening = nil
    }

    /// Commits the reviewed change through the ledger's validated write path.
    func write() {
        guard let editor, let draft, let review = pending?.review, pending?.status == .ready, !isRunning else { return }
        pending?.status = .writing
        let epoch = epoch
        Task { [weak self] in
            do {
                let next = try await editor.write(review, draft)
                let revisions = await editor.written(review)
                guard let self, self.epoch == epoch else { return await editor.close(next) }
                self.draft = next
                self.pending = nil
                self.written = review
                if let revisions, let index = self.messages.lastIndex(where: { $0.role == .assistant }) {
                    self.messages[index].write = LedgerAgentWriteRecord(
                        parent: revisions.parent, revision: revisions.revision,
                        files: review.files.map(\.path), writtenAt: Date())
                }
                self.note = String(localized: "（系统提示：上一轮的草稿改动已写入账本，草稿与账本现在一致。）")
                self.onSettled?(self)
            } catch {
                guard self?.epoch == epoch else { return }
                if case let .conflict(paths)? = error as? LedgerAgentEditError {
                    self?.pending?.status = .conflict(paths)
                } else {
                    self?.pending?.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Drops the change; the draft starts again from the current ledger.
    func discard() {
        guard let editor, let draft, !isRunning, !isWriting else { return }
        let review = pending?.review
        pending = nil
        // The fresh copy has nothing a stopped turn left unreviewed.
        draftUnreviewed = false
        note = String(localized: "（系统提示：用户放弃了上一轮的草稿改动，草稿已恢复为当前账本。）")
        self.draft = nil
        // The next turn waits for the fresh copy instead of making its own.
        reopening = Task { try? await editor.discard(review, draft) }
        onSettled?(self)
    }

    /// Whether the change written after `message` can be undone now.
    func canUndo(_ message: LedgerAgentMessage) -> Bool {
        guard let write = message.write, write.undoneAt == nil else { return false }
        return undoing == nil && !isRunning && !isWriting && !switching
    }

    /// Reverses the change written after `message` as a new commit on the
    /// current ledger. The draft follows on the next turn, which rebases it
    /// onto the ledger, and the model is told what was undone.
    func undo(_ message: LedgerAgentMessage) {
        guard canUndo(message), let editor, let record = message.write else { return }
        undoing = message.id
        undoFailure = nil
        let epoch = epoch, id = message.id
        Task { [weak self] in
            do {
                try await editor.undo(record)
                guard let self, self.epoch == epoch else { return }
                self.undoing = nil
                if let index = self.messages.firstIndex(where: { $0.id == id }) {
                    self.messages[index].write?.undoneAt = Date()
                }
                if self.written != nil, self.messages.last(where: { $0.role == .assistant })?.id == id { self.written = nil }
                let files = record.files.joined(separator: "、")
                let undone = String(localized: "（系统提示：用户撤销了之前写入账本的一次改动（\(files)），账本已恢复到那次写入之前；之后别处的改动保留。）")
                self.note = self.note.map { $0 + "\n" + undone } ?? undone
                self.onSettled?(self)
            } catch {
                guard let self, self.epoch == epoch else { return }
                self.undoing = nil
                let text: String = switch error as? LedgerAgentEditError {
                case let .conflict(paths)?:
                    String(localized: "之后的改动动到了同一处（\(paths.joined(separator: "、"))），没法自动撤销。可以让助手手动改回去。")
                default: error.localizedDescription
                }
                self.undoFailure = UndoFailure(message: id, text: text)
            }
        }
    }

    /// Whether the App settings change under `message` can be undone now.
    func canUndoAppSettings(_ message: LedgerAgentMessage) -> Bool {
        guard let change = message.settings, change.undoneAt == nil else { return false }
        return undoingSettings == nil && !isRunning && !isWriting && !switching
    }

    /// Puts the sections this answer changed back the way they were. The
    /// settings screens run their own side effects again, so reminders are
    /// rescheduled exactly as a manual change would reschedule them.
    func undoAppSettings(_ message: LedgerAgentMessage) {
        guard canUndoAppSettings(message), let host = appSettings, let change = message.settings else { return }
        undoingSettings = message.id
        undoFailure = nil
        let epoch = epoch, id = message.id, titles = change.titles
        Task { [weak self] in
            let result = await host.apply(change.previous, change.sections)
            guard let self, self.epoch == epoch else { return }
            self.undoingSettings = nil
            guard result.failures.isEmpty else {
                self.undoFailure = UndoFailure(message: id, text: result.failures.joined(separator: "；"))
                return
            }
            if let index = self.messages.firstIndex(where: { $0.id == id }) {
                self.messages[index].settings?.undoneAt = Date()
            }
            let note = String(localized: "（系统提示：用户撤销了之前对 App 设置的改动（\(titles)），这些设置已经恢复成改之前的样子。）")
            self.note = self.note.map { $0 + "\n" + note } ?? note
            self.onSettled?(self)
        }
    }

    private static func hasText(_ reply: String?) -> Bool {
        !(reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A failure that a frozen connection explains: not a stop, and not a key
    /// the provider refused.
    private static func diedWithConnection(_ outcome: Result<Outcome, Error>) -> Bool {
        switch outcome {
        case let .success(turn):
            guard !turn.response.ok, turn.response.cancelled != true else { return false }
            if case .failed = LedgerAgentError.classify(turn.response.error ?? "") { return true }
            return false
        case let .failure(error as LedgerAgentError):
            if case .failed = error { return true }
            return false
        case .failure(is CancellationError): return false
        case .failure: return true
        }
    }

    private func finish(_ outcome: Result<Outcome, Error>, question: String, questionID: UUID?, started: Date) {
        guard case let .running(since) = phase, since == started else {
            // A stopped or reset turn may still have opened a copy.
            if case let .success(turn) = outcome, let opened = turn.draft {
                if opened.id == draft?.id {
                    // The same draft, rebased on a newer ledger by the turn.
                    draft = opened
                } else if let editor {
                    Task { await editor.close(opened) }
                }
            }
            if let stopped = stopping, stopped.started == started {
                if case let .success(turn) = outcome { settleStop(turn.response, stopped) } else { stopping = nil }
            }
            return
        }
        task = nil
        if case let .success(turn) = outcome {
            if let opened = turn.draft { draft = opened }
            reopening = nil
            if turn.review != nil { draftUnreviewed = false }
            switch turn.review {
            case nil: break
            case let .success(review)?:
                pending = review.map { .init(review: $0, status: .ready, holdReason: writePolicy.holdReason(for: $0)) }
            case let .failure(error)?:
                switch error as? LedgerAgentEditError {
                case let .conflict(paths)?: pending = .init(review: nil, status: .conflict(paths))
                default: pending = .init(review: nil, status: .invalid(error.localizedDescription))
                }
            }
        }
        switch outcome {
        case let .success(turn) where turn.response.ok && (Self.hasText(turn.response.reply) || pending?.review != nil):
            note = nil
            if let failure = turn.settingsFailure {
                // The next turn knows which settings did not take, so it can
                // tell the user instead of assuming the change landed.
                note = String(localized: "（系统提示：上一轮想改的 App 设置有一部分没改成：\(failure)。可以换一种说法再试，或者告诉用户在设置页里改。）")
            }
            unannounced = []
            if let next = turn.response.transcript, !next.isEmpty {
                transcript = next
                markRecorded(questionID)
            }
            let autoWriting = pending?.review.map { writePolicy.writesWithoutAsking($0) } ?? false
            let reply = Self.hasText(turn.response.reply) ? turn.response.reply ?? ""
                : autoWriting ? String(localized: "改动已经准备好，正在写入账本。")
                : String(localized: "改动已经准备好，请在下方查看并确认。")
            let steps = turn.response.steps.isEmpty ? liveDraft?.steps ?? [] : turn.response.steps
            let answer = LedgerAgentMessage(role: .assistant, text: reply, toolCalls: turn.response.toolCalls,
                                            duration: Date().timeIntervalSince(started),
                                            rememberedMemory: turn.response.memoryUpdated, ask: turn.response.ask,
                                            steps: steps, usage: turn.response.usage,
                                            compacted: turn.response.compacted || liveDraft?.compacted == true,
                                            settings: turn.settingsChange)
            messages.append(answer)
            if let usage = turn.response.usage, usage.fraction != nil { self.usage = usage }
            phase = .idle
            resumes = 0
            if let review = pending?.review {
                endRunning(.changeReady(reply, files: review.files.count))
            } else {
                endRunning(.answered(reply))
            }
        case let .success(turn) where turn.response.cancelled == true:
            // Stopped by the native loop rather than the stop button: keep
            // what it wrote, and the question with it, in the conversation.
            let reply = (turn.response.reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {
                let answer = LedgerAgentMessage(role: .assistant, text: reply, toolCalls: turn.response.toolCalls,
                                                duration: Date().timeIntervalSince(started),
                                                steps: turn.response.steps.isEmpty ? liveDraft?.stoppedSteps ?? [] : turn.response.steps,
                                                stopped: true, usage: turn.response.usage)
                messages.append(answer)
            }
            adoptStopped(turn.response, question: questionID)
            phase = .idle
            endRunning(.stopped)
        case _ where lifecycle?.turnWasSuspended == true && Self.diedWithConnection(outcome):
            // iOS froze the app while the request was out; the connection
            // died with it, which says nothing about the question.
            markInterrupted(question: question)
        case let .success(turn):
            // An answer without any text reads as no answer at all; say so and
            // offer a retry instead of drawing an empty reply.
            let error = LedgerAgentError.classify(turn.response.error ?? String(localized: "模型这次没有给出文字回答，点重试再问一次。"))
            phase = .failed(error, question: question)
            endRunning(.failed(error.localizedDescription))
        case let .failure(error as LedgerAgentError):
            phase = .failed(error, question: question)
            endRunning(.failed(error.localizedDescription))
        case let .failure(error) where error is CancellationError:
            phase = .idle
            endRunning(.stopped)
        case let .failure(error):
            phase = .failed(.failed(error.localizedDescription), question: question)
            endRunning(.failed(error.localizedDescription))
        }
        if let review = pending?.review, pending?.status == .ready, !isRunning, writePolicy.writesWithoutAsking(review) {
            write()
        }
    }
}

/// One file of a pending change: what happened to it and the changed lines
/// with a little context, in the order a unified diff shows them.
struct LedgerAgentFileDiff: Identifiable, Equatable, Sendable {
    enum Change: Equatable, Sendable { case added, removed, modified }
    struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case context, added, removed, gap }
        let kind: Kind
        let text: String
    }

    var id: String { path }
    let path: String
    let change: Change
    let added: Int
    let removed: Int
    let lines: [Line]

    static let contextLines = 2
    static let maximumLines = 400

    init(path: String, before: Data?, after: Data?) {
        self.path = path
        change = before == nil ? .added : after == nil ? .removed : .modified
        if Self.isBinary(before) || Self.isBinary(after) {
            // A saved statement or image: say what it is, not its bytes.
            added = 0
            removed = 0
            let size = ByteCountFormatter.string(fromByteCount: Int64((after ?? before)?.count ?? 0), countStyle: .file)
            lines = [.init(kind: .gap, text: String(localized: "二进制文件 · \(size)"))]
            return
        }
        let old = Self.lines(before), new = Self.lines(after)
        let difference = new.difference(from: old)
        var removedOffsets = Set<Int>(), insertedOffsets = Set<Int>()
        for step in difference {
            switch step {
            case let .remove(offset, _, _): removedOffsets.insert(offset)
            case let .insert(offset, _, _): insertedOffsets.insert(offset)
            }
        }
        added = insertedOffsets.count
        removed = removedOffsets.count
        // Interleave both sides: removals before the insertions that replace them.
        var all: [Line] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removedOffsets.contains(i) {
                all.append(.init(kind: .removed, text: old[i])); i += 1
            } else if j < new.count, insertedOffsets.contains(j) {
                all.append(.init(kind: .added, text: new[j])); j += 1
            } else {
                all.append(.init(kind: .context, text: i < old.count ? old[i] : new[j])); i += 1; j += 1
            }
        }
        var keep = [Bool](repeating: false, count: all.count)
        for (index, line) in all.enumerated() where line.kind != .context {
            for near in max(0, index - Self.contextLines)...min(all.count - 1, index + Self.contextLines) { keep[near] = true }
        }
        var shown: [Line] = []
        var skipped = 0
        for (index, line) in all.enumerated() {
            guard keep[index] else { skipped += 1; continue }
            if skipped > 0, !shown.isEmpty { shown.append(.init(kind: .gap, text: String(localized: "\(skipped) 行未改动"))) }
            skipped = 0
            shown.append(line)
        }
        if shown.count > Self.maximumLines {
            let hidden = shown[Self.maximumLines...].filter { $0.kind == .added || $0.kind == .removed }.count
            shown = Array(shown.prefix(Self.maximumLines))
            shown.append(.init(kind: .gap, text: String(localized: "还有 \(hidden) 行改动未显示")))
        }
        lines = shown
    }

    static func isBinary(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty else { return false }
        var head = Data(data.prefix(8000))
        if head.contains(0) { return true }
        if data.count > 8000 {
            // A multi-byte character cut at the boundary is not binary.
            for _ in 0..<3 where String(data: head, encoding: .utf8) == nil { head.removeLast() }
        }
        return String(data: head, encoding: .utf8) == nil
    }

    private static func lines(_ data: Data?) -> [String] {
        guard let data, !data.isEmpty else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text.components(separatedBy: "\n")
    }
}

/// A chart the model asks the app to draw, written in its reply as a fenced
/// `chart` block of JSON. A block that does not decode, or does not add up,
/// shows as code instead.
struct LedgerAgentChart: Codable, Equatable, Sendable {
    /// `hbar` lays bars along the y axis; `waterfall` draws one series of
    /// changes as floating bars from a running total.
    enum Kind: String, Codable, Sendable { case bar, hbar, line, area, pie, waterfall }
    struct Series: Codable, Equatable, Sendable {
        var name: String
        var values: [Double]
        /// In a bar, line or area chart, draws this series as another of
        /// those kinds, such as a line over bars.
        var kind: Kind? = nil
    }

    /// A horizontal reference line, such as a budget or an average.
    struct Rule: Codable, Equatable, Sendable {
        var value: Double
        var label: String? = nil
    }

    var type: Kind
    var title: String? = nil
    var unit: String? = nil
    /// Bars of different series stack unless this is false.
    var stacked: Bool? = nil
    var labels: [String]
    var series: [Series]
    /// A `ledger://` page per label, opened from the selected mark. Links
    /// that are not ledger pages, or do not line up with the labels, are
    /// dropped rather than failing the chart.
    var links: [String]? = nil
    var rules: [Rule]? = nil

    static let maximumLabels = 60
    static let maximumSeries = 8
    static let maximumRules = 3

    init?(json: String) {
        guard var chart = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)), chart.isValid else { return nil }
        chart.links = Self.normalized(chart.links, count: chart.labels.count)
        self = chart
    }

    init(type: Kind, title: String? = nil, unit: String? = nil, stacked: Bool? = nil, labels: [String], series: [Series],
         links: [String]? = nil, rules: [Rule]? = nil) {
        self.rules = rules
        self.type = type
        self.title = title
        self.unit = unit
        self.stacked = stacked
        self.labels = labels
        self.series = series
        self.links = Self.normalized(links, count: labels.count)
    }

    private static func normalized(_ links: [String]?, count: Int) -> [String]? {
        guard let links, links.count == count else { return nil }
        let kept = links.map { LedgerAgentVisual.ledgerLink($0)?.absoluteString ?? "" }
        return kept.contains { !$0.isEmpty } ? kept : nil
    }

    /// The page behind a label, if the model gave one.
    func link(for label: String) -> URL? {
        guard let links, let index = labels.firstIndex(of: label), !links[index].isEmpty else { return nil }
        return URL(string: links[index])
    }

    var isValid: Bool {
        guard !labels.isEmpty, labels.count <= Self.maximumLabels, !series.isEmpty, series.count <= Self.maximumSeries,
              Set(labels).count == labels.count else { return false }
        if type == .pie || type == .waterfall, series.count != 1 { return false }
        let mixable: Set<Kind> = [.bar, .line, .area]
        if series.contains(where: { $0.kind != nil && (!mixable.contains(type) || !mixable.contains($0.kind!)) }) { return false }
        if rules?.contains(where: { !$0.value.isFinite }) == true { return false }
        return series.allSatisfy { $0.values.count == labels.count && $0.values.allSatisfy(\.isFinite) }
            && (type != .pie || series[0].values.allSatisfy { $0 >= 0 })
    }

    /// One mark per label and series, in label order.
    struct Point: Identifiable, Equatable, Sendable {
        var id: String { series + "\u{1F}" + label }
        let label: String
        let series: String
        let value: Double
    }

    var points: [Point] {
        series.flatMap { entry in zip(labels, entry.values).map { Point(label: $0, series: entry.name, value: $1) } }
    }

    /// How a series is drawn: its own kind when mixed, else the chart's.
    func kind(of seriesName: String) -> Kind {
        series.first { $0.name == seriesName }?.kind ?? type
    }

    /// A waterfall step: where its bar starts and ends on the running total.
    struct Step: Identifiable, Equatable, Sendable {
        var id: String { label }
        let label: String
        let start: Double
        let end: Double
        /// 增加, 减少, or 合计 for the closing total bar.
        let category: String
    }

    static let waterfallTotal = "合计"

    /// The steps of a waterfall, closed by a total bar unless the last
    /// label already is one.
    var steps: [Step] {
        guard type == .waterfall, let values = series.first?.values else { return [] }
        var running = 0.0
        var steps: [Step] = zip(labels, values).map { label, value in
            defer { running += value }
            return Step(label: label, start: running, end: running + value, category: value >= 0 ? "增加" : "减少")
        }
        if labels.last != Self.waterfallTotal {
            steps.append(Step(label: Self.waterfallTotal, start: 0, end: running, category: Self.waterfallTotal))
        }
        return steps
    }
}

/// Splits a reply into prose and fenced code, and finds the beancount entry a
/// read-only reply suggests for a write request.
enum LedgerAgentReplyText {
    /// A block of a reply's Markdown. Text inside a block keeps its inline
    /// Markdown (emphasis, code spans, links) for the view to render.
    enum Segment: Equatable, Sendable {
        case prose(String)
        case heading(level: Int, text: String)
        case list(ordered: Bool, items: [ListItem])
        case quote(String)
        case table(header: [String], rows: [[String]])
        case rule
        case code(String)
        case chart(LedgerAgentChart)
        case visual(LedgerAgentVisual)
    }

    struct ListItem: Equatable, Sendable {
        var marker: String
        var text: String
        var depth: Int
    }

    /// `streaming` reads a reply still being written: a fence that has not
    /// closed yet shows its lines as prose until it does, so half a chart or
    /// visual never draws as a broken block.
    static func segments(_ text: String, streaming: Bool = false) -> [Segment] {
        var segments: [Segment] = []
        var lines: [Substring] = []
        var inCode = false
        var language = ""
        func flush() {
            if inCode {
                let code = lines.joined(separator: "\n")
                if language == "chart", let chart = LedgerAgentChart(json: code) {
                    segments.append(.chart(chart))
                } else if language == "visual", let visual = LedgerAgentVisual(json: code) {
                    segments.append(.visual(visual))
                } else {
                    segments.append(.code(code))
                }
            } else {
                segments.append(contentsOf: blocks(lines))
            }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                inCode.toggle()
                language = inCode ? trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() : ""
            } else {
                lines.append(line)
            }
        }
        // An unclosed fence still shows as code, once the reply is complete.
        if inCode, streaming { inCode = false }
        flush()
        return segments
    }

    private static func blocks(_ lines: [Substring]) -> [Segment] {
        var blocks: [Segment] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var items: [ListItem] = []
        var ordered = false
        func close() {
            let prose = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !prose.isEmpty { blocks.append(.prose(prose)) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            if !items.isEmpty { blocks.append(.list(ordered: ordered, items: items)) }
            paragraph = []
            quote = []
            items = []
        }
        var index = 0
        while index < lines.count {
            let raw = String(lines[index])
            let line = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty {
                close()
            } else if let heading = heading(line) {
                close()
                blocks.append(heading)
            } else if line.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                close()
                blocks.append(.rule)
            } else if line.contains("|"), index < lines.count, isTableDivider(String(lines[index])) {
                close()
                var rows: [[String]] = []
                index += 1
                while index < lines.count, lines[index].contains("|") {
                    rows.append(cells(String(lines[index])))
                    index += 1
                }
                let header = cells(line)
                blocks.append(.table(header: header, rows: rows.map { row in
                    Array((row + Array(repeating: "", count: max(0, header.count - row.count))).prefix(header.count))
                }))
            } else if line.hasPrefix(">") {
                if quote.isEmpty { close() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let item = listItem(raw) {
                if items.isEmpty {
                    close()
                    ordered = item.marker.hasSuffix(".")
                }
                items.append(item)
            } else if !items.isEmpty, raw.first == " " || raw.first == "\t" {
                // An indented line continues the item above it.
                items[items.count - 1].text += "\n" + line
            } else {
                if !quote.isEmpty || !items.isEmpty { close() }
                paragraph.append(raw)
            }
        }
        close()
        return blocks
    }

    private static func heading(_ line: String) -> Segment? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text.replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression))
    }

    private static func listItem(_ raw: String) -> ListItem? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let line = raw.trimmingCharacters(in: .whitespaces)
        if let range = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
            var text = String(line[range.upperBound...])
            var marker = "•"
            if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                marker = text.hasPrefix("[ ]") ? "☐" : "☑"
                text.removeFirst(4)
            }
            return ListItem(marker: marker, text: text, depth: indent / 2)
        }
        if let range = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            let marker = line[range].trimmingCharacters(in: .whitespaces)
            return ListItem(marker: String(marker.dropLast()) + ".", text: String(line[range.upperBound...]), depth: indent / 2)
        }
        return nil
    }

    private static func isTableDivider(_ line: String) -> Bool {
        line.contains("-") && line.range(of: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#, options: .regularExpression) != nil
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Percent-encodes the query of every `ledger://` link target, so a link
    /// the model wrote with Chinese, spaces or reserved characters in it
    /// still parses as a Markdown link. A target that is already encoded is
    /// decoded first, so nothing is encoded twice.
    static func encodingLedgerLinks(_ text: String) -> String {
        guard text.contains("](ledger://") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "](ledger://") {
            result += String(rest[..<open.lowerBound])
            result += "]("
            let target = rest[rest.index(open.lowerBound, offsetBy: 2)...]
            // The target ends at the parenthesis that closes the link,
            // counting any the query itself opens.
            var depth = 0
            var end = target.endIndex
            for index in target.indices {
                if target[index] == "(" { depth += 1 } else if target[index] == ")" {
                    if depth == 0 { end = index; break }
                    depth -= 1
                }
            }
            guard end < target.endIndex else {
                result += String(target)
                rest = ""
                break
            }
            result += encodedLedgerURL(String(target[..<end]))
            rest = target[end...]
        }
        return result + String(rest)
    }

    private static func encodedLedgerURL(_ raw: String) -> String {
        guard let question = raw.firstIndex(of: "?") else { return raw }
        let head = raw[..<question]
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#()[]")
        let pairs = raw[raw.index(after: question)...].split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let encode = { (part: Substring) -> String in
                let plain = String(part).removingPercentEncoding ?? String(part)
                return plain.addingPercentEncoding(withAllowedCharacters: allowed) ?? plain
            }
            return parts.count == 2 ? encode(parts[0]) + "=" + encode(parts[1]) : encode(parts[0])
        }
        return String(head) + "?" + pairs.joined(separator: "&")
    }

    /// The reply without its Markdown, for 复制为纯文本. Headings, list items
    /// and quotes keep their words, emphasis and link syntax go, a table
    /// becomes tab-separated rows, code keeps its lines, and a chart or
    /// visual leaves its title.
    static func plainText(_ text: String) -> String {
        segments(text).compactMap { segment -> String? in
            switch segment {
            case let .prose(text), let .quote(text), let .heading(_, text): plainInline(text)
            case let .list(_, items):
                items.map { String(repeating: "  ", count: min($0.depth, 4)) + $0.marker + " " + plainInline($0.text) }
                    .joined(separator: "\n")
            case let .table(header, rows):
                ([header] + rows).map { $0.map(plainInline).joined(separator: "\t") }.joined(separator: "\n")
            case .rule: nil
            case let .code(code): code
            case let .chart(chart): chart.title
            case let .visual(visual): visual.title
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private static func plainInline(_ text: String) -> String {
        let text = encodingLedgerLinks(text)
        let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return parsed.map { String($0.characters) } ?? text
    }

    /// The first fenced block that opens with a dated transaction header.
    static func beancountDraft(in text: String) -> String? {
        for case let .code(code) in segments(text) {
            let first = code.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if let first, first.range(of: #"^\s*\d{4}-\d{2}-\d{2}\s+[*!]"#, options: .regularExpression) != nil {
                return code
            }
        }
        return nil
    }
}

/// The report a fatal native error left behind. In a bound Go library a
/// goroutine panic aborts the app, so the core writes the report to a file in
/// the runtime directory and the Agent screen shows it on the next visit.
enum LedgerAgentCrashReport {
    static let fileName = "agent-crash.log"
    static let maximumBytes = 16_000

    /// Returns the report, if any, and moves it aside so it shows once.
    static func take(runtimeRoot: URL) -> String? {
        let file = runtimeRoot.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        let previous = runtimeRoot.appendingPathComponent("agent-crash.previous.log")
        try? FileManager.default.removeItem(at: previous)
        if (try? FileManager.default.moveItem(at: file, to: previous)) == nil {
            try? FileManager.default.removeItem(at: file)
        }
        let text = crashingGoroutine(String(decoding: data.prefix(maximumBytes), as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Keeps the panic message and the goroutine that raised it, which Go writes first; the idle goroutines after it only bury the cause.
    static func crashingGoroutine(_ text: String) -> String {
        let blocks = text.components(separatedBy: "\n\ngoroutine ")
        return blocks.prefix(2).joined(separator: "\n\ngoroutine ")
    }
}

/// Brings a stage in line with an Agent draft: every ledger file the draft has
/// is copied when it differs, and every one it no longer has is removed.
/// Only .bean files outside hidden directories count; anything else in the
/// stage is left as committed.
/// Carries the draft's files over a staged copy of the ledger: every file
/// that is not hidden, so a statement the Agent saved, moved or deleted is
/// part of the change like an edited `.bean` file. Hidden files on either
/// side are left alone.
enum LedgerAgentDraftMirror {
    static func apply(from draft: URL, to stage: URL, fileManager: FileManager = .default) throws {
        let source = try files(in: draft, fileManager: fileManager)
        let target = try files(in: stage, fileManager: fileManager)
        for path in source.sorted() {
            let origin = draft.appendingPathComponent(path)
            let destination = stage.appendingPathComponent(path)
            if target.contains(path), fileManager.contentsEqual(atPath: origin.path, andPath: destination.path) { continue }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: origin).write(to: destination)
        }
        for path in target.subtracting(source) {
            try fileManager.removeItem(at: stage.appendingPathComponent(path))
        }
    }

    static func files(in root: URL, fileManager: FileManager = .default) throws -> Set<String> {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var paths = Set<String>()
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            paths.insert(String(path.dropFirst(base.count + 1)))
        }
        return paths
    }
}

/// Carries an Agent draft over a ledger that moved on since the draft was
/// copied, like a rebase: the draft's own changes (draft against `base`, the
/// generation it was copied from) are replayed on top of the current ledger.
/// A file only one side changed takes that side. A file both changed is
/// merged line by line, and only changes to the same lines are a conflict.
/// In `.bean` files, lines both sides inserted at the same place are both
/// kept (the ledger's first), since the order of entries does not matter to
/// Beancount; a binary file both sides changed is always a conflict.
enum LedgerAgentMerge {
    enum FileResult: Equatable {
        /// The merged content; nil when the file ends up deleted.
        case merged(Data?)
        case conflict
    }

    /// The merged tree, as the paths whose merged content differs from
    /// `current` (nil deletes) and the paths that conflict.
    struct Plan: Equatable {
        var changes: [String: Data?] = [:]
        var conflicts: [String] = []
    }

    static func plan(base: URL, draft: URL, current: URL, fileManager: FileManager = .default) throws -> Plan {
        let baseFiles = try LedgerAgentDraftMirror.files(in: base, fileManager: fileManager)
        let draftFiles = try LedgerAgentDraftMirror.files(in: draft, fileManager: fileManager)
        var plan = Plan()
        for path in baseFiles.union(draftFiles).sorted() {
            let inBase = baseFiles.contains(path), inDraft = draftFiles.contains(path)
            if inBase, inDraft, fileManager.contentsEqual(atPath: base.appendingPathComponent(path).path,
                                                          andPath: draft.appendingPathComponent(path).path) { continue }
            let read = { (root: URL) throws -> Data? in
                let url = root.appendingPathComponent(path)
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                return try Data(contentsOf: url)
            }
            let theirs = try read(current)
            let ancestor: Data? = try inBase ? read(base) : nil
            let ours: Data? = try inDraft ? read(draft) : nil
            switch merge(path: path, base: ancestor, ours: ours, theirs: theirs) {
            case .conflict: plan.conflicts.append(path)
            case let .merged(data) where data != theirs: plan.changes.updateValue(data, forKey: path)
            case .merged: break
            }
        }
        return plan
    }

    /// Writes a plan's changes into a tree that holds `current`'s files.
    static func apply(_ changes: [String: Data?], to root: URL, fileManager: FileManager = .default) throws {
        for (path, data) in changes.sorted(by: { $0.key < $1.key }) {
            let url = root.appendingPathComponent(path)
            if let data {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    static func merge(path: String, base: Data?, ours: Data?, theirs: Data?) -> FileResult {
        if ours == base { return .merged(theirs) }
        if theirs == base || theirs == ours { return .merged(ours) }
        // Both sides changed the file, and differently. A deletion against an
        // edit, or any binary file, cannot be merged by lines.
        guard let ours, let theirs, let o = Text(base ?? Data()), let a = Text(ours), let b = Text(theirs),
              let lines = mergeLines(base: o.lines, ours: a.lines, theirs: b.lines,
                                     keepsBothInsertions: path.hasSuffix(".bean")) else { return .conflict }
        let newline = a.endsWithNewline != o.endsWithNewline ? a.endsWithNewline : b.endsWithNewline
        return .merged(Data((lines.joined(separator: "\n") + (newline && !lines.isEmpty ? "\n" : "")).utf8))
    }

    private struct Text {
        let lines: [String]
        let endsWithNewline: Bool

        init?(_ data: Data) {
            guard !LedgerAgentFileDiff.isBinary(data), let text = String(data: data, encoding: .utf8) else { return nil }
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            self.lines = lines
            endsWithNewline = text.hasSuffix("\n")
        }
    }

    /// diff3 over lines: walks the stretches every side agrees on, and takes
    /// whichever side changed each stretch in between. nil on a conflict.
    static func mergeLines(base o: [String], ours a: [String], theirs b: [String], keepsBothInsertions: Bool) -> [String]? {
        let ma = matches(o, a), mb = matches(o, b)
        var merged: [String] = []
        var i = 0, j = 0, k = 0
        while true {
            while i < o.count, ma[i] == j, mb[i] == k {
                merged.append(o[i]); i += 1; j += 1; k += 1
            }
            if i == o.count, j == a.count, k == b.count { return merged }
            // The next base line both sides kept ends the changed stretch.
            var next = i
            while next < o.count, ma[next] == nil || mb[next] == nil { next += 1 }
            let nj = next < o.count ? ma[next]! : a.count
            let nk = next < o.count ? mb[next]! : b.count
            let chunkO = Array(o[i..<next]), chunkA = Array(a[j..<nj]), chunkB = Array(b[k..<nk])
            if chunkA == chunkO {
                merged += chunkB
            } else if chunkB == chunkO || chunkA == chunkB {
                merged += chunkA
            } else if keepsBothInsertions, chunkO.isEmpty {
                merged += chunkB + chunkA
            } else {
                return nil
            }
            i = next; j = nj; k = nk
        }
    }

    /// For each line of `old`, the line of `new` it is kept as, if any.
    private static func matches(_ old: [String], _ new: [String]) -> [Int?] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var result = [Int?](repeating: nil, count: old.count)
        var j = 0
        for i in old.indices where !removed.contains(i) {
            while inserted.contains(j) { j += 1 }
            result[i] = j
            j += 1
        }
        return result
    }
}

extension LedgerAgentEditor {
    static func live(_ repository: LocalLedgerRepository) -> LedgerAgentEditor {
        LedgerAgentEditor(
            open: { try await repository.openAgentDraft() },
            review: { try await repository.reviewAgentDraft($0) },
            write: { try await repository.writeAgentDraft($0, draft: $1) },
            discard: { try await repository.discardAgentDraft($0, draft: $1) },
            close: { await repository.closeAgentDraft($0) },
            rebase: { try await repository.rebaseAgentDraft($0) },
            written: { await repository.agentWrite(for: $0) },
            undo: { try await repository.undoAgentWrite($0) })
    }
}

/// bean_check: the native loop calls back into the app's embedded Beancount
/// validator, so the Agent checks its draft with the same rules a commit uses.
enum LedgerAgentChecker {
    static func install() { _ = installed }

    private static let installed: Void = {
        #if canImport(LedgerCore)
        MobileagentSetChecker(Bridge())
        #endif
    }()

    /// Runs a validation to completion for a caller that cannot await.
    static func check(workspace: URL, entrypoint: String) -> String {
        let result = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await EmbeddedBeancountValidator.shared.validate(workspace: workspace, entryFile: entrypoint) }
            catch { result.set(error.localizedDescription) }
            done.signal()
        }
        done.wait()
        return result.value
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = ""
        var value: String { lock.withLock { stored } }
        func set(_ message: String) { lock.withLock { stored = message } }
    }

    #if canImport(LedgerCore)
    /// Called on a Go goroutine's thread, never on the main thread or the
    /// cooperative pool, so blocking it on the validator is safe.
    private final class Bridge: NSObject, MobileagentCheckerProtocol {
        func check(_ workspaceRoot: String?, entrypoint: String?) -> String {
            LedgerAgentChecker.check(workspace: URL(fileURLWithPath: workspaceRoot ?? "", isDirectory: true),
                                     entrypoint: entrypoint ?? "main.bean")
        }
    }
    #endif
}
