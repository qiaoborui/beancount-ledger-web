import Foundation
import XCTest
@testable import LedgerMobile

final class LogicalLocalStorageTests: XCTestCase {
    private final class Credentials: LocalGitCredentialStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID: LocalGitCredential] = [:]
        func load(for id: UUID) throws -> LocalGitCredential? { lock.withLock { values[id] } }
        func save(_ credential: LocalGitCredential, for id: UUID) throws { lock.withLock { values[id] = credential } }
        func remove(for id: UUID) throws { _ = lock.withLock { values.removeValue(forKey: id) } }
        var count: Int { lock.withLock { values.count } }
    }
    private struct Engine: LocalLedgerEngine {
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            _ = try Data(contentsOf: URL(fileURLWithPath: request.workspaceRoot).appendingPathComponent(request.entrypoint))
            return Data("{}".utf8)
        }
    }
    private actor Git: LocalGitTransport {
        var commits: [String: [String: Data]]
        var parents: [String: String] = [:]
        var executablePaths: [String: Set<String>]
        var head: String
        var requests: [LocalGitRequest] = []
        var failingOperation: String?
        var fetchEntered: XCTestExpectation?
        var fetchContinuation: CheckedContinuation<Void, Never>?
        var pushEntered: XCTestExpectation?
        var pushContinuation: CheckedContinuation<Void, Never>?

        init(files: [String: String], executable: Set<String> = []) {
            commits = ["initial": files.mapValues { Data($0.utf8) }]
            executablePaths = ["initial": executable]
            head = files.isEmpty ? "" : "initial"
        }
        func setRemote(_ name: String, files: [String: String], executable: Set<String> = []) {
            commits[name] = files.mapValues { Data($0.utf8) }
            executablePaths[name] = executable
            head = name
        }
        func fail(_ operation: String?) { failingOperation = operation }
        func suspendFetch(_ expectation: XCTestExpectation) { fetchEntered = expectation }
        func releaseFetch() { fetchContinuation?.resume(); fetchContinuation = nil; fetchEntered = nil }
        func suspendPush(_ expectation: XCTestExpectation) { pushEntered = expectation }
        func releasePush() { pushContinuation?.resume(); pushContinuation = nil; pushEntered = nil }
        func contents() -> [String: Data] { commits[head] ?? [:] }
        func executableContents() -> Set<String> { executablePaths[head] ?? [] }
        func dispatch(_ request: LocalGitRequest) async throws -> Data {
            requests.append(request)
            if failingOperation == request.operation { throw LocalStorageError.gitFailure("offline") }
            switch request.operation {
            case "fetch":
                if let fetchEntered {
                    await withCheckedContinuation { fetchContinuation = $0; fetchEntered.fulfill() }
                }
                return try JSONSerialization.data(withJSONObject: ["remoteHead": head, "branchExists": !head.isEmpty])
            case "export":
                let directory = URL(fileURLWithPath: try XCTUnwrap(request.directory))
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let files = try XCTUnwrap(commits[try XCTUnwrap(request.commit)])
                for (path, data) in files {
                    let target = directory.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target)
                    let executable = executablePaths[request.commit ?? ""]?.contains(path) == true
                    try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: target.path)
                }
                return Data("{}".utf8)
            case "commit":
                let directory = URL(fileURLWithPath: try XCTUnwrap(request.directory))
                var files: [String: Data] = [:]
                var executable = Set<String>()
                let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
                while let url = enumerator.nextObject() as? URL {
                    if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                        let path = String(url.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1))
                        files[path] = try Data(contentsOf: url)
                        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                        if (permissions?.intValue ?? 0) & 0o111 != 0 { executable.insert(path) }
                    }
                }
                let commit = UUID().uuidString
                commits[commit] = files
                executablePaths[commit] = executable
                parents[commit] = request.parent ?? ""
                return try JSONSerialization.data(withJSONObject: ["commit": commit])
            case "push":
                if let pushEntered {
                    await withCheckedContinuation { pushContinuation = $0; pushEntered.fulfill() }
                }
                guard request.expectedRemoteHead == head,
                      parents[try XCTUnwrap(request.commit)] == head else {
                    throw LocalStorageError.gitFailure("remote changed")
                }
                head = try XCTUnwrap(request.commit)
                return try JSONSerialization.data(withJSONObject: ["remoteHead": head])
            default: throw LocalStorageError.gitFailure("unexpected test operation")
            }
        }
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LogicalLocalStorageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func catalog(_ root: URL, git: Git, credentials: Credentials = Credentials()) -> LocalLedgerCatalog {
        LocalLedgerCatalog(rootDirectory: root, engine: Engine(), gitTransport: git, gitCredentials: credentials,
            validator: { root, entry in
                if try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8).contains("INVALID") {
                    throw LocalLedgerError.operationFailed("canonical rejection")
                }
            })
    }
    private func imported(_ git: Git) async throws -> (LocalLedgerCatalog, LocalLedgerDescriptor, LocalLedgerRepository) {
        let catalog = catalog(try root(), git: git)
        let descriptor = try await catalog.importGit(repositoryURL: "https://git.example.com/ledger.git", name: "Git ledger")
        return (catalog, descriptor, catalog.repository(for: descriptor))
    }
    private func edit(_ repository: LocalLedgerRepository, path: String = "main.bean", text: String) async throws {
        let draft = try await repository.readFile(path: path)
        try await repository.saveFile(draft, text: text)
    }

    func testGitImportOnlyFetchesAndLocalWritesNeverUseNetwork() async throws {
        let git = Git(files: ["main.bean": "; original\n"])
        let (_, _, repository) = try await imported(git)
        let initial = try await repository.storageStatus()
        XCTAssertEqual(initial.phase, .synced)
        let requests = await git.requests
        XCTAssertEqual(requests.map(\.operation), ["fetch", "export"])
        try await edit(repository, text: "; local edit\n")
        let after = try await repository.storageStatus()
        XCTAssertEqual(after.phase, .pending)
        let afterRequests = await git.requests
        XCTAssertEqual(afterRequests.count, requests.count)
        let draft = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(draft.text, "; local edit\n")
    }

    func testThreeWayMergeCombinesIndependentFilesAndPushesExactRemoteParent() async throws {
        let git = Git(files: ["main.bean": "; base\n", "accounts.bean": "; base accounts\n"])
        let (_, _, repository) = try await imported(git)
        try await edit(repository, text: "; local\n")
        await git.setRemote("remote-two", files: ["main.bean": "; base\n", "accounts.bean": "; remote accounts\n"])
        let status = try await repository.synchronize()
        XCTAssertEqual(status.phase, .synced)
        let local = try await repository.readFile(path: "main.bean")
        let accounts = try await repository.readFile(path: "accounts.bean")
        XCTAssertEqual(local.text, "; local\n")
        XCTAssertEqual(accounts.text, "; remote accounts\n")
        let remote = await git.contents()
        XCTAssertEqual(remote["main.bean"], Data(local.text.utf8))
        XCTAssertEqual(remote["accounts.bean"], Data(accounts.text.utf8))
        let push = await git.requests.last(where: { $0.operation == "push" })
        XCTAssertEqual(push?.expectedRemoteHead, "remote-two")
    }

    func testSameFileConflictPreservesBothVersionsAndExplicitResolutionCanSync() async throws {
        let git = Git(files: ["main.bean": "; base\n"])
        let (_, _, repository) = try await imported(git)
        try await edit(repository, text: "; ours\n")
        let before = try await repository.workspace.currentRevision()
        await git.setRemote("remote-two", files: ["main.bean": "; theirs\n", "remote.bean": "; remote-only\n"])
        do { _ = try await repository.synchronize(); XCTFail("conflict accepted") }
        catch { XCTAssertEqual(error as? LocalStorageError, .conflicts(["main.bean"])) }
        let after = try await repository.workspace.currentRevision()
        XCTAssertEqual(before?.id, after?.id)
        let status = try await repository.storageStatus()
        XCTAssertEqual(status.phase, .conflicted)
        let exported = try await repository.exportSyncConflictVersions()
        defer { try? FileManager.default.removeItem(at: exported) }
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("local/main.bean"), encoding: .utf8), "; ours\n")
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("remote/main.bean"), encoding: .utf8), "; theirs\n")
        let resolved = try await repository.resolveSyncConflicts(keepingLocal: true)
        XCTAssertEqual(resolved.phase, .pending)
        let remoteOnly = try await repository.readFile(path: "remote.bean")
        XCTAssertEqual(remoteOnly.text, "; remote-only\n")
        let final = try await repository.synchronize()
        XCTAssertEqual(final.phase, .synced)
        let remote = await git.contents()
        XCTAssertEqual(remote["main.bean"], Data("; ours\n".utf8))
    }

    func testCanonicalRejectionOfRemoteTreePreservesLocalGeneration() async throws {
        let git = Git(files: ["main.bean": "; valid\n"])
        let (_, _, repository) = try await imported(git)
        let before = try await repository.workspace.currentRevision()
        await git.setRemote("bad", files: ["main.bean": "INVALID"])
        do { _ = try await repository.synchronize(); XCTFail("invalid remote published") }
        catch { XCTAssertEqual(error as? LocalLedgerError, .operationFailed("canonical rejection")) }
        let after = try await repository.workspace.currentRevision()
        XCTAssertEqual(before?.id, after?.id)
        let draft = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(draft.text, "; valid\n")
    }

    func testOfflineFetchAndPushFailuresKeepLocalWritesAndRetryableBase() async throws {
        let git = Git(files: ["main.bean": "; base\n"])
        let (_, _, repository) = try await imported(git)
        try await edit(repository, text: "; first local\n")
        await git.fail("fetch")
        do { _ = try await repository.synchronize(); XCTFail("offline fetch accepted") } catch {}
        try await edit(repository, text: "; second local\n")
        await git.fail("push")
        do { _ = try await repository.synchronize(); XCTFail("offline push accepted") } catch {}
        let failed = try await repository.storageStatus()
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.baseCommit, "initial")
        let draft = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(draft.text, "; second local\n")
        await git.fail(nil)
        let retried = try await repository.synchronize()
        XCTAssertEqual(retried.phase, .synced)
        let remote = await git.contents()
        XCTAssertEqual(remote["main.bean"], Data(draft.text.utf8))
    }

    func testLocalEditDuringFetchRejectsStaleMerge() async throws {
        let git = Git(files: ["main.bean": "; base\n", "accounts.bean": "; base\n"])
        let (_, _, repository) = try await imported(git)
        await git.setRemote("remote-two", files: ["main.bean": "; base\n", "accounts.bean": "; remote\n"])
        let entered = expectation(description: "fetch in flight")
        await git.suspendFetch(entered)
        let syncing = Task { try await repository.synchronize() }
        await fulfillment(of: [entered], timeout: 3)
        try await edit(repository, text: "; edited during fetch\n")
        await git.releaseFetch()
        do { _ = try await syncing.value; XCTFail("stale sync overwrote local edit") }
        catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
        let draft = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(draft.text, "; edited during fetch\n")
    }

    func testRemoteChangeDuringPushNeverForcesAndLeavesLocalReadable() async throws {
        let git = Git(files: ["main.bean": "; base\n"])
        let (_, _, repository) = try await imported(git)
        try await edit(repository, text: "; local\n")
        let entered = expectation(description: "push in flight")
        await git.suspendPush(entered)
        let syncing = Task { try await repository.synchronize() }
        await fulfillment(of: [entered], timeout: 3)
        await git.setRemote("raced", files: ["main.bean": "; remote racer\n"])
        await git.releasePush()
        do { _ = try await syncing.value; XCTFail("push overwrote newer remote") }
        catch { XCTAssertEqual(error as? LocalStorageError, .gitFailure("remote changed")) }
        let remote = await git.contents()
        XCTAssertEqual(remote["main.bean"], Data("; remote racer\n".utf8))
        let local = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(local.text, "; local\n")
    }

    func testConfigurationKeepsSameIdentityAndCredentialsWhileDisconnectPreservesLedger() async throws {
        let git = Git(files: [:]), credentials = Credentials()
        let catalog = catalog(try root(), git: git, credentials: credentials)
        let original = try await catalog.create(name: "Device ledger")
        let credential = LocalGitCredential(username: "person", token: "secret-test-token")
        let configured = try await catalog.configureGit(ledgerID: original.id,
            repositoryURL: "https://git.example.com/ledger.git", credential: credential)
        let same = try await catalog.configureGit(ledgerID: original.id, repositoryURL: "https://git.example.com/ledger.git")
        XCTAssertEqual(configured.git, same.git)
        XCTAssertEqual(try credentials.load(for: XCTUnwrap(same.git).id), credential)
        let json = String(decoding: try JSONEncoder().encode(same), as: UTF8.self)
        XCTAssertFalse(json.contains(credential.token))
        XCTAssertFalse(json.contains(credential.username))
        let disconnected = try await catalog.disconnectGit(ledgerID: original.id)
        XCTAssertNil(disconnected.git)
        XCTAssertNil(try credentials.load(for: XCTUnwrap(same.git).id))
        let draft = try await catalog.repository(for: disconnected).readFile(path: "main.bean")
        XCTAssertTrue(draft.text.contains("Device ledger"))
        let requests = await git.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLegacyDescriptorAndHTTPSConfigurationValidation() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Old\",\"entrypoint\":\"main.bean\",\"createdAt\":0}".utf8)
        XCTAssertNil(try JSONDecoder().decode(LocalLedgerDescriptor.self, from: data).git)
        for url in ["http://git.example.com/repo", "https://token@git.example.com/repo", "https://git.example.com/repo?token=secret", "file:///tmp/repo"] {
            XCTAssertThrowsError(try LocalGitConfiguration(repositoryURL: url))
        }
        for branch in ["../main", "main.lock", "bad branch", "refs//main", "a\\b"] {
            XCTAssertThrowsError(try LocalGitConfiguration(repositoryURL: "https://git.example.com/repo", branch: branch))
        }
    }

    func testInitialConnectionPreservesRemoteOnlyFiles() async throws {
        let git = Git(files: ["remote.bean": "; remote-only\n"])
        let catalog = catalog(try root(), git: git)
        let local = try await catalog.create(name: "Local")
        let configured = try await catalog.configureGit(ledgerID: local.id, repositoryURL: "https://git.example.com/ledger.git")
        let repository = catalog.repository(for: configured)
        let original = try await repository.readFile(path: "main.bean")
        let status = try await repository.synchronize()
        XCTAssertEqual(status.phase, .synced)
        let remote = await git.contents()
        XCTAssertEqual(remote["main.bean"], Data(original.text.utf8))
        XCTAssertEqual(remote["remote.bean"], Data("; remote-only\n".utf8))
    }

    func testLocalLedgerSavePreservesClonedExecutableScriptMode() async throws {
        let script = "scripts/check.sh"
        let git = Git(files: ["main.bean": "; base\n", script: "#!/bin/sh\n"], executable: [script])
        let (_, _, repository) = try await imported(git)
        try await edit(repository, text: "; local edit\n")
        _ = try await repository.synchronize()
        let executable = await git.executableContents()
        XCTAssertEqual(executable, [script])
        let permissions = try await repository.workspace.withCurrentSnapshot { _, root in
            try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(script).path)[.posixPermissions] as? NSNumber
        }
        XCTAssertEqual(permissions?.intValue, 0o700)
    }

    func testRemoteModeOnlyChangesPublishWithoutAnUnnecessaryPush() async throws {
        let script = "scripts/check.sh", files = ["main.bean": "; base\n", "scripts/check.sh": "#!/bin/sh\n"]
        let git = Git(files: files)
        let (_, _, repository) = try await imported(git)
        for (commit, executable) in [("executable", true), ("regular", false)] {
            await git.setRemote(commit, files: files, executable: executable ? [script] : [])
            let status = try await repository.synchronize()
            XCTAssertEqual(status.phase, .synced)
            XCTAssertEqual(status.baseCommit, commit)
            let (paths, permissions) = try await repository.workspace.withCurrentSnapshot { revision, root in
                let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(script).path)[.posixPermissions] as? NSNumber
                return (revision.changedPaths, permissions?.intValue)
            }
            XCTAssertEqual(paths, [script])
            XCTAssertEqual(permissions, executable ? 0o700 : 0o600)
        }
        let pushes = await git.requests.filter { $0.operation == "push" }
        XCTAssertTrue(pushes.isEmpty)
    }

    func testImportedExecutableAndAtomicReplacementKeepOnlyPrivatePermissions() async throws {
        let source = try root(), workspace = LocalLedgerWorkspace(rootDirectory: try root())
        let script = source.appendingPathComponent("check.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: script.path)
        let imported = try await workspace.importLedger(from: source) { _ in }
        _ = try await workspace.commit(expectedRevisionID: imported.id,
            changes: [.write(Data("#!/bin/sh\nexit 0\n".utf8), to: "check.sh")]) { _ in }
        let permissions = try await workspace.withCurrentSnapshot { _, root in
            try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("check.sh").path)[.posixPermissions] as? NSNumber
        }
        XCTAssertEqual(permissions?.intValue, 0o700)
        let sourcePermissions = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(sourcePermissions?.intValue, 0o777)
    }

    func testImportedGitMetadataStaysLocalAndIsExcludedFromPush() async throws {
        let git = Git(files: [:])
        let catalog = catalog(try root(), git: git)
        let source = try root()
        let metadata = source.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("private source config".utf8).write(to: metadata.appendingPathComponent("config"))
        try Data("; imported\n".utf8).write(to: source.appendingPathComponent("main.bean"))
        let local = try await catalog.importLedger(from: source, name: "Imported")
        let configured = try await catalog.configureGit(ledgerID: local.id, repositoryURL: "https://git.example.com/ledger.git")
        let repository = catalog.repository(for: configured)
        _ = try await repository.synchronize()
        let remote = await git.contents()
        XCTAssertEqual(Set(remote.keys), ["main.bean"])
        XCTAssertEqual(try String(contentsOf: metadata.appendingPathComponent("config"), encoding: .utf8), "private source config")
        let retained = try await repository.workspace.withCurrentSnapshot { _, root in
            try String(contentsOf: root.appendingPathComponent(".git/config"), encoding: .utf8)
        }
        XCTAssertEqual(retained, "private source config")
    }

    func testReopeningRestoresSyncBaseAndDerivesPendingFromCurrentRevision() async throws {
        let git = Git(files: ["main.bean": "; base\n"])
        let (catalog, descriptor, repository) = try await imported(git)
        let reopened = catalog.repository(for: descriptor)
        let initial = try await reopened.storageStatus()
        XCTAssertEqual(initial.phase, .synced)
        XCTAssertEqual(initial.baseCommit, "initial")
        try await edit(repository, text: "; next\n")
        let pending = try await reopened.storageStatus()
        XCTAssertEqual(pending.phase, .pending)
        _ = try await reopened.synchronize()
        let restored = try await catalog.repository(for: descriptor).storageStatus()
        XCTAssertEqual(restored.phase, .synced)
        XCTAssertNotEqual(restored.baseCommit, "initial")
        XCTAssertNotNil(restored.lastSyncedAt)
    }

    func testConflictResolutionRejectsLocalRevisionChangedSinceConflict() async throws {
        let git = Git(files: ["main.bean": "; base\n"])
        let (_, _, repository) = try await imported(git)
        try await edit(repository, text: "; ours\n")
        await git.setRemote("remote-two", files: ["main.bean": "; theirs\n"])
        do { _ = try await repository.synchronize(); XCTFail("conflict accepted") } catch {}
        try await edit(repository, text: "; newest local\n")
        let before = await git.requests.count
        do { _ = try await repository.resolveSyncConflicts(keepingLocal: false); XCTFail("stale resolution accepted") }
        catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
        let draft = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(draft.text, "; newest local\n")
        let after = await git.requests.count
        XCTAssertEqual(before, after)
    }

    func testStructuralFileDirectoryConflictResolvesEntireSelectedSubtree() async throws {
        for keepLocal in [true, false] {
            let git = Git(files: ["main.bean": "; base\n"])
            let (_, _, repository) = try await imported(git)
            let revision = try await repository.workspace.currentRevision()
            _ = try await repository.workspace.commit(expectedRevisionID: revision?.id,
                changes: [.write(Data("ours".utf8), to: "notes")]) { _ in }
            await git.setRemote("remote-two", files: ["main.bean": "; base\n", "notes/remote.txt": "theirs"])
            do { _ = try await repository.synchronize(); XCTFail("structural conflict accepted") }
            catch { XCTAssertEqual(error as? LocalStorageError, .conflicts(["notes", "notes/remote.txt"])) }
            _ = try await repository.resolveSyncConflicts(keepingLocal: keepLocal)
            _ = try await repository.synchronize()
            let remote = await git.contents()
            XCTAssertEqual(remote["notes"], keepLocal ? Data("ours".utf8) : nil)
            XCTAssertEqual(remote["notes/remote.txt"], keepLocal ? nil : Data("theirs".utf8))
        }
    }

    func testCaseAliasedDirectoriesConflictBeforePublishingMixedTree() async throws {
        for keepLocal in [true, false] {
            let git = Git(files: ["main.bean": "; base\n"])
            let (_, _, repository) = try await imported(git)
            let revision = try await repository.workspace.currentRevision()
            _ = try await repository.workspace.commit(expectedRevisionID: revision?.id,
                changes: [.write(Data("ours".utf8), to: "Notes/local.txt")]) { _ in }
            await git.setRemote("remote-two", files: ["main.bean": "; base\n", "notes/remote.txt": "theirs"])
            do { _ = try await repository.synchronize(); XCTFail("case alias conflict accepted") }
            catch { XCTAssertEqual(error as? LocalStorageError, .conflicts(["Notes", "notes"])) }
            _ = try await repository.resolveSyncConflicts(keepingLocal: keepLocal)
            _ = try await repository.synchronize()
            let remote = await git.contents()
            XCTAssertEqual(remote["Notes/local.txt"], keepLocal ? Data("ours".utf8) : nil)
            XCTAssertEqual(remote["notes/remote.txt"], keepLocal ? nil : Data("theirs".utf8))
        }
    }

    func testSeparateProvidersSerializeSyncWhileLocalWriteRemainsAvailable() async throws {
        let git = Git(files: ["main.bean": "; base\n"])
        let (catalog, descriptor, repository) = try await imported(git)
        let other = catalog.repository(for: descriptor)
        let entered = expectation(description: "first provider fetch")
        await git.suspendFetch(entered)
        let syncing = Task { try await repository.synchronize() }
        await fulfillment(of: [entered], timeout: 3)
        do { _ = try await other.synchronize(); XCTFail("concurrent provider sync accepted") }
        catch { XCTAssertEqual(error as? LocalStorageError, .synchronizationInProgress) }
        try await edit(other, text: "; concurrent local\n")
        await git.releaseFetch()
        do { _ = try await syncing.value; XCTFail("stale local snapshot accepted") }
        catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
        let draft = try await other.readFile(path: "main.bean")
        XCTAssertEqual(draft.text, "; concurrent local\n")
    }

    func testLocalEditDuringPushStaysPendingAfterPinnedRevisionIsPushed() async throws {
        let git = Git(files: ["main.bean": "; base\n"])
        let (_, _, repository) = try await imported(git)
        try await edit(repository, text: "; pushed\n")
        let entered = expectation(description: "push in flight")
        await git.suspendPush(entered)
        let syncing = Task { try await repository.synchronize() }
        await fulfillment(of: [entered], timeout: 3)
        try await edit(repository, text: "; later local\n")
        await git.releasePush()
        let status = try await syncing.value
        XCTAssertEqual(status.phase, .pending)
        let remote = await git.contents()
        XCTAssertEqual(remote["main.bean"], Data("; pushed\n".utf8))
        let local = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(local.text, "; later local\n")
    }

    func testFailedImportCleansOnlyNewDirectoryAndCredential() async throws {
        let git = Git(files: ["main.bean": "INVALID"]), credentials = Credentials()
        let directory = try root()
        let catalog = catalog(directory, git: git, credentials: credentials)
        let existing = try await catalog.create(name: "Preserved")
        do {
            _ = try await catalog.importGit(repositoryURL: "https://git.example.com/ledger.git", name: "Rejected",
                credential: .init(username: "person", token: "secret"))
            XCTFail("invalid import accepted")
        } catch { XCTAssertEqual(error as? LocalLedgerError, .operationFailed("canonical rejection")) }
        XCTAssertEqual(credentials.count, 0)
        let listed = try await catalog.list()
        XCTAssertEqual(listed.map(\.id), [existing.id])
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(children.map(\.lastPathComponent), [existing.id.uuidString])
    }

    func testCancelledImportCleansNewDirectoryAndCredential() async throws {
        let git = Git(files: ["main.bean": "; base\n"]), credentials = Credentials()
        let directory = try root()
        let catalog = catalog(directory, git: git, credentials: credentials)
        let entered = expectation(description: "import fetch")
        await git.suspendFetch(entered)
        let importing = Task {
            try await catalog.importGit(repositoryURL: "https://git.example.com/ledger.git", name: "Cancelled",
                credential: .init(username: "person", token: "secret"))
        }
        await fulfillment(of: [entered], timeout: 3)
        importing.cancel()
        await git.releaseFetch()
        do { _ = try await importing.value; XCTFail("cancelled import accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(credentials.count, 0)
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(children.isEmpty)
    }
}
