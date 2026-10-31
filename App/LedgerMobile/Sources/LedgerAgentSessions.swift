import Foundation

/// One conversation as it is saved in the ledger's runtime directory.
struct LedgerAgentSavedConversation: Codable, Equatable, Identifiable, Sendable {
    struct Message: Codable, Equatable, Sendable {
        let role: String
        let text: String
        var toolCalls: [LedgerAgentToolCall] = []
        var duration: TimeInterval? = nil
    }

    var version = 1
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var messages: [Message]
    /// The conversation had a change on its card, or possibly in its draft,
    /// that was never written when it was last saved.
    var unwrittenChange = false

    /// The first question names the conversation.
    var title: String {
        let question = messages.first { $0.role == LedgerAgentMessage.Role.user.rawValue }?.text ?? ""
        return Self.oneLine(question)
    }

    /// The last reply, as one plain line.
    var summary: String {
        guard let reply = messages.last(where: { $0.role == LedgerAgentMessage.Role.assistant.rawValue })?.text else {
            return String(localized: "还没有回答")
        }
        return Self.oneLine(reply.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: ""))
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*| ").union(.whitespaces)) }
            .filter { !$0.isEmpty && !$0.allSatisfy { "-:| ".contains($0) } }
            .joined(separator: " ")
    }
}

/// The 账本助手 conversations of the open ledger: the one on screen, one that
/// is still answering after the user moved on, and the saved history.
///
/// Only one turn runs at a time. Moving to another conversation does not stop
/// a running turn: that conversation stays alive here until it ends, and
/// while it runs no other conversation can ask. A conversation is saved
/// whenever a turn, a write or a discard settles; leaving one drops its
/// draft, so a change it never wrote is lost and the saved copy says so.
@MainActor
final class LedgerAgentSessions: ObservableObject {
    static let shared = LedgerAgentSessions()
    /// Conversations kept; the oldest beyond this are deleted.
    static let limit = 200

    /// Reads and writes saved conversations; the ledger's workspace in the
    /// app, memory in tests.
    struct Storage: Sendable {
        var save: @Sendable (UUID, Data) async throws -> Void
        var load: @Sendable () async -> [Data]
        var remove: @Sendable (UUID) async -> Void
        var removeAll: @Sendable () async -> Void
    }

    @Published private(set) var current: LedgerAgentConversation
    /// Newest first.
    @Published private(set) var saved: [LedgerAgentSavedConversation] = []
    /// A conversation the user moved away from while it was answering. It
    /// stays until it ends and the user opens it, or another takes its place.
    @Published private(set) var background: LedgerAgentConversation?
    private var ledgerID: UUID?
    private var storage: Storage?
    private var loading: Task<Void, Never>?

    init() {
        current = LedgerAgentConversation()
        wire(current)
    }

    /// Another conversation is answering, so the one on screen cannot ask.
    var busyElsewhere: Bool { background?.isRunning == true }

    /// Switches to the history of the ledger on screen; another ledger drops
    /// every live conversation.
    func bind(ledger id: UUID, storage: Storage) {
        guard ledgerID != id else { return }
        if ledgerID != nil {
            background?.reset()
            background = nil
            current.reset()
            current = LedgerAgentConversation()
            wire(current)
        }
        ledgerID = id
        self.storage = storage
        saved = []
        loading = Task { [weak self] in
            let records = await storage.load().compactMap { try? Self.decoder.decode(LedgerAgentSavedConversation.self, from: $0) }
            guard let self, self.ledgerID == id else { return }
            self.merge(records)
        }
    }

    func startNew() {
        guard !current.messages.isEmpty || current.isRunning || current.pending != nil else { return }
        show(LedgerAgentConversation())
    }

    func open(_ id: UUID) {
        guard id != current.id else { return }
        if let background, background.id == id { return show(background) }
        guard let record = saved.first(where: { $0.id == id }) else { return }
        show(LedgerAgentConversation(restoring: record))
    }

    /// After a notification about the conversation in the background, show it.
    func showBackground() {
        guard let background, !background.isRunning else { return }
        show(background)
    }

    /// The running conversation cannot be deleted; the one on screen is
    /// replaced by a new one.
    func delete(_ id: UUID) {
        guard background?.id != id || background?.isRunning == false else { return }
        if current.id == id {
            if current.isRunning { return }
            current.reset()
            current = LedgerAgentConversation()
            wire(current)
        }
        if background?.id == id {
            background?.reset()
            background = nil
        }
        saved.removeAll { $0.id == id }
        if let storage { Task { await storage.remove(id) } }
    }

    /// Deletes every saved conversation except one that is answering.
    func deleteAll() {
        let keep = [current, background].compactMap { $0 }.filter(\.isRunning).map(\.id)
        if !current.isRunning {
            current.reset()
            current = LedgerAgentConversation()
            wire(current)
        }
        if let background, !background.isRunning {
            background.reset()
            self.background = nil
        }
        let removed = saved.filter { !keep.contains($0.id) }.map(\.id)
        saved.removeAll { !keep.contains($0.id) }
        guard let storage else { return }
        Task {
            if keep.isEmpty { await storage.removeAll() } else { for id in removed { await storage.remove(id) } }
        }
    }

    private func show(_ next: LedgerAgentConversation) {
        let previous = current
        save(previous)
        if previous.isRunning {
            // Only one conversation answers at a time, so a finished one in
            // the background gives way.
            if let background, background !== next { background.reset() }
            background = previous
        } else if previous !== background {
            previous.reset()
        }
        if background === next { background = nil }
        current = next
        wire(next)
    }

    private func wire(_ conversation: LedgerAgentConversation) {
        conversation.onSettled = { [weak self] in self?.save($0) }
    }

    private func save(_ conversation: LedgerAgentConversation) {
        guard let record = conversation.saved() else { return }
        merge([record])
        guard let storage, let data = try? Self.encoder.encode(record) else { return }
        let removed = prune()
        Task {
            try? await storage.save(record.id, data)
            for id in removed { await storage.remove(id) }
        }
    }

    private func merge(_ records: [LedgerAgentSavedConversation]) {
        var byID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records where (byID[record.id]?.updatedAt ?? .distantPast) <= record.updatedAt {
            byID[record.id] = record
        }
        saved = byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func prune() -> [UUID] {
        guard saved.count > Self.limit else { return [] }
        let live = Set([current.id, background?.id].compactMap { $0 })
        let removed = saved.dropFirst(Self.limit).map(\.id).filter { !live.contains($0) }
        saved.removeAll { removed.contains($0.id) }
        return removed
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension LedgerAgentSessions.Storage {
    static func live(_ repository: LocalLedgerRepository) -> Self {
        let workspace = repository.workspace
        return .init(
            save: { try await workspace.saveAgentConversation(id: $0, data: $1) },
            load: { await workspace.agentConversations() },
            remove: { await workspace.removeAgentConversation(id: $0) },
            removeAll: { await workspace.removeAgentConversations() })
    }
}
