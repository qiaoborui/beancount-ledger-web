import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Owns an app-private, local-first Beancount workspace.
///
/// Each committed revision is an immutable generation. `current.json` is the
/// atomic pointer to the active generation, so readers never observe a partial
/// multi-file write. This type deliberately has no App Group entry point: full
/// ledger files stay in the main application's container.
actor LocalLedgerWorkspace {
    typealias Validator = @Sendable (URL) async throws -> Void

    private static let copyBufferSize = 256 * 1024
    private static let maximumRevisionBytes = 1024 * 1024
    private static let revisionFileName = "revision.json"
    private static let committedMarkerName = ".committed"

    /// Bounds a generation, counting directories as entries as well as files.
    struct TreeLimits: Sendable {
        var maximumEntries = 10_000
        var maximumBytes = 256 * 1024 * 1024
        var maximumDepth = 32
    }

    private struct TreeBudget {
        let limits: TreeLimits
        var entries = 0
        var bytes = 0

        mutating func addEntry(_ path: String) throws {
            guard entries < limits.maximumEntries,
                  path.split(separator: "/").count <= limits.maximumDepth else {
                throw WorkspaceError.treeLimitExceeded
            }
            entries += 1
        }

        mutating func addBytes(_ count: Int) throws {
            guard count >= 0, count <= limits.maximumBytes - bytes else {
                throw WorkspaceError.treeLimitExceeded
            }
            bytes += count
        }
    }

    struct Revision: Codable, Equatable, Sendable {
        static let schemaVersion = 1

        let version: Int
        let id: UUID
        let parentID: UUID?
        let createdAt: Date
        let changedPaths: [String]

        init(id: UUID, parentID: UUID?, createdAt: Date, changedPaths: [String]) {
            version = Self.schemaVersion
            self.id = id
            self.parentID = parentID
            self.createdAt = createdAt
            self.changedPaths = changedPaths
        }
    }

    struct Change: Equatable, Sendable {
        enum Operation: Equatable, Sendable {
            case write(Data)
            case remove
        }

        let relativePath: String
        let operation: Operation

        static func write(_ data: Data, to relativePath: String) -> Self {
            Self(relativePath: relativePath, operation: .write(data))
        }

        static func remove(_ relativePath: String) -> Self {
            Self(relativePath: relativePath, operation: .remove)
        }
    }

    enum WorkspaceError: LocalizedError, Equatable {
        case invalidRoot
        case invalidSource
        case invalidRelativePath(String)
        case duplicateRelativePath(String)
        case symbolicLink(String)
        case unsupportedItem(String)
        case transactionInProgress
        case missingRevision
        case corruptRevision
        case staleRevision
        case treeLimitExceeded
        case revisionTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidRoot:
                "无法创建本地账本目录"
            case .invalidSource:
                "请选择有效的账本目录"
            case let .invalidRelativePath(path):
                "账本路径无效：\(path)"
            case let .duplicateRelativePath(path):
                "同一次修改包含重复路径：\(path)"
            case let .symbolicLink(path):
                "本地账本不接受符号链接：\(path)"
            case let .unsupportedItem(path):
                "本地账本只接受目录和普通文件：\(path)"
            case .transactionInProgress:
                "本地账本正在保存另一项修改"
            case .missingRevision:
                "本地账本还没有可用版本"
            case .corruptRevision:
                "本地账本版本信息已损坏"
            case .staleRevision:
                "账本已更新，请刷新预览后再确认修改"
            case .treeLimitExceeded:
                "账本目录的文件数量、总大小或层级超过限制"
            case .revisionTooLarge:
                "本次修改的版本信息超过大小限制"
            }
        }
    }

    nonisolated let rootDirectory: URL

    private let fileManager = FileManager()
    private let generationsDirectory: URL
    private let stagingDirectory: URL
    private let currentRevisionFile: URL
    private let copyEntryHook: @Sendable (String) throws -> Void
    private let treeLimits: TreeLimits
    private var transactionInProgress = false
    private var transactionLockHeld = false
    #if canImport(Darwin)
    private var transactionLockDescriptor: Int32?
    #endif

    init(
        rootDirectory: URL,
        treeLimits: TreeLimits = TreeLimits(),
        copyEntryHook: @escaping @Sendable (String) throws -> Void = { _ in }
    ) {
        let root = rootDirectory.standardizedFileURL
        self.rootDirectory = root
        generationsDirectory = root.appendingPathComponent("generations", isDirectory: true)
        stagingDirectory = root.appendingPathComponent("staging", isDirectory: true)
        currentRevisionFile = root.appendingPathComponent("current.json", isDirectory: false)
        self.copyEntryHook = copyEntryHook
        self.treeLimits = treeLimits
    }

    /// Creates a workspace in Application Support/Ledgers/<ledger-id>.
    static func appManaged(ledgerID: UUID) throws -> LocalLedgerWorkspace {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return LocalLedgerWorkspace(
            rootDirectory: applicationSupport
                .appendingPathComponent("Ledgers", isDirectory: true)
                .appendingPathComponent(ledgerID.uuidString, isDirectory: true)
        )
    }

    /// Creates the first empty generation, or returns the existing revision.
    @discardableResult
    func create() throws -> Revision {
        try beginTransaction()
        defer { endTransaction() }
        try prepareLayout()
        try acquireTransactionLock()
        try removeAbandonedStages()
        if let current = try loadCurrentRevisionIfPresent() {
            return current
        }

        let stage = try makeStage()
        defer { removeIfPresent(stage) }
        let workspace = stage.appendingPathComponent("workspace", isDirectory: true)
        try createProtectedDirectory(workspace)
        return try finalize(stage: stage, parentID: nil, changedPaths: [])
    }

    /// Imports a directory into a fresh generation after validation succeeds.
    /// A nil expected revision requires an empty workspace; replacement requires
    /// the revision used to prepare the user's preview.
    @discardableResult
    func importLedger(
        from sourceDirectory: URL,
        expectedRevisionID: UUID? = nil,
        validator: Validator
    ) async throws -> Revision {
        try beginTransaction()
        defer { endTransaction() }
        try prepareLayout()
        try acquireTransactionLock()
        try removeAbandonedStages()
        let source = try validatedSourceDirectory(sourceDirectory)
        guard !isDescendant(rootDirectory, of: source),
              !isDescendant(source, of: rootDirectory) else {
            throw WorkspaceError.invalidSource
        }
        let sourceIdentity = try directoryIdentity(at: source)

        let parent = try loadCurrentRevisionIfPresent()
        guard parent?.id == expectedRevisionID else { throw WorkspaceError.staleRevision }
        let stage = try makeStage()
        defer { removeIfPresent(stage) }
        let workspace = stage.appendingPathComponent("workspace", isDirectory: true)
        try createProtectedDirectory(workspace)
        try copyDirectoryContents(
            from: source,
            to: workspace,
            sourceRoot: source,
            expectedSourceIdentity: sourceIdentity,
            requiresExternalSource: true
        )
        try Task.checkCancellation()
        try await validator(workspace)
        try Task.checkCancellation()
        let importedPaths = try validateTree(at: workspace)
        try protectTree(at: workspace)
        return try finalize(stage: stage, parentID: parent?.id, changedPaths: importedPaths)
    }

    /// Applies all changes to a private staging copy and switches generations
    /// only after the complete staged ledger passes validation.
    /// A nil expected revision requires an empty workspace.
    @discardableResult
    func commit(
        expectedRevisionID: UUID? = nil,
        changes: [Change],
        mutateStage: Validator? = nil,
        validator: Validator
    ) async throws -> Revision {
        try beginTransaction()
        defer { endTransaction() }
        try prepareLayout()
        try acquireTransactionLock()
        try removeAbandonedStages()
        let parent = try loadCurrentRevisionIfPresent()
        guard parent?.id == expectedRevisionID else { throw WorkspaceError.staleRevision }
        let normalizedChanges = try validatedChanges(changes)
        let stage = try makeStage()
        defer { removeIfPresent(stage) }
        let workspace = stage.appendingPathComponent("workspace", isDirectory: true)

        if let parent {
            let currentWorkspace = try workspaceURL(for: parent)
            let sourceIdentity = try directoryIdentity(at: currentWorkspace)
            try createProtectedDirectory(workspace)
            try copyDirectoryContents(
                from: currentWorkspace,
                to: workspace,
                sourceRoot: currentWorkspace,
                expectedSourceIdentity: sourceIdentity,
                requiresExternalSource: false
            )
        } else {
            try createProtectedDirectory(workspace)
        }

        for change in normalizedChanges {
            try Task.checkCancellation()
            try apply(change, in: workspace)
        }
        if let mutateStage {
            try await mutateStage(workspace)
            try Task.checkCancellation()
        }
        try await validator(workspace)
        try Task.checkCancellation()
        let finalPaths = try validateTree(at: workspace)
        var changedPaths = Set(normalizedChanges.map(\.relativePath))
        if mutateStage != nil {
            if let parent {
                let previous = try workspaceURL(for: parent)
                let previousPaths = Set(try validateTree(at: previous))
                let finalPathSet = Set(finalPaths)
                for path in previousPaths.union(finalPathSet) {
                    let existed = previousPaths.contains(path)
                    let exists = finalPathSet.contains(path)
                    if !existed || !exists {
                        changedPaths.insert(path)
                    } else {
                        let oldFile = try secureDescendant(path, of: previous, allowMissingLeaf: false)
                        let newFile = try secureDescendant(path, of: workspace, allowMissingLeaf: false)
                        let executionChanged = try isExecutable(oldFile) != isExecutable(newFile)
                        if !fileManager.contentsEqual(atPath: oldFile.path, andPath: newFile.path)
                            || executionChanged {
                            changedPaths.insert(path)
                        }
                    }
                }
            } else {
                changedPaths.formUnion(finalPaths)
            }
        }
        try protectTree(at: workspace)
        return try finalize(
            stage: stage,
            parentID: parent?.id,
            changedPaths: changedPaths.sorted()
        )
    }

    func currentRevision() throws -> Revision? {
        try prepareLayout()
        return try loadCurrentRevisionIfPresent()
    }

    /// Pins one immutable generation for the duration of `operation`.
    /// Consumers should derive their read model inside this scope and avoid
    /// retaining the filesystem URL after the operation returns.
    func withCurrentSnapshot<Value: Sendable>(
        _ operation: @Sendable (Revision, URL) async throws -> Value
    ) async throws -> Value {
        let revision = try requiredCurrentRevision()
        let workspace = try workspaceURL(for: revision)
        return try await operation(revision, workspace)
    }

    private func requiredCurrentRevision() throws -> Revision {
        try prepareLayout()
        guard let revision = try loadCurrentRevisionIfPresent() else {
            throw WorkspaceError.missingRevision
        }
        return revision
    }

    func readFile(at relativePath: String) throws -> Data {
        try readFileSnapshot(at: relativePath).data
    }

    /// Reads bytes and their revision under one actor turn, with the same path
    /// and regular-file checks used by writes.
    func readFileSnapshot(at relativePath: String) throws -> (revision: Revision, data: Data) {
        let path = try validatedRelativePath(relativePath)
        let revision = try requiredCurrentRevision()
        let workspace = try workspaceURL(for: revision)
        let file = try secureDescendant(path, of: workspace, allowMissingLeaf: false)
        guard try itemKind(at: file) == .regularFile else {
            throw WorkspaceError.unsupportedItem(path)
        }
        return (revision, try readRegularFile(at: file, displayPath: path))
    }

    // MARK: - Layout and revision pointer

    private func prepareLayout() throws {
        guard rootDirectory.isFileURL else { throw WorkspaceError.invalidRoot }
        try createProtectedDirectory(rootDirectory)
        try createProtectedDirectory(generationsDirectory)
        try createProtectedDirectory(stagingDirectory)
    }

    private func beginTransaction() throws {
        guard !transactionInProgress else { throw WorkspaceError.transactionInProgress }
        transactionInProgress = true
    }

    private func endTransaction() {
        releaseTransactionLock()
        transactionInProgress = false
    }

    private func releaseTransactionLock() {
        #if canImport(Darwin)
        if let descriptor = transactionLockDescriptor {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            transactionLockDescriptor = nil
        }
        #endif
        transactionLockHeld = false
    }

    private func acquireTransactionLock() throws {
        guard !transactionLockHeld else { throw WorkspaceError.transactionInProgress }
        #if canImport(Darwin)
        let lock = rootDirectory.appendingPathComponent(".workspace.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WorkspaceError.invalidRoot }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw WorkspaceError.transactionInProgress
        }
        do {
            try protect(lock)
        } catch {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw error
        }
        transactionLockDescriptor = descriptor
        #endif
        transactionLockHeld = true
    }

    private func removeAbandonedStages() throws {
        for item in try fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: nil
        ) where UUID(uuidString: item.lastPathComponent) != nil {
            try fileManager.removeItem(at: item)
        }
        for item in try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        ) {
            guard item.lastPathComponent.hasPrefix(".current-"),
                  item.pathExtension == "json",
                  try itemKind(at: item) == .regularFile else { continue }
            try fileManager.removeItem(at: item)
        }
    }

    private func makeStage() throws -> URL {
        let stage = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createProtectedDirectory(stage)
        return stage
    }

    private func finalize(stage: URL, parentID: UUID?, changedPaths: [String]) throws -> Revision {
        let revision = Revision(
            id: UUID(),
            parentID: parentID,
            createdAt: Date(),
            changedPaths: changedPaths
        )
        let generation = generationDirectory(for: revision.id)
        guard !fileManager.fileExists(atPath: generation.path) else {
            throw WorkspaceError.corruptRevision
        }

        try writeRevisionMetadata(revision, in: stage)
        try synchronizeTree(at: stage)
        try Task.checkCancellation()
        try fileManager.moveItem(at: stage, to: generation)
        do {
            try synchronizeDirectory(generationsDirectory)
            try writeCurrentRevision(revision)
        } catch {
            try? fileManager.removeItem(at: generation)
            try? synchronizeDirectory(generationsDirectory)
            throw error
        }
        // `current.json` publication is the commit point. Recovery only trusts
        // generations carrying this post-publication marker.
        try? writeCommittedMarker(for: revision.id, in: generation)
        return revision
    }

    private func writeRevisionMetadata(_ revision: Revision, in generation: URL) throws {
        let metadata = generation.appendingPathComponent(Self.revisionFileName)
        try encodedRevision(revision).write(to: metadata)
        try protect(metadata)
    }

    private func writeCurrentRevision(_ revision: Revision) throws {
        let pending = rootDirectory.appendingPathComponent(
            ".current-" + UUID().uuidString + ".json",
            isDirectory: false
        )
        defer { removeIfPresent(pending) }
        try encodedRevision(revision).write(to: pending)
        try protect(pending)
        try synchronizeFile(pending)
        #if canImport(Darwin)
        guard rename(pending.path, currentRevisionFile.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        #else
        if fileManager.fileExists(atPath: currentRevisionFile.path) {
            _ = try fileManager.replaceItemAt(currentRevisionFile, withItemAt: pending)
        } else {
            try fileManager.moveItem(at: pending, to: currentRevisionFile)
        }
        #endif
        // The rename above is the commit point. A directory fsync improves
        // crash durability; any post-rename failure leaves a valid pointer.
        try? synchronizeDirectory(rootDirectory)
    }

    private func writeCommittedMarker(for revisionID: UUID, in generation: URL) throws {
        let marker = generation.appendingPathComponent(Self.committedMarkerName)
        if try hasCommittedMarker(for: revisionID, in: generation) { return }
        let pending = generation.appendingPathComponent(".committed-" + UUID().uuidString)
        defer { removeIfPresent(pending) }
        try Data(revisionID.uuidString.utf8).write(to: pending)
        try protect(pending)
        try synchronizeFile(pending)
        #if canImport(Darwin)
        guard rename(pending.path, marker.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        #else
        if fileManager.fileExists(atPath: marker.path) {
            _ = try fileManager.replaceItemAt(marker, withItemAt: pending)
        } else {
            try fileManager.moveItem(at: pending, to: marker)
        }
        #endif
        try? synchronizeDirectory(generation)
    }

    private func hasCommittedMarker(for revisionID: UUID, in generation: URL) throws -> Bool {
        let marker = generation.appendingPathComponent(Self.committedMarkerName)
        guard try itemKindIfPresent(at: marker) == .regularFile else { return false }
        let data = try readRegularFile(at: marker, displayPath: marker.path, maximumBytes: 64)
        return String(data: data, encoding: .utf8) == revisionID.uuidString
    }

    private func loadCurrentRevisionIfPresent() throws -> Revision? {
        let initial = try readCurrentPointer()
        if case let .valid(revision) = initial {
            if transactionLockHeld {
                try? writeCommittedMarker(for: revision.id, in: generationDirectory(for: revision.id))
            }
            return revision
        }

        let acquiredForRecovery = !transactionLockHeld
        if acquiredForRecovery {
            try acquireTransactionLock()
        }
        defer {
            if acquiredForRecovery { releaseTransactionLock() }
        }

        // Another workspace instance may have published while this caller was
        // acquiring the root lock. Its pointer is authoritative.
        let locked = try readCurrentPointer()
        if case let .valid(revision) = locked {
            try? writeCommittedMarker(for: revision.id, in: generationDirectory(for: revision.id))
            return revision
        }
        if let recovered = try recoverCurrentRevision() {
            try writeCurrentRevision(recovered)
            return recovered
        }
        guard case .missing = locked else { throw WorkspaceError.corruptRevision }
        return nil
    }

    private enum CurrentPointer {
        case missing
        case invalid
        case valid(Revision)
    }

    private func readCurrentPointer() throws -> CurrentPointer {
        guard let pointerKind = try itemKindIfPresent(at: currentRevisionFile) else {
            return .missing
        }
        guard pointerKind == .regularFile else { return .invalid }
        do {
            let revision = try decodedRevision(at: currentRevisionFile, expectedID: nil)
            try validateStoredRevision(revision)
            return .valid(revision)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .invalid
        }
    }

    private func recoverCurrentRevision() throws -> Revision? {
        var revisions: [Revision] = []
        for generation in try fileManager.contentsOfDirectory(
            at: generationsDirectory,
            includingPropertiesForKeys: nil
        ) {
            guard let expectedID = UUID(uuidString: generation.lastPathComponent),
                  (try? itemKind(at: generation)) == .directory,
                  (try? hasCommittedMarker(for: expectedID, in: generation)) == true else { continue }
            let metadata = generation.appendingPathComponent(Self.revisionFileName)
            do {
                let revision = try decodedRevision(at: metadata, expectedID: expectedID)
                try validateStoredRevision(revision)
                revisions.append(revision)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        guard !revisions.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })

        for revision in revisions {
            var visited = Set<UUID>()
            var cursor: Revision? = revision
            while let current = cursor {
                guard visited.insert(current.id).inserted else {
                    throw WorkspaceError.corruptRevision
                }
                cursor = current.parentID.flatMap { byID[$0] }
            }
        }

        let referencedParents = Set(revisions.compactMap { revision in
            revision.parentID.flatMap { byID[$0]?.id }
        })
        let heads = revisions.filter { !referencedParents.contains($0.id) }
        guard heads.count == 1 else { throw WorkspaceError.corruptRevision }
        return heads[0]
    }

    private func decodedRevision(at url: URL, expectedID: UUID?) throws -> Revision {
        guard try itemKind(at: url) == .regularFile else {
            throw WorkspaceError.corruptRevision
        }
        let data = try readRegularFile(
            at: url,
            displayPath: url.lastPathComponent,
            maximumBytes: Self.maximumRevisionBytes
        )
        let revision = try JSONDecoder().decode(Revision.self, from: data)
        guard expectedID == nil || revision.id == expectedID else {
            throw WorkspaceError.corruptRevision
        }
        try validateRevisionMetadata(revision)
        return revision
    }

    private func validateRevisionMetadata(_ revision: Revision) throws {
        guard revision.version == Revision.schemaVersion,
              revision.parentID != revision.id,
              revision.changedPaths == revision.changedPaths.sorted() else {
            throw WorkspaceError.corruptRevision
        }
        var aliases = Set<String>()
        for path in revision.changedPaths {
            let validated = try validatedRelativePath(path)
            guard aliases.insert(canonicalPathKey(validated)).inserted else {
                throw WorkspaceError.corruptRevision
            }
        }
    }

    private func validateStoredRevision(_ revision: Revision) throws {
        _ = try workspaceURL(for: revision)
        let metadata = generationDirectory(for: revision.id)
            .appendingPathComponent(Self.revisionFileName)
        if try itemKindIfPresent(at: metadata) != nil {
            let stored = try decodedRevision(at: metadata, expectedID: revision.id)
            guard stored == revision else { throw WorkspaceError.corruptRevision }
        }
    }

    private func encodedRevision(_ revision: Revision) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(revision)
        guard data.count <= Self.maximumRevisionBytes else { throw WorkspaceError.revisionTooLarge }
        return data
    }

    private func generationDirectory(for revisionID: UUID) -> URL {
        generationsDirectory.appendingPathComponent(revisionID.uuidString, isDirectory: true)
    }

    private func workspaceURL(for revision: Revision) throws -> URL {
        let generation = generationDirectory(for: revision.id)
        guard try itemKind(at: generation) == .directory else {
            throw WorkspaceError.corruptRevision
        }
        let workspace = generation.appendingPathComponent("workspace", isDirectory: true)
        guard try itemKind(at: workspace) == .directory else {
            throw WorkspaceError.corruptRevision
        }
        _ = try validateTree(at: workspace)
        return workspace
    }

    // MARK: - Changes and paths

    private func validatedChanges(_ changes: [Change]) throws -> [Change] {
        var seen = Set<String>()
        var budget = TreeBudget(limits: treeLimits)
        return try changes.map { change in
            let path = try validatedRelativePath(change.relativePath)
            try budget.addEntry(path)
            if case let .write(data) = change.operation { try budget.addBytes(data.count) }
            guard seen.insert(canonicalPathKey(path)).inserted else {
                throw WorkspaceError.duplicateRelativePath(path)
            }
            return Change(relativePath: path, operation: change.operation)
        }
    }

    private func validatedRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceError.invalidRelativePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
        }), components.count <= treeLimits.maximumDepth,
            components.joined(separator: "/") == path else {
            throw WorkspaceError.invalidRelativePath(path)
        }
        return path
    }

    private func canonicalPathKey(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map {
                String($0)
                    .precomposedStringWithCanonicalMapping
                    .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    .precomposedStringWithCanonicalMapping
            }
            .joined(separator: "/")
    }

    private func secureDescendant(
        _ relativePath: String,
        of root: URL,
        allowMissingLeaf: Bool
    ) throws -> URL {
        let path = try validatedRelativePath(relativePath)
        let components = path.split(separator: "/").map(String.init)
        var candidate = root
        for (index, component) in components.enumerated() {
            candidate.appendPathComponent(component, isDirectory: false)
            let isLeaf = index == components.count - 1
            guard let kind = try itemKindIfPresent(at: candidate) else {
                if isLeaf && allowMissingLeaf { return candidate }
                if !isLeaf && allowMissingLeaf { continue }
                throw WorkspaceError.unsupportedItem(path)
            }
            if kind == .symbolicLink {
                throw WorkspaceError.symbolicLink(path)
            }
            if !isLeaf && kind != .directory {
                throw WorkspaceError.unsupportedItem(path)
            }
        }
        return candidate
    }

    private func apply(_ change: Change, in workspace: URL) throws {
        let destination = try secureDescendant(change.relativePath, of: workspace, allowMissingLeaf: true)
        switch change.operation {
        case let .write(data):
            let parent = destination.deletingLastPathComponent()
            try createProtectedDirectory(parent)
            if let kind = try itemKindIfPresent(at: destination), kind != .regularFile {
                if kind == .symbolicLink { throw WorkspaceError.symbolicLink(change.relativePath) }
                throw WorkspaceError.unsupportedItem(change.relativePath)
            }
            let executable = try itemKindIfPresent(at: destination) == .regularFile ? isExecutable(destination) : false
            try data.write(to: destination, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: destination.path)
            try protect(destination)
        case .remove:
            guard let kind = try itemKindIfPresent(at: destination) else { return }
            if kind == .symbolicLink { throw WorkspaceError.symbolicLink(change.relativePath) }
            guard kind == .regularFile else {
                throw WorkspaceError.unsupportedItem(change.relativePath)
            }
            try fileManager.removeItem(at: destination)
        }
    }

    // MARK: - Safe tree copying

    private func validatedSourceDirectory(_ source: URL) throws -> URL {
        guard source.isFileURL else { throw WorkspaceError.invalidSource }
        let standardized = source.standardizedFileURL
        guard try itemKind(at: standardized) == .directory else {
            throw WorkspaceError.invalidSource
        }
        return standardized
    }

    private func copyDirectoryContents(
        from source: URL,
        to destination: URL,
        sourceRoot: URL,
        expectedSourceIdentity: FileIdentity,
        requiresExternalSource: Bool
    ) throws {
        var budget = TreeBudget(limits: treeLimits)
        #if canImport(Darwin)
        let descriptor = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WorkspaceError.invalidSource }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              fileIdentity(status) == expectedSourceIdentity,
              status.st_mode & S_IFMT == S_IFDIR,
              let pinnedSource = fileURL(for: descriptor) else {
            throw WorkspaceError.invalidSource
        }
        if requiresExternalSource,
           isDescendant(rootDirectory, of: pinnedSource)
            || isDescendant(pinnedSource, of: rootDirectory) {
            throw WorkspaceError.invalidSource
        }
        var aliases = Set<String>()
        try copyDirectoryContents(
            fromDirectoryDescriptor: descriptor,
            to: destination,
            relativePrefix: "",
            aliases: &aliases,
            budget: &budget
        )
        #else
        guard try directoryIdentity(at: source) == expectedSourceIdentity else {
            throw WorkspaceError.invalidSource
        }
        try copyDirectoryContentsByPath(from: source, to: destination, sourceRoot: sourceRoot, budget: &budget)
        #endif
    }

    #if canImport(Darwin)
    private func copyDirectoryContents(
        fromDirectoryDescriptor directoryDescriptor: Int32,
        to destination: URL,
        relativePrefix: String,
        aliases: inout Set<String>,
        budget: inout TreeBudget
    ) throws {
        try Task.checkCancellation()
        for name in try directoryEntryNames(directoryDescriptor, maximumEntries: treeLimits.maximumEntries - budget.entries) {
            try Task.checkCancellation()
            let relativePath = relativePrefix.isEmpty ? name : relativePrefix + "/" + name
            try budget.addEntry(relativePath)
            _ = try validatedRelativePath(relativePath)
            guard aliases.insert(canonicalPathKey(relativePath)).inserted else {
                throw WorkspaceError.duplicateRelativePath(relativePath)
            }
            try copyEntryHook(relativePath)
            let childDescriptor = openat(
                directoryDescriptor,
                name,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK
            )
            guard childDescriptor >= 0 else {
                if errno == ELOOP { throw WorkspaceError.symbolicLink(relativePath) }
                throw WorkspaceError.invalidSource
            }
            var status = stat()
            guard fstat(childDescriptor, &status) == 0 else {
                close(childDescriptor)
                throw WorkspaceError.invalidSource
            }
            let target = destination.appendingPathComponent(name)
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                defer { close(childDescriptor) }
                try createProtectedDirectory(target)
                try copyDirectoryContents(
                    fromDirectoryDescriptor: childDescriptor,
                    to: target,
                    relativePrefix: relativePath,
                    aliases: &aliases,
                    budget: &budget
                )
            case S_IFREG:
                try copyRegularFile(fromDescriptor: childDescriptor, to: target,
                    executable: status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0, budget: &budget)
                try protect(target)
            default:
                close(childDescriptor)
                throw WorkspaceError.unsupportedItem(relativePath)
            }
        }
    }

    private func directoryEntryNames(_ directoryDescriptor: Int32, maximumEntries: Int) throws -> [String] {
        let streamDescriptor = openat(directoryDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard streamDescriptor >= 0, let directory = fdopendir(streamDescriptor) else {
            if streamDescriptor >= 0 { close(streamDescriptor) }
            throw WorkspaceError.invalidSource
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw WorkspaceError.invalidSource }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let data = withUnsafeBytes(of: entry.pointee.d_name) { Data($0.prefix(length)) }
            guard let name = String(data: data, encoding: .utf8) else {
                throw WorkspaceError.invalidSource
            }
            if name != "." && name != ".." {
                guard names.count < maximumEntries else { throw WorkspaceError.treeLimitExceeded }
                names.append(name)
            }
        }
        return names.sorted()
    }

    private func fileURL(for descriptor: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            fcntl(descriptor, F_GETPATH, pointer.baseAddress!)
        }
        guard result == 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: bytes, encoding: .utf8) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func copyRegularFile(
        fromDescriptor sourceDescriptor: Int32,
        to destination: URL,
        executable: Bool,
        budget: inout TreeBudget
    ) throws {
        let destinationDescriptor = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            close(sourceDescriptor)
            throw CocoaError(.fileWriteUnknown)
        }
        let input = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        let output = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: true)
        defer {
            try? input.close()
            try? output.close()
        }
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: Self.copyBufferSize), !chunk.isEmpty else { break }
            try budget.addBytes(chunk.count)
            try output.write(contentsOf: chunk)
        }
        guard fchmod(destinationDescriptor, executable ? S_IRUSR | S_IWUSR | S_IXUSR : S_IRUSR | S_IWUSR) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try output.synchronize()
    }
    #else
    private func copyDirectoryContentsByPath(
        from source: URL, to destination: URL, sourceRoot: URL, budget: inout TreeBudget
    ) throws {
        try Task.checkCancellation()
        guard try itemKind(at: source) == .directory,
              isDescendant(source.resolvingSymlinksInPath(), of: sourceRoot.resolvingSymlinksInPath()) else {
            throw WorkspaceError.symbolicLink(source.path)
        }
        for item in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            let relativePath = String(item.path.dropFirst(sourceRoot.path.count + 1))
            try budget.addEntry(relativePath)
            let target = destination.appendingPathComponent(item.lastPathComponent)
            switch try itemKind(at: item) {
            case .directory:
                try createProtectedDirectory(target)
                try copyDirectoryContentsByPath(from: item, to: target, sourceRoot: sourceRoot, budget: &budget)
            case .regularFile:
                let executable = try isExecutable(item)
                let input = try FileHandle(forReadingFrom: item)
                defer { try? input.close() }
                fileManager.createFile(atPath: target.path, contents: nil)
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                while let chunk = try input.read(upToCount: Self.copyBufferSize), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try budget.addBytes(chunk.count)
                    try output.write(contentsOf: chunk)
                }
                try fileManager.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: target.path)
                try protect(target)
            case .symbolicLink:
                throw WorkspaceError.symbolicLink(item.path)
            case .other:
                throw WorkspaceError.unsupportedItem(item.path)
            }
        }
    }
    #endif

    @discardableResult
    private func validateTree(at directory: URL) throws -> [String] {
        var aliases = Set<String>()
        var budget = TreeBudget(limits: treeLimits)
        return try validateTree(at: directory, relativePrefix: "", aliases: &aliases, budget: &budget)
    }

    private func validateTree(
        at directory: URL,
        relativePrefix: String,
        aliases: inout Set<String>,
        budget: inout TreeBudget
    ) throws -> [String] {
        try Task.checkCancellation()
        guard try itemKind(at: directory) == .directory else {
            throw WorkspaceError.unsupportedItem(relativePrefix)
        }
        var files: [String] = []
        for item in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            let relativePath = relativePrefix.isEmpty
                ? item.lastPathComponent
                : relativePrefix + "/" + item.lastPathComponent
            try budget.addEntry(relativePath)
            _ = try validatedRelativePath(relativePath)
            guard aliases.insert(canonicalPathKey(relativePath)).inserted else {
                throw WorkspaceError.duplicateRelativePath(relativePath)
            }
            switch try itemKind(at: item) {
            case .directory:
                files.append(contentsOf: try validateTree(
                    at: item,
                    relativePrefix: relativePath,
                    aliases: &aliases,
                    budget: &budget
                ))
            case .regularFile:
                let attributes = try fileManager.attributesOfItem(atPath: item.path)
                guard let size = attributes[.size] as? NSNumber,
                      size.uint64Value <= UInt64(Int.max) else { throw WorkspaceError.treeLimitExceeded }
                try budget.addBytes(size.intValue)
                files.append(relativePath)
            case .symbolicLink:
                throw WorkspaceError.symbolicLink(relativePath)
            case .other:
                throw WorkspaceError.unsupportedItem(relativePath)
            }
        }
        return files.sorted()
    }

    private func protectTree(at directory: URL) throws {
        try Task.checkCancellation()
        try protect(directory)
        for item in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try Task.checkCancellation()
            switch try itemKind(at: item) {
            case .directory:
                try protectTree(at: item)
            case .regularFile:
                try protect(item)
            case .symbolicLink:
                throw WorkspaceError.symbolicLink(item.path)
            case .other:
                throw WorkspaceError.unsupportedItem(item.path)
            }
        }
    }

    private func synchronizeTree(at item: URL) throws {
        try Task.checkCancellation()
        switch try itemKind(at: item) {
        case .directory:
            for child in try fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                try synchronizeTree(at: child)
            }
            try synchronizeDirectory(item)
        case .regularFile:
            try synchronizeFile(item)
        case .symbolicLink:
            throw WorkspaceError.symbolicLink(item.path)
        case .other:
            throw WorkspaceError.unsupportedItem(item.path)
        }
    }

    private func synchronizeFile(_ file: URL) throws {
        #if canImport(Darwin)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        #endif
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        #if canImport(Darwin)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        #endif
    }

    // MARK: - Filesystem primitives

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private func directoryIdentity(at url: URL) throws -> FileIdentity {
        #if canImport(Darwin)
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw WorkspaceError.invalidSource
        }
        return fileIdentity(status)
        #else
        guard try itemKind(at: url) == .directory else { throw WorkspaceError.invalidSource }
        return FileIdentity(device: 0, inode: UInt64(bitPattern: Int64(url.standardizedFileURL.path.hashValue)))
        #endif
    }

    #if canImport(Darwin)
    private func fileIdentity(_ status: stat) -> FileIdentity {
        FileIdentity(
            device: UInt64(bitPattern: Int64(status.st_dev)),
            inode: UInt64(status.st_ino)
        )
    }
    #endif

    private enum ItemKind {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    private func itemKind(at url: URL) throws -> ItemKind {
        guard let kind = try itemKindIfPresent(at: url) else {
            throw WorkspaceError.unsupportedItem(url.path)
        }
        return kind
    }

    private func itemKindIfPresent(at url: URL) throws -> ItemKind? {
        #if canImport(Darwin)
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        switch status.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regularFile
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
        #else
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { return .symbolicLink }
        if values.isDirectory == true { return .directory }
        if values.isRegularFile == true { return .regularFile }
        return .other
        #endif
    }

    private func readRegularFile(
        at url: URL,
        displayPath: String,
        maximumBytes: Int? = nil
    ) throws -> Data {
        #if canImport(Darwin)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw WorkspaceError.symbolicLink(displayPath) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw WorkspaceError.unsupportedItem(displayPath)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        if let maximumBytes {
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { throw WorkspaceError.corruptRevision }
            return data
        }
        return try handle.readToEnd() ?? Data()
        #else
        guard try itemKind(at: url) == .regularFile else {
            throw WorkspaceError.unsupportedItem(displayPath)
        }
        let data = try Data(contentsOf: url)
        if let maximumBytes, data.count > maximumBytes { throw WorkspaceError.corruptRevision }
        return data
        #endif
    }

    private func createProtectedDirectory(_ directory: URL) throws {
        if let kind = try itemKindIfPresent(at: directory) {
            if kind == .symbolicLink { throw WorkspaceError.symbolicLink(directory.path) }
            guard kind == .directory else { throw WorkspaceError.invalidRoot }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try protect(directory)
    }

    private func protect(_ url: URL) throws {
        let mode = try itemKind(at: url) == .directory || isExecutable(url) ? 0o700 : 0o600
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func isExecutable(_ url: URL) throws -> Bool {
        let permissions = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return (permissions?.intValue ?? 0) & 0o111 != 0
    }

    private func removeIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let ancestorPath = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == ancestorPath || candidatePath.hasPrefix(ancestorPath + "/")
    }
}
