import Foundation

/// One run of a scheduled task, as ledger-automation records it in
/// runs/<id>/run.json on the repository's automation-runs branch
/// (docs/ledger-automation.md).
struct LedgerAutomationRun: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case ok, degraded, failed
    }

    let id: String
    let task: String
    let taskName: String
    let slot: Date
    let startedAt: Date
    let finishedAt: Date
    let status: Status
    var error: String? = nil
    let conversationId: String
    let summary: String
    let findings: Int
    let newFindings: Int
    let hasDraft: Bool
    var draftFiles: [String]? = nil
    var model: String? = nil

    var conversationID: UUID? { UUID(uuidString: conversationId) }

    /// A run id names a directory; anything else is not one.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 160 && !id.hasPrefix(".")
            && id.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.".unicodeScalars.contains($0) }
    }

    var statusText: String {
        switch status {
        case .ok: String(localized: "已完成")
        case .degraded: String(localized: "没跑完，稍后重试")
        case .failed: String(localized: "没跑完")
        }
    }
}

/// Reads an exported automation-runs tree. Every read is from the folder
/// alone, so it can run off the main actor.
enum LedgerAutomationRecords {
    static func runs(in root: URL, fileManager: FileManager = .default) -> [LedgerAutomationRun] {
        let directory = root.appendingPathComponent("runs", isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter(LedgerAutomationRun.isValidID).compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name).appendingPathComponent("run.json")),
                  let run = try? decoder.decode(LedgerAutomationRun.self, from: data), run.id == name else { return nil }
            return run
        }
        .sorted { ($0.slot, $0.id) > ($1.slot, $1.id) }
    }

    static func directory(of run: String, in root: URL) -> URL? {
        guard LedgerAutomationRun.isValidID(run) else { return nil }
        return root.appendingPathComponent("runs", isDirectory: true).appendingPathComponent(run, isDirectory: true)
    }

    /// The run as a saved conversation, and the transcript the model reads
    /// when it is continued; nil when the run left no conversation.
    static func conversation(of run: String, in root: URL) -> (LedgerAgentSavedConversation, Data?)? {
        guard let directory = directory(of: run, in: root),
              let data = try? Data(contentsOf: directory.appendingPathComponent("conversation.json")),
              var record = try? conversationDecoder.decode(LedgerAgentSavedConversation.self, from: data) else { return nil }
        record.automationRun = run
        return (record, try? Data(contentsOf: directory.appendingPathComponent("transcript")))
    }

    static func draft(of run: LedgerAutomationRun, in root: URL) -> LedgerAgentCloudDraft? {
        guard run.hasDraft, let directory = directory(of: run.id, in: root) else { return nil }
        let draft = directory.appendingPathComponent("draft", isDirectory: true)
        guard FileManager.default.fileExists(atPath: draft.path) else { return nil }
        return LedgerAgentCloudDraft(base: draft.appendingPathComponent("base", isDirectory: true),
                                     after: draft.appendingPathComponent("after", isDirectory: true),
                                     source: String(localized: "定时任务「\(run.taskName)」"))
    }

    /// Go writes RFC 3339 times with up to nine fractional digits, which
    /// `ISO8601DateFormatter` does not read; the fraction is dropped.
    static func date(_ text: String) -> Date? {
        var text = text
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            text.removeSubrange(dot..<end)
        }
        return ISO8601DateFormatter().date(from: text)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = LedgerAutomationRecords.date(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable time \(text)")
            }
            return date
        }
        return decoder
    }()

    /// Conversations are saved the way the App saves its own.
    static let conversationDecoder = decoder
}

/// The scheduled task runs of the ledger on screen: fetched from the Git
/// repository's automation-runs branch, each run's conversation added to the
/// assistant's history once, and its draft carried into the conversation
/// the first time it is opened.
@MainActor
final class LedgerAutomationCenter: ObservableObject {
    static let shared = LedgerAutomationCenter()

    enum Availability: Equatable {
        case unknown
        /// The ledger is not synced with Git, or no run was pushed yet.
        case none
        case available
    }

    /// Newest first.
    @Published private(set) var runs: [LedgerAutomationRun] = []
    @Published private(set) var availability = Availability.unknown
    @Published private(set) var refreshing = false
    @Published private(set) var error: String?
    @Published private(set) var refreshedAt: Date?
    /// Runs that finished since the 定时任务 page was last looked at.
    @Published private(set) var unseen = 0

    private var ledgerID: UUID?
    private var root: URL?
    private var source: (@Sendable () async throws -> URL?)?
    private var refreshTask: Task<Void, Never>?
    private let defaults: UserDefaults
    /// Refreshes on opening the drawer at most this often.
    static let staleInterval: TimeInterval = 120

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Follows the ledger on screen; another ledger starts over.
    func attach(ledger id: UUID, source: @escaping @Sendable () async throws -> URL?) {
        self.source = source
        guard ledgerID != id else { return }
        ledgerID = id
        root = nil
        runs = []
        unseen = 0
        error = nil
        refreshedAt = nil
        availability = .unknown
        refreshTask?.cancel()
        refreshTask = nil
        refreshing = false
        LedgerAgentSessions.shared.automationDraft = { [weak self] run, force in self?.draftToAdopt(run, force: force) }
        refreshIfStale()
    }

    func refreshIfStale() {
        if let refreshedAt, Date().timeIntervalSince(refreshedAt) < Self.staleInterval { return }
        Task { await refresh() }
    }

    /// Fetches the runs branch and adds new runs' conversations to the
    /// history. Concurrent calls share one fetch.
    func refresh() async {
        if let refreshTask { return await refreshTask.value }
        guard let source, let ledger = ledgerID else { return }
        refreshing = true
        let task = Task { [weak self] in
            let outcome: Result<URL?, Error>
            do { outcome = .success(try await source()) } catch { outcome = .failure(error) }
            let loaded: [LedgerAutomationRun]
            if case let .success(root?) = outcome {
                loaded = await Task.detached(priority: .utility) { LedgerAutomationRecords.runs(in: root) }.value
            } else {
                loaded = []
            }
            await self?.finishRefresh(ledger: ledger, outcome: outcome, runs: loaded)
        }
        refreshTask = task
        await task.value
    }

    private func finishRefresh(ledger: UUID, outcome: Result<URL?, Error>, runs loaded: [LedgerAutomationRun]) async {
        refreshTask = nil
        refreshing = false
        guard ledger == ledgerID else { return }
        refreshedAt = Date()
        switch outcome {
        case let .failure(failure):
            error = failure.localizedDescription
            return
        case .success(nil):
            error = nil
            root = nil
            runs = []
            availability = .none
        case let .success(root?):
            error = nil
            self.root = root
            runs = loaded
            availability = loaded.isEmpty ? .none : .available
            await importConversations(ledger: ledger, root: root)
        }
        updateUnseen()
    }

    /// Each run's conversation joins the history once. One the user deleted
    /// stays deleted, and one continued on the phone keeps its later turns.
    private func importConversations(ledger: UUID, root: URL) async {
        let sessions = LedgerAgentSessions.shared
        guard sessions.boundLedger == ledger else { return }
        let present = Set(runs.map(\.id))
        var imported = stored(.imported, ledger).intersection(present)
        for run in runs.reversed() where run.status == .ok && !imported.contains(run.id) {
            guard let found = await Task.detached(priority: .utility, operation: {
                LedgerAutomationRecords.conversation(of: run.id, in: root)
            }).value else { continue }
            await sessions.addAutomationConversation(found.0, transcript: found.1)
            imported.insert(run.id)
        }
        store(imported, .imported, ledger)
        store(stored(.adopted, ledger).intersection(present), .adopted, ledger)
    }

    /// Opens the run's conversation, adding it to the history if it is not
    /// there yet; `reloadingDraft` carries its draft over again even when it
    /// was carried before.
    func open(_ run: LedgerAutomationRun, reloadingDraft: Bool = false) async {
        guard let ledger = ledgerID, let root, let id = run.conversationID else { return }
        let sessions = LedgerAgentSessions.shared
        if !sessions.saved.contains(where: { $0.id == id }) {
            guard let found = await Task.detached(priority: .userInitiated, operation: {
                LedgerAutomationRecords.conversation(of: run.id, in: root)
            }).value else { return }
            await sessions.addAutomationConversation(found.0, transcript: found.1)
            var imported = stored(.imported, ledger)
            imported.insert(run.id)
            store(imported, .imported, ledger)
        }
        sessions.open(id, reloadingAutomationDraft: reloadingDraft)
    }

    /// A notification's link: fetch first, since the run is likely new.
    func open(runID: String) async {
        await refresh()
        guard let run = runs.first(where: { $0.id == runID }) else {
            if error == nil { error = String(localized: "没找到这次运行，可能还没推送到仓库，稍后再试。") }
            return
        }
        await open(run)
    }

    /// The draft of a run whose conversation is being opened: the first
    /// time only, unless the user asked for it again.
    private func draftToAdopt(_ run: String, force: Bool) -> LedgerAgentCloudDraft? {
        guard let ledger = ledgerID, let root, let record = runs.first(where: { $0.id == run }) else { return nil }
        var adopted = stored(.adopted, ledger)
        guard force || !adopted.contains(run), let draft = LedgerAutomationRecords.draft(of: record, in: root) else { return nil }
        adopted.insert(run)
        store(adopted, .adopted, ledger)
        return draft
    }

    func markSeen() {
        guard let ledger = ledgerID, let newest = runs.map(\.finishedAt).max() else { return }
        defaults.set(newest, forKey: key(.seen, ledger))
        updateUnseen()
    }

    private func updateUnseen() {
        guard let ledger = ledgerID else {
            unseen = 0
            return
        }
        let seen = defaults.object(forKey: key(.seen, ledger)) as? Date
        // The first look at the page counts nothing as new.
        guard let seen else {
            if let newest = runs.map(\.finishedAt).max() { defaults.set(newest, forKey: key(.seen, ledger)) }
            unseen = 0
            return
        }
        unseen = runs.filter { $0.finishedAt > seen }.count
    }

    private enum Key: String { case imported, adopted, seen }

    private func key(_ key: Key, _ ledger: UUID) -> String { "ledgerAutomation.\(key.rawValue).\(ledger.uuidString)" }

    private func stored(_ name: Key, _ ledger: UUID) -> Set<String> {
        Set(defaults.stringArray(forKey: key(name, ledger)) ?? [])
    }

    private func store(_ values: Set<String>, _ name: Key, _ ledger: UUID) {
        defaults.set(values.sorted(), forKey: key(name, ledger))
    }
}
