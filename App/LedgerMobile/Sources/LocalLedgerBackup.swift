import CryptoKit
import Foundation

/// Describes one single-file ledger backup. A backup is one immutable file so
/// that iCloud Drive (or any other Files provider) can only ever show a
/// complete copy: a half-uploaded directory tree can never pass as a backup.
struct LedgerBackupManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let path: String
        let size: Int
        let sha256: String
    }

    static let currentFormatVersion = 1

    let formatVersion: Int
    let ledgerID: UUID
    let ledgerName: String
    let entrypoint: String
    let revisionID: UUID
    let createdAt: Date
    /// Digest over every file path and content hash. Equal digests mean equal
    /// ledger trees, regardless of device, revision ID, or backup time.
    let contentDigest: String
    let files: [File]
}

enum LedgerBackupError: LocalizedError, Equatable {
    case folderNotConfigured
    case folderUnavailable
    case notABackup
    case unsupportedVersion(Int)
    case corrupt(String)
    case entrypointMissing(String)

    var errorDescription: String? {
        switch self {
        case .folderNotConfigured: String(localized: "请先选择备份文件夹")
        case .folderUnavailable: String(localized: "无法访问备份文件夹，请重新选择。若位于 iCloud 云盘，请确认已登录 iCloud 并开启 iCloud 云盘。")
        case .notABackup: String(localized: "这不是 Ledger 账本备份文件")
        case let .unsupportedVersion(version): String(localized: "备份格式版本 \(version) 需要更新的 App 才能恢复")
        case let .corrupt(detail): String(localized: "备份文件已损坏或不完整：\(detail)")
        case let .entrypointMissing(path): String(localized: "备份中没有当前账本的入口文件 \(path)，请改为恢复为新账本")
        }
    }
}

/// `.ledgerbackup` layout: 8-byte magic, UInt32 big-endian format version,
/// UInt32 big-endian manifest length, JSON manifest, then every file's bytes
/// in manifest order. Lengths and SHA-256 hashes are checked on extraction.
enum LedgerBackupArchive {
    static let fileExtension = "ledgerbackup"
    static let magic = Data("LEDGERBK".utf8)
    static let headerLength = 16
    static let maximumManifestBytes = 16 * 1024 * 1024
    private static let chunkSize = 256 * 1024

    struct ScannedFile: Sendable {
        let source: URL
        let entry: LedgerBackupManifest.File
    }

    /// Hashes every regular file below `directory`. Version-control metadata is
    /// excluded, matching the ledger export.
    static func scan(directory: URL, limits: LocalLedgerWorkspace.TreeLimits = .init()) throws -> [ScannedFile] {
        var files: [ScannedFile] = []
        var entries = 0, bytes = 0
        func walk(_ url: URL, prefix: String, depth: Int) throws {
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
            for name in names {
                if name.caseInsensitiveCompare(".git") == .orderedSame { continue }
                let child = url.appendingPathComponent(name)
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                if values.isSymbolicLink == true { continue }
                entries += 1
                guard entries <= limits.maximumEntries, depth <= limits.maximumDepth else {
                    throw LedgerBackupError.corrupt(String(localized: "账本目录超过备份限制"))
                }
                if values.isDirectory == true {
                    try walk(child, prefix: path, depth: depth + 1)
                } else if values.isRegularFile == true {
                    let (size, hash) = try hashFile(child)
                    bytes += size
                    guard bytes <= limits.maximumBytes else { throw LedgerBackupError.corrupt(String(localized: "账本目录超过备份限制")) }
                    files.append(ScannedFile(source: child, entry: .init(path: path, size: size, sha256: hash)))
                }
            }
        }
        try walk(directory, prefix: "", depth: 1)
        return files.sorted { $0.entry.path < $1.entry.path }
    }

    static func contentDigest(of files: [LedgerBackupManifest.File]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(file.sha256.utf8))
            hasher.update(data: Data([10]))
        }
        return hex(hasher.finalize())
    }

    /// Writes a complete archive to `destination`, which must not exist.
    static func write(_ scanned: [ScannedFile], manifest: LedgerBackupManifest, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        guard manifestData.count <= maximumManifestBytes else { throw LedgerBackupError.corrupt(String(localized: "备份清单过大")) }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: protectedAttributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var header = magic
        header.append(bigEndian: UInt32(manifest.formatVersion))
        header.append(bigEndian: UInt32(manifestData.count))
        try output.write(contentsOf: header)
        try output.write(contentsOf: manifestData)
        for file in scanned {
            let input = try FileHandle(forReadingFrom: file.source)
            defer { try? input.close() }
            var copied = 0
            while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                copied += chunk.count
                guard copied <= file.entry.size else { throw LedgerBackupError.corrupt(String(localized: "账本文件在备份期间发生变化")) }
                try output.write(contentsOf: chunk)
            }
            guard copied == file.entry.size else { throw LedgerBackupError.corrupt(String(localized: "账本文件在备份期间发生变化")) }
        }
        try output.synchronize()
    }

    static func readManifest(at url: URL) throws -> LedgerBackupManifest {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try readManifest(from: input, totalLength: fileLength(of: url))
    }

    /// Extracts into `directory` (created, must not exist) after verifying every
    /// path, length, and hash. Nothing in the archive can escape `directory`.
    @discardableResult
    static func extract(_ url: URL, to directory: URL) throws -> LedgerBackupManifest {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let manifest = try readManifest(from: input, totalLength: fileLength(of: url))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: protectedAttributes)
        for file in manifest.files {
            let components = file.path.split(separator: "/").map(String.init)
            var parent = directory
            for component in components.dropLast() {
                parent.appendPathComponent(component, isDirectory: true)
                if !FileManager.default.fileExists(atPath: parent.path) {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: protectedAttributes)
                }
            }
            let target = parent.appendingPathComponent(components.last!)
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: protectedAttributes) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            var hasher = SHA256()
            var remaining = file.size
            while remaining > 0 {
                guard let chunk = try input.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else {
                    throw LedgerBackupError.corrupt(String(localized: "\(file.path) 内容不完整"))
                }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                remaining -= chunk.count
            }
            guard hex(hasher.finalize()) == file.sha256 else {
                throw LedgerBackupError.corrupt(String(localized: "\(file.path) 校验失败"))
            }
        }
        return manifest
    }

    private static func readManifest(from input: FileHandle, totalLength: Int) throws -> LedgerBackupManifest {
        guard totalLength >= headerLength, let header = try input.read(upToCount: headerLength),
              header.count == headerLength, header.prefix(magic.count) == magic else {
            throw LedgerBackupError.notABackup
        }
        let version = Int(header.bigEndianUInt32(at: 8))
        guard version <= LedgerBackupManifest.currentFormatVersion, version >= 1 else {
            throw LedgerBackupError.unsupportedVersion(version)
        }
        let manifestLength = Int(header.bigEndianUInt32(at: 12))
        guard manifestLength <= maximumManifestBytes, manifestLength <= totalLength - headerLength,
              let manifestData = try input.read(upToCount: manifestLength), manifestData.count == manifestLength else {
            throw LedgerBackupError.corrupt(String(localized: "备份清单不完整"))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: LedgerBackupManifest
        do { manifest = try decoder.decode(LedgerBackupManifest.self, from: manifestData) }
        catch { throw LedgerBackupError.corrupt(String(localized: "无法读取备份清单")) }
        guard manifest.formatVersion == version else { throw LedgerBackupError.corrupt(String(localized: "备份版本信息不一致")) }
        try validate(manifest, payloadLength: totalLength - headerLength - manifestLength)
        return manifest
    }

    private static func validate(_ manifest: LedgerBackupManifest, payloadLength: Int) throws {
        let limits = LocalLedgerWorkspace.TreeLimits()
        guard manifest.files.count <= limits.maximumEntries else { throw LedgerBackupError.corrupt(String(localized: "文件数量超过限制")) }
        var seen = Set<String>(), directories = Set<String>(), total = 0
        for file in manifest.files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.count <= limits.maximumDepth,
                  parts.allSatisfy({ part in
                      !part.isEmpty && part != "." && part != ".." && part.caseInsensitiveCompare(".git") != .orderedSame
                          && !part.contains("\\") && !part.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
                  }),
                  file.size >= 0, file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw LedgerBackupError.corrupt(String(localized: "包含无效路径 \(file.path)"))
            }
            // Case-insensitive volumes would merge two entries into one file.
            let key = file.path.lowercased()
            guard seen.insert(key).inserted, !directories.contains(key) else {
                throw LedgerBackupError.corrupt(String(localized: "包含重复路径 \(file.path)"))
            }
            for depth in 1..<parts.count { directories.insert(parts[0..<depth].joined(separator: "/").lowercased()) }
            guard file.size <= limits.maximumBytes - total else { throw LedgerBackupError.corrupt(String(localized: "总大小超过限制")) }
            total += file.size
        }
        guard seen.isDisjoint(with: directories) else { throw LedgerBackupError.corrupt(String(localized: "文件与目录路径冲突")) }
        guard total == payloadLength else { throw LedgerBackupError.corrupt(String(localized: "文件长度与清单不一致")) }
        guard contentDigest(of: manifest.files) == manifest.contentDigest else {
            throw LedgerBackupError.corrupt(String(localized: "清单摘要不一致"))
        }
    }

    private static func hashFile(_ url: URL) throws -> (Int, String) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        var size = 0
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += chunk.count
        }
        return (size, hex(hasher.finalize()))
    }

    static func fileLength(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static var protectedAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.complete]
        #else
        nil
        #endif
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        let start = index(startIndex, offsetBy: offset)
        return self[start..<index(start, offsetBy: 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// One backup file found in the backup folder. Everything shown in a listing
/// comes from the file name, so iCloud does not need to download a backup
/// before the user picks it.
struct LedgerBackupEntry: Identifiable, Hashable, Sendable {
    let url: URL
    /// The ledger ID folder that holds the backup.
    let ledgerID: UUID
    let ledgerName: String
    let createdAt: Date
    let digestPrefix: String
    let size: Int?
    var id: URL { url }

    static let digestPrefixLength = 12

    static func fileName(ledgerName: String, createdAt: Date, contentDigest: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:?*\"<>|_").union(.controlCharacters).union(.newlines)
        let dash: Unicode.Scalar = "-"
        var name = String(String.UnicodeScalarView(ledgerName.unicodeScalars.map { unsafe.contains($0) ? dash : $0 }))
            .trimmingCharacters(in: .whitespaces)
        if name.hasPrefix(".") { name = "-" + name.dropFirst() }
        name = String(name.prefix(40))
        if name.isEmpty { name = "ledger" }
        return "\(name)_\(timestampFormatter.string(from: createdAt))_\(contentDigest.prefix(digestPrefixLength)).\(LedgerBackupArchive.fileExtension)"
    }

    /// Parses `<name>_<UTC timestamp>_<digest>.ledgerbackup`, tolerating the
    /// "name 2.ext" copies a sync provider creates and iCloud's `.name.icloud`
    /// placeholders for files not yet downloaded.
    init?(url: URL, ledgerID: UUID, size: Int?) {
        var name = url.lastPathComponent
        if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(".icloud".count)) }
        guard name.hasSuffix("." + LedgerBackupArchive.fileExtension) else { return nil }
        name = String(name.dropLast(LedgerBackupArchive.fileExtension.count + 1))
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let createdAt = Self.timestampFormatter.date(from: String(parts[parts.count - 2])) else { return nil }
        let digest = parts[parts.count - 1].prefix(Self.digestPrefixLength)
        guard digest.count == Self.digestPrefixLength, digest.allSatisfy(\.isHexDigit) else { return nil }
        self.url = url
        self.ledgerID = ledgerID
        self.ledgerName = parts.dropLast(2).joined(separator: "_")
        self.createdAt = createdAt
        self.digestPrefix = String(digest)
        self.size = size
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

/// Backups in a user-chosen folder, normally inside iCloud Drive:
/// `<folder>/<ledger ID>/<name>_<time>_<digest>.ledgerbackup`.
///
/// Conflict rules:
/// - Every backup is a new, immutable file whose name carries its creation
///   time and content digest. Two devices never write the same file, so the
///   sync provider has nothing to merge.
/// - A tree whose digest already exists in the ledger's folder is not written
///   again, so repeated or concurrent backups of unchanged data are no-ops.
/// - Pruning only removes files that match the backup naming scheme, oldest
///   first, and never the backup it just wrote.
/// - All reads and writes go through `NSFileCoordinator`, which also makes
///   iCloud download a backup before it is read.
actor LedgerBackupStore {
    enum Outcome: Equatable, Sendable {
        case created(LedgerBackupEntry)
        case unchanged(LedgerBackupEntry)

        var entry: LedgerBackupEntry {
            switch self { case let .created(entry), let .unchanged(entry): entry }
        }
    }

    private enum PreparedBackup: Sendable {
        case existing(LedgerBackupEntry)
        case archive(LedgerBackupManifest, URL)
    }

    nonisolated let rootDirectory: URL
    private let retention: Int
    private let temporaryDirectory: URL

    init(rootDirectory: URL, retention: Int = 30,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.rootDirectory = rootDirectory
        self.retention = max(1, retention)
        self.temporaryDirectory = temporaryDirectory
    }

    /// All backups in the folder, newest first.
    func list() throws -> [LedgerBackupEntry] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { throw LedgerBackupError.folderUnavailable }
        var entries: [LedgerBackupEntry] = []
        for folder in try FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard let ledgerID = UUID(uuidString: folder.lastPathComponent),
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            entries += try Self.list(folder: folder, ledgerID: ledgerID)
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Writes a backup of the workspace's current generation, unless the
    /// folder already holds one with identical content.
    func backup(workspace: LocalLedgerWorkspace, descriptor: LocalLedgerDescriptor,
                now: Date = Date()) async throws -> Outcome {
        let folder = rootDirectory.appendingPathComponent(descriptor.id.uuidString, isDirectory: true)
        let staging = temporaryDirectory.appendingPathComponent("LedgerBackup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: LedgerBackupArchive.protectedAttributes)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Hash and archive inside the pinned generation; the provider copy
        // happens afterwards so a slow upload never holds the workspace.
        let existing = try coordinatedList(folder: folder, ledgerID: descriptor.id)
        let prepared: PreparedBackup = try await workspace.withCurrentSnapshot { revision, root in
            let scanned = try LedgerBackupArchive.scan(directory: root)
            let files = scanned.map(\.entry)
            let digest = LedgerBackupArchive.contentDigest(of: files)
            if let match = existing.first(where: { digest.hasPrefix($0.digestPrefix) }) { return .existing(match) }
            guard files.contains(where: { $0.path == descriptor.entrypoint }) else {
                throw LedgerBackupError.entrypointMissing(descriptor.entrypoint)
            }
            let manifest = LedgerBackupManifest(formatVersion: LedgerBackupManifest.currentFormatVersion,
                ledgerID: descriptor.id, ledgerName: descriptor.name, entrypoint: descriptor.entrypoint,
                revisionID: revision.id, createdAt: now, contentDigest: digest, files: files)
            let archive = staging.appendingPathComponent("backup." + LedgerBackupArchive.fileExtension)
            try LedgerBackupArchive.write(scanned, manifest: manifest, to: archive)
            return .archive(manifest, archive)
        }
        let manifest: LedgerBackupManifest, archive: URL
        switch prepared {
        case let .existing(entry): return .unchanged(entry)
        case let .archive(preparedManifest, preparedArchive): (manifest, archive) = (preparedManifest, preparedArchive)
        }

        let name = LedgerBackupEntry.fileName(ledgerName: descriptor.name, createdAt: now,
            contentDigest: manifest.contentDigest)
        let destination = folder.appendingPathComponent(name)
        try coordinate(writing: destination, options: .forReplacing) { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) { return }
            try FileManager.default.copyItem(at: archive, to: url)
        }
        guard let entry = LedgerBackupEntry(url: destination, ledgerID: descriptor.id,
            size: try? LedgerBackupArchive.fileLength(of: destination)) else {
            throw LedgerBackupError.corrupt(String(localized: "无法命名备份文件"))
        }
        try prune(folder: folder, ledgerID: descriptor.id, keeping: entry)
        return .created(entry)
    }

    /// Downloads (if needed) and extracts a backup into a new private
    /// directory. The caller owns and removes the returned directory.
    func extract(_ entry: LedgerBackupEntry) throws -> (manifest: LedgerBackupManifest, directory: URL) {
        try Self.extract(fileAt: entry.url, temporaryDirectory: temporaryDirectory)
    }

    /// Extracts any backup file, such as one picked in Files on a new device.
    static func extract(fileAt url: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws
        -> (manifest: LedgerBackupManifest, directory: URL) {
        let staging = temporaryDirectory.appendingPathComponent("LedgerRestore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: LedgerBackupArchive.protectedAttributes)
        do {
            let local = staging.appendingPathComponent("backup." + LedgerBackupArchive.fileExtension)
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            try coordinate(reading: url) { readable in
                try FileManager.default.copyItem(at: readable, to: local)
            }
            let directory = staging.appendingPathComponent("ledger", isDirectory: true)
            let manifest = try LedgerBackupArchive.extract(local, to: directory)
            try FileManager.default.removeItem(at: local)
            return (manifest, directory)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Removes the private directory returned by `extract`.
    static func discardExtraction(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private static func list(folder: URL, ledgerID: UUID) throws -> [LedgerBackupEntry] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .compactMap { url in
                LedgerBackupEntry(url: url, ledgerID: ledgerID,
                    size: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize)
            }
    }

    private func coordinatedList(folder: URL, ledgerID: UUID) throws -> [LedgerBackupEntry] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { throw LedgerBackupError.folderUnavailable }
        var entries: [LedgerBackupEntry] = []
        guard FileManager.default.fileExists(atPath: folder.path) else { return entries }
        try Self.coordinate(reading: folder) { url in entries = try Self.list(folder: url, ledgerID: ledgerID) }
        return entries
    }

    private func prune(folder: URL, ledgerID: UUID, keeping kept: LedgerBackupEntry) throws {
        let entries = try Self.list(folder: folder, ledgerID: ledgerID).sorted { $0.createdAt > $1.createdAt }
        guard entries.count > retention else { return }
        for entry in entries.dropFirst(retention) where entry.url != kept.url {
            try? coordinate(writing: entry.url, options: .forDeleting) { url in
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func coordinate(writing url: URL, options: NSFileCoordinator.WritingOptions,
                            _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let bodyError { throw bodyError }
        if let coordinationError { throw coordinationError }
    }

    private static func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let bodyError { throw bodyError }
        if let coordinationError { throw coordinationError }
    }
}

/// The user-chosen backup folder, kept as a security-scoped bookmark so it
/// survives relaunches. Picking a folder in iCloud Drive needs no iCloud
/// entitlement, so this works with Personal Team and sideloaded builds.
struct LedgerBackupFolder: Sendable {
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    static let bookmarkKey = "ledger.backup.folderBookmark"
    static let automaticPrefix = "ledger.backup.automatic."
    static let lastBackupPrefix = "ledger.backup.last."
    static let automaticInterval: TimeInterval = 24 * 60 * 60

    let url: URL

    static var current: LedgerBackupFolder? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolutionOptions,
            relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let refreshed = try? bookmark(for: url) { defaults.set(refreshed, forKey: bookmarkKey) }
        return LedgerBackupFolder(url: url)
    }

    /// Persists a folder returned by the system folder picker.
    static func select(_ url: URL) throws -> LedgerBackupFolder {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        defaults.set(try bookmark(for: url), forKey: bookmarkKey)
        return LedgerBackupFolder(url: url)
    }

    static func clear() { defaults.removeObject(forKey: bookmarkKey) }

    var displayName: String {
        FileManager.default.displayName(atPath: url.path)
    }

    @MainActor
    func withAccess<Value: Sendable>(_ body: (URL) async throws -> Value) async throws -> Value {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { throw LedgerBackupError.folderUnavailable }
        return try await body(url)
    }

    static func automaticEnabled(for ledgerID: UUID) -> Bool {
        defaults.object(forKey: automaticPrefix + ledgerID.uuidString) as? Bool ?? true
    }

    static func setAutomatic(_ enabled: Bool, for ledgerID: UUID) {
        defaults.set(enabled, forKey: automaticPrefix + ledgerID.uuidString)
    }

    static func lastBackup(for ledgerID: UUID) -> Date? {
        defaults.object(forKey: lastBackupPrefix + ledgerID.uuidString) as? Date
    }

    static func recordBackup(for ledgerID: UUID, at date: Date) {
        defaults.set(date, forKey: lastBackupPrefix + ledgerID.uuidString)
    }

    static func automaticBackupDue(for ledgerID: UUID, now: Date = Date()) -> Bool {
        guard current != nil, automaticEnabled(for: ledgerID) else { return false }
        guard let last = lastBackup(for: ledgerID) else { return true }
        return now.timeIntervalSince(last) >= automaticInterval || now < last
    }

    private static func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        .withSecurityScope
        #else
        []
        #endif
    }
}
