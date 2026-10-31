import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif

/// One read the on-device Agent made while answering.
struct LedgerAgentToolCall: Decodable, Equatable, Sendable {
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
        default: name
        }
        if name == "get_ledger_summary", let start = argument("start"), let end = argument("end") {
            return base + " · " + String(localized: "\(Self.shortDate(start)) 至 \(Self.shortDate(end))")
        }
        if name == "search_transactions", let query = argument("query") { return base + " · " + query }
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
    struct Model: Decodable, Identifiable, Hashable, Sendable { let id: String; let title: String }
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
    let history: [HistoryEntry]
    let message: String
}

struct LedgerAgentTurnResponse: Decodable, Sendable {
    let ok: Bool
    var reply: String? = nil
    var toolCalls: [LedgerAgentToolCall] = []
    var error: String? = nil
    var cancelled: Bool? = nil
    var modelUnavailable: Bool? = nil

    private enum CodingKeys: String, CodingKey { case ok, reply, toolCalls, error, cancelled, modelUnavailable }
    init(ok: Bool, reply: String? = nil, toolCalls: [LedgerAgentToolCall] = [], error: String? = nil,
         cancelled: Bool? = nil, modelUnavailable: Bool? = nil) {
        self.ok = ok; self.reply = reply; self.toolCalls = toolCalls; self.error = error
        self.cancelled = cancelled; self.modelUnavailable = modelUnavailable
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        reply = try container.decodeIfPresent(String.self, forKey: .reply)
        toolCalls = try container.decodeIfPresent([LedgerAgentToolCall].self, forKey: .toolCalls) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
        cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled)
        modelUnavailable = try container.decodeIfPresent(Bool.self, forKey: .modelUnavailable)
    }
}

enum LedgerAgentError: LocalizedError, Equatable {
    case notConfigured
    case invalidKey(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "请先设置模型与 API Key")
        case .invalidKey: String(localized: "API Key 无效或已过期")
        case let .failed(message): message
        }
    }

    /// The provider's own words, shown under the headline.
    var detail: String? {
        switch self {
        case .notConfigured: nil
        case let .invalidKey(message), let .failed(message): message
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

    static let native = LedgerAgentRunner(run: { request in
        #if canImport(LedgerCore)
        // A turn blocks for as long as the model takes; keep it off the
        // cooperative pool.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Data(MobileagentRunTurnJSON(String(decoding: request, as: UTF8.self)).utf8))
            }
        }
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    }, cancel: { turnID in
        #if canImport(LedgerCore)
        MobileagentCancelTurn(turnID)
        #endif
    })
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
                guard let user = pendingUser else { continue }
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

/// The in-memory conversation behind the Agent screen. Nothing is written to
/// disk; leaving the screen or starting a new chat drops it.
@MainActor
final class LedgerAgentConversation: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(since: Date)
        case failed(LedgerAgentError, question: String)
    }

    @Published private(set) var messages: [LedgerAgentMessage] = []
    @Published private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    var isRunning: Bool { if case .running = phase { true } else { false } }

    typealias Send = @Sendable (_ message: String, _ history: [LedgerAgentTurnRequest.HistoryEntry]) async throws -> LedgerAgentTurnResponse

    /// Starts a turn. The question shows at once; the reply, or the failure,
    /// replaces the running state when the turn ends.
    func send(_ raw: String, using send: @escaping Send) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isRunning else { return }
        let history = LedgerAgentHistory.entries(from: messages)
        if case let .failed(_, previous) = phase, messages.last?.role == .user, messages.last?.text == previous {
            messages.removeLast()
        }
        messages.append(.init(role: .user, text: question))
        let started = Date()
        phase = .running(since: started)
        task = Task { [weak self] in
            let outcome: Result<LedgerAgentTurnResponse, Error>
            do { outcome = .success(try await send(question, history)) } catch { outcome = .failure(error) }
            self?.finish(outcome, question: question, started: started)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        guard isRunning else { return }
        // A stopped question stays visible; it is not resent as history.
        phase = .idle
    }

    func reset() {
        task?.cancel()
        task = nil
        messages = []
        phase = .idle
    }

    private func finish(_ outcome: Result<LedgerAgentTurnResponse, Error>, question: String, started: Date) {
        guard case let .running(since) = phase, since == started else { return }
        task = nil
        switch outcome {
        case let .success(response) where response.ok:
            messages.append(.init(role: .assistant, text: response.reply ?? "", toolCalls: response.toolCalls,
                                  duration: Date().timeIntervalSince(started)))
            phase = .idle
        case let .success(response) where response.cancelled == true:
            phase = .idle
        case let .success(response):
            phase = .failed(LedgerAgentError.classify(response.error ?? String(localized: "模型没有返回回答")), question: question)
        case let .failure(error as LedgerAgentError):
            phase = .failed(error, question: question)
        case let .failure(error) where error is CancellationError:
            phase = .idle
        case let .failure(error):
            phase = .failed(.failed(error.localizedDescription), question: question)
        }
    }
}

/// Splits a reply into prose and fenced code, and finds the beancount entry a
/// read-only reply suggests for a write request.
enum LedgerAgentReplyText {
    enum Segment: Equatable, Sendable {
        case prose(String)
        case code(String)
    }

    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var lines: [Substring] = []
        var inCode = false
        func flush() {
            let joined = lines.joined(separator: "\n")
            lines = []
            if inCode {
                segments.append(.code(joined))
            } else {
                let prose = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty { segments.append(.prose(prose)) }
            }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                lines.append(line)
            }
        }
        // An unclosed fence still shows as code.
        flush()
        return segments
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
