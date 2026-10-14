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
/// Callers serialize access through `LocalModelRequestGate`, which also guards
/// the sibling `canonical-stream` scratch directory the entries are linked into.
struct LocalCanonicalStreamCache {
    /// Two entries cover the committed generation plus the one a write is
    /// about to publish. Streams are O(N) in ledger size, so keep this small.
    static let capacity = 2

    let directory: URL
    private let fileManager = FileManager.default

    init(runtimeRoot: URL, fingerprint: String = Self.runtimeFingerprint) {
        directory = runtimeRoot.appendingPathComponent("canonical-cache", isDirectory: true)
            .appendingPathComponent(fingerprint, isDirectory: true)
    }

    private struct Entry: Codable { let bytes: Int; let sha256: String }

    private func names(for sourceVersion: String) throws -> (stream: URL, entry: URL) {
        guard sourceVersion.count == 64, sourceVersion.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw LocalLedgerError.invalidConfiguration("模型缓存键无效")
        }
        return (directory.appendingPathComponent(sourceVersion + ".records"),
                directory.appendingPathComponent(sourceVersion + ".json"))
    }

    /// True when a verified stream for this source exists. A successful export
    /// implies canonical validation passed, so this also answers "is it valid".
    func contains(_ sourceVersion: String) -> Bool {
        guard let paths = try? names(for: sourceVersion) else { return false }
        return verified(stream: paths.stream, entry: paths.entry)
    }

    /// Links the cached stream to `output`. Returns false on a miss or when the
    /// entry fails verification (the entry is then removed).
    func restore(_ sourceVersion: String, to output: URL) -> Bool {
        guard let paths = try? names(for: sourceVersion) else { return false }
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

    /// Best-effort: a failure here only costs a later re-export.
    func store(_ stream: URL, sourceVersion: String, descriptor: EmbeddedBeancountValidator.StreamDescriptor) {
        guard let paths = try? names(for: sourceVersion) else { return }
        let target = paths.stream, entry = paths.entry
        do {
            try prepareDirectory()
            let token = UUID().uuidString
            let temporaryStream = directory.appendingPathComponent(".\(token).records")
            let temporaryEntry = directory.appendingPathComponent(".\(token).json")
            defer {
                try? fileManager.removeItem(at: temporaryStream)
                try? fileManager.removeItem(at: temporaryEntry)
            }
            do { try fileManager.linkItem(at: stream, to: temporaryStream) }
            catch { try fileManager.copyItem(at: stream, to: temporaryStream) }
            // The descriptor's checksum covers the records but not the footer
            // (Go verifies that one on ingest); the entry pins the whole file.
            guard Self.size(of: temporaryStream) == descriptor.bytes,
                  let digest = Self.sha256(of: temporaryStream) else { return }
            try JSONEncoder().encode(Entry(bytes: descriptor.bytes, sha256: digest)).write(to: temporaryEntry)
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

    private func verified(stream: URL, entry: URL) -> Bool {
        guard let data = try? Data(contentsOf: entry),
              let record = try? JSONDecoder().decode(Entry.self, from: data),
              Self.size(of: stream) == record.bytes,
              Self.sha256(of: stream) == record.sha256 else { return false }
        return true
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = directory.deletingLastPathComponent()
        guard parent.standardizedFileURL.path == parent.resolvingSymlinksInPath().standardizedFileURL.path,
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw LocalLedgerError.invalidConfiguration("模型缓存目录不允许符号链接")
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

    private func evict() {
        let entries = ((try? fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for entry in entries.dropFirst(Self.capacity) {
            try? fileManager.removeItem(at: entry)
            try? fileManager.removeItem(at: entry.deletingPathExtension().appendingPathExtension("records"))
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
