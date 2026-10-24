import Foundation

/// Multi-device sync through a user-picked folder, normally in iCloud Drive.
/// Picking a folder with the system picker needs no iCloud entitlement, so
/// this works with Personal Team and sideloaded builds where CloudKit and an
/// app ubiquity container are unavailable.
struct LocalFolderSyncConfiguration: Codable, Equatable, Hashable, Sendable {
    /// Identifies this device's head file in the shared folder.
    let id: UUID
    let bookmark: Data
    let folderName: String
    let deviceName: String
}

/// Shared folder layout:
///
/// ```
/// <folder>/ledger-sync.json                     ledger name and entry file
/// <folder>/snapshots/<content digest>.ledgerbackup
/// <folder>/devices/<configuration ID>.json      one head per device
/// ```
///
/// Conflict rules:
/// - A snapshot is one immutable, content-addressed `.ledgerbackup` file, so a
///   peer either sees a complete, hash-checked tree or nothing.
/// - Each device only ever writes its own head file. iCloud has no
///   compare-and-swap, and with a single writer per file it never needs to
///   create conflict copies.
/// - Every head lists the digests it has incorporated, newest first. A peer
///   merges another head against the newest digest both have seen, with the
///   same three-way file merge and conflict review as Git storage. The merge is
///   symmetric, so two devices merging each other at once reach the same digest.
enum FolderSyncLayout {
    static let markerName = "ledger-sync.json"
    static let snapshotsName = "snapshots"
    static let devicesName = "devices"
    static let formatVersion = 1
    /// Digests kept in a head's history.
    static let historyLimit = 64
    /// History entries per head whose snapshots survive pruning.
    static let retainedHistory = 16
    /// Unreferenced snapshots stay this long so a slow peer can still read them.
    static let pruneGrace: TimeInterval = 3 * 24 * 60 * 60

    struct Marker: Codable, Equatable, Sendable {
        var formatVersion = FolderSyncLayout.formatVersion
        let ledgerName: String
        let entrypoint: String
        let createdAt: Date
    }

    struct Head: Codable, Equatable, Sendable {
        var formatVersion = FolderSyncLayout.formatVersion
        let deviceID: UUID
        let deviceName: String
        let head: String
        let history: [String]
        let updatedAt: Date
    }

    static func readMarker(in folder: URL) throws -> Marker? {
        let url = folder.appendingPathComponent(markerName)
        guard FolderFiles.exists(url) else { return nil }
        let marker: Marker
        do { marker = try decoder.decode(Marker.self, from: FolderFiles.read(url)) }
        catch let error as LedgerBackupError { throw error }
        catch { throw LedgerBackupError.corrupt(String(localized: "无法读取同步文件夹信息")) }
        guard marker.formatVersion <= formatVersion else { throw LedgerBackupError.unsupportedVersion(marker.formatVersion) }
        return marker
    }

    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Coordinated file access in a provider folder. Coordinated reads also make
/// iCloud download an item before it is read.
enum FolderFiles {
    /// True for a downloaded item or iCloud's `.name.icloud` placeholder.
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder(for: url).path)
    }

    static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    /// Item names in `directory`, with placeholders reported by their real name.
    static func names(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).map { name in
            name.hasPrefix(".") && name.hasSuffix(".icloud") ? String(name.dropFirst().dropLast(".icloud".count)) : name
        }
        return Array(Set(names)).sorted()
    }

    static func modificationDate(of url: URL) -> Date? {
        for candidate in [url, placeholder(for: url)] {
            if let date = try? candidate.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { return date }
        }
        return nil
    }

    static func read(_ url: URL) throws -> Data {
        var data = Data()
        try coordinate(reading: url) { data = try Data(contentsOf: $0) }
        return data
    }

    static func copy(_ url: URL, to destination: URL) throws {
        try coordinate(reading: url) { try FileManager.default.copyItem(at: $0, to: destination) }
    }

    static func write(_ data: Data, to url: URL) throws {
        try coordinate(writing: url, options: .forReplacing) { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    /// Copies `source` to `url` unless an item with that name already exists.
    static func publish(_ source: URL, to url: URL) throws {
        try coordinate(writing: url, options: .forReplacing) { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) { return }
            try FileManager.default.copyItem(at: source, to: url)
        }
    }

    static func remove(_ url: URL) throws {
        try coordinate(writing: url, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
    }

    private static func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let bodyError { throw bodyError }
        if let coordinationError { throw coordinationError }
    }

    private static func coordinate(writing url: URL, options: NSFileCoordinator.WritingOptions,
                                   _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let bodyError { throw bodyError }
        if let coordinationError { throw coordinationError }
    }
}

/// Resolves the configured folder. Tests inject a plain directory.
struct FolderSyncLocation: Sendable {
    let resolve: @Sendable () throws -> URL

    static func bookmark(_ data: Data) -> FolderSyncLocation {
        FolderSyncLocation {
            var stale = false
            do { return try URL(resolvingBookmarkData: data, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale) }
            catch { throw LedgerBackupError.folderUnavailable }
        }
    }

    static func directory(_ url: URL) -> FolderSyncLocation { FolderSyncLocation { url } }

    /// Call while the picker's security scope is active.
    static func makeBookmark(for url: URL) throws -> Data {
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

actor FolderLocalStorage: LogicalLocalStorage {
    nonisolated let workspace: LocalLedgerWorkspace
    nonisolated let configuration: LocalFolderSyncConfiguration
    private let ledger: LocalLedgerDescriptor
    private let location: FolderSyncLocation
    private let now: @Sendable () -> Date
    private let syncRoot: URL
    private var synchronizing = false

    private struct State: Codable {
        var version = 1
        /// Digest of the tree this device last published.
        var baseDigest: String?
        /// Digests this device has published or merged, newest first.
        var known: [String] = []
        var syncedRevisionID: UUID?
        var pendingRevisionID: UUID?
        var lastSyncedAt: Date?
        var failure: String?
        var conflictPaths: [String] = []
        var conflictAttemptID: UUID?
        var conflictLocalRevisionID: UUID?
        var conflictPeer: FolderSyncLayout.Head?
    }

    init(workspace: LocalLedgerWorkspace, configuration: LocalFolderSyncConfiguration, ledger: LocalLedgerDescriptor,
         location: FolderSyncLocation? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.workspace = workspace
        self.configuration = configuration
        self.ledger = ledger
        self.location = location ?? .bookmark(configuration.bookmark)
        self.now = now
        syncRoot = workspace.rootDirectory.appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent(configuration.id.uuidString, isDirectory: true)
    }

    func didCommit(_ revision: LocalLedgerWorkspace.Revision) async { }

    func status() async throws -> LocalStorageSyncStatus {
        let state = try loadState()
        let current = try await workspace.currentRevision()
        let phase: LocalStorageSyncStatus.Phase
        if synchronizing { phase = .synchronizing }
        else if !state.conflictPaths.isEmpty { phase = .conflicted }
        else if state.failure != nil { phase = .failed }
        else if let current, state.syncedRevisionID == current.id { phase = .synced }
        else { phase = .pending }
        return .init(mode: .folder, phase: phase, lastSyncedAt: state.lastSyncedAt,
            baseCommit: state.baseDigest, conflictPaths: state.conflictPaths, message: state.failure)
    }

    func synchronize(validator: @escaping LocalLedgerWorkspace.Validator) async throws -> LocalStorageSyncStatus {
        guard !synchronizing else { throw LocalStorageError.synchronizationInProgress }
        let lease = try SyncLease(directory: syncRoot)
        defer { lease.release() }
        try prepareLayout()
        synchronizing = true
        defer { synchronizing = false }
        do {
            let folder = try location.resolve()
            let granted = folder.startAccessingSecurityScopedResource()
            defer { if granted { folder.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: folder.path) else { throw LedgerBackupError.folderUnavailable }
            if try await workspace.currentRevision() != nil {
                try await workspace.withCurrentSnapshot { revision, root in
                    try await self.exchange(folder: folder, revision: revision, localRoot: root, validator: validator)
                }
            } else {
                try await exchange(folder: folder, revision: nil, localRoot: nil, validator: validator)
            }
            synchronizing = false
            return try await status()
        } catch {
            if var state = try? loadState() {
                state.failure = error.localizedDescription
                try? saveState(state)
            }
            throw error
        }
    }

    private func exchange(folder: URL, revision: LocalLedgerWorkspace.Revision?, localRoot: URL?,
                          validator: @escaping LocalLedgerWorkspace.Validator) async throws {
        var state = try loadState()
        if let marker = try FolderSyncLayout.readMarker(in: folder), marker.entrypoint != ledger.entrypoint {
            throw LocalStorageError.invalidGitConfiguration(String(localized: "该同步文件夹属于入口文件为 \(marker.entrypoint) 的账本"))
        }
        let peers = try readPeerHeads(in: folder)
        let ownHead = headURL(in: folder, for: configuration.id)
        let unseen = peers.filter { !state.known.contains($0.head) }
            .sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }

        // Fast path: nothing changed here or on any peer since the last exchange.
        if let revision, state.syncedRevisionID == revision.id, unseen.isEmpty,
           state.conflictAttemptID == nil, FolderFiles.exists(ownHead) {
            state.lastSyncedAt = now()
            state.failure = nil
            try saveState(state)
            return
        }

        let attemptID = UUID()
        let attempt = attemptsRoot.appendingPathComponent(attemptID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
        var retainAttempt = false
        defer { if !retainAttempt { try? FileManager.default.removeItem(at: attempt) } }

        let local = try localRoot.map(StorageTree.read) ?? [:]
        var merging = local
        let committed = Set(state.known)
        var known = state.known
        var mergedPeer = false
        for (index, peer) in unseen.enumerated() {
            // The head can arrive before its snapshot; the next exchange retries.
            guard let remoteRoot = try loadSnapshot(peer.head, from: folder,
                into: attempt.appendingPathComponent("remote-\(index)", isDirectory: true)) else { continue }
            let baseRoot = attempt.appendingPathComponent("base-\(index)", isDirectory: true)
            // Ancestors come from what this device had already committed to, so
            // the conflict review below can redo the merge from the workspace.
            // A pruned or missing ancestor merges against an empty tree, which
            // can only report more conflicts, never silently drop a change.
            let ancestor = peer.history.first { committed.contains($0) }
            if try ancestor.flatMap({ try loadSnapshot($0, from: folder, into: baseRoot) }) == nil {
                try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)
            }
            let remote = try StorageTree.read(remoteRoot)
            let result = StorageTree.merge(base: try StorageTree.read(baseRoot), local: merging, remote: remote)
            if !result.conflicts.isEmpty {
                try FileManager.default.moveItem(at: remoteRoot, to: attempt.appendingPathComponent("remote", isDirectory: true))
                try FileManager.default.moveItem(at: baseRoot, to: attempt.appendingPathComponent("base", isDirectory: true))
                if localRoot != nil {
                    let conflictLocal = attempt.appendingPathComponent("local", isDirectory: true)
                    try FileManager.default.createDirectory(at: conflictLocal, withIntermediateDirectories: true)
                    try StorageTree.materialize(local, in: conflictLocal)
                }
                let previousAttempt = state.conflictAttemptID
                state.conflictPaths = result.conflicts
                state.conflictAttemptID = attemptID
                state.conflictLocalRevisionID = revision?.id
                state.conflictPeer = peer
                state.failure = nil
                try saveState(state)
                retainAttempt = true
                discardAttempt(previousAttempt)
                throw LocalStorageError.conflicts(result.conflicts)
            }
            merging = result.files
            known = Self.prepend([peer.head] + peer.history, to: known)
            mergedPeer = true
        }

        let merged = merging
        let published: LocalLedgerWorkspace.Revision
        if let revision, StorageTree.sameContents(local, merged) {
            guard try await workspace.currentRevision()?.id == revision.id else {
                throw LocalLedgerWorkspace.WorkspaceError.staleRevision
            }
            published = revision
        } else if let revision {
            published = try await workspace.commit(expectedRevisionID: revision.id, changes: [], mutateStage: { stage in
                try StorageTree.materialize(merged, in: stage)
            }, validator: validator)
        } else {
            guard !merged.isEmpty else { throw LocalStorageError.emptySyncFolder }
            published = try await workspace.commit(changes: [], mutateStage: { stage in
                try StorageTree.materialize(merged, in: stage)
            }, validator: validator)
        }

        let digest = Self.digest(of: merged)
        if state.baseDigest != digest || mergedPeer || !FolderFiles.exists(ownHead) {
            try publishSnapshot(merged, digest: digest, revisionID: published.id, to: folder, staging: attempt)
            known = Self.prepend([digest], to: known)
            let head = FolderSyncLayout.Head(deviceID: configuration.id, deviceName: configuration.deviceName,
                head: digest, history: known, updatedAt: now())
            try FolderFiles.write(FolderSyncLayout.encoder.encode(head), to: ownHead)
            if try FolderSyncLayout.readMarker(in: folder) == nil {
                let marker = FolderSyncLayout.Marker(ledgerName: ledger.name, entrypoint: ledger.entrypoint, createdAt: now())
                try FolderFiles.write(FolderSyncLayout.encoder.encode(marker), to: folder.appendingPathComponent(FolderSyncLayout.markerName))
            }
            pruneSnapshots(in: folder, heads: peers + [head])
        }
        let previousAttempt = state.conflictAttemptID
        state.baseDigest = digest
        state.known = known
        state.syncedRevisionID = published.id
        state.pendingRevisionID = nil
        state.conflictPaths = []
        state.conflictAttemptID = nil
        state.conflictLocalRevisionID = nil
        state.conflictPeer = nil
        state.failure = nil
        state.lastSyncedAt = now()
        try saveState(state)
        discardAttempt(previousAttempt)
    }

    func resolveConflicts(keepingLocal: Bool, validator: @escaping LocalLedgerWorkspace.Validator) async throws -> LocalStorageSyncStatus {
        guard !synchronizing else { throw LocalStorageError.synchronizationInProgress }
        let lease = try SyncLease(directory: syncRoot)
        defer { lease.release() }
        synchronizing = true
        defer { synchronizing = false }
        var state = try loadState()
        guard let attemptID = state.conflictAttemptID, let expected = state.conflictLocalRevisionID,
              let peer = state.conflictPeer, !state.conflictPaths.isEmpty else {
            throw LocalStorageError.gitFailure(String(localized: "请先同步以读取当前冲突"))
        }
        let attempt = attemptsRoot.appendingPathComponent(attemptID.uuidString)
        let remote = try StorageTree.read(attempt.appendingPathComponent("remote"))
        let base = try StorageTree.read(attempt.appendingPathComponent("base"))
        let published = try await workspace.withCurrentSnapshot { revision, localRoot in
            guard revision.id == expected else { throw LocalLedgerWorkspace.WorkspaceError.staleRevision }
            let local = try StorageTree.read(localRoot)
            let merged = StorageTree.merge(base: base, local: local, remote: remote, keepingLocalConflicts: keepingLocal)
            return try await self.workspace.commit(expectedRevisionID: expected, changes: [], mutateStage: { stage in
                try StorageTree.materialize(merged.files, in: stage)
            }, validator: validator)
        }
        // The peer's head is now part of this device's history; the next
        // exchange publishes the resolved tree without merging that head again.
        state.known = Self.prepend([peer.head] + peer.history, to: state.known)
        state.syncedRevisionID = nil
        state.pendingRevisionID = published.id
        state.conflictPaths = []
        state.conflictAttemptID = nil
        state.conflictLocalRevisionID = nil
        state.conflictPeer = nil
        state.failure = nil
        try saveState(state)
        discardAttempt(attemptID)
        synchronizing = false
        return try await status()
    }

    func exportConflictVersions() async throws -> URL {
        let state = try loadState()
        guard let attemptID = state.conflictAttemptID else { throw LocalStorageError.gitFailure(String(localized: "当前没有待处理的冲突")) }
        let source = attemptsRoot.appendingPathComponent(attemptID.uuidString)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerSyncConflict-" + UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    // MARK: - Folder

    private func headURL(in folder: URL, for id: UUID) -> URL {
        folder.appendingPathComponent(FolderSyncLayout.devicesName, isDirectory: true)
            .appendingPathComponent(id.uuidString + ".json")
    }

    private func snapshotURL(in folder: URL, digest: String) -> URL {
        folder.appendingPathComponent(FolderSyncLayout.snapshotsName, isDirectory: true)
            .appendingPathComponent(digest + "." + LedgerBackupArchive.fileExtension)
    }

    /// Other devices' heads. Names that are not `<UUID>.json`, such as a
    /// provider's "name 2.json" copy, are ignored.
    private func readPeerHeads(in folder: URL) throws -> [FolderSyncLayout.Head] {
        let directory = folder.appendingPathComponent(FolderSyncLayout.devicesName, isDirectory: true)
        var heads: [FolderSyncLayout.Head] = []
        for name in try FolderFiles.names(in: directory) where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(".json".count))), id != configuration.id else { continue }
            let data = try FolderFiles.read(directory.appendingPathComponent(name))
            guard let head = try? FolderSyncLayout.decoder.decode(FolderSyncLayout.Head.self, from: data) else {
                throw LedgerBackupError.corrupt(String(localized: "无法读取其他设备的同步记录"))
            }
            guard head.formatVersion <= FolderSyncLayout.formatVersion else {
                throw LedgerBackupError.unsupportedVersion(head.formatVersion)
            }
            guard head.deviceID == id, FolderSyncLayout.isDigest(head.head),
                  head.history.allSatisfy(FolderSyncLayout.isDigest) else {
                throw LedgerBackupError.corrupt(String(localized: "无法读取其他设备的同步记录"))
            }
            heads.append(head)
        }
        return heads
    }

    /// Extracts the snapshot into `directory`, or returns nil when the folder
    /// does not hold it yet. The local base copy avoids a download.
    private func loadSnapshot(_ digest: String, from folder: URL, into directory: URL) throws -> URL? {
        let archive: URL
        let cached = cachedBaseURL(digest)
        if FileManager.default.fileExists(atPath: cached.path) {
            archive = cached
        } else {
            let remote = snapshotURL(in: folder, digest: digest)
            guard FolderFiles.exists(remote) else { return nil }
            archive = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".ledgerbackup")
            try FolderFiles.copy(remote, to: archive)
        }
        let manifest = try LedgerBackupArchive.extract(archive, to: directory, attributes: LedgerBackupArchive.syncAttributes)
        guard manifest.contentDigest == digest else { throw LedgerBackupError.corrupt(String(localized: "快照摘要与文件名不一致")) }
        return directory
    }

    private func publishSnapshot(_ files: [String: StorageTree.File], digest: String, revisionID: UUID,
                                 to folder: URL, staging: URL) throws {
        let scanned = files.keys.sorted().map { path in
            let file = files[path]!
            return LedgerBackupArchive.ScannedFile(source: file.url,
                entry: .init(path: path, size: file.size, sha256: file.digest.map { String(format: "%02x", $0) }.joined()))
        }
        let manifest = LedgerBackupManifest(formatVersion: LedgerBackupManifest.currentFormatVersion,
            ledgerID: ledger.id, ledgerName: ledger.name, entrypoint: ledger.entrypoint,
            revisionID: revisionID, createdAt: now(), contentDigest: digest, files: scanned.map(\.entry))
        let archive = staging.appendingPathComponent("publish.ledgerbackup")
        try LedgerBackupArchive.write(scanned, manifest: manifest, to: archive, attributes: LedgerBackupArchive.syncAttributes)
        try FolderFiles.publish(archive, to: snapshotURL(in: folder, digest: digest))
        // Keep exactly one local copy: the tree the next merge most likely uses as base.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: baseCacheRoot.path)) ?? [] {
            try? FileManager.default.removeItem(at: baseCacheRoot.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: archive, to: cachedBaseURL(digest))
    }

    /// Removes snapshots that no head's recent history references. Pruning is
    /// best effort: a failure never fails the exchange.
    private func pruneSnapshots(in folder: URL, heads: [FolderSyncLayout.Head]) {
        let referenced = Set(heads.flatMap { [$0.head] + $0.history.prefix(FolderSyncLayout.retainedHistory) })
        let directory = folder.appendingPathComponent(FolderSyncLayout.snapshotsName, isDirectory: true)
        let suffix = "." + LedgerBackupArchive.fileExtension
        let cutoff = now().addingTimeInterval(-FolderSyncLayout.pruneGrace)
        for name in (try? FolderFiles.names(in: directory)) ?? [] where name.hasSuffix(suffix) {
            let digest = String(name.dropLast(suffix.count))
            guard FolderSyncLayout.isDigest(digest), !referenced.contains(digest) else { continue }
            let url = directory.appendingPathComponent(name)
            guard let modified = FolderFiles.modificationDate(of: url), modified < cutoff else { continue }
            try? FolderFiles.remove(FileManager.default.fileExists(atPath: url.path) ? url : FolderFiles.placeholder(for: url))
        }
    }

    static func digest(of files: [String: StorageTree.File]) -> String {
        LedgerBackupArchive.contentDigest(of: files.map { path, file in
            LedgerBackupManifest.File(path: path, size: file.size, sha256: file.digest.map { String(format: "%02x", $0) }.joined())
        })
    }

    static func prepend(_ digests: [String], to history: [String]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for digest in digests + history where seen.insert(digest).inserted {
            result.append(digest)
            if result.count == FolderSyncLayout.historyLimit { break }
        }
        return result
    }

    // MARK: - Local state

    private var attemptsRoot: URL { syncRoot.appendingPathComponent("candidates", isDirectory: true) }
    private var baseCacheRoot: URL { syncRoot.appendingPathComponent("base", isDirectory: true) }
    private var stateURL: URL { syncRoot.appendingPathComponent("folder-state.json") }
    private func cachedBaseURL(_ digest: String) -> URL {
        baseCacheRoot.appendingPathComponent(digest + "." + LedgerBackupArchive.fileExtension)
    }

    private func discardAttempt(_ id: UUID?) {
        guard let id else { return }
        try? FileManager.default.removeItem(at: attemptsRoot.appendingPathComponent(id.uuidString))
    }

    private func loadState() throws -> State {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return State() }
        do {
            let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
            guard state.version == 1 else { throw LocalStorageError.corruptSyncState }
            return state
        } catch { throw LocalStorageError.corruptSyncState }
    }

    private func saveState(_ state: State) throws {
        try FileManager.default.createDirectory(at: syncRoot, withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(state).write(to: stateURL, options: .ledgerProtectedUntilFirstUserAuthentication)
        #else
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        #endif
    }

    private func prepareLayout() throws {
        for directory in [workspace.rootDirectory, syncRoot.deletingLastPathComponent(), syncRoot, attemptsRoot, baseCacheRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            #endif
        }
    }
}
