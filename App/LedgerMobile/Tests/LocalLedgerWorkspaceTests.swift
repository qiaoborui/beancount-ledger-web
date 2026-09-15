import Foundation
import XCTest
@testable import LedgerMobile

final class LocalLedgerWorkspaceTests: XCTestCase {
    private enum TestError: Error {
        case rejected
    }

    private func fixture() throws -> (root: URL, workspace: LocalLedgerWorkspace) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLedgerWorkspaceTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, LocalLedgerWorkspace(rootDirectory: root.appendingPathComponent("managed")))
    }

    func testCreatePersistsAnEmptyCurrentGeneration() async throws {
        let fixture = try fixture()
        let revision = try await fixture.workspace.create()
        let currentRevision = try await fixture.workspace.currentRevision()

        XCTAssertEqual(revision.version, LocalLedgerWorkspace.Revision.schemaVersion)
        XCTAssertNil(revision.parentID)
        XCTAssertEqual(revision.changedPaths, [])
        XCTAssertEqual(currentRevision, revision)
        let currentContents = try await fixture.workspace.withCurrentSnapshot { _, directory in
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
        }
        XCTAssertEqual(currentContents, [])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.workspace.rootDirectory.appendingPathComponent("current.json").path
        ))
    }

    func testPublishedGenerationDiscardsStagedImportRuntime() async throws {
        let fixture = try fixture()
        let original = try await fixture.workspace.create()
        let revision = try await fixture.workspace.commit(expectedRevisionID: original.id,
            changes: [.write(Data("; ledger".utf8), to: "main.bean")], mutateStage: { root in
                let runtime = root.deletingLastPathComponent().appendingPathComponent("runtime/imports/fixture")
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
                try Data("synthetic raw statement".utf8).write(to: runtime.appendingPathComponent("original"))
            }, validator: { _ in })
        let generation = fixture.workspace.rootDirectory.appendingPathComponent("generations/" + revision.id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: generation.appendingPathComponent("runtime").path))
        XCTAssertEqual(try Data(contentsOf: generation.appendingPathComponent("workspace/main.bean")), Data("; ledger".utf8))
    }

    func testStalePreviewCannotOverwriteNewerCommitOrImportReplacement() async throws {
        let fixture = try fixture()
        let base = try await fixture.workspace.create()
        let other = LocalLedgerWorkspace(rootDirectory: fixture.workspace.rootDirectory)
        let latest = try await other.commit(
            expectedRevisionID: base.id,
            changes: [.write(Data("latest".utf8), to: "main.bean")],
            validator: { _ in }
        )
        let source = fixture.root.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: source.appendingPathComponent("main.bean"))

        for expectedID in [base.id, nil] {
            do {
                _ = try await fixture.workspace.commit(
                    expectedRevisionID: expectedID,
                    changes: [.write(Data("stale".utf8), to: "main.bean")]
                ) { _ in XCTFail("Stale changes reached validation") }
                XCTFail("Expected stale revision")
            } catch let error as LocalLedgerWorkspace.WorkspaceError {
                XCTAssertEqual(error, .staleRevision)
            }
            do {
                _ = try await fixture.workspace.importLedger(from: source, expectedRevisionID: expectedID) { _ in
                    XCTFail("Stale replacement reached validation")
                }
                XCTFail("Expected stale revision")
            } catch let error as LocalLedgerWorkspace.WorkspaceError {
                XCTAssertEqual(error, .staleRevision)
            }
        }
        let current = try await fixture.workspace.currentRevision()
        let contents = try await fixture.workspace.readFile(at: "main.bean")
        XCTAssertEqual(current, latest)
        XCTAssertEqual(contents, Data("latest".utf8))
        let replaced = try await fixture.workspace.importLedger(from: source, expectedRevisionID: latest.id) { _ in }
        XCTAssertEqual(replaced.parentID, latest.id)
    }

    func testImportBoundsCumulativeEntriesBytesAndDepthBeforeValidation() async throws {
        let fixture = try fixture()
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("123".utf8).write(to: source.appendingPathComponent("one.bean"))
        try Data("456".utf8).write(to: source.appendingPathComponent("nested/two.bean"))

        let limits: [LocalLedgerWorkspace.TreeLimits] = [
            .init(maximumEntries: 2, maximumBytes: 6, maximumDepth: 2),
            .init(maximumEntries: 3, maximumBytes: 5, maximumDepth: 2),
            .init(maximumEntries: 3, maximumBytes: 6, maximumDepth: 1),
        ]
        for (index, limit) in limits.enumerated() {
            let workspace = LocalLedgerWorkspace(
                rootDirectory: fixture.root.appendingPathComponent("limited-\(index)"),
                treeLimits: limit
            )
            let original = try await workspace.create()
            do {
                _ = try await workspace.importLedger(from: source, expectedRevisionID: original.id) { _ in
                    XCTFail("Oversized source reached validation")
                }
                XCTFail("Expected tree limit")
            } catch let error as LocalLedgerWorkspace.WorkspaceError {
                XCTAssertEqual(error, .treeLimitExceeded)
            }
            let current = try await workspace.currentRevision()
            XCTAssertEqual(current, original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:
                workspace.rootDirectory.appendingPathComponent("staging").path), [])
        }
        let exact = LocalLedgerWorkspace(
            rootDirectory: fixture.root.appendingPathComponent("exact"),
            treeLimits: .init(maximumEntries: 3, maximumBytes: 6, maximumDepth: 2)
        )
        _ = try await exact.importLedger(from: source) { _ in }
        let exactFile = try await exact.readFile(at: "nested/two.bean")
        XCTAssertEqual(exactFile, Data("456".utf8))
    }

    func testOversizedRevisionMetadataFailsBeforePublishingGeneration() async throws {
        let fixture = try fixture()
        let original = try await fixture.workspace.create()
        let changes = (0..<6_000).map { index in
            LocalLedgerWorkspace.Change.remove(String(repeating: "a", count: 190) + "\(index).bean")
        }
        do {
            _ = try await fixture.workspace.commit(
                expectedRevisionID: original.id, changes: changes, validator: { _ in }
            )
            XCTFail("Expected revision size limit")
        } catch let error as LocalLedgerWorkspace.WorkspaceError {
            XCTAssertEqual(error, .revisionTooLarge)
        }
        let current = try await fixture.workspace.currentRevision()
        XCTAssertEqual(current, original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:
            fixture.workspace.rootDirectory.appendingPathComponent("generations").path), [original.id.uuidString])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:
            fixture.workspace.rootDirectory.appendingPathComponent("staging").path), [])
    }

    func testImportCopiesNestedRegularFilesAndRecordsRevision() async throws {
        let fixture = try fixture()
        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("transactions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("include \"transactions/2026.bean\"".utf8)
            .write(to: source.appendingPathComponent("main.bean"))
        try Data("2026-09-15 * \"Coffee\"".utf8)
            .write(to: source.appendingPathComponent("transactions/2026.bean"))

        let revision = try await fixture.workspace.importLedger(from: source) { _ in }
        let mainFile = try await fixture.workspace.readFile(at: "main.bean")
        let currentRevision = try await fixture.workspace.currentRevision()

        XCTAssertNil(revision.parentID)
        XCTAssertEqual(revision.changedPaths, ["main.bean", "transactions/2026.bean"])
        XCTAssertEqual(mainFile, Data("include \"transactions/2026.bean\"".utf8))
        XCTAssertEqual(currentRevision, revision)
    }

    func testCommitAppliesAllChangesAsOneGeneration() async throws {
        let fixture = try fixture()
        let first = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [
                .write(Data("old".utf8), to: "main.bean"),
                .write(Data("remove me".utf8), to: "notes.txt"),
            ],
            validator: { _ in }
        )

        let second = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [
                .write(Data("new".utf8), to: "main.bean"),
                .write(Data("account Assets:Cash".utf8), to: "accounts/cash.bean"),
                .remove("notes.txt"),
            ],
            validator: { _ in }
        )
        let mainFile = try await fixture.workspace.readFile(at: "main.bean")
        let accountFile = try await fixture.workspace.readFile(at: "accounts/cash.bean")

        XCTAssertEqual(second.parentID, first.id)
        XCTAssertEqual(second.changedPaths, ["accounts/cash.bean", "main.bean", "notes.txt"])
        XCTAssertEqual(mainFile, Data("new".utf8))
        XCTAssertEqual(accountFile, Data("account Assets:Cash".utf8))
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.workspace.readFile(at: "notes.txt")
        }
    }

    func testRejectsUnsafeAndDuplicateRelativePaths() async throws {
        let fixture = try fixture()
        let invalid = ["", "/main.bean", "../main.bean", "a/../main.bean", "a//main.bean", "a\\main.bean", "./main.bean"]

        for path in invalid {
            await XCTAssertThrowsErrorAsync(path) {
                _ = try await fixture.workspace.commit(
                    expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                    changes: [.write(Data(), to: path)],
                    validator: { _ in }
                )
            }
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.workspace.commit(
                expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                changes: [
                    .write(Data("one".utf8), to: "main.bean"),
                    .write(Data("two".utf8), to: "main.bean"),
                ],
                validator: { _ in }
            )
        }
        let currentRevision = try await fixture.workspace.currentRevision()
        XCTAssertNil(currentRevision)
    }

    func testRejectsCaseAndUnicodeEquivalentPathAliases() async throws {
        let fixture = try fixture()
        let aliases = [
            ("Accounts/Cash.bean", "accounts/cash.bean"),
            ("caf\u{00E9}.bean", "cafe\u{0301}.bean"),
        ]

        for (first, second) in aliases {
            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.workspace.commit(
                    expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                    changes: [
                        .write(Data("one".utf8), to: first),
                        .write(Data("two".utf8), to: second),
                    ],
                    validator: { _ in }
                )
            }
        }
        let currentRevision = try await fixture.workspace.currentRevision()
        XCTAssertNil(currentRevision)
    }

    func testRejectsAnyImportSourceOverlappingManagedWorkspace() async throws {
        let fixture = try fixture()
        _ = try await fixture.workspace.create()
        let managedSources = [
            fixture.root,
            fixture.workspace.rootDirectory,
            fixture.workspace.rootDirectory.appendingPathComponent("staging"),
            fixture.workspace.rootDirectory.appendingPathComponent("generations"),
        ]

        for source in managedSources {
            await XCTAssertThrowsErrorAsync(source.path) {
                _ = try await fixture.workspace.importLedger(from: source) { _ in }
            }
        }

        let staging = fixture.workspace.rootDirectory.appendingPathComponent("staging")
        let stagingItems = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        XCTAssertEqual(stagingItems, [])
    }

    func testRejectsSymlinksDuringImportAndGenerationCopy() async throws {
        let fixture = try fixture()
        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        let outside = fixture.root.appendingPathComponent("outside.bean")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("main.bean"),
            withDestinationURL: outside
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.workspace.importLedger(from: source) { _ in }
        }
        let revisionAfterRejectedImport = try await fixture.workspace.currentRevision()
        XCTAssertNil(revisionAfterRejectedImport)

        try FileManager.default.removeItem(at: source.appendingPathComponent("main.bean"))
        try Data("safe".utf8).write(to: source.appendingPathComponent("main.bean"))
        _ = try await fixture.workspace.importLedger(from: source) { _ in }
        try await fixture.workspace.withCurrentSnapshot { _, directory in
            try FileManager.default.createSymbolicLink(
                at: directory.appendingPathComponent("escape.bean"),
                withDestinationURL: outside
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.workspace.commit(
                expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                changes: [.write(Data("changed".utf8), to: "main.bean")],
                validator: { _ in }
            )
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testPinnedDirectoryDescriptorPreventsAncestorSwapEscape() async throws {
        let fixture = try fixture()
        let source = fixture.root.appendingPathComponent("source")
        let inside = source.appendingPathComponent("inside")
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: inside.appendingPathComponent("main.bean"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("main.bean"))
        let pinnedLocation = source.appendingPathComponent("pinned-after-swap")
        let workspace = LocalLedgerWorkspace(
            rootDirectory: fixture.root.appendingPathComponent("managed-openat")
        ) { relativePath in
            guard relativePath == "inside/main.bean" else { return }
            try FileManager.default.moveItem(at: inside, to: pinnedLocation)
            try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside)
        }

        _ = try await workspace.importLedger(from: source) { _ in }

        let imported = try await workspace.readFile(at: "inside/main.bean")
        XCTAssertEqual(imported, Data("safe".utf8))
    }

    func testValidationFailureKeepsCurrentRevisionAndRemovesStaging() async throws {
        let fixture = try fixture()
        let first = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [.write(Data("valid".utf8), to: "main.bean")],
            validator: { _ in }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.workspace.commit(
                expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                changes: [.write(Data("invalid".utf8), to: "main.bean")]
            ) { _ in
                throw TestError.rejected
            }
        }

        let currentRevision = try await fixture.workspace.currentRevision()
        let mainFile = try await fixture.workspace.readFile(at: "main.bean")
        XCTAssertEqual(currentRevision, first)
        XCTAssertEqual(mainFile, Data("valid".utf8))
        let staging = fixture.workspace.rootDirectory.appendingPathComponent("staging")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testCancellationKeepsCurrentRevisionAndRemovesStaging() async throws {
        let fixture = try fixture()
        let first = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [.write(Data("valid".utf8), to: "main.bean")],
            validator: { _ in }
        )
        let task = Task {
            try await fixture.workspace.commit(
                expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                changes: [.write(Data("cancelled".utf8), to: "main.bean")]
            ) { _ in
                try await Task.sleep(for: .seconds(30))
            }
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let currentRevision = try await fixture.workspace.currentRevision()
        let mainFile = try await fixture.workspace.readFile(at: "main.bean")
        XCTAssertEqual(currentRevision, first)
        XCTAssertEqual(mainFile, Data("valid".utf8))
        let staging = fixture.workspace.rootDirectory.appendingPathComponent("staging")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testSeparateWorkspaceActorsCannotPublishConcurrentGenerations() async throws {
        let fixture = try fixture()
        _ = try await fixture.workspace.create()
        let secondWorkspace = LocalLedgerWorkspace(rootDirectory: fixture.workspace.rootDirectory)
        let gate = WorkspaceValidatorGate()
        let firstCommit = Task {
            try await fixture.workspace.commit(
                expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                changes: [.write(Data("first".utf8), to: "main.bean")]
            ) { _ in
                await gate.hold()
            }
        }
        await gate.waitUntilEntered()

        do {
            _ = try await secondWorkspace.commit(
                expectedRevisionID: try await secondWorkspace.currentRevision()?.id,
                changes: [.write(Data("second".utf8), to: "main.bean")],
                validator: { _ in }
            )
            XCTFail("Expected the filesystem transaction lock")
        } catch let error as LocalLedgerWorkspace.WorkspaceError {
            XCTAssertEqual(error, .transactionInProgress)
        }

        await gate.release()
        _ = try await firstCommit.value
        let mainFile = try await fixture.workspace.readFile(at: "main.bean")
        XCTAssertEqual(mainFile, Data("first".utf8))
    }

    func testScopedSnapshotRemainsPinnedAcrossANewerCommit() async throws {
        let fixture = try fixture()
        let original = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [.write(Data("original".utf8), to: "main.bean")],
            validator: { _ in }
        )
        let gate = WorkspaceValidatorGate()
        let reading = Task {
            try await fixture.workspace.withCurrentSnapshot { revision, directory in
                await gate.hold()
                return (
                    revision,
                    try Data(contentsOf: directory.appendingPathComponent("main.bean"))
                )
            }
        }
        await gate.waitUntilEntered()

        let latest = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [.write(Data("latest".utf8), to: "main.bean")],
            validator: { _ in }
        )
        await gate.release()
        let (snapshotRevision, snapshotFile) = try await reading.value
        let currentRevision = try await fixture.workspace.currentRevision()

        XCTAssertEqual(snapshotRevision, original)
        XCTAssertEqual(snapshotFile, Data("original".utf8))
        XCTAssertEqual(currentRevision, latest)
    }

    func testRecoveryRefusesToWriteWhileAnotherInstanceOwnsRootLock() async throws {
        let fixture = try fixture()
        _ = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [.write(Data("old".utf8), to: "main.bean")],
            validator: { _ in }
        )
        let gate = WorkspaceValidatorGate()
        let publishing = Task {
            try await fixture.workspace.commit(
                expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                changes: [.write(Data("new".utf8), to: "main.bean")]
            ) { _ in
                await gate.hold()
            }
        }
        await gate.waitUntilEntered()
        let pointer = fixture.workspace.rootDirectory.appendingPathComponent("current.json")
        try FileManager.default.removeItem(at: pointer)
        let reader = LocalLedgerWorkspace(rootDirectory: fixture.workspace.rootDirectory)

        do {
            _ = try await reader.currentRevision()
            XCTFail("Expected recovery to honor the root lock")
        } catch let error as LocalLedgerWorkspace.WorkspaceError {
            XCTAssertEqual(error, .transactionInProgress)
        }

        await gate.release()
        let published = try await publishing.value
        let reread = try await reader.currentRevision()
        let mainFile = try await reader.readFile(at: "main.bean")
        XCTAssertEqual(reread, published)
        XCTAssertEqual(mainFile, Data("new".utf8))
    }

    func testRecoversLatestGenerationFromCorruptOrMissingCurrentPointer() async throws {
        let fixture = try fixture()
        _ = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [.write(Data("first".utf8), to: "main.bean")],
            validator: { _ in }
        )
        let latest = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [.write(Data("latest".utf8), to: "main.bean")],
            validator: { _ in }
        )
        let pointer = fixture.workspace.rootDirectory.appendingPathComponent("current.json")

        try Data("{truncated".utf8).write(to: pointer)
        let recoveredFromCorruption = try await fixture.workspace.currentRevision()
        let recoveredFile = try await fixture.workspace.readFile(at: "main.bean")
        XCTAssertEqual(recoveredFromCorruption, latest)
        XCTAssertEqual(recoveredFile, Data("latest".utf8))

        try FileManager.default.removeItem(at: pointer)
        let recoveredFromMissingPointer = try await fixture.workspace.currentRevision()
        XCTAssertEqual(recoveredFromMissingPointer, latest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pointer.path))

        let outside = fixture.root.appendingPathComponent("outside.json")
        try Data("preserve me".utf8).write(to: outside)
        try FileManager.default.removeItem(at: pointer)
        try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: outside)
        let recoveredFromSymlink = try await fixture.workspace.currentRevision()
        XCTAssertEqual(recoveredFromSymlink, latest)
        XCTAssertEqual(try Data(contentsOf: outside), Data("preserve me".utf8))
        let pointerValues = try pointer.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(pointerValues.isSymbolicLink, false)
    }

    func testRecoverySkipsGenerationLeftBeforeCurrentPointerCommitPoint() async throws {
        let fixture = try fixture()
        let committed = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [.write(Data("committed".utf8), to: "main.bean")],
            validator: { _ in }
        )
        let generations = fixture.workspace.rootDirectory.appendingPathComponent("generations")
        let committedGeneration = generations.appendingPathComponent(committed.id.uuidString)
        let orphan = LocalLedgerWorkspace.Revision(
            id: UUID(),
            parentID: committed.id,
            createdAt: Date().addingTimeInterval(60),
            changedPaths: ["main.bean"]
        )
        let orphanGeneration = generations.appendingPathComponent(orphan.id.uuidString)
        try FileManager.default.copyItem(at: committedGeneration, to: orphanGeneration)
        let orphanMarker = orphanGeneration.appendingPathComponent(".committed")
        try FileManager.default.removeItem(at: orphanMarker)
        try JSONEncoder().encode(orphan)
            .write(to: orphanGeneration.appendingPathComponent("revision.json"))
        try Data("uncommitted".utf8)
            .write(to: orphanGeneration.appendingPathComponent("workspace/main.bean"))
        let pointer = fixture.workspace.rootDirectory.appendingPathComponent("current.json")
        try Data("{corrupt".utf8).write(to: pointer)

        let recovered = try await fixture.workspace.currentRevision()
        let recoveredFile = try await fixture.workspace.readFile(at: "main.bean")

        XCTAssertEqual(recovered, committed)
        XCTAssertEqual(recoveredFile, Data("committed".utf8))
    }

    func testRecoveryUsesParentGraphWhenDeviceClockMovesBackward() async throws {
        let fixture = try fixture()
        let first = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [.write(Data("first".utf8), to: "main.bean")],
            validator: { _ in }
        )
        let latest = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [.write(Data("latest".utf8), to: "main.bean")],
            validator: { _ in }
        )
        let backdated = LocalLedgerWorkspace.Revision(
            id: latest.id,
            parentID: first.id,
            createdAt: first.createdAt.addingTimeInterval(-3600),
            changedPaths: latest.changedPaths
        )
        let generation = fixture.workspace.rootDirectory
            .appendingPathComponent("generations/" + latest.id.uuidString)
        try JSONEncoder().encode(backdated)
            .write(to: generation.appendingPathComponent("revision.json"))
        try Data("{corrupt".utf8)
            .write(to: fixture.workspace.rootDirectory.appendingPathComponent("current.json"))

        let recovered = try await fixture.workspace.currentRevision()
        let recoveredFile = try await fixture.workspace.readFile(at: "main.bean")
        XCTAssertEqual(recovered, backdated)
        XCTAssertEqual(recoveredFile, Data("latest".utf8))
    }

    func testRecoveryFailsForCommittedForksAndCycles() async throws {
        do {
            let fixture = try fixture()
            let first = try await fixture.workspace.commit(
                expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                changes: [.write(Data("first".utf8), to: "main.bean")],
                validator: { _ in }
            )
            _ = try await fixture.workspace.commit(
                expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                changes: [.write(Data("second".utf8), to: "main.bean")],
                validator: { _ in }
            )
            let generations = fixture.workspace.rootDirectory.appendingPathComponent("generations")
            let fork = LocalLedgerWorkspace.Revision(
                id: UUID(),
                parentID: first.id,
                createdAt: Date(),
                changedPaths: ["main.bean"]
            )
            let forkGeneration = generations.appendingPathComponent(fork.id.uuidString)
            try FileManager.default.copyItem(
                at: generations.appendingPathComponent(first.id.uuidString),
                to: forkGeneration
            )
            try JSONEncoder().encode(fork)
                .write(to: forkGeneration.appendingPathComponent("revision.json"))
            try Data(fork.id.uuidString.utf8)
                .write(to: forkGeneration.appendingPathComponent(".committed"))
            try Data("{corrupt".utf8)
                .write(to: fixture.workspace.rootDirectory.appendingPathComponent("current.json"))

            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.workspace.currentRevision()
            }
        }

        do {
            let fixture = try fixture()
            let first = try await fixture.workspace.commit(
                expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                changes: [.write(Data("first".utf8), to: "main.bean")],
                validator: { _ in }
            )
            let second = try await fixture.workspace.commit(
                expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                changes: [.write(Data("second".utf8), to: "main.bean")],
                validator: { _ in }
            )
            let cyclicFirst = LocalLedgerWorkspace.Revision(
                id: first.id,
                parentID: second.id,
                createdAt: first.createdAt,
                changedPaths: first.changedPaths
            )
            let generations = fixture.workspace.rootDirectory.appendingPathComponent("generations")
            try JSONEncoder().encode(cyclicFirst).write(
                to: generations
                    .appendingPathComponent(first.id.uuidString)
                    .appendingPathComponent("revision.json")
            )
            try Data("{corrupt".utf8)
                .write(to: fixture.workspace.rootDirectory.appendingPathComponent("current.json"))

            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.workspace.currentRevision()
            }
        }
    }

    func testRetainsCommittedGenerationsAndRemovesAbandonedStages() async throws {
        let fixture = try fixture()
        var latest: LocalLedgerWorkspace.Revision?
        let revisionCount = 24
        for index in 0..<revisionCount {
            latest = try await fixture.workspace.commit(
                expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
                changes: [.write(Data("\(index)".utf8), to: "main.bean")],
                validator: { _ in }
            )
        }
        let generations = fixture.workspace.rootDirectory.appendingPathComponent("generations")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: generations.path).count,
            revisionCount
        )

        let abandoned = fixture.workspace.rootDirectory
            .appendingPathComponent("staging")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        let reopened = try await fixture.workspace.create()
        XCTAssertEqual(reopened, latest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    #if os(iOS)
    func testCommittedLedgerUsesFirstUnlockFileProtection() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("iOS Data Protection attributes require a physical device filesystem")
        #else
        let fixture = try fixture()
        _ = try await fixture.workspace.commit(
            expectedRevisionID: try await fixture.workspace.currentRevision()?.id,
            changes: [.write(Data("protected".utf8), to: "main.bean")],
            validator: { _ in }
        )
        let protection = try await fixture.workspace.withCurrentSnapshot { _, directory in
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("main.bean").path
            )
            return attributes[.protectionKey] as? String
        }
        XCTAssertEqual(protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        #endif
    }
    #endif
}

private actor WorkspaceValidatorGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ message: @autoclosure () -> String = "",
        _ expression: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error. " + message(), file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
