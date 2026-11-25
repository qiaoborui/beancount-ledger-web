import Foundation

/// The 账本助手's memory folder, `runtime/agent-memory/`, the same layout as
/// `server/agentmemory`:
///
/// ```
/// MEMORY.md                  always in the system prompt
/// <topic>.md                 read on demand, e.g. merchants.md
/// <group>/<topic>.md         e.g. accounts/credit-cards.md
/// ```
///
/// A topic file starts with a `description:` front matter that says when it
/// is worth reading; the prompt lists every topic file with it. The folder
/// syncs to other devices through the assistant's iCloud folder and, for a
/// Git ledger, through the repository's `agent-memory` branch, which the
/// scheduled tasks on the automation host read and write too.
enum LedgerAgentMemoryLayout {
    static let directory = "agent-memory"
    static let legacyFile = "agent-memory.md"
    static let indexName = "MEMORY.md"
    static let branch = "agent-memory"
    static let maxIndexBytes = 8000
    static let maxFileBytes = 16000

    /// The folder path of what was typed, or nil when it cannot be one:
    /// lower-case ASCII segments, at most two folders, ".md" added.
    static func clean(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty || path.caseInsensitiveCompare(indexName) == .orderedSame
            || path.caseInsensitiveCompare("MEMORY") == .orderedSame { return indexName }
        if !path.hasSuffix(".md") { path += ".md" }
        guard path.utf8.count <= 120 else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count <= 3 else { return nil }
        for (index, segment) in segments.enumerated() {
            let name = index == segments.count - 1 ? String(segment.dropLast(3)) : segment
            guard isValidSegment(name) else { return nil }
        }
        return path
    }

    static func isMemoryPath(_ path: String) -> Bool { clean(path) == path }

    private static func isValidSegment(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 48 else { return false }
        for (index, scalar) in name.unicodeScalars.enumerated() {
            let value = scalar.value
            let letterOrDigit = (0x61...0x7A).contains(value) || (0x30...0x39).contains(value)
            let joiner = value == 0x2D || value == 0x5F
            guard letterOrDigit || (joiner && index > 0) else { return false }
        }
        return true
    }

    /// The front matter's description, else the file's first line.
    static func description(of content: String) -> String {
        let (meta, body) = splitFrontMatter(content)
        if let value = meta["description"], !value.isEmpty { return value }
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "#-* ").union(.whitespaces))
            if !trimmed.isEmpty { return String(trimmed.prefix(60)) }
        }
        return ""
    }

    /// The `key: value` lines of a leading `---` block and the text after it.
    static func splitFrontMatter(_ content: String) -> ([String: String], String) {
        let text = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("---\n") else { return ([:], text) }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return ([:], text) }
        var meta: [String: String] = [:]
        for line in rest[..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty, meta[key] == nil { meta[key] = value }
        }
        var body = String(rest[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        return (meta, body)
    }

    /// Sets the description of a topic file, adding the front matter.
    static func withDescription(_ content: String, _ description: String) -> String {
        let line = description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return content }
        let text = content.replacingOccurrences(of: "\r\n", with: "\n")
        var keep: [String] = []
        var body = text
        if text.hasPrefix("---\n"), let end = text.dropFirst(4).range(of: "\n---") {
            let rest = text.dropFirst(4)
            for entry in rest[..<end.lowerBound].split(separator: "\n") {
                let key = entry.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if key == "description" { continue }
                keep.append(String(entry))
            }
            body = String(rest[end.upperBound...])
        }
        while body.hasPrefix("\n") { body.removeFirst() }
        return (["---", "description: " + line] + keep + ["---", "", body]).joined(separator: "\n")
    }

    /// Trims a file the way it is saved.
    static func normalize(_ content: String) -> String {
        let trimmed = content.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }

    /// Reads every memory file under folder, path → content.
    static func load(_ folder: URL) -> [String: String] {
        var files: [String: String] = [:]
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return files }
        let prefix = folder.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(prefix) else { continue }
            let path = String(full.dropFirst(prefix.count))
            guard isMemoryPath(path), let data = try? Data(contentsOf: url) else { continue }
            files[path] = String(decoding: data, as: UTF8.self)
        }
        return files
    }

    /// One text for a digest of the whole folder.
    static func digestText(_ files: [String: String]) -> String {
        files.keys.sorted().map { "# " + $0 + "\n" + (files[$0] ?? "") }.joined(separator: "\n")
    }

    /// Whether a path under runtime/ belongs to the memory, for the iCloud
    /// sync: the folder's files, and the single memory.md of older versions.
    static func isSyncedMemory(_ runtimePath: String) -> Bool {
        if runtimePath == legacyFile { return true }
        guard runtimePath.hasPrefix(directory + "/") else { return false }
        return isMemoryPath(String(runtimePath.dropFirst(directory.count + 1)))
    }
}

/// What a sync with the memory branch did.
struct LedgerAgentMemorySyncResult: Decodable, Equatable, Sendable {
    var remoteHead: String
    var pulled: Int
    var pushed: Int
    var files: Int
}

/// Keeps the open ledger's memory folder in step with the `agent-memory`
/// branch of its Git repository, where the automation host reads and writes
/// it: a few seconds after a local change, when the assistant opens, and on
/// request from the memory page. A ledger without Git skips it.
@MainActor
final class LedgerAgentMemorySync: ObservableObject {
    static let shared = LedgerAgentMemorySync()
    /// Without a local change, the branch is read at most this often.
    static let interval: TimeInterval = 10 * 60
    static let debounce: Duration = .seconds(5)

    @Published private(set) var running = false
    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastResult: LedgerAgentMemorySyncResult?
    @Published private(set) var error: String?
    /// Whether the open ledger syncs with Git at all.
    @Published private(set) var available = false
    /// Bumped whenever a sync changed the local folder, so the memory page
    /// reloads.
    @Published private(set) var revision = 0

    private weak var repository: LocalLedgerRepository?
    private var pending: Task<Void, Never>?
    private var again = false
    private var lastDigest: Int?

    func attach(_ repository: LocalLedgerRepository) {
        if self.repository?.descriptor.id != repository.descriptor.id {
            lastSynced = nil
            lastResult = nil
            lastDigest = nil
            error = nil
        }
        self.repository = repository
        available = repository.descriptor.git != nil
        schedule(after: .zero, force: false)
    }

    /// The memory, or a conversation, was saved.
    func localChanged() { schedule(after: Self.debounce, force: false) }

    func syncNow() async {
        pending?.cancel()
        await run(force: true)
    }

    private func schedule(after delay: Duration, force: Bool) {
        guard available, repository != nil else { return }
        if running { again = true; return }
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.run(force: force)
        }
    }

    private func run(force: Bool) async {
        guard available, !running, let repository, LedgerAgentSettings.shared.usesMemory else { return }
        let workspace = repository.workspace
        let digest = LedgerAgentStarterCache.digest(await workspace.agentMemory())
        if !force, digest == lastDigest, let lastSynced, Date().timeIntervalSince(lastSynced) < Self.interval { return }
        running = true
        defer {
            running = false
            if again { again = false; schedule(after: Self.debounce, force: false) }
        }
        let id = repository.descriptor.id
        do {
            let folder = try await workspace.prepareAgentMemory()
            let result = try await repository.syncAgentMemory(folder: folder)
            await workspace.protectAgentMemory()
            guard self.repository?.descriptor.id == id else { return }
            lastSynced = Date()
            lastResult = result
            lastDigest = LedgerAgentStarterCache.digest(await workspace.agentMemory())
            error = nil
            if let result, result.pulled > 0 {
                revision += 1
                // Other devices on iCloud get what the branch brought.
                LedgerAgentCloudSync.shared.localChanged()
            }
        } catch {
            guard self.repository?.descriptor.id == id else { return }
            self.error = error.localizedDescription
        }
    }
}
