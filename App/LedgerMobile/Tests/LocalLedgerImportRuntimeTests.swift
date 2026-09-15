import Foundation
import XCTest
@testable import LedgerMobile

final class LocalLedgerImportRuntimeTests: XCTestCase {
    private func fixture() async throws -> (LocalLedgerWorkspace, LocalLedgerWorkspace.Revision) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportRuntimeTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = LocalLedgerWorkspace(rootDirectory: root)
        let revision = try await workspace.create()
        return (workspace, revision)
    }

    private func source(_ root: URL, path: String, date: Date = Date()) throws -> URL {
        let directory = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("original")
        try Data("synthetic source".utf8).write(to: file)
        for item in [file, directory] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
        }
        return directory
    }

    func testRetentionRemovesExpiredCopiesAndPreservesRecentPreviewAndEveryLedger() async throws {
        let (workspace, revision) = try await fixture()
        let root = workspace.rootDirectory
        let now = Date()
        let expired = try source(root, path: "runtime/imports/expired", date: now.addingTimeInterval(-90_000))
        let scratch = try source(root, path: "runtime/scratch/imports/expired", date: now.addingTimeInterval(-90_000))
        let recent = try source(root, path: "runtime/imports/active", date: now.addingTimeInterval(-100))
        let generation = root.appendingPathComponent("generations/" + revision.id.uuidString)
        let historicalRuntime = try source(generation, path: "runtime/imports/old-copy")
        let ledger = generation.appendingPathComponent("workspace/main.bean")
        try Data("; historical ledger".utf8).write(to: ledger)
        let history = root.appendingPathComponent("runtime/bql-history.json")
        try Data("[]".utf8).write(to: history)
        try await workspace.maintainImportRuntime(now: now)
        for removed in [expired, scratch, historicalRuntime] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertEqual(try Data(contentsOf: ledger), Data("; historical ledger".utf8))
        XCTAssertEqual(try Data(contentsOf: history), Data("[]".utf8))
        let current = try await workspace.currentRevision()
        XCTAssertEqual(current, revision)
    }

    func testRuntimeCleanupIsIndependentOfLedgerTreeLimits() async throws {
        let (base, _) = try await fixture()
        let workspace = LocalLedgerWorkspace(rootDirectory: base.rootDirectory,
            treeLimits: .init(maximumEntries: 1, maximumBytes: 4, maximumDepth: 1))
        let current = try await workspace.currentRevision()
        let expired = try source(workspace.rootDirectory, path: "runtime/imports/expired",
            date: Date().addingTimeInterval(-90_000))
        let revision = try await workspace.commit(expectedRevisionID: current?.id,
            changes: [.write(Data("; ok".utf8), to: "main.bean")], mutateStage: { root in
                let runtime = root.deletingLastPathComponent().appendingPathComponent("runtime/imports/fixture")
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
                try Data("synthetic bill larger than the ledger quota".utf8)
                    .write(to: runtime.appendingPathComponent("original"))
            }, validator: { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.rootDirectory
            .appendingPathComponent("generations/" + revision.id.uuidString + "/runtime").path))
        let ledger = try await workspace.readFile(at: "main.bean")
        XCTAssertEqual(ledger, Data("; ok".utf8))
    }

    func testRejectedCommitRetainsPreviewAndSuccessfulRetryConsumesOnlyItsID() async throws {
        let (workspace, revision) = try await fixture()
        let original = try source(workspace.rootDirectory, path: "runtime/imports/retry")
        let other = try source(workspace.rootDirectory, path: "runtime/imports/other")
        do {
            _ = try await workspace.commit(expectedRevisionID: revision.id, changes: [], consumingImportID: "retry") { _ in
                throw LocalLedgerError.operationFailed("synthetic rejection")
            }
            XCTFail("Expected canonical rejection")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let committed = try await workspace.commit(expectedRevisionID: revision.id,
            changes: [.write(Data("; accepted".utf8), to: "main.bean")], consumingImportID: "retry") { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.rootDirectory
            .appendingPathComponent("generations/" + committed.id.uuidString + "/.consumed-import").path))
    }

    func testCleanupFailureAfterPublicationRetainsRetryMarkerAndPreservesSymlinkTarget() async throws {
        let (workspace, revision) = try await fixture()
        let external = try source(workspace.rootDirectory, path: "external-fixture")
        let runtime = workspace.rootDirectory.appendingPathComponent("runtime/imports")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let link = runtime.appendingPathComponent("retry")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let committed = try await workspace.commit(expectedRevisionID: revision.id,
            changes: [.write(Data("; accepted".utf8), to: "main.bean")], consumingImportID: "retry") { _ in }
        let marker = workspace.rootDirectory.appendingPathComponent("generations/" + committed.id.uuidString + "/.consumed-import")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("original")), Data("synthetic source".utf8))
        try FileManager.default.removeItem(at: link)
        try await workspace.maintainImportRuntime()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let current = try await workspace.currentRevision()
        XCTAssertEqual(current, committed)
    }

    private actor Gate {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testInFlightPreviewExcludesCleanupAndWritesAcrossWorkspaceInstances() async throws {
        let (workspace, revision) = try await fixture()
        let original = try source(workspace.rootDirectory, path: "runtime/imports/active")
        let gate = Gate()
        let preview = Task {
            try await workspace.withImportPreviewSnapshot { _, _ in await gate.wait() }
        }
        while !(await gate.started) { await Task.yield() }
        let other = LocalLedgerWorkspace(rootDirectory: workspace.rootDirectory)
        do {
            try await other.maintainImportRuntime(now: Date().addingTimeInterval(90_000))
            XCTFail("Cleanup overlapped a preview")
        } catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .transactionInProgress) }
        do {
            _ = try await other.commit(expectedRevisionID: revision.id, changes: []) { _ in }
            XCTFail("Write overlapped a preview")
        } catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .transactionInProgress) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        await gate.release()
        try await preview.value
        try await other.maintainImportRuntime(now: Date().addingTimeInterval(90_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }
}
