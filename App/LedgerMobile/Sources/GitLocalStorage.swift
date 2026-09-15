import Foundation
import CryptoKit
import Darwin

actor GitLocalStorage: LogicalLocalStorage {
    nonisolated let workspace: LocalLedgerWorkspace
    nonisolated let configuration: LocalGitConfiguration
    private let transport: any LocalGitTransport
    private let credentials: any LocalGitCredentialStoring
    private let syncRoot: URL
    private var synchronizing = false

    private struct State: Codable {
        var version = 1
        var baseCommit: String?
        var syncedRevisionID: UUID?
        var pendingRevisionID: UUID?
        var lastSyncedAt: Date?
        var failure: String?
        var conflictPaths: [String] = []
        var conflictAttemptID: UUID?
        var conflictLocalRevisionID: UUID?
        var conflictRemoteCommit: String?
    }
    private struct FetchResult: Decodable { let remoteHead: String; let branchExists: Bool }
    private struct CommitResult: Decodable { let commit: String }

    init(workspace: LocalLedgerWorkspace, configuration: LocalGitConfiguration,
         transport: any LocalGitTransport = EmbeddedLocalGitTransport(),
         credentials: any LocalGitCredentialStoring = DeviceLocalGitCredentialStore()) {
        self.workspace = workspace
        self.configuration = configuration
        self.transport = transport
        self.credentials = credentials
        syncRoot = workspace.rootDirectory.appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent(configuration.id.uuidString, isDirectory: true)
    }

    func didCommit(_ revision: LocalLedgerWorkspace.Revision) async {
        // current.json is the durable pending-write record. Deriving pending
        // status from its revision avoids competing state writes from another
        // provider while synchronization or conflict resolution is suspended.
    }

    func status() async throws -> LocalStorageSyncStatus {
        let state = try loadState()
        let current = try await workspace.currentRevision()
        let phase: LocalStorageSyncStatus.Phase
        if synchronizing { phase = .synchronizing }
        else if !state.conflictPaths.isEmpty { phase = .conflicted }
        else if state.failure != nil { phase = .failed }
        else if let current, state.syncedRevisionID == current.id { phase = .synced }
        else { phase = .pending }
        return .init(mode: .git, phase: phase, lastSyncedAt: state.lastSyncedAt,
            baseCommit: state.baseCommit, conflictPaths: state.conflictPaths, message: state.failure)
    }

    func synchronize(validator: @escaping LocalLedgerWorkspace.Validator) async throws -> LocalStorageSyncStatus {
        guard !synchronizing else { throw LocalStorageError.synchronizationInProgress }
        let lease = try SyncLease(directory: syncRoot)
        defer { lease.release() }
        try prepareProtectedLayout()
        defer { try? protectTree(syncRoot) }
        synchronizing = true
        defer { synchronizing = false }
        do {
            if try await workspace.currentRevision() != nil {
                try await workspace.withCurrentSnapshot { revision, root in
                    try await self.synchronizeSnapshot(revision: revision, localRoot: root, validator: validator)
                }
            } else {
                try await synchronizeSnapshot(revision: nil, localRoot: nil, validator: validator)
            }
            synchronizing = false
            return try await status()
        } catch {
            if var state = try? loadState() {
                state.failure = safeMessage(error)
                try? saveState(state)
            }
            throw error
        }
    }

    private func synchronizeSnapshot(revision: LocalLedgerWorkspace.Revision?, localRoot: URL?,
                                     validator: @escaping LocalLedgerWorkspace.Validator) async throws {
        var state = try loadState()
        let credential = try credentials.load(for: configuration.id)
        let fetch: FetchResult = try await request("fetch", credential: credential)
        let remoteCommit = fetch.branchExists ? fetch.remoteHead : ""
        let attemptID = UUID()
        let attempt = attemptsRoot.appendingPathComponent(attemptID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
        var retainAttempt = false
        defer { if !retainAttempt { try? FileManager.default.removeItem(at: attempt) } }
        let remoteRoot = attempt.appendingPathComponent("remote", isDirectory: true)
        try await export(commit: remoteCommit, to: remoteRoot)
        let baseRoot = attempt.appendingPathComponent("base", isDirectory: true)
        try await export(commit: state.baseCommit ?? "", to: baseRoot)
        let local = try localRoot.map(StorageTree.read) ?? [:]
        let remote = try StorageTree.read(remoteRoot)
        let base = try StorageTree.read(baseRoot)
        let merge = StorageTree.merge(base: base, local: local, remote: remote)
        if !merge.conflicts.isEmpty {
            let previousAttempt = state.conflictAttemptID
            if localRoot != nil {
                let conflictLocal = attempt.appendingPathComponent("local", isDirectory: true)
                try FileManager.default.createDirectory(at: conflictLocal, withIntermediateDirectories: true)
                try StorageTree.materialize(local, in: conflictLocal)
            }
            state.conflictPaths = merge.conflicts
            state.conflictAttemptID = attemptID
            state.conflictLocalRevisionID = revision?.id
            state.conflictRemoteCommit = remoteCommit
            state.failure = nil
            try saveState(state)
            retainAttempt = true
            discardAttempt(previousAttempt)
            throw LocalStorageError.conflicts(merge.conflicts)
        }
        let published: LocalLedgerWorkspace.Revision
        if let revision {
            if StorageTree.sameContents(local, merge.files) {
                guard try await workspace.currentRevision()?.id == revision.id else {
                    throw LocalLedgerWorkspace.WorkspaceError.staleRevision
                }
                published = revision
            } else {
                published = try await workspace.commit(expectedRevisionID: revision.id, changes: [], mutateStage: { stage in
                    try StorageTree.materialize(merge.files, in: stage)
                }, validator: validator)
            }
        } else {
            guard !remote.isEmpty else { throw LocalStorageError.emptyRepository }
            published = try await workspace.commit(changes: [], mutateStage: { stage in
                try StorageTree.materialize(remote, in: stage)
            }, validator: validator)
        }
        let matchesRemote = StorageTree.sameContents(merge.files, remote)
        let previousAttempt = state.conflictAttemptID
        state.baseCommit = remoteCommit.isEmpty ? nil : remoteCommit
        state.syncedRevisionID = matchesRemote ? published.id : nil
        state.pendingRevisionID = matchesRemote ? nil : published.id
        state.conflictPaths = []
        state.conflictAttemptID = nil
        state.conflictLocalRevisionID = nil
        state.conflictRemoteCommit = nil
        state.failure = nil
        // This base is durable before push. A failed or interrupted push leaves
        // local changes relative to the fetched remote tree for the next merge.
        try saveState(state)
        discardAttempt(previousAttempt)
        if !matchesRemote {
            let newCommit = try await workspace.withCurrentSnapshot { current, root in
                guard current.id == published.id else { throw LocalLedgerWorkspace.WorkspaceError.staleRevision }
                return try await self.commitAndPush(root: root, parent: remoteCommit, credential: credential)
            }
            state.baseCommit = newCommit
            state.syncedRevisionID = published.id
            state.pendingRevisionID = nil
        }
        state.lastSyncedAt = Date()
        try saveState(state)
    }

    func resolveConflicts(keepingLocal: Bool, validator: @escaping LocalLedgerWorkspace.Validator) async throws -> LocalStorageSyncStatus {
        guard !synchronizing else { throw LocalStorageError.synchronizationInProgress }
        let lease = try SyncLease(directory: syncRoot)
        defer { lease.release() }
        synchronizing = true
        defer { synchronizing = false }
        var state = try loadState()
        guard let attemptID = state.conflictAttemptID, let expected = state.conflictLocalRevisionID,
              !state.conflictPaths.isEmpty else { throw LocalStorageError.gitFailure("请先同步以读取当前冲突") }
        let attempt = attemptsRoot.appendingPathComponent(attemptID.uuidString)
        let remote = try StorageTree.read(attempt.appendingPathComponent("remote"))
        let base = try StorageTree.read(attempt.appendingPathComponent("base"))
        let published = try await workspace.withCurrentSnapshot { revision, localRoot in
            guard revision.id == expected else { throw LocalLedgerWorkspace.WorkspaceError.staleRevision }
            let local = try StorageTree.read(localRoot)
            let merged = StorageTree.merge(base: base, local: local, remote: remote, keepingLocalConflicts: keepingLocal)
            // Even a keep-local decision creates a validated generation, so
            // conflict acceptance and its expected revision have one commit point.
            return try await self.workspace.commit(expectedRevisionID: expected, changes: [], mutateStage: { stage in
                try StorageTree.materialize(merged.files, in: stage)
            }, validator: validator)
        }
        state.baseCommit = state.conflictRemoteCommit.flatMap { $0.isEmpty ? nil : $0 }
        state.syncedRevisionID = nil
        state.pendingRevisionID = published.id
        state.conflictPaths = []
        state.conflictAttemptID = nil
        state.conflictLocalRevisionID = nil
        state.conflictRemoteCommit = nil
        state.failure = nil
        try saveState(state)
        discardAttempt(attemptID)
        synchronizing = false
        return try await status()
    }

    func exportConflictVersions() async throws -> URL {
        let state = try loadState()
        guard let attemptID = state.conflictAttemptID else { throw LocalStorageError.gitFailure("当前没有待处理的冲突") }
        let source = attemptsRoot.appendingPathComponent(attemptID.uuidString)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerSyncConflict-" + UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: destination)
        try protectTree(destination)
        return destination
    }

    private func commitAndPush(root: URL, parent: String, credential: LocalGitCredential?) async throws -> String {
        // Imported folders can retain their original .git metadata locally.
        // Construct a dedicated immutable Git tree containing only ledger files.
        let snapshot = attemptsRoot.appendingPathComponent("push-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        try StorageTree.materialize(StorageTree.read(root), in: snapshot)
        try protectTree(snapshot)
        var commit = makeRequest("commit")
        commit.directory = snapshot.path
        commit.parent = parent
        commit.message = "Update local ledger"
        commit.authorName = "Ledger Mobile"
        commit.authorEmail = "ledger@localhost"
        let result = try JSONDecoder().decode(CommitResult.self, from: await transport.dispatch(commit))
        try protectTree(syncRoot)
        var push = makeRequest("push", credential: credential)
        push.commit = result.commit
        push.expectedRemoteHead = parent
        _ = try await transport.dispatch(push)
        try protectTree(syncRoot)
        return result.commit
    }
    private func export(commit: String, to directory: URL) async throws {
        if commit.isEmpty {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return
        }
        var request = makeRequest("export")
        request.commit = commit
        request.directory = directory.path
        _ = try await transport.dispatch(request)
        try protectTree(syncRoot)
    }
    private func request<T: Decodable>(_ operation: String, credential: LocalGitCredential?) async throws -> T {
        let data = try await transport.dispatch(makeRequest(operation, credential: credential))
        try protectTree(syncRoot)
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func makeRequest(_ operation: String, credential: LocalGitCredential? = nil) -> LocalGitRequest {
        LocalGitRequest(operation: operation, storageRoot: syncRoot.appendingPathComponent("repository.git").path,
            url: configuration.repositoryURL.absoluteString, branch: configuration.branch,
            username: credential?.username.isEmpty == false ? credential?.username : "x-access-token",
            password: credential?.token)
    }
    private var attemptsRoot: URL { syncRoot.appendingPathComponent("candidates", isDirectory: true) }
    private var stateURL: URL { syncRoot.appendingPathComponent("state.json") }
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
        try JSONEncoder().encode(state).write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        #endif
    }
    private func safeMessage(_ error: Error) -> String {
        var message = error.localizedDescription
        if let credential = try? credentials.load(for: configuration.id), !credential.token.isEmpty {
            message = message.replacingOccurrences(of: credential.token, with: "••••")
        }
        return message
    }
    private func prepareProtectedLayout() throws {
        for directory in [workspace.rootDirectory, syncRoot.deletingLastPathComponent(), syncRoot,
                          attemptsRoot, syncRoot.appendingPathComponent("repository.git", isDirectory: true)] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            #endif
        }
    }
    private func protectTree(_ directory: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            while let url = enumerator.nextObject() as? URL {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw LocalStorageError.unsafeFile(url.lastPathComponent)
                }
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            }
        }
        #endif
    }
}

private enum StorageTree {
    struct File: Sendable {
        let url: URL
        let digest: Data
        let size: Int
        let executable: Bool
    }
    struct Merge: Sendable {
        var files: [String: File]
        var conflicts: [String]
    }
    static func read(_ root: URL) throws -> [String: File] {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
            throw LocalStorageError.unsafeFile(root.lastPathComponent)
        }
        var files: [String: File] = [:], aliases = Set<String>()
        var count = 0, bytes = 0
        while let url = enumerator.nextObject() as? URL {
            let normalized = url.standardizedFileURL
            guard normalized.path.hasPrefix(root.path + "/") else { throw LocalStorageError.unsafeFile(url.lastPathComponent) }
            let path = String(normalized.path.dropFirst(root.path.count + 1))
            if path.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) {
                enumerator.skipDescendants(); continue
            }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard values.isSymbolicLink != true, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  aliases.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw LocalStorageError.unsafeFile(path)
            }
            count += 1
            guard count <= 10_000, components.count <= 32 else { throw LocalStorageError.treeLimitExceeded }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw LocalStorageError.unsafeFile(path) }
            let size = values.fileSize ?? 0
            guard size >= 0, size <= 64 * 1024 * 1024,
                  size <= 256 * 1024 * 1024 - bytes else { throw LocalStorageError.treeLimitExceeded }
            bytes += size
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            files[path] = File(url: url, digest: Data(digest.finalize()), size: size,
                executable: (permissions?.intValue ?? 0) & 0o111 != 0)
        }
        return files
    }
    private static func equal(_ lhs: File?, _ rhs: File?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (left?, right?): left.size == right.size && left.digest == right.digest && left.executable == right.executable
        default: false
        }
    }
    static func sameContents(_ lhs: [String: File], _ rhs: [String: File]) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { equal($0.value, rhs[$0.key]) }
    }
    static func merge(base: [String: File], local: [String: File], remote: [String: File],
                      keepingLocalConflicts: Bool? = nil) -> Merge {
        var merged: [String: File] = [:], conflicts: [String] = []
        for path in Set(base.keys).union(local.keys).union(remote.keys).sorted() {
            let ancestor = base[path], ours = local[path], theirs = remote[path]
            if equal(ours, theirs) { merged[path] = ours }
            else if equal(ours, ancestor) { merged[path] = theirs }
            else if equal(theirs, ancestor) { merged[path] = ours }
            else if let keepingLocalConflicts { merged[path] = keepingLocalConflicts ? ours : theirs }
            else { conflicts.append(path) }
        }
        // A directory/file collision across independently added paths is also a
        // conflict. Canonical validation must never see a partial mixed tree.
        let paths = Set(merged.keys)
        var structuralRoots = Set<String>()
        var foldedPaths: [String: String] = [:]
        for path in paths {
            let components = path.split(separator: "/")
            for depth in 1...components.count {
                let prefix = components.prefix(depth).joined(separator: "/")
                let folded = prefix.precomposedStringWithCanonicalMapping.lowercased()
                if let other = foldedPaths[folded], other != prefix {
                    conflicts.append(other); conflicts.append(prefix)
                    structuralRoots.insert(other); structuralRoots.insert(prefix)
                }
                foldedPaths[folded] = prefix
            }
            if components.count > 1 {
                for depth in 1..<components.count {
                    let ancestor = components.prefix(depth).joined(separator: "/")
                    if paths.contains(ancestor) {
                        conflicts.append(ancestor); conflicts.append(path)
                        structuralRoots.insert(ancestor)
                    }
                }
            }
        }
        if let keepingLocalConflicts, !structuralRoots.isEmpty {
            let selected = keepingLocalConflicts ? local : remote
            for root in structuralRoots {
                for path in Array(merged.keys) where path == root || path.hasPrefix(root + "/") { merged.removeValue(forKey: path) }
                for (path, file) in selected where path == root || path.hasPrefix(root + "/") { merged[path] = file }
            }
            conflicts = []
        }
        return Merge(files: merged, conflicts: Array(Set(conflicts)).sorted())
    }
    static func materialize(_ files: [String: File], in stage: URL) throws {
        var directories = Set<String>(), bytes = 0
        for (path, file) in files {
            guard file.size <= 256 * 1024 * 1024 - bytes else { throw LocalStorageError.treeLimitExceeded }
            bytes += file.size
            let components = path.split(separator: "/")
            for depth in 1..<components.count { directories.insert(components.prefix(depth).joined(separator: "/")) }
        }
        guard files.count + directories.count <= 10_000 else { throw LocalStorageError.treeLimitExceeded }
        // Only the workspace-owned staging copy is changed. Its parent generation
        // and every selected merge source remain immutable during materialization.
        for item in try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
            where item.lastPathComponent != ".git" {
            try FileManager.default.removeItem(at: item)
        }
        for (path, file) in files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let destination = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file.url, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: file.executable ? 0o700 : 0o600], ofItemAtPath: destination.path)
        }
    }
}

/// Serializes explicit sync operations across independently opened providers.
private final class SyncLease {
    private var descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent("sync.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LocalStorageError.gitFailure("无法锁定本地同步目录") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            throw LocalStorageError.synchronizationInProgress
        }
    }
    func release() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}
