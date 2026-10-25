import CryptoKit
import Foundation

/// Content-addressed store of exported canonical streams.
///
/// A stream is a pure function of the ledger source and the bundled Beancount
/// runtime, so it is keyed by the Go source version (a hash over every source
/// file's path and bytes) together with a fingerprint of this app build. A hit
/// lets the engine register a model without starting the Python loader; Go
/// still rechecks the source version before and after ingesting it.
///
/// Each source version can hold two files: the exporter's `.records` stream and
/// the binary `.snap1` snapshot Go writes after it ingests that stream. The
/// snapshot decodes the same model without parsing NDJSON, so registration
/// prefers it; the stream stays as the fallback when a snapshot is rejected.
/// Both are pinned by size and SHA-256 and live under the build fingerprint,
/// because each is a product of this build's exporter and Go core.
///
/// Callers serialize access through `LocalModelRequestGate`, which also guards
/// the sibling `canonical-stream` scratch directory the entries are linked into.
struct LocalCanonicalStreamCache {
    enum Format: String, CaseIterable {
        case records
        case snapshot = "snap1"

        /// Cached file and its `{bytes, sha256}` entry. Records keep the
        /// original `<version>.json` name so earlier entries stay readable.
        fileprivate func names(in directory: URL, version: String) -> (stream: URL, entry: URL) {
            switch self {
            case .records:
                return (directory.appendingPathComponent(version + ".records"),
                        directory.appendingPathComponent(version + ".json"))
            case .snapshot:
                return (directory.appendingPathComponent(version + ".snap1"),
                        directory.appendingPathComponent(version + ".snap1.json"))
            }
        }
    }

    /// Each entry is an O(N) `.records` stream (plus its ~6x smaller snapshot). Four covers a committed
    /// generation, the stage a write is publishing, and the generation it is
    /// replacing: with two, any single write evicted the committed stream and the
    /// next read re-ran the Python loader (measured 770 ms at 20k transactions).
    /// Still bounded, and eviction is by modification date.
    static let capacity = 4

    let directory: URL
    private let fileManager = FileManager.default

    init(runtimeRoot: URL, fingerprint: String = Self.runtimeFingerprint) {
        directory = runtimeRoot.appendingPathComponent("canonical-cache", isDirectory: true)
            .appendingPathComponent(fingerprint, isDirectory: true)
    }

    private struct Entry: Codable { let bytes: Int; let sha256: String }

    private static func isSourceVersion(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func names(for sourceVersion: String, format: Format = .records) throws -> (stream: URL, entry: URL) {
        guard Self.isSourceVersion(sourceVersion) else {
            throw LocalLedgerError.invalidConfiguration(String(localized: "模型缓存键无效"))
        }
        return format.names(in: directory, version: sourceVersion)
    }

    /// True when a verified stream or snapshot for this source exists. Either
    /// one exists only after an export passed canonical validation, so this also
    /// answers "is it valid".
    func contains(_ sourceVersion: String) -> Bool {
        Format.allCases.contains { contains(sourceVersion, format: $0) }
    }

    func contains(_ sourceVersion: String, format: Format) -> Bool {
        guard let paths = try? names(for: sourceVersion, format: format) else { return false }
        return verified(stream: paths.stream, entry: paths.entry)
    }

    /// Links the cached file to `output`. Returns false on a miss or when the
    /// entry fails verification (the entry is then removed).
    func restore(_ sourceVersion: String, format: Format = .records, to output: URL) -> Bool {
        guard let paths = try? names(for: sourceVersion, format: format) else { return false }
        let stream = paths.stream, entry = paths.entry
        guard verified(stream: stream, entry: entry) else {
            try? fileManager.removeItem(at: stream)
            try? fileManager.removeItem(at: entry)
            return false
        }
        do {
            do { try fileManager.linkItem(at: stream, to: output) }
            catch { try fileManager.copyItem(at: stream, to: output) }
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.path)
            return true
        } catch {
            try? fileManager.removeItem(at: output)
            return false
        }
    }

    /// Drops one format of an entry, e.g. a snapshot Go refused to load.
    func remove(_ sourceVersion: String, format: Format) {
        guard let paths = try? names(for: sourceVersion, format: format) else { return }
        try? fileManager.removeItem(at: paths.stream)
        try? fileManager.removeItem(at: paths.entry)
    }

    /// Best-effort: a failure here only costs a later re-export.
    func store(_ stream: URL, sourceVersion: String, descriptor: EmbeddedBeancountValidator.StreamDescriptor) {
        store(stream, sourceVersion: sourceVersion, format: .records, expectedBytes: descriptor.bytes)
    }

    /// Keeps the snapshot Go wrote after registering `sourceVersion`. There is
    /// no exporter descriptor for it; the entry pins the bytes as written, and
    /// Go itself checks the embedded source version and checksums on load.
    func storeSnapshot(_ snapshot: URL, sourceVersion: String) {
        guard let bytes = Self.size(of: snapshot), bytes > 0 else { return }
        store(snapshot, sourceVersion: sourceVersion, format: .snapshot, expectedBytes: bytes)
    }

    private func store(_ stream: URL, sourceVersion: String, format: Format, expectedBytes: Int) {
        guard let paths = try? names(for: sourceVersion, format: format) else { return }
        let target = paths.stream, entry = paths.entry
        do {
            try prepareDirectory()
            let token = UUID().uuidString
            let temporaryStream = directory.appendingPathComponent(".\(token).\(format.rawValue)")
            let temporaryEntry = directory.appendingPathComponent(".\(token).json")
            defer {
                try? fileManager.removeItem(at: temporaryStream)
                try? fileManager.removeItem(at: temporaryEntry)
            }
            do { try fileManager.linkItem(at: stream, to: temporaryStream) }
            catch { try fileManager.copyItem(at: stream, to: temporaryStream) }
            // The descriptor's checksum covers the records but not the footer
            // (Go verifies that one on ingest); the entry pins the whole file.
            guard Self.size(of: temporaryStream) == expectedBytes,
                  let digest = Self.sha256(of: temporaryStream) else { return }
            try JSONEncoder().encode(Entry(bytes: expectedBytes, sha256: digest)).write(to: temporaryEntry)
            _ = try? fileManager.removeItem(at: target)
            try fileManager.moveItem(at: temporaryStream, to: target)
            _ = try? fileManager.removeItem(at: entry)
            try fileManager.moveItem(at: temporaryEntry, to: entry)
            evict()
        } catch {
            try? fileManager.removeItem(at: target)
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Identity of a cached stream file. A hit re-hashes the whole `.records`
    /// file (13.8 ms at 32 MB) and `contains` + `restore` did it twice per
    /// request. Cached streams are immutable once moved into place, so the
    /// verification result is remembered against the file's identity and only
    /// recomputed when that identity changes.
    private struct StreamStamp: Equatable {
        let bytes: Int
        let modified: Date
        let entryBytes: Int
        let entryModified: Date
    }

    private final class VerificationCache: @unchecked Sendable {
        private let limit = 8
        private var entries: [String: (stamp: StreamStamp, digest: String)] = [:]
        private var order: [String] = []

        func digest(for key: String, matching stamp: StreamStamp) -> String? {
            guard let entry = entries[key], entry.stamp == stamp else { return nil }
            return entry.digest
        }

        func remember(_ digest: String, stamp: StreamStamp, key: String) {
            entries[key] = (stamp, digest)
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > limit { entries.removeValue(forKey: order.removeFirst()) }
        }
    }

    private static let verificationCache = VerificationCache()

    private func stamp(stream: URL, entry: URL) -> StreamStamp? {
        guard let streamValues = try? stream.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
              streamValues.isRegularFile == true, streamValues.isSymbolicLink != true,
              let streamBytes = streamValues.fileSize,
              let streamModified = streamValues.contentModificationDate,
              let entryValues = try? entry.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let entryBytes = entryValues.fileSize,
              let entryModified = entryValues.contentModificationDate else { return nil }
        return StreamStamp(bytes: streamBytes, modified: streamModified,
            entryBytes: entryBytes, entryModified: entryModified)
    }

    private func verified(stream: URL, entry: URL) -> Bool {
        let key = stream.lastPathComponent
        let current = stamp(stream: stream, entry: entry)
        guard let data = try? Data(contentsOf: entry),
              let record = try? JSONDecoder().decode(Entry.self, from: data),
              Self.size(of: stream) == record.bytes else { return false }
        // A matching stamp proves this exact file already produced this digest.
        if let current, Self.verificationCache.digest(for: key, matching: current) == record.sha256 {
            return true
        }
        guard Self.sha256(of: stream) == record.sha256 else { return false }
        if let current { Self.verificationCache.remember(record.sha256, stamp: current, key: key) }
        return true
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = directory.deletingLastPathComponent()
        guard parent.standardizedFileURL.path == parent.resolvingSymlinksInPath().standardizedFileURL.path,
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw LocalLedgerError.invalidConfiguration(String(localized: "模型缓存目录不允许符号链接"))
        }
        #if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: parent.path)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        // Streams from an earlier build were produced by a different runtime.
        for stale in (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        where stale.lastPathComponent != directory.lastPathComponent {
            try? fileManager.removeItem(at: stale)
        }
    }

    /// Keeps the `capacity` most recently used source versions, counting a
    /// version's stream and snapshot as one entry.
    private func evict() {
        var used: [String: Date] = [:]
        for file in (try? fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            let version = String(file.lastPathComponent.prefix(64))
            guard Self.isSourceVersion(version) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            used[version] = max(used[version] ?? .distantPast, modified)
        }
        for (version, _) in used.sorted(by: { $0.value > $1.value }).dropFirst(Self.capacity) {
            for format in Format.allCases { remove(version, format: format) }
        }
    }

    private static func size(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return values.fileSize
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Changes whenever the installed app (and therefore its bundled Python,
    /// Beancount and exporter) changes, including Debug rebuilds.
    static let runtimeFingerprint: String = {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let modified = bundle.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(version)|\(build)|\(modified)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }()
}
