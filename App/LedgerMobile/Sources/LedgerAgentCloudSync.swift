import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 账本助手 data kept in iCloud, so the history and memory.md survive
/// deleting the app and follow the user to their other devices.
///
/// The folder is `Documents/Assistant` in the app's own iCloud container on
/// paid-team builds (`LedgerICloud`). Sideloaded builds cannot carry the
/// iCloud entitlement and use a folder the user picks in iCloud Drive
/// instead; a picked folder, once chosen, keeps precedence.
///
/// Folder layout:
///
/// ```
/// <folder>/agent-sync.json                            format marker
/// <folder>/preferences.plist                          model choice and switches, no keys
/// <folder>/ledgers/<key>/ledger.json                  which ledger this is
/// <folder>/ledgers/<key>/files/agent-memory/MEMORY.md, <topic>.md, <group>/<topic>.md
/// <folder>/ledgers/<key>/files/agent-memory.md          (versions before the folder)
/// <folder>/ledgers/<key>/files/agent-history/<id>.json, <id>.transcript, <id>.<leaf>.transcript
/// <folder>/ledgers/<key>/files/agent-attachments/<id>/<file>
/// <folder>/ledgers/<key>/files/agent-artifacts/<artifact-id>.json
/// ```
///
/// `<key>` comes from the ledger's Git remote, or its name, rather than its
/// local id, which a reinstall changes.
///
/// Merge rules, per file, against the digest both sides had at this device's
/// last sync:
/// - Changed on one side only: that side wins, deletions included.
/// - Changed on both: a memory file is merged line by line; a conversation keeps
///   the record with the later `updatedAt`, and its transcripts and
///   attachments follow that record; an artifact keeps the newer file;
///   deleted on one side and changed on the other keeps the change.
/// API keys live in the Keychain and are never read here.
enum LedgerAgentSyncLayout {
    static let markerName = "agent-sync.json"
    static let preferencesName = "preferences.plist"
    static let ledgersName = "ledgers"
    static let ledgerInfoName = "ledger.json"
    static let filesName = "files"
    static let formatVersion = 1
    static let memoryPath = "agent-memory.md"
    static let historyDirectory = "agent-history"
    static let attachmentsDirectory = "agent-attachments"
    static let artifactsDirectory = "agent-artifacts"

    struct Marker: Codable, Equatable, Sendable {
        var formatVersion = LedgerAgentSyncLayout.formatVersion
        let createdAt: Date
    }

    /// What a ledger's folder holds, so another install can offer it.
    struct LedgerInfo: Codable, Equatable, Identifiable, Sendable {
        var formatVersion = LedgerAgentSyncLayout.formatVersion
        let key: String
        let name: String
        let updatedAt: Date
        var deviceName: String? = nil
        var id: String { key }
    }

    /// The folder name of a ledger: its iCloud container folder, or its Git
    /// remote and branch, so a reinstall that joins or clones it again finds
    /// the same data; else its name.
    static func key(for descriptor: LocalLedgerDescriptor) -> String {
        let identity: String
        if let container = descriptor.folder?.container {
            // Every device that joined the iCloud ledger names the same folder,
            // whatever the ledger is called locally.
            identity = "icloud:" + container
        } else if let git = descriptor.git {
            var url = git.repositoryURL.absoluteString.lowercased()
            while url.hasSuffix("/") { url.removeLast() }
            if url.hasSuffix(".git") { url.removeLast(4) }
            identity = "git:" + url + "#" + git.branch
        } else {
            identity = "name:" + descriptor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(digest(Data(identity.utf8)).prefix(20))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a path under runtime/ is assistant data that syncs.
    static func isSynced(_ path: String, attachments: Bool = true) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        if LedgerAgentMemoryLayout.isSyncedMemory(path) { return true }
        if parts.count == 2, parts[0] == historyDirectory { return isHistoryFile(parts[1]) }
        if parts.count == 2, parts[0] == artifactsDirectory, parts[1].hasSuffix(".json") {
            return LedgerAgentArtifactSpec.isValidID(String(parts[1].dropLast(5)))
        }
        if attachments, parts.count == 3, parts[0] == attachmentsDirectory {
            return UUID(uuidString: parts[1]) != nil && !parts[2].hasPrefix(".")
        }
        return false
    }

    /// `<id>.json`, `<id>.transcript` or `<id>.<leaf>.transcript`.
    static func isHistoryFile(_ name: String) -> Bool {
        if name.hasSuffix(".json") { return UUID(uuidString: String(name.dropLast(5))) != nil }
        guard name.hasSuffix(".transcript") else { return false }
        let ids = name.dropLast(".transcript".count).split(separator: ".", omittingEmptySubsequences: false)
        return (1...2).contains(ids.count) && ids.allSatisfy { UUID(uuidString: String($0)) != nil }
    }

    /// The conversation a synced file belongs to; nil for memory.md.
    static func conversationID(of path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == historyDirectory { return UUID(uuidString: String(parts[1].prefix(36))) }
        if parts.count == 3, parts[0] == attachmentsDirectory { return UUID(uuidString: parts[1]) }
        return nil
    }

    static func isRecord(_ path: String) -> Bool {
        path.hasPrefix(historyDirectory + "/") && path.hasSuffix(".json")
    }

    /// Whether a synced path is a memory file, merged line by line.
    static func isMemory(_ path: String) -> Bool { LedgerAgentMemoryLayout.isSyncedMemory(path) }

    /// Three-way merge of a memory file, one line per fact: lines the other
    /// side removed go, lines it added are kept next to the same copy of the
    /// line they followed there (or at the end), and this side's own edits
    /// stay as they are. `server/agentmemory.MergeLines` is the same rule.
    static func mergeMemory(base: String, local: String, remote: String) -> String {
        func lines(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "\r", with: "").replacingOccurrences(
                    of: "\\s+$", with: "", options: .regularExpression)
            }
        }
        let baseLines = lines(base), remoteLines = lines(remote)
        let baseSet = Set(baseLines), remoteSet = Set(remoteLines)
        // Front matter fences stay even when the other side moved them.
        let removed = baseSet.subtracting(remoteSet).filter { !$0.isEmpty && $0 != "---" }
        var result = lines(local).filter { !removed.contains($0) }
        for (index, line) in remoteLines.enumerated() where !line.isEmpty && !baseSet.contains(line) && !result.contains(line) {
            var insertAt = result.count
            for previousIndex in stride(from: index - 1, through: 0, by: -1) where !remoteLines[previousIndex].isEmpty {
                let previous = remoteLines[previousIndex]
                // The same copy of a repeated anchor, such as "---".
                let occurrence = remoteLines[...previousIndex].filter { $0 == previous }.count
                let matches = result.indices.filter { result[$0] == previous }
                if let found = matches.count >= occurrence ? matches[occurrence - 1] : matches.last {
                    insertAt = found + 1
                    break
                }
            }
            // Keep a trailing blank line after the text, not before the line.
            if insertAt == result.count {
                while insertAt > 0, result[insertAt - 1].isEmpty { insertAt -= 1 }
            }
            result.insert(line, at: insertAt)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        while result.first?.isEmpty == true { result.removeFirst() }
        return result.isEmpty ? "" : result.joined(separator: "\n") + "\n"
    }
}

/// What a sync did, for the settings page.
struct LedgerAgentSyncReport: Equatable, Sendable {
    var uploaded = 0
    var downloaded = 0
    var merged = 0
    var failed = 0
    var changedLocally: Bool { downloaded > 0 || merged > 0 }
}

/// One local change a sync wants: `staged` replaces the file, nil removes
/// it. It applies only while the file still has `expected` (nil: absent), so
/// a save made during the sync is never overwritten.
struct LedgerAgentSyncLocalChange: Equatable, Sendable {
    let path: String
    let staged: URL?
    let expected: LedgerAgentSyncEngine.Stamp?
}

/// The two-way sync of one ledger's assistant data. Remote reads and writes
/// happen here, off the workspace; local writes go through `apply`, which the
/// app runs on the workspace actor.
struct LedgerAgentSyncEngine: Sendable {
    struct Stamp: Codable, Equatable, Sendable {
        var size: Int64?
        var modified: Double
    }

    struct State: Codable, Equatable, Sendable {
        struct Entry: Codable, Equatable, Sendable {
            var digest: String
            var local: Stamp?
            var remote: Stamp?
        }

        var version = 1
        /// The folder and ledger key the entries describe; another one starts
        /// over, as a first sync.
        var identity = ""
        var entries: [String: Entry] = [:]
        /// memory.md as both sides last agreed, the base of its merge
        /// (versions before the memory folder).
        var memoryBase: String?
        /// Each memory file as both sides last agreed, the base of its merge.
        var memoryBases: [String: String]?
    }

    /// runtime/ of the ledger's workspace.
    let runtime: URL
    /// `<folder>/ledgers/<key>/files`.
    let remote: URL
    /// This device's state, outside the synced files.
    let stateURL: URL
    /// Where pulled files wait for `apply`.
    let incoming: URL
    let identity: String
    var includesAttachments = true

    init(runtime: URL, remote: URL, identity: String, includesAttachments: Bool = true) {
        self.runtime = runtime
        self.remote = remote
        self.identity = identity
        self.includesAttachments = includesAttachments
        let own = runtime.appendingPathComponent("agent-sync", isDirectory: true)
        stateURL = own.appendingPathComponent("state.json")
        incoming = own.appendingPathComponent("incoming", isDirectory: true)
    }

    private enum Action {
        case none
        case push
        case pull
        case write(Data)
    }

    func run(apply: @Sendable ([LedgerAgentSyncLocalChange]) async throws -> Set<String>) async throws -> LedgerAgentSyncReport {
        var state = loadState()
        if state.identity != identity { state = State(identity: identity) }
        if let legacy = state.memoryBase, state.memoryBases?[LedgerAgentSyncLayout.memoryPath] == nil {
            state.memoryBases = (state.memoryBases ?? [:]).merging([LedgerAgentSyncLayout.memoryPath: legacy]) { current, _ in current }
        }
        state.memoryBase = nil
        let memoryBases = state.memoryBases ?? [:]
        resolveRemoteConflicts(memoryBases: memoryBases)
        let localStamps = scanLocal()
        let remoteStamps = try scanRemote()
        var report = LedgerAgentSyncReport()

        // Records first, so a conversation's other files can follow the
        // record that won.
        let paths = Set(localStamps.keys).union(remoteStamps.keys).union(state.entries.keys)
            .filter { LedgerAgentSyncLayout.isSynced($0, attachments: includesAttachments) }
            .sorted { (LedgerAgentSyncLayout.isRecord($0) ? 0 : 1, $0) < (LedgerAgentSyncLayout.isRecord($1) ? 0 : 1, $1) }
        var winners: [UUID: Bool] = [:] // true: remote won
        var changes: [LedgerAgentSyncLocalChange] = []
        var settled: [String: String?] = [:] // path -> agreed digest, nil when gone on both sides
        var agreedMemory: [String: String] = [:]

        try? FileManager.default.removeItem(at: incoming)

        for path in paths {
            let entry = state.entries[path]
            let localURL = runtime.appendingPathComponent(path)
            let remoteURL = remote.appendingPathComponent(path)
            do {
                var localData: Data?
                var remoteData: Data?
                let localDigest: String?
                if let stamp = localStamps[path] {
                    if let entry, entry.local == stamp {
                        localDigest = entry.digest
                    } else {
                        let data = try Data(contentsOf: localURL)
                        localData = data
                        localDigest = LedgerAgentSyncLayout.digest(data)
                    }
                } else { localDigest = nil }
                let remoteDigest: String?
                if let stamp = remoteStamps[path] {
                    if let entry, entry.remote == stamp {
                        remoteDigest = entry.digest
                    } else {
                        let data = try FolderFiles.read(remoteURL)
                        remoteData = data
                        remoteDigest = LedgerAgentSyncLayout.digest(data)
                    }
                } else { remoteDigest = nil }
                let base = entry?.digest

                var action = Action.none
                if localDigest == remoteDigest {
                    action = .none
                } else if localDigest == base {
                    action = .pull
                } else if remoteDigest == base {
                    action = .push
                } else if localDigest == nil {
                    action = .pull
                } else if remoteDigest == nil {
                    action = .push
                } else if LedgerAgentSyncLayout.isMemory(path) {
                    let local = String(decoding: try localData ?? Data(contentsOf: localURL), as: UTF8.self)
                    let theirs = String(decoding: try remoteData ?? FolderFiles.read(remoteURL), as: UTF8.self)
                    let merged = LedgerAgentSyncLayout.mergeMemory(base: memoryBases[path] ?? "", local: local, remote: theirs)
                    action = .write(Data(merged.utf8))
                    report.merged += 1
                } else if LedgerAgentSyncLayout.isRecord(path) {
                    let local = try localData ?? Data(contentsOf: localURL)
                    let theirs = try remoteData ?? FolderFiles.read(remoteURL)
                    let remoteWins = Self.updatedAt(theirs) > Self.updatedAt(local)
                    if let id = LedgerAgentSyncLayout.conversationID(of: path) { winners[id] = remoteWins }
                    action = remoteWins ? .pull : .push
                    report.merged += 1
                } else {
                    let id = LedgerAgentSyncLayout.conversationID(of: path)
                    let remoteWins = id.flatMap { winners[$0] }
                        ?? ((remoteStamps[path]?.modified ?? 0) > (localStamps[path]?.modified ?? 0))
                    action = remoteWins ? .pull : .push
                }

                switch action {
                case .none:
                    settled[path] = .some(localDigest)
                    if LedgerAgentSyncLayout.isMemory(path), localDigest != nil, localDigest != base || memoryBases[path] == nil {
                        agreedMemory[path] = String(decoding: try localData ?? Data(contentsOf: localURL), as: UTF8.self)
                    }
                case .push:
                    if localDigest == nil {
                        try FolderFiles.remove(remoteURL)
                    } else {
                        let data = try localData ?? Data(contentsOf: localURL)
                        try FolderFiles.write(data, to: remoteURL)
                        if LedgerAgentSyncLayout.isMemory(path) { agreedMemory[path] = String(decoding: data, as: UTF8.self) }
                    }
                    settled[path] = .some(localDigest)
                    report.uploaded += 1
                case .pull:
                    var staged: URL?
                    if remoteDigest != nil {
                        let data = try remoteData ?? FolderFiles.read(remoteURL)
                        staged = try stage(data)
                        if LedgerAgentSyncLayout.isMemory(path) { agreedMemory[path] = String(decoding: data, as: UTF8.self) }
                    }
                    changes.append(.init(path: path, staged: staged, expected: localStamps[path]))
                    settled[path] = .some(remoteDigest)
                    report.downloaded += 1
                case let .write(data):
                    try FolderFiles.write(data, to: remoteURL)
                    changes.append(.init(path: path, staged: try stage(data), expected: localStamps[path]))
                    settled[path] = .some(LedgerAgentSyncLayout.digest(data))
                    agreedMemory[path] = String(decoding: data, as: UTF8.self)
                }
            } catch {
                report.failed += 1
            }
        }

        var applied = Set<String>()
        if !changes.isEmpty { applied = try await apply(changes) }
        try? FileManager.default.removeItem(at: incoming)
        let skipped = Set(changes.map(\.path)).subtracting(applied)
        report.failed += skipped.count

        for (path, digest) in settled where !skipped.contains(path) {
            guard let digest else {
                state.entries[path] = nil
                continue
            }
            state.entries[path] = .init(digest: digest,
                                        local: Self.localStamp(runtime.appendingPathComponent(path)),
                                        remote: Self.remoteStamp(remote.appendingPathComponent(path)))
        }
        var bases = memoryBases
        for (path, text) in agreedMemory where !skipped.contains(path) { bases[path] = text }
        for path in bases.keys where state.entries[path] == nil { bases[path] = nil }
        state.memoryBases = bases.isEmpty ? nil : bases
        try saveState(state)
        return report
    }

    /// Applies pulled files under runtime/, each only while the local file is
    /// still what the plan saw. Returns the paths it changed.
    static func applyLocally(_ changes: [LedgerAgentSyncLocalChange], runtime: URL) -> Set<String> {
        var applied = Set<String>()
        let fileManager = FileManager.default
        for change in changes {
            let target = runtime.appendingPathComponent(change.path)
            guard localStamp(target) == change.expected else { continue }
            do {
                if let staged = change.staged {
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: target.path) {
                        _ = try fileManager.replaceItemAt(target, withItemAt: staged)
                    } else {
                        try fileManager.moveItem(at: staged, to: target)
                    }
                } else if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                    // An emptied attachment folder goes too.
                    let parent = target.deletingLastPathComponent()
                    if change.path.hasPrefix(LedgerAgentSyncLayout.attachmentsDirectory + "/"),
                       (try? fileManager.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                        try? fileManager.removeItem(at: parent)
                    }
                }
                applied.insert(change.path)
            } catch {
                continue
            }
        }
        return applied
    }

    // MARK: - Files

    /// Two devices that wrote memory.md or the same conversation at once
    /// leave iCloud conflict versions behind; fold them in by the same rules
    /// as a merge, before reading the remote side.
    private func resolveRemoteConflicts(memoryBases: [String: String]) {
        for path in Self.memoryPaths(in: remote, names: { try FolderFiles.names(in: $0) }) {
            _ = try? FolderConflictVersions.resolve(at: remote.appendingPathComponent(path)) { current, other in
                Data(LedgerAgentSyncLayout.mergeMemory(base: memoryBases[path] ?? "", local: String(decoding: current, as: UTF8.self),
                                                       remote: String(decoding: other, as: UTF8.self)).utf8)
            }
        }
        let history = remote.appendingPathComponent(LedgerAgentSyncLayout.historyDirectory, isDirectory: true)
        for name in (try? FolderFiles.names(in: history)) ?? [] where name.hasSuffix(".json") {
            _ = try? FolderConflictVersions.resolve(at: history.appendingPathComponent(name)) { current, other in
                Self.updatedAt(other) > Self.updatedAt(current) ? other : current
            }
        }
    }

    private func stage(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let url = incoming.appendingPathComponent(UUID().uuidString)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The memory files under root (runtime/ or the folder's files/): the
    /// legacy memory.md and everything in agent-memory/, two folders deep.
    static func memoryPaths(in root: URL, names: (URL) throws -> [String]) -> [String] {
        var paths = [LedgerAgentSyncLayout.memoryPath]
        var pending: [(String, Int)] = [(LedgerAgentMemoryLayout.directory, 0)]
        while let (relative, depth) = pending.popLast() {
            let directory = root.appendingPathComponent(relative, isDirectory: true)
            for name in (try? names(directory)) ?? [] where !name.hasPrefix(".") {
                let path = relative + "/" + name
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    if depth < 2 { pending.append((path, depth + 1)) }
                } else if LedgerAgentMemoryLayout.isSyncedMemory(path) {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    private func scanLocal() -> [String: Stamp] {
        var stamps: [String: Stamp] = [:]
        let fileManager = FileManager.default
        func add(_ path: String) {
            if let stamp = Self.localStamp(runtime.appendingPathComponent(path)) { stamps[path] = stamp }
        }
        for path in Self.memoryPaths(in: runtime, names: { try fileManager.contentsOfDirectory(atPath: $0.path) }) { add(path) }
        let history = runtime.appendingPathComponent(LedgerAgentSyncLayout.historyDirectory, isDirectory: true)
        for name in (try? fileManager.contentsOfDirectory(atPath: history.path)) ?? [] {
            add(LedgerAgentSyncLayout.historyDirectory + "/" + name)
        }
        let artifacts = runtime.appendingPathComponent(LedgerAgentSyncLayout.artifactsDirectory, isDirectory: true)
        for name in (try? fileManager.contentsOfDirectory(atPath: artifacts.path)) ?? [] {
            add(LedgerAgentSyncLayout.artifactsDirectory + "/" + name)
        }
        if includesAttachments {
            let attachments = runtime.appendingPathComponent(LedgerAgentSyncLayout.attachmentsDirectory, isDirectory: true)
            for id in (try? fileManager.contentsOfDirectory(atPath: attachments.path)) ?? [] where UUID(uuidString: id) != nil {
                let folder = attachments.appendingPathComponent(id, isDirectory: true)
                for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
                    add(LedgerAgentSyncLayout.attachmentsDirectory + "/" + id + "/" + name)
                }
            }
        }
        return stamps.filter { LedgerAgentSyncLayout.isSynced($0.key, attachments: includesAttachments) }
    }

    private func scanRemote() throws -> [String: Stamp] {
        var stamps: [String: Stamp] = [:]
        func add(_ path: String) {
            if let stamp = Self.remoteStamp(remote.appendingPathComponent(path)) { stamps[path] = stamp }
        }
        for path in Self.memoryPaths(in: remote, names: { try FolderFiles.names(in: $0) }) { add(path) }
        let history = remote.appendingPathComponent(LedgerAgentSyncLayout.historyDirectory, isDirectory: true)
        for name in try FolderFiles.names(in: history) { add(LedgerAgentSyncLayout.historyDirectory + "/" + name) }
        let artifacts = remote.appendingPathComponent(LedgerAgentSyncLayout.artifactsDirectory, isDirectory: true)
        for name in try FolderFiles.names(in: artifacts) { add(LedgerAgentSyncLayout.artifactsDirectory + "/" + name) }
        if includesAttachments {
            let attachments = remote.appendingPathComponent(LedgerAgentSyncLayout.attachmentsDirectory, isDirectory: true)
            for id in try FolderFiles.names(in: attachments) where UUID(uuidString: id) != nil {
                for name in try FolderFiles.names(in: attachments.appendingPathComponent(id, isDirectory: true)) {
                    add(LedgerAgentSyncLayout.attachmentsDirectory + "/" + id + "/" + name)
                }
            }
        }
        return stamps.filter { LedgerAgentSyncLayout.isSynced($0.key, attachments: includesAttachments) }
    }

    /// Size and modification time of a regular local file; nil when absent
    /// or not a regular file.
    static func localStamp(_ url: URL) -> Stamp? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let modified = values.contentModificationDate else { return nil }
        return Stamp(size: values.fileSize.map(Int64.init), modified: modified.timeIntervalSinceReferenceDate)
    }

    /// The modification time of a file in the folder, downloaded or still an
    /// iCloud placeholder. Placeholders have no reliable size.
    static func remoteStamp(_ url: URL) -> Stamp? {
        guard FolderFiles.exists(url), let modified = FolderFiles.modificationDate(of: url) else { return nil }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return nil }
        return Stamp(size: nil, modified: modified.timeIntervalSinceReferenceDate)
    }

    private static func updatedAt(_ data: Data) -> Date {
        struct Record: Decodable { let updatedAt: Date }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Record.self, from: data))?.updatedAt ?? .distantPast
    }

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private func saveState(_ state: State) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
}

/// The assistant's preferences that are safe to keep in the folder: the
/// model choice, favorites and switches. API keys stay in the Keychain. A
/// fresh install takes them back once; afterwards each sync writes this
/// device's.
enum LedgerAgentSyncPreferences {
    static let keys = [
        "ledger.agent.model-choice", "ledger.agent.custom-choice", "ledger.agent.thinking",
        "ledger.agent.favorite-models", "ledger.agent.keep-awake", "ledger.agent.write-policy",
        "ledger.agent.memory", "ledger.agent.assists", "ledger.agent.suggestions",
        "ledger.agent.context-windows", "ledger.agent.max-output-tokens", "ledger.agent.disabled-skills",
    ]

    static func snapshot(_ defaults: UserDefaults) -> Data? {
        var values: [String: Any] = [:]
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            if let data = value as? Data, containsCredential(data) { continue }
            values[key] = value
        }
        guard !values.isEmpty else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    /// Whether this install has none of the preferences yet.
    static func isFresh(_ defaults: UserDefaults) -> Bool {
        !keys.contains { defaults.object(forKey: $0) != nil }
    }

    @discardableResult
    static func restore(_ data: Data, into defaults: UserDefaults) -> Bool {
        guard let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return false }
        var restored = false
        for key in keys {
            guard let value = values[key] else { continue }
            if let data = value as? Data, containsCredential(data) { continue }
            defaults.set(value, forKey: key)
            restored = true
        }
        return restored
    }

    /// A custom endpoint whose URL carries a user, a password or a query
    /// string may hold a token, so it is left out.
    static func containsCredential(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        guard text.contains("baseurl") else { return false }
        struct Choice: Decodable { struct Custom: Decodable { let baseURL: String? }; let custom: Custom? }
        guard let url = (try? JSONDecoder().decode(Choice.self, from: data))?.custom?.baseURL, !url.isEmpty else { return false }
        guard let components = URLComponents(string: url) else { return true }
        return components.user != nil || components.password != nil || components.query != nil
    }
}

/// The picked folder, kept as a bookmark so it survives relaunches, and the
/// switches of the settings page.
struct LedgerAgentSyncFolder: Sendable {
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    static let bookmarkKey = "ledger.agent.sync.folderBookmark"
    /// On: the app's iCloud container, used when no folder was picked.
    static let iCloudKey = "ledger.agent.sync.icloud"
    static let attachmentsKey = "ledger.agent.sync.attachments"
    static let restoredPreferencesKey = "ledger.agent.sync.preferences-restored"
    static let linkPrefix = "ledger.agent.sync.link."
    static let lastSyncPrefix = "ledger.agent.sync.last."

    let url: URL
    var isICloudContainer = false

    /// The folder to sync with. The container resolves off the main thread.
    static func resolve() async -> LedgerAgentSyncFolder? {
        if let picked = current { return picked }
        guard defaults.bool(forKey: iCloudKey) else { return nil }
        return await Task.detached(priority: .utility) { () -> LedgerAgentSyncFolder? in
            guard let url = LedgerICloud.assistantDirectory() else { return nil }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return LedgerAgentSyncFolder(url: url, isICloudContainer: true)
        }.value
    }

    static var usesICloud: Bool { defaults.data(forKey: bookmarkKey) == nil && defaults.bool(forKey: iCloudKey) }

    static var current: LedgerAgentSyncFolder? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolutionOptions,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let refreshed = try? FolderSyncLocation.makeBookmark(for: url) { defaults.set(refreshed, forKey: bookmarkKey) }
        return LedgerAgentSyncFolder(url: url)
    }

    static var isOn: Bool { defaults.data(forKey: bookmarkKey) != nil || defaults.bool(forKey: iCloudKey) }

    /// Persists a folder returned by the system folder picker.
    static func select(_ url: URL) throws -> LedgerAgentSyncFolder {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        defaults.set(try FolderSyncLocation.makeBookmark(for: url), forKey: bookmarkKey)
        defaults.removeObject(forKey: iCloudKey)
        return LedgerAgentSyncFolder(url: url)
    }

    static func selectICloud() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.set(true, forKey: iCloudKey)
    }

    static func clear() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: iCloudKey)
    }

    static var includesAttachments: Bool {
        get { defaults.object(forKey: attachmentsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: attachmentsKey) }
    }

    /// The folder key a ledger uses: one the user linked, else its own.
    static func key(for descriptor: LocalLedgerDescriptor) -> String {
        defaults.string(forKey: linkPrefix + descriptor.id.uuidString) ?? LedgerAgentSyncLayout.key(for: descriptor)
    }

    static func link(_ ledgerID: UUID, to key: String?) {
        defaults.set(key, forKey: linkPrefix + ledgerID.uuidString)
    }

    static func lastSync(for ledgerID: UUID) -> Date? {
        defaults.object(forKey: lastSyncPrefix + ledgerID.uuidString) as? Date
    }

    static func recordSync(for ledgerID: UUID, at date: Date) {
        defaults.set(date, forKey: lastSyncPrefix + ledgerID.uuidString)
    }

    var displayName: String { isICloudContainer ? "iCloud" : FileManager.default.displayName(atPath: url.path) }

    @MainActor
    func withAccess<Value: Sendable>(_ body: (URL) async throws -> Value) async throws -> Value {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { throw LedgerBackupError.folderUnavailable }
        return try await body(url)
    }

    /// The ledgers whose assistant data the folder holds.
    static func ledgers(in folder: URL) -> [LedgerAgentSyncLayout.LedgerInfo] {
        let root = folder.appendingPathComponent(LedgerAgentSyncLayout.ledgersName, isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? FolderFiles.names(in: root)) ?? []).compactMap { key in
            let file = root.appendingPathComponent(key, isDirectory: true).appendingPathComponent(LedgerAgentSyncLayout.ledgerInfoName)
            guard let data = try? FolderFiles.read(file) else { return nil }
            return try? decoder.decode(LedgerAgentSyncLayout.LedgerInfo.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        .withSecurityScope
        #else
        []
        #endif
    }
}

/// Runs the sync for the open ledger: when the app comes to the front, a few
/// seconds after a conversation or memory.md is saved, and on request from
/// the settings page.
@MainActor
final class LedgerAgentCloudSync: ObservableObject {
    static let shared = LedgerAgentCloudSync()
    /// How long after a save the next sync waits, so a burst of saves
    /// uploads once.
    static let debounce: Duration = .seconds(4)

    @Published private(set) var isOn = LedgerAgentSyncFolder.isOn
    @Published private(set) var folderName: String? = LedgerAgentSyncFolder.usesICloud ? "iCloud" : LedgerAgentSyncFolder.current?.displayName
    @Published private(set) var usesICloud = LedgerAgentSyncFolder.usesICloud
    @Published private(set) var running = false
    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastReport: LedgerAgentSyncReport?
    @Published private(set) var error: String?
    /// Other ledgers' data in the folder, which this ledger can take over
    /// after a reinstall named or cloned it differently.
    @Published private(set) var otherLedgers: [LedgerAgentSyncLayout.LedgerInfo] = []
    @Published private(set) var currentKey: String?
    @Published var includesAttachments = LedgerAgentSyncFolder.includesAttachments {
        didSet { LedgerAgentSyncFolder.includesAttachments = includesAttachments }
    }

    private weak var repository: LocalLedgerRepository?
    private var pending: Task<Void, Never>?
    private var again = false

    /// The ledger on screen; its data syncs from now on.
    func attach(_ repository: LocalLedgerRepository) {
        // The memory branch of a Git ledger syncs whether or not iCloud does.
        LedgerAgentMemorySync.shared.attach(repository)
        let changed = self.repository?.descriptor.id != repository.descriptor.id
        self.repository = repository
        if changed {
            lastSynced = LedgerAgentSyncFolder.lastSync(for: repository.descriptor.id)
            lastReport = nil
            error = nil
            currentKey = LedgerAgentSyncFolder.key(for: repository.descriptor)
        } else if let lastSynced, Date().timeIntervalSince(lastSynced) < Self.foregroundInterval {
            // Coming back to the app moments after a sync finds nothing new.
            return
        }
        schedule(after: .zero)
    }

    /// Syncs on coming to the front at most this often.
    static let foregroundInterval: TimeInterval = 60

    /// A conversation or memory.md was saved.
    func localChanged() {
        LedgerAgentMemorySync.shared.localChanged()
        schedule(after: Self.debounce)
    }

    func choose(folder url: URL) {
        do {
            let folder = try LedgerAgentSyncFolder.select(url)
            isOn = true
            usesICloud = false
            folderName = folder.displayName
            error = nil
            schedule(after: .zero)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Syncs through the app's iCloud container.
    func useICloud() async {
        guard await LedgerICloud.available() else {
            error = LedgerBackupError.iCloudUnavailable.localizedDescription
            return
        }
        LedgerAgentSyncFolder.selectICloud()
        isOn = true
        usesICloud = true
        folderName = "iCloud"
        error = nil
        schedule(after: .zero)
    }

    /// Turns iCloud sync on when nothing is set up yet, for a ledger that
    /// just started syncing through iCloud. A picked folder is left alone.
    func turnOnICloudIfAvailable() {
        guard !isOn else { return }
        Task { await useICloud() }
    }

    /// Another device changed a file in the assistant's iCloud folder.
    func remoteChanged() { schedule(after: Self.debounce) }

    /// Stops syncing. The folder and this device's data both stay.
    func turnOff() {
        pending?.cancel()
        LedgerAgentSyncFolder.clear()
        isOn = false
        usesICloud = false
        folderName = nil
        otherLedgers = []
        error = nil
    }

    /// Makes this ledger use another ledger's folder data, merged with what
    /// it has, such as the history of the same ledger before a reinstall.
    func link(to key: String) {
        guard let repository else { return }
        LedgerAgentSyncFolder.link(repository.descriptor.id, to: key)
        currentKey = key
        schedule(after: .zero)
    }

    func syncNow() async {
        pending?.cancel()
        await run()
    }

    private func schedule(after delay: Duration) {
        guard isOn, repository != nil else { return }
        if running { again = true; return }
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    private func run() async {
        guard isOn, !running, let repository else { return }
        running = true
        guard let folder = await LedgerAgentSyncFolder.resolve() else {
            running = false
            error = LedgerAgentSyncFolder.usesICloud ? LedgerBackupError.iCloudUnavailable.localizedDescription
                : LedgerBackupError.folderUnavailable.localizedDescription
            return
        }
        defer {
            running = false
            if again { again = false; schedule(after: Self.debounce) }
        }
        let descriptor = repository.descriptor
        let key = LedgerAgentSyncFolder.key(for: descriptor)
        let attachments = includesAttachments
        let workspace = repository.workspace
        let deviceName = LedgerAgentCloudSync.deviceName
        let defaults = LedgerAgentSyncFolder.defaults
        let restorePreferences = !defaults.bool(forKey: LedgerAgentSyncFolder.restoredPreferencesKey)
            && LedgerAgentSyncPreferences.isFresh(defaults)
        let preferences = LedgerAgentSyncPreferences.snapshot(defaults)
        do {
            let runtime = try await workspace.prepareAgentSyncRuntime()
            let outcome = try await folder.withAccess { root -> (LedgerAgentSyncReport, [LedgerAgentSyncLayout.LedgerInfo], Data?) in
                try await Task.detached {
                    try Self.prepare(root: root)
                    let restored = restorePreferences
                        ? try? FolderFiles.read(root.appendingPathComponent(LedgerAgentSyncLayout.preferencesName)) : nil
                    let ledgerRoot = root.appendingPathComponent(LedgerAgentSyncLayout.ledgersName, isDirectory: true)
                        .appendingPathComponent(key, isDirectory: true)
                    let engine = LedgerAgentSyncEngine(
                        runtime: runtime,
                        remote: ledgerRoot.appendingPathComponent(LedgerAgentSyncLayout.filesName, isDirectory: true),
                        identity: key + "|" + root.standardizedFileURL.path,
                        includesAttachments: attachments)
                    let report = try await engine.run { changes in
                        await workspace.applyAgentSync(changes)
                    }
                    let info = LedgerAgentSyncLayout.LedgerInfo(key: key, name: descriptor.name, updatedAt: Date(), deviceName: deviceName)
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                    try FolderFiles.write(try encoder.encode(info), to: ledgerRoot.appendingPathComponent(LedgerAgentSyncLayout.ledgerInfoName))
                    if restored == nil, let preferences {
                        try? FolderFiles.write(preferences, to: root.appendingPathComponent(LedgerAgentSyncLayout.preferencesName))
                    }
                    let others = LedgerAgentSyncFolder.ledgers(in: root).filter { $0.key != key }
                    return (report, others, restored)
                }.value
            }
            let (report, others, restored) = outcome
            if restorePreferences {
                defaults.set(true, forKey: LedgerAgentSyncFolder.restoredPreferencesKey)
                if let restored, LedgerAgentSyncPreferences.restore(restored, into: defaults) {
                    LedgerAgentSettings.shared.reloadFromDefaults()
                    LedgerAgentSkillSettings.shared.reloadFromDefaults()
                }
            }
            guard self.repository?.descriptor.id == descriptor.id else { return }
            let now = Date()
            LedgerAgentSyncFolder.recordSync(for: descriptor.id, at: now)
            lastSynced = now
            lastReport = report
            otherLedgers = others
            currentKey = key
            error = report.failed > 0 ? String(localized: "有 \(report.failed) 个文件这次没有同步，稍后会再试。") : nil
            if report.changedLocally {
                // Memory another device wrote goes on to the Git branch too.
                LedgerAgentMemorySync.shared.localChanged()
                LedgerAgentSessions.shared.reloadSaved()
                LedgerAgentArtifactShelf.shared.changed()
            }
        } catch {
            guard self.repository?.descriptor.id == descriptor.id else { return }
            self.error = error.localizedDescription
        }
    }

    nonisolated private static func prepare(root: URL) throws {
        let marker = root.appendingPathComponent(LedgerAgentSyncLayout.markerName)
        guard !FolderFiles.exists(marker) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FolderFiles.write(try encoder.encode(LedgerAgentSyncLayout.Marker(createdAt: Date())), to: marker)
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }
}

