import Foundation
import XCTest
@testable import LedgerMobile

/// Staging cost and change detection for `LocalLedgerWorkspace.prepare` / `commit`:
/// the staged copy is an APFS clone (byte copy as fallback), and only files
/// whose stat moved after staging are compared or read.
final class LocalLedgerWorkspaceStagingTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLedgerWorkspaceStagingTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func seed(
        _ files: [String: String], cloning: Bool = true
    ) async throws -> (workspace: LocalLedgerWorkspace, revision: LocalLedgerWorkspace.Revision) {
        let workspace = LocalLedgerWorkspace(
            rootDirectory: try makeRoot().appendingPathComponent("managed"), usesFileCloning: cloning)
        let base = try await workspace.create()
        let revision = try await workspace.commit(
            expectedRevisionID: base.id,
            changes: files.sorted { $0.key < $1.key }.map { .write(Data($0.value.utf8), to: $0.key) },
            validator: { _ in })
        return (workspace, revision)
    }

    private func summary(_ prepared: LocalLedgerWorkspace.PreparedFiles) -> [String] {
        prepared.files.map { file in
            "\(file.path)|\(file.before.map { String(decoding: $0, as: UTF8.self) } ?? "∅")|"
                + "\(file.after.map { String(decoding: $0, as: UTF8.self) } ?? "∅")"
        }
    }

    private let sample = [
        "main.bean": "include \"a.bean\"\n",
        "a.bean": "2026-01-01 open Assets:Cash\n",
        "keep/b.bean": "2026-01-02 open Expenses:Food\n",
        "keep/c.bean": "; untouched\n",
        "gone.bean": "; to delete\n",
    ]

    /// The mutation touches: modify, add, delete, same-size edit, rewrite with
    /// identical bytes, and a no-op metadata touch.
    private static func mutate(_ root: URL) throws {
        try Data("include \"a.bean\"\n; edited\n".utf8).write(to: root.appendingPathComponent("main.bean"))
        try Data("2026-01-01 open Assets:Cash\n".utf8)
            .write(to: root.appendingPathComponent("a.bean"))                       // identical rewrite
        try Data("2026-01-02 open Expenses:Fund\n".utf8)
            .write(to: root.appendingPathComponent("keep/b.bean"))                  // same length edit
        try Data("; new\n".utf8).write(to: root.appendingPathComponent("added.bean"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.bean"))
        try FileManager.default.setAttributes([.modificationDate: Date()],
            ofItemAtPath: root.appendingPathComponent("keep/c.bean").path)          // touch only
    }

    func testStagingClonesRegularFilesOnApfs() async throws {
        let (workspace, revision) = try await seed(sample)
        let before = await workspace.copyStatistics
        _ = try await workspace.prepare(expectedRevisionID: revision.id, mutateStage: { _ in }, validator: { _ in })
        let after = await workspace.copyStatistics
        let cloned = after.cloned - before.cloned
        let copied = after.copied - before.copied
        if cloned == 0 { throw XCTSkip("volume under test does not support clonefile") }
        XCTAssertEqual(cloned, sample.count)
        XCTAssertEqual(copied, 0)
    }

    func testFallbackByteCopyWhenCloningDisabled() async throws {
        let (workspace, revision) = try await seed(sample, cloning: false)
        let before = await workspace.copyStatistics
        let prepared = try await workspace.prepare(expectedRevisionID: revision.id,
            mutateStage: { try Self.mutate($0) }, validator: { _ in })
        let after = await workspace.copyStatistics
        XCTAssertEqual(after.cloned, before.cloned)
        XCTAssertEqual(after.copied - before.copied, sample.count)
        XCTAssertEqual(prepared.files.count, 4)
    }

    func testCloneAndFallbackProduceIdenticalPreparedFiles() async throws {
        let cloned = try await seed(sample, cloning: true)
        let copied = try await seed(sample, cloning: false)
        let a = try await cloned.workspace.prepare(expectedRevisionID: cloned.revision.id,
            mutateStage: { try Self.mutate($0) }, validator: { _ in })
        let b = try await copied.workspace.prepare(expectedRevisionID: copied.revision.id,
            mutateStage: { try Self.mutate($0) }, validator: { _ in })
        XCTAssertEqual(summary(a), summary(b))
    }

    func testChangeDetectionReportsAddModifyDeleteAndSkipsUnchanged() async throws {
        let (workspace, revision) = try await seed(sample)
        let prepared = try await workspace.prepare(expectedRevisionID: revision.id,
            mutateStage: { try Self.mutate($0) }, validator: { _ in })
        XCTAssertEqual(summary(prepared), [
            "added.bean|∅|; new\n",
            "gone.bean|; to delete\n|∅",
            "keep/b.bean|2026-01-02 open Expenses:Food\n|2026-01-02 open Expenses:Fund\n",
            "main.bean|include \"a.bean\"\n|include \"a.bean\"\n; edited\n",
        ])
        XCTAssertEqual(prepared.changes.count, 4)
    }

    func testNoMutationYieldsNoChanges() async throws {
        let (workspace, revision) = try await seed(sample)
        let prepared = try await workspace.prepare(expectedRevisionID: revision.id,
            mutateStage: { _ in }, validator: { _ in })
        XCTAssertTrue(prepared.files.isEmpty)
    }

    /// A clone is a distinct inode: editing the staged file in place must not
    /// leak into the immutable parent generation (as it would with a hard link).
    func testInPlaceWriteToStagedCloneLeavesParentGenerationIntact() async throws {
        let (workspace, revision) = try await seed(sample)
        let prepared = try await workspace.prepare(expectedRevisionID: revision.id, mutateStage: { root in
            let handle = try FileHandle(forWritingTo: root.appendingPathComponent("main.bean"))
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data("XXXXXXX".utf8))
        }, validator: { _ in })
        XCTAssertEqual(prepared.files.map(\.path), ["main.bean"])
        let stored = try await workspace.readFile(at: "main.bean")
        XCTAssertEqual(stored, Data(sample["main.bean"]!.utf8))
        let latest = try await workspace.currentRevision()
        XCTAssertEqual(latest, revision)
    }

    func testCommitRecordsSamePathsWithCloneAndFallback() async throws {
        var results: [[String]] = []
        for cloning in [true, false] {
            let (workspace, revision) = try await seed(sample, cloning: cloning)
            let committed = try await workspace.commit(expectedRevisionID: revision.id, changes: [],
                mutateStage: { try Self.mutate($0) }, validator: { _ in })
            results.append(committed.changedPaths)
        }
        XCTAssertEqual(results[0], ["added.bean", "gone.bean", "keep/b.bean", "main.bean"])
        XCTAssertEqual(results[0], results[1])
    }

    func testStagingStillRejectsSymbolicLinksAndTreeLimits() async throws {
        let (workspace, revision) = try await seed(sample)
        let root = workspace.rootDirectory
        let generation = root.appendingPathComponent("generations/\(revision.id.uuidString)/workspace")
        try FileManager.default.createSymbolicLink(
            at: generation.appendingPathComponent("link.bean"),
            withDestinationURL: generation.appendingPathComponent("main.bean"))
        do {
            _ = try await workspace.prepare(expectedRevisionID: revision.id, mutateStage: { _ in }, validator: { _ in })
            XCTFail("symlink must be rejected")
        } catch {}

        let limited = LocalLedgerWorkspace(
            rootDirectory: try makeRoot().appendingPathComponent("limited"),
            treeLimits: .init(maximumEntries: 10_000, maximumBytes: 64, maximumDepth: 32))
        let base = try await limited.create()
        let first = try await limited.commit(expectedRevisionID: base.id,
            changes: [.write(Data(repeating: 65, count: 40), to: "a.bean")], validator: { _ in })
        do {
            _ = try await limited.prepare(expectedRevisionID: first.id, mutateStage: { root in
                try Data(repeating: 66, count: 40).write(to: root.appendingPathComponent("b.bean"))
            }, validator: { _ in })
            XCTFail("byte budget must be enforced after mutation")
        } catch {
            XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .treeLimitExceeded)
        }
    }

    /// Rough A/B timing on a synthetic ledger. Prints, never asserts a ratio.
    func testSyntheticLedgerStagingTiming() async throws {
        let count = 3_000
        var files: [String: String] = [:]
        let body = String(repeating: "2026-01-01 * \"payee\" \"narration\"\n  Assets:Cash  1.00 CNY\n  Expenses:Food\n", count: 40)
        for index in 0..<count { files[String(format: "transactions/%04d/f%05d.bean", index / 100, index)] = body }
        var report: [String] = []
        for cloning in [false, true] {
            let (workspace, revision) = try await seed(files, cloning: cloning)
            var samples: [Double] = []
            var current = revision
            for run in 0..<3 {
                let started = Date()
                let prepared = try await workspace.prepare(expectedRevisionID: current.id, mutateStage: { root in
                    try Data("; run \(run)\n".utf8).write(to: root.appendingPathComponent("transactions/0000/f00000.bean"))
                }, validator: { _ in })
                samples.append(Date().timeIntervalSince(started))
                XCTAssertEqual(prepared.files.map(\.path), ["transactions/0000/f00000.bean"])
            }
            _ = current
            current = revision
            report.append(String(format: "%@ files=%d prepare ms=%@", cloning ? "clone   " : "bytecopy", count,
                samples.map { String(format: "%.0f", $0 * 1000) }.joined(separator: "/")))
        }
        print("[staging-timing] " + report.joined(separator: " | "))
    }
}
