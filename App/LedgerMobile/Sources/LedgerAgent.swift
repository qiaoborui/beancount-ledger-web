import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif

/// One read the on-device Agent made while answering.
struct LedgerAgentToolCall: Codable, Equatable, Sendable {
    let name: String
    var arguments: BQLCell? = nil
    let isError: Bool

    /// The row title, in the words of the design: what was read, then the range
    /// or search term when the arguments carry one.
    var title: String {
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
        default: name
        }
        if name == "get_ledger_summary", let start = argument("start"), let end = argument("end") {
            return base + " · " + String(localized: "\(Self.shortDate(start)) 至 \(Self.shortDate(end))")
        }
        if name == "search_transactions", let query = argument("query") { return base + " · " + query }
        if ["read_file", "edit_file", "write_file"].contains(name), let path = argument("path") { return base + " · " + path }
        return base
    }

    /// BQL text shown under the row, for the two tools that take one.
    var source: String? {
        guard name == "run_bql" || name == "validate_bql" else { return nil }
        return argument("query")
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

/// One visible message. Tool reads hang off the assistant reply they led to.
struct LedgerAgentMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
    var toolCalls: [LedgerAgentToolCall] = []
    var duration: TimeInterval? = nil
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

    private enum CodingKeys: String, CodingKey { case ok, reply, toolCalls, error, cancelled, modelUnavailable, edited }
    init(ok: Bool, reply: String? = nil, toolCalls: [LedgerAgentToolCall] = [], error: String? = nil,
         cancelled: Bool? = nil, modelUnavailable: Bool? = nil, edited: Bool = false) {
        self.ok = ok; self.reply = reply; self.toolCalls = toolCalls; self.error = error
        self.cancelled = cancelled; self.modelUnavailable = modelUnavailable; self.edited = edited
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
    })

    private struct TurnID: Decodable { let turnId: String }

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
    enum Kind: String, Decodable, Sendable { case model, tool }
    let kind: Kind
    var call: LedgerAgentToolCall? = nil

    var title: String {
        guard kind == .tool, let call else { return String(localized: "正在思考") }
        return call.title
    }

    /// One event of the native loop; nil for a version or kind this build
    /// does not know.
    static func decode(_ json: String) -> LedgerAgentStep? {
        struct Event: Decodable {
            let version: Int
            let kind: Kind
            var name: String?
            var arguments: BQLCell?
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(json.utf8)), event.version == 1 else { return nil }
        switch event.kind {
        case .model: return .init(kind: .model)
        case .tool:
            guard let name = event.name, !name.isEmpty else { return nil }
            return .init(kind: .tool, call: .init(name: name, arguments: event.arguments, isError: false))
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
    /// The ledger was committed to since the draft was copied.
    case stale
    /// The draft does not pass the app's own Beancount validation.
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .stale: String(localized: "账本在对话期间有了新的改动，这份草稿不能直接写入")
        case let .invalid(message): message
        }
    }
}

/// The ledger side of editing: the draft copy, the change it amounts to, and
/// the existing validated commit. Tests substitute it.
struct LedgerAgentEditor: Sendable {
    var open: @Sendable () async throws -> LedgerAgentDraft
    /// nil when the draft equals the committed ledger.
    var review: @Sendable (LedgerAgentDraft) async throws -> LedgerAgentReview?
    /// Commits the reviewed change and returns the draft rebased on it.
    var write: @Sendable (LedgerAgentReview, LedgerAgentDraft) async throws -> LedgerAgentDraft
    /// Drops the change and returns a fresh copy of the current ledger.
    var discard: @Sendable (LedgerAgentReview?, LedgerAgentDraft) async throws -> LedgerAgentDraft
    var close: @Sendable (LedgerAgentDraft) async -> Void
}

/// The change card under the conversation.
struct LedgerAgentPendingEdit: Equatable {
    enum Status: Equatable {
        case ready
        case invalid(String)
        case stale
        case writing
        case failed(String)
    }
    var review: LedgerAgentReview?
    var status: Status
}

/// One conversation behind the Agent screen. Nothing is written to the
/// ledger without the change card's confirmation. `LedgerAgentSessions` keeps
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

    @Published private(set) var messages: [LedgerAgentMessage] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pending: LedgerAgentPendingEdit?
    /// The last change written from this conversation, until the next turn.
    @Published private(set) var written: LedgerAgentReview?
    /// What the running turn is doing now; nil before its first event.
    @Published private(set) var step: LedgerAgentStep?
    /// When the running turn last reported a step, or started.
    private(set) var stepSince: Date?
    private(set) var stepCount = 0
    /// Shown above a reopened conversation whose change was never written.
    private(set) var restoredNotice: String?
    /// Told when a turn, a write or a discard settles, so the conversation
    /// can be saved.
    var onSettled: ((LedgerAgentConversation) -> Void)?
    /// True while the Agent screen shows this conversation.
    var isOnScreen = false
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
    private var reopening: Task<LedgerAgentDraft?, Never>?
    var editor: LedgerAgentEditor?

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
        messages = saved.messages.compactMap { stored in
            LedgerAgentMessage.Role(rawValue: stored.role).map {
                LedgerAgentMessage(role: $0, text: stored.text, toolCalls: stored.toolCalls, duration: stored.duration)
            }
        }
        if saved.unwrittenChange {
            restoredNotice = String(localized: "上次的草稿改动没有写入，重新打开后已放弃。需要的话让助手重新改一次。")
            note = String(localized: "（系统提示：这是重新打开的旧对话，之前草稿里没有写入的改动已经放弃，账本以当前内容为准。）")
        }
    }

    /// What to save, or nil while nothing has been asked.
    func saved(at date: Date = Date()) -> LedgerAgentSavedConversation? {
        guard !messages.isEmpty else { return nil }
        return LedgerAgentSavedConversation(
            id: id, createdAt: createdAt, updatedAt: date,
            messages: messages.map { .init(role: $0.role.rawValue, text: $0.text, toolCalls: $0.toolCalls, duration: $0.duration) },
            unwrittenChange: pending?.review != nil || draftUnreviewed)
    }

    private struct Outcome: Sendable {
        let response: LedgerAgentTurnResponse
        let draft: LedgerAgentDraft?
        let review: Result<LedgerAgentReview?, Error>?
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
        guard !question.isEmpty, !isRunning, !isWriting else { return false }
        let history = LedgerAgentHistory.entries(from: messages)
        if case let .failed(_, previous) = phase, messages.last?.role == .user, messages.last?.text == previous {
            messages.removeLast()
        }
        messages.append(.init(role: .user, text: question))
        written = nil
        let started = Date()
        phase = .running(since: started)
        step = nil
        stepSince = started
        stepCount = 0
        let editor = editor, existing = draft, reopening = reopening, unreviewed = draftUnreviewed
        let message = note.map { $0 + "\n\n" + question } ?? question
        let report: LedgerAgentSteps.Handler = { [weak self] step in
            Task { @MainActor in self?.advance(step, started: started) }
        }
        lifecycle?.turnStarted(question: question, conversation: self)
        task = Task { [weak self] in
            let outcome: Result<Outcome, Error>
            do {
                // A copy that cannot be made leaves the turn read-only.
                var draft = existing
                if draft == nil, let reopening { draft = await reopening.value }
                if draft == nil, let editor { draft = try? await editor.open() }
                let response = try await send(message, history, draft?.root, report)
                var review: Result<LedgerAgentReview?, Error>?
                if response.edited || unreviewed, let editor, let draft {
                    do { review = .success(try await editor.review(draft)) } catch { review = .failure(error) }
                }
                outcome = .success(.init(response: response, draft: draft, review: review))
            } catch { outcome = .failure(error) }
            self?.finish(outcome, question: question, started: started)
        }
        return true
    }

    func stop() {
        task?.cancel()
        task = nil
        guard isRunning else { return }
        // A stopped question stays visible; it is not resent as history.
        phase = .idle
        endRunning(.stopped)
    }

    /// Ends the running turn because the app is losing its background time.
    /// The question comes back for a retry; the draft keeps what the turn
    /// already changed, and the next turn is told so.
    func interrupt() {
        guard isRunning else { return }
        task?.cancel()
        task = nil
        let question = messages.last { $0.role == .user }?.text ?? ""
        phase = .failed(.interrupted, question: question)
        if draft != nil {
            note = String(localized: "（系统提示：上一轮回答被系统中断，草稿里可能已有部分改动；继续之前请先查看草稿的现状。）")
        }
        endRunning(.interrupted)
    }

    private func advance(_ step: LedgerAgentStep, started: Date) {
        guard case let .running(since) = phase, since == started else { return }
        stepSince = Date()
        self.step = step
        stepCount += 1
        lifecycle?.turnStepped(step, count: stepCount)
    }

    private func endRunning(_ ending: LedgerAgentTurnEnding) {
        if ending == .stopped || ending == .interrupted, draft != nil { draftUnreviewed = true }
        step = nil
        stepSince = nil
        restoredNotice = nil
        lifecycle?.turnEnded(ending)
        onSettled?(self)
    }

    func reset() {
        task?.cancel()
        task = nil
        if isRunning { lifecycle?.turnEnded(.stopped) }
        step = nil
        restoredNotice = nil
        draftUnreviewed = false
        messages = []
        phase = .idle
        pending = nil
        written = nil
        note = nil
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
                guard let self, self.epoch == epoch else { return await editor.close(next) }
                self.draft = next
                self.pending = nil
                self.written = review
                self.note = String(localized: "（系统提示：上一轮的草稿改动已写入账本，草稿与账本现在一致。）")
                self.onSettled?(self)
            } catch {
                guard self?.epoch == epoch else { return }
                self?.pending?.status = error as? LedgerAgentEditError == .stale ? .stale : .failed(error.localizedDescription)
            }
        }
    }

    /// Drops the change; the draft starts again from the current ledger.
    func discard() {
        guard let editor, let draft, !isRunning, !isWriting else { return }
        let review = pending?.review
        pending = nil
        note = String(localized: "（系统提示：用户放弃了上一轮的草稿改动，草稿已恢复为当前账本。）")
        self.draft = nil
        // The next turn waits for the fresh copy instead of making its own.
        reopening = Task { try? await editor.discard(review, draft) }
        onSettled?(self)
    }

    private static func hasText(_ reply: String?) -> Bool {
        !(reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func finish(_ outcome: Result<Outcome, Error>, question: String, started: Date) {
        guard case let .running(since) = phase, since == started else {
            // A stopped or reset turn may still have opened a copy.
            if case let .success(turn) = outcome, let opened = turn.draft, opened != draft, let editor {
                Task { await editor.close(opened) }
            }
            return
        }
        task = nil
        if case let .success(turn) = outcome {
            if draft == nil { draft = turn.draft }
            reopening = nil
            if turn.review != nil { draftUnreviewed = false }
            switch turn.review {
            case nil: break
            case let .success(review)?:
                pending = review.map { .init(review: $0, status: .ready) }
            case let .failure(error)?:
                switch error as? LedgerAgentEditError {
                case .stale?: pending = .init(review: nil, status: .stale)
                default: pending = .init(review: nil, status: .invalid(error.localizedDescription))
                }
            }
        }
        switch outcome {
        case let .success(turn) where turn.response.ok && (Self.hasText(turn.response.reply) || pending?.review != nil):
            note = nil
            let reply = Self.hasText(turn.response.reply) ? turn.response.reply ?? ""
                : String(localized: "改动已经准备好，请在下方查看并确认。")
            messages.append(.init(role: .assistant, text: reply, toolCalls: turn.response.toolCalls,
                                  duration: Date().timeIntervalSince(started)))
            phase = .idle
            if let review = pending?.review {
                endRunning(.changeReady(reply, files: review.files.count))
            } else {
                endRunning(.answered(reply))
            }
        case let .success(turn) where turn.response.cancelled == true:
            phase = .idle
            endRunning(.stopped)
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
    enum Kind: String, Codable, Sendable { case bar, line, pie }
    struct Series: Codable, Equatable, Sendable {
        var name: String
        var values: [Double]
    }

    var type: Kind
    var title: String? = nil
    var unit: String? = nil
    /// Bars of different series stack unless this is false.
    var stacked: Bool? = nil
    var labels: [String]
    var series: [Series]

    static let maximumLabels = 60
    static let maximumSeries = 8

    init?(json: String) {
        guard let chart = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)), chart.isValid else { return nil }
        self = chart
    }

    init(type: Kind, title: String? = nil, unit: String? = nil, stacked: Bool? = nil, labels: [String], series: [Series]) {
        self.type = type
        self.title = title
        self.unit = unit
        self.stacked = stacked
        self.labels = labels
        self.series = series
    }

    private var isValid: Bool {
        guard !labels.isEmpty, labels.count <= Self.maximumLabels, !series.isEmpty, series.count <= Self.maximumSeries,
              Set(labels).count == labels.count else { return false }
        if type == .pie, series.count != 1 { return false }
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
    }

    struct ListItem: Equatable, Sendable {
        var marker: String
        var text: String
        var depth: Int
    }

    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var lines: [Substring] = []
        var inCode = false
        var language = ""
        func flush() {
            if inCode {
                let code = lines.joined(separator: "\n")
                if language == "chart", let chart = LedgerAgentChart(json: code) {
                    segments.append(.chart(chart))
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
        // An unclosed fence still shows as code.
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
enum LedgerAgentDraftMirror {
    static func apply(from draft: URL, to stage: URL, fileManager: FileManager = .default) throws {
        let source = try beanFiles(in: draft, fileManager: fileManager)
        let target = try beanFiles(in: stage, fileManager: fileManager)
        for path in source.sorted() {
            let data = try Data(contentsOf: draft.appendingPathComponent(path))
            let destination = stage.appendingPathComponent(path)
            if target.contains(path), (try? Data(contentsOf: destination)) == data { continue }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
        }
        for path in target.subtracting(source) {
            try fileManager.removeItem(at: stage.appendingPathComponent(path))
        }
    }

    static func beanFiles(in root: URL, fileManager: FileManager = .default) throws -> Set<String> {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var paths = Set<String>()
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "bean" else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            paths.insert(String(path.dropFirst(base.count + 1)))
        }
        return paths
    }
}

extension LedgerAgentEditor {
    static func live(_ repository: LocalLedgerRepository) -> LedgerAgentEditor {
        LedgerAgentEditor(
            open: { try await repository.openAgentDraft() },
            review: { try await repository.reviewAgentDraft($0) },
            write: { try await repository.writeAgentDraft($0, draft: $1) },
            discard: { try await repository.discardAgentDraft($0, draft: $1) },
            close: { await repository.closeAgentDraft($0) })
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
