import Foundation

/// One conversation as it is saved in the ledger's runtime directory.
struct LedgerAgentSavedConversation: Codable, Equatable, Identifiable, Sendable {
    struct Message: Codable, Equatable, Sendable {
        let role: String
        let text: String
        var toolCalls: [LedgerAgentToolCall] = []
        var duration: TimeInterval? = nil
        /// Names of the files sent with a question; absent in older saves.
        var attachments: [String]? = nil
        /// The turn behind an answer changed memory.md; absent when not.
        var memory: Bool? = nil
        /// The choices a reply asked the user to pick from.
        var ask: LedgerAgentAsk? = nil
        /// The change written to the ledger after a reply.
        var write: LedgerAgentWriteRecord? = nil
    }

    var version = 1
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var messages: [Message]
    /// The conversation had a change on its card, or possibly in its draft,
    /// that was never written when it was last saved.
    var unwrittenChange = false
    /// The files attached to the conversation; absent in older saves.
    var attachments: [LedgerAgentAttachment]? = nil
    /// The recap at the bottom of the conversation, if one was written.
    var recap: LedgerAgentRecap? = nil
    /// The name the model gave the conversation; absent in older saves, which
    /// are still named by their first question.
    var generatedTitle: String? = nil
    /// The name the user gave the conversation; it wins over the model's.
    /// Absent in older saves and until the user renames it.
    var customTitle: String? = nil
    /// When the user pinned the conversation to the top of the history;
    /// pinned conversations are never pruned.
    var pinnedAt: Date? = nil

    /// The user's name, the model's, or the first question.
    var title: String {
        Self.title(custom: customTitle, generated: generatedTitle,
                   question: messages.first { $0.role == LedgerAgentMessage.Role.user.rawValue }?.text)
    }

    /// How a conversation is named, saved or still on screen.
    static func title(custom: String?, generated: String?, question: String?) -> String {
        for name in [custom, generated] {
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return oneLine(name)
            }
        }
        return oneLine(question ?? "")
    }

    /// The conversation as plain text for sharing: its name, then each
    /// question and answer with the names of the files sent along. The reads
    /// behind an answer are left out.
    func plainTextExport() -> String {
        var blocks = [title]
        for message in messages {
            switch LedgerAgentMessage.Role(rawValue: message.role) {
            case .user:
                var block = String(localized: "问：") + message.text
                if let files = message.attachments, !files.isEmpty {
                    block += "\n" + String(localized: "附件：") + files.joined(separator: "、")
                }
                blocks.append(block)
            case .assistant:
                blocks.append(String(localized: "答：") + message.text)
            case nil:
                continue
            }
        }
        return blocks.joined(separator: "\n\n")
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
        return title.localizedCaseInsensitiveContains(query)
            || messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*| ").union(.whitespaces)) }
            .filter { !$0.isEmpty && !$0.allSatisfy { "-:| ".contains($0) } }
            .joined(separator: " ")
    }
}

/// One section of the history list: the pinned conversations, newest pin
/// first, then the rest by when they were last used, newest first.
struct LedgerAgentHistoryGroup: Equatable, Identifiable, Sendable {
    enum Kind: CaseIterable, Sendable {
        case pinned, today, yesterday, week, month, earlier
    }

    let kind: Kind
    let items: [LedgerAgentSavedConversation]
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .pinned: String(localized: "置顶")
        case .today: String(localized: "今天")
        case .yesterday: String(localized: "昨天")
        case .week: String(localized: "过去 7 天")
        case .month: String(localized: "本月")
        case .earlier: String(localized: "更早")
        }
    }

    /// Empty sections are left out.
    static func grouping(_ items: [LedgerAgentSavedConversation], now: Date = Date(),
                         calendar: Calendar = .current) -> [Self] {
        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var byKind: [Kind: [LedgerAgentSavedConversation]] = [:]
        for item in items {
            let kind: Kind
            if item.pinnedAt != nil { kind = .pinned }
            else if calendar.isDate(item.updatedAt, inSameDayAs: now) { kind = .today }
            else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                    calendar.isDate(item.updatedAt, inSameDayAs: yesterday) { kind = .yesterday }
            else if item.updatedAt >= weekAgo { kind = .week }
            else if calendar.isDate(item.updatedAt, equalTo: now, toGranularity: .month) { kind = .month }
            else { kind = .earlier }
            byKind[kind, default: []].append(item)
        }
        byKind[.pinned]?.sort { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
        for kind in Kind.allCases where kind != .pinned {
            byKind[kind]?.sort { $0.updatedAt > $1.updatedAt }
        }
        return Kind.allCases.compactMap { kind in byKind[kind].map { Self(kind: kind, items: $0) } }
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
        /// The model-facing transcript, stored apart from the record so the
        /// history list stays small; `remove` drops it too.
        var saveTranscript: @Sendable (UUID, Data) async throws -> Void = { _, _ in }
        var loadTranscript: @Sendable (UUID) async -> Data? = { _ in nil }
        /// Drops attachment files of conversations other than these.
        var sweepAttachments: @Sendable (Set<UUID>) async -> Void = { _ in }
    }

    @Published private(set) var current: LedgerAgentConversation
    /// Newest first.
    @Published private(set) var saved: [LedgerAgentSavedConversation] = []
    /// A conversation the user moved away from while it was answering. It
    /// stays until it ends and the user opens it, or another takes its place.
    @Published private(set) var background: LedgerAgentConversation?
    /// A question from Siri or a shortcut for the conversation on screen to
    /// send once it can.
    @Published var queuedQuestion: String?
    private var ledgerID: UUID?
    private var storage: Storage?
    private var loading: Task<Void, Never>?
    /// What the composer held when the user left each conversation; kept
    /// only while the app runs.
    private var unsent: [UUID: String] = [:]

    init() {
        current = LedgerAgentConversation()
        wire(current)
    }

    /// Questions asked lately, newest first, so suggestions do not repeat
    /// them.
    func recentQuestions(limit: Int = 12) -> [String] {
        var seen = Set<String>()
        var questions: [String] = []
        let live = [current, background].compactMap { $0 }.flatMap { $0.messages.filter { $0.role == .user }.map(\.text).reversed() }
        let stored = saved.flatMap { $0.messages.filter { $0.role == LedgerAgentMessage.Role.user.rawValue }.map(\.text).reversed() }
        for question in live + stored where seen.insert(question).inserted {
            questions.append(question)
            if questions.count == limit { break }
        }
        return questions
    }

    /// Another conversation is answering, so the one on screen cannot ask.
    var busyElsewhere: Bool { background?.isRunning == true }

    /// What the header calls a live conversation, the way the history will.
    func title(of conversation: LedgerAgentConversation) -> String {
        LedgerAgentSavedConversation.title(
            custom: saved.first { $0.id == conversation.id }?.customTitle, generated: conversation.generatedTitle,
            question: conversation.messages.first { $0.role == .user }?.text)
    }

    /// The name the user gave a conversation, if any.
    func customTitle(of id: UUID) -> String? {
        saved.first { $0.id == id }?.customTitle
    }

    /// Names a conversation; an empty name gives it back the model's name or
    /// its first question.
    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateRecord(id) { $0.customTitle = name.isEmpty ? nil : name }
    }

    /// Names a conversation from the rename field, which opens holding the
    /// name `shown`. Saving that name untouched keeps an automatic name
    /// automatic, so the model's name can still replace the first question.
    func rename(_ id: UUID, to name: String, shown: String) {
        let unchanged = name.trimmingCharacters(in: .whitespacesAndNewlines)
            == shown.trimmingCharacters(in: .whitespacesAndNewlines)
        if unchanged, customTitle(of: id) == nil { return }
        rename(id, to: name)
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        updateRecord(id) { record in
            if pinned != (record.pinnedAt != nil) { record.pinnedAt = pinned ? Date() : nil }
        }
    }

    func unsentText(for id: UUID) -> String { unsent[id] ?? "" }

    func setUnsentText(_ text: String, for id: UUID) {
        unsent[id] = text.isEmpty ? nil : text
    }

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
        unsent = [:]
        loading = Task { [weak self] in
            let records = await storage.load().compactMap { try? Self.decoder.decode(LedgerAgentSavedConversation.self, from: $0) }
            guard let self, self.ledgerID == id else { return }
            self.merge(records)
            let keep = Set(records.map(\.id) + [self.current.id, self.background?.id].compactMap { $0 })
            await storage.sweepAttachments(keep)
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
        let reopened = LedgerAgentConversation(restoring: record)
        show(reopened)
        // A transcript dropped with an unwritten change no longer matches
        // the ledger the model will read; the visible history is enough.
        guard !record.unwrittenChange, let storage else { return }
        Task { [weak reopened] in
            guard let data = await storage.loadTranscript(id) else { return }
            reopened?.adoptTranscript(String(decoding: data, as: UTF8.self))
        }
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
        unsent[id] = nil
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
        unsent = unsent.filter { keep.contains($0.key) }
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
        guard var record = conversation.saved() else { return }
        // The name and pin are the user's, kept on the saved record rather
        // than the conversation, so every save carries them over.
        if let previous = saved.first(where: { $0.id == record.id }) {
            record.customTitle = previous.customTitle
            record.pinnedAt = previous.pinnedAt
        }
        merge([record])
        guard let storage, let data = try? Self.encoder.encode(record) else { return }
        let removed = prune()
        let transcript = conversation.transcript.map { Data($0.utf8) }
        Task {
            try? await storage.save(record.id, data)
            if let transcript { try? await storage.saveTranscript(record.id, transcript) }
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

    /// Changes what the user owns on a record, its name or its pin, without
    /// moving it in the history. A conversation on screen that was not saved
    /// yet is saved with the change.
    private func updateRecord(_ id: UUID, _ change: (inout LedgerAgentSavedConversation) -> Void) {
        var record: LedgerAgentSavedConversation
        if let existing = saved.first(where: { $0.id == id }) {
            record = existing
        } else if let live = [current, background].compactMap({ $0 }).first(where: { $0.id == id }),
                  let fresh = live.saved() {
            record = fresh
        } else {
            return
        }
        let before = record
        change(&record)
        guard record != before else { return }
        if let index = saved.firstIndex(where: { $0.id == id }) { saved[index] = record } else { merge([record]) }
        guard let storage, let data = try? Self.encoder.encode(record) else { return }
        Task { try? await storage.save(id, data) }
    }

    /// The oldest conversations beyond the limit, except pinned ones and the
    /// ones still live.
    private func prune() -> [UUID] {
        guard saved.count > Self.limit else { return [] }
        let live = Set([current.id, background?.id].compactMap { $0 })
        let removable = saved.filter { $0.pinnedAt == nil && !live.contains($0.id) }
        let removed = Set(removable.suffix(saved.count - Self.limit).map(\.id))
        saved.removeAll { removed.contains($0.id) }
        return Array(removed)
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
            removeAll: { await workspace.removeAgentConversations() },
            saveTranscript: { try await workspace.saveAgentTranscript(id: $0, data: $1) },
            loadTranscript: { await workspace.agentTranscript(id: $0) },
            sweepAttachments: { await workspace.removeAgentAttachments(keeping: $0) })
    }
}
