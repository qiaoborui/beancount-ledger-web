import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import LedgerMobile

final class BoundedLedgerPublicationTests: XCTestCase {
    private struct Fixture: Sendable {
        let workspace: LocalLedgerWorkspace
        let revision: LocalLedgerWorkspace.Revision
        let root: URL
        var pointer: URL { root.appendingPathComponent("derived/bounded/current.json") }
    }

    private func fixture(faults: PublicationFileFaults = PublicationFileFaults(), aliased: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BoundedPublication-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var workspaceRoot = root
        if aliased {
            let target = root.appendingPathComponent("real")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            // Alias an ancestor, not the workspace itself: child symlinks stay forbidden.
            workspaceRoot = alias.appendingPathComponent("workspace")
        }
        let workspace = LocalLedgerWorkspace(rootDirectory: workspaceRoot,
                                             fileManager: PublicationFailureFileManager(faults: faults))
        let revision = try await workspace.commit(changes: [.write(Data("; synthetic A\n".utf8), to: "main.bean")], validator: { _ in })
        return Fixture(workspace: workspace, revision: revision, root: workspaceRoot)
    }

    private static func export(_ source: BoundedSourceLease, _ entry: String, _ derived: URL, _ name: String) async throws -> EmbeddedBeancountValidator.StreamSummary {
        XCTAssertEqual(entry, "main.bean")
        XCTAssertNotEqual(source.directory, derived)
        // Fixture files only. Production uses the protected runtime exporter.
        try Data(source.identity.utf8).write(to: derived.appendingPathComponent(name))
        return .init(records: 3, directives: 1, postings: 1,
                     sourceDigest: source.identity, sha256: source.identity)
    }

    private func publication(_ fixture: Fixture, behavior: PublicationBackend.Behavior = .success,
                             exporter: @escaping BoundedLedgerPublication.Exporter = BoundedLedgerPublicationTests.export) -> BoundedLedgerPublication {
        BoundedLedgerPublication(workspace: fixture.workspace, exporter: exporter,
            makeClient: { directory in
                BoundedReadIndexClient(backend: try PublicationBackend(directory: directory, behavior: behavior))
            })
    }

    private func expectError(_ expected: BoundedReadIndexError,
                             _ operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("expected explicit error", file: file, line: line) }
        catch { XCTAssertEqual(error as? BoundedReadIndexError, expected, file: file, line: line) }
    }

    func testSchemasOneAndTwoFailUntilExplicitRebuild() async throws {
        for schema in [1, 2] {
            let f = try await fixture()
            let p = publication(f)
            p.unlock()
            let manifest = try await p.rebuild(expectedRevisionID: f.revision.id)
            let current = try Data(contentsOf: f.pointer)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
            var index = try XCTUnwrap(object["index"] as? [String: Any])
            index["schema_version"] = schema
            object["index"] = index
            let old = try JSONSerialization.data(withJSONObject: object)
            try old.write(to: f.pointer)
            await expectError(.corrupt) { _ = try await p.withReadLease { _, _ in true } }
            XCTAssertEqual(try Data(contentsOf: f.pointer), old)
            for behavior: PublicationBackend.Behavior in [.buildFailure, .openFailure, .oldSchema, .schemaTwo] {
                let failing = publication(f, behavior: behavior)
                failing.unlock()
                await expectError(behavior == .buildFailure ? .unavailable : .corrupt) {
                    _ = try await failing.rebuild(expectedRevisionID: f.revision.id)
                }
                XCTAssertEqual(try Data(contentsOf: f.pointer), old)
            }
            let rebuilt = try await p.rebuild(expectedRevisionID: f.revision.id)
            XCTAssertEqual(rebuilt.index.schemaVersion, 3)
            XCTAssertNotEqual(rebuilt.generationID, manifest.generationID)
            try await p.withReadLease { _, reader in _ = try reader.accounts() }
            let outdatedBuilder = publication(f, behavior: schema == 1 ? .oldSchema : .schemaTwo)
            outdatedBuilder.unlock()
            let rebuiltBytes = try Data(contentsOf: f.pointer)
            await expectError(.corrupt) { _ = try await outdatedBuilder.rebuild(expectedRevisionID: f.revision.id) }
            XCTAssertEqual(try Data(contentsOf: f.pointer), rebuiltBytes)
        }
    }

    func testLockedByDefaultAndMissingManifestNeverFallsBack() async throws {
        let f = try await fixture()
        let p = publication(f)
        await expectError(.unavailable) { _ = try await p.rebuild(expectedRevisionID: f.revision.id) }
        p.unlock()
        await expectError(.unavailable) { _ = try await p.withReadLease { _, _ in true } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pointer.path))
    }

    func testPublicationPinsSourceAndIndexWithoutChangingFinancialPointer() async throws {
        let f = try await fixture()
        let sourcePointer = try Data(contentsOf: f.root.appendingPathComponent("current.json"))
        let p = publication(f)
        p.unlock()
        let manifest = try await p.rebuild(expectedRevisionID: f.revision.id)
        XCTAssertEqual(manifest.sourceRevisionID, f.revision.id)
        XCTAssertEqual(try BoundedLedgerManifest.decode(Data(contentsOf: f.pointer)), manifest)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("current.json")), sourcePointer)
        let lease = try await p.withReadLease { lease, client in
            XCTAssertEqual(try client.transactions().revision, lease.manifest.index.revision)
            XCTAssertEqual(try String(contentsOf: lease.source.directory.appendingPathComponent("main.bean"), encoding: .utf8), "; synthetic A\n")
            XCTAssertFalse(lease.isStale)
            return lease
        }
        XCTAssertEqual(lease.source.identity, manifest.sourceIdentity)
        XCTAssertEqual(lease.source.revisionID, manifest.sourceRevisionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.derivedDirectory.appendingPathComponent("stream.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.source.directory.appendingPathComponent("derived").path))
        for (url, mode) in [(lease.derivedDirectory, 0o700), (lease.database, 0o600), (f.pointer, 0o600)] {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, mode)
        }
    }

    func testFailedRebuildRetainsLastMatchedGenerationAndReportsStale() async throws {
        let f = try await fixture()
        let p = publication(f)
        p.unlock()
        let first = try await p.rebuild(expectedRevisionID: f.revision.id)
        let bytes = try Data(contentsOf: f.pointer)
        let second = try await f.workspace.commit(expectedRevisionID: f.revision.id,
            changes: [.write(Data("; synthetic B\n".utf8), to: "main.bean")], validator: { _ in })
        let failing = publication(f, behavior: .buildFailure)
        failing.unlock()
        await expectError(.unavailable) { _ = try await failing.rebuild(expectedRevisionID: second.id) }
        XCTAssertEqual(try Data(contentsOf: f.pointer), bytes)
        let reopened = try await p.withReadLease { lease, _ in
            XCTAssertTrue(lease.isStale)
            XCTAssertEqual(lease.source.revisionID, first.sourceRevisionID)
            XCTAssertEqual(try String(contentsOf: lease.source.directory.appendingPathComponent("main.bean"), encoding: .utf8), "; synthetic A\n")
            return lease.manifest
        }
        XCTAssertEqual(reopened, first)
        let now = try await f.workspace.currentRevision()
        XCTAssertEqual(now?.id, second.id)
    }

    func testWrongExpectedRevisionFailsBeforeExport() async throws {
        let f = try await fixture()
        let p = publication(f, exporter: { _, _, _, _ in
            XCTFail("stale revision must not export")
            throw BoundedReadIndexError.corrupt
        })
        p.unlock()
        await expectError(.revisionMismatch) { _ = try await p.rebuild(expectedRevisionID: UUID()) }
    }

    func testManifestMustMatchExporterIdentityCountsAndEntrypoint() async throws {
        let f = try await fixture()
        for behavior in [PublicationBackend.Behavior.wrongSource, .wrongStream, .wrongCount, .wrongEntrypoint] {
            let p = publication(f, behavior: behavior)
            p.unlock()
            await expectError(.revisionMismatch) { _ = try await p.rebuild(expectedRevisionID: f.revision.id) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.pointer.path))
        }
    }

    func testSameSizeSameMtimeMutationDuringExportIsRejected() async throws {
        let f = try await fixture()
        let p = publication(f, exporter: { source, entry, derived, name in
            let file = source.directory.appendingPathComponent(entry)
            let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]!
            let summary = try await BoundedLedgerPublicationTests.export(source, entry, derived, name)
            try Data("; synthetic B\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            return summary
        })
        p.unlock()
        await expectError(.revisionMismatch) { _ = try await p.rebuild(expectedRevisionID: f.revision.id) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pointer.path))
    }

    func testReopenDetectsChangedSupportFileWithoutLegacyFallback() async throws {
        let f = try await fixture()
        let p = publication(f)
        p.unlock()
        _ = try await p.rebuild(expectedRevisionID: f.revision.id)
        let source = f.root.appendingPathComponent("generations/\(f.revision.id.uuidString)/workspace")
        try Data("# synthetic plugin".utf8).write(to: source.appendingPathComponent("plugin.py"))
        await expectError(.revisionMismatch) { _ = try await p.withReadLease { _, _ in true } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.pointer.path))
    }

    func testCorruptOrOversizedPointerDoesNotScanOldGenerations() async throws {
        let f = try await fixture()
        let p = publication(f)
        p.unlock()
        _ = try await p.rebuild(expectedRevisionID: f.revision.id)
        try Data("{}".utf8).write(to: f.pointer)
        await expectError(.corrupt) { _ = try await p.withReadLease { _, _ in true } }
        try Data(repeating: 32, count: BoundedLedgerManifest.maximumBytes + 1).write(to: f.pointer)
        await expectError(.unavailable) { _ = try await p.withReadLease { _, _ in true } }
    }

    func testIntegrityFailureAndWALSidecarRetainLastMatchedGeneration() async throws {
        for behavior in [PublicationBackend.Behavior.openFailure, .sidecar] {
            let f = try await fixture()
            let good = publication(f)
            good.unlock()
            let first = try await good.rebuild(expectedRevisionID: f.revision.id)
            let bytes = try Data(contentsOf: f.pointer)
            let second = try await f.workspace.commit(expectedRevisionID: f.revision.id,
                changes: [.write(Data("; synthetic B\n".utf8), to: "main.bean")], validator: { _ in })
            let failing = publication(f, behavior: behavior)
            failing.unlock()
            await expectError(.corrupt) { _ = try await failing.rebuild(expectedRevisionID: second.id) }
            try await assertRetained(f, first: first, pointer: bytes, current: second.id)
        }
    }

    private func assertRetained(_ f: Fixture, first: BoundedLedgerManifest,
                                pointer: Data, current: UUID) async throws {
        XCTAssertEqual(try Data(contentsOf: f.pointer), pointer)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: f.pointer.deletingLastPathComponent().path)),
                       Set(["current.json", first.generationID.uuidString]))
        // A new coordinator/backend must reopen the on-disk pair, not cached state.
        let reopened = publication(f)
        reopened.unlock()
        try await reopened.withReadLease { lease, reader in
            XCTAssertEqual(lease.manifest, first)
            XCTAssertEqual(lease.source.revisionID, first.sourceRevisionID)
            XCTAssertTrue(lease.isStale)
            XCTAssertEqual(try String(contentsOf: lease.source.directory.appendingPathComponent("main.bean"), encoding: .utf8), "; synthetic A\n")
            BoundedLedgerPublicationTests.assertQueries(reader, manifest: first.index)
        }
        let source = try await f.workspace.currentRevision()
        XCTAssertEqual(source?.id, current)
    }

    func testAliasedAncestorBuildAndReopenUseCanonicalBackendRoot() async throws {
        let f = try await fixture(aliased: true)
        XCTAssertNotEqual(f.root.path, try BoundedIndexWire.resolvedDirectory(f.root))
        let p = publication(f)
        p.unlock()
        let first = try await p.rebuild(expectedRevisionID: f.revision.id)
        let reopened = publication(f)
        reopened.unlock()
        try await reopened.withReadLease { lease, reader in
            XCTAssertEqual(lease.manifest, first)
            XCTAssertFalse(lease.isStale)
            BoundedLedgerPublicationTests.assertQueries(reader, manifest: first.index)
            // Prove the fake rejects the original unresolved absolute spelling,
            // rather than silently canonicalizing it and masking the regression.
            let backend = try PublicationBackend(directory: lease.derivedDirectory, behavior: .success)
            let manifestJSON = String(decoding: try JSONEncoder().encode(first.index), as: UTF8.self)
            XCTAssertEqual(backend.open(lease.database.path, manifestJSON: manifestJSON),
                           #"{"error":{"code":"invalid_request"}}"#)
            XCTAssertEqual(backend.build(lease.derivedDirectory.appendingPathComponent("stream.jsonl").path,
                                         destination: lease.database.path),
                           #"{"error":{"code":"invalid_request"}}"#)
        }
    }

    func testSymlinkedDerivedRootCannotWriteOutsideWorkspace() async throws {
        let f = try await fixture()
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("derived"), withDestinationURL: outside)
        let p = publication(f)
        p.unlock()
        await expectError(.unavailable) { _ = try await p.rebuild(expectedRevisionID: f.revision.id) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testSymlinkedDatabaseIsRejectedOnReopen() async throws {
        let f = try await fixture()
        let p = publication(f)
        p.unlock()
        let manifest = try await p.rebuild(expectedRevisionID: f.revision.id)
        let database = f.root.appendingPathComponent("derived/bounded/\(manifest.generationID.uuidString)/index.sqlite")
        try FileManager.default.removeItem(at: database)
        try FileManager.default.createSymbolicLink(at: database, withDestinationURL: f.root.appendingPathComponent("current.json"))
        await expectError(.corrupt) { _ = try await p.withReadLease { _, _ in true } }
    }

    func testLateProtectionFailuresRetainLastMatchedGeneration() async throws {
        for failure in [PublicationFileFaults.Failure.databaseProtection, .pointerProtection] {
            try await checkFilesystemFailure(failure)
        }
    }

    func testPointerRenameFailureRetainsLastMatchedGeneration() async throws {
        // Directory permissions cannot force EACCES for a privileged process.
        guard geteuid() != 0 else { throw XCTSkip("rename fault requires an unprivileged process") }
        try await checkFilesystemFailure(.pointerRename)
    }

    private func checkFilesystemFailure(_ failure: PublicationFileFaults.Failure) async throws {
        let files = PublicationFileFaults()
        let f = try await fixture(faults: files)
        let p = publication(f)
        p.unlock()
        let first = try await p.rebuild(expectedRevisionID: f.revision.id)
        let bytes = try Data(contentsOf: f.pointer)
        let second = try await f.workspace.commit(expectedRevisionID: f.revision.id,
            changes: [.write(Data("; synthetic B\n".utf8), to: "main.bean")], validator: { _ in })
        files.arm(failure)
        defer { files.restorePermissions() }
        await expectError(.unavailable) { _ = try await p.rebuild(expectedRevisionID: second.id) }
        XCTAssertTrue(files.didInject)
        files.restorePermissions()
        try await assertRetained(f, first: first, pointer: bytes, current: second.id)
    }

    func testLockAndCancelSuppressSuspendedExportAndPreservePointer() async throws {
        let f = try await fixture()
        let first = publication(f)
        first.unlock()
        _ = try await first.rebuild(expectedRevisionID: f.revision.id)
        let old = try Data(contentsOf: f.pointer)
        for lock in [false, true] {
            let barrier = PublicationBarrier()
            let p = publication(f, exporter: { source, entry, derived, name in
                await barrier.pause()
                return try await BoundedLedgerPublicationTests.export(source, entry, derived, name)
            })
            p.unlock()
            let task = Task { try await p.rebuild(expectedRevisionID: f.revision.id) }
            await barrier.waitUntilPaused()
            await expectError(.busy) { _ = try await p.rebuild(expectedRevisionID: f.revision.id) }
            if lock { p.lock(); p.unlock() } else { p.cancel() }
            await barrier.resume()
            await expectError(.canceled) { _ = try await task.value }
            XCTAssertEqual(try Data(contentsOf: f.pointer), old)
        }
    }

    func testTaskCancellationReleasesWorkspaceAndDoesNotPublish() async throws {
        let f = try await fixture()
        let barrier = PublicationBarrier()
        let p = publication(f, exporter: { source, entry, derived, name in
            await barrier.pause()
            return try await BoundedLedgerPublicationTests.export(source, entry, derived, name)
        })
        p.unlock()
        let task = Task { try await p.rebuild(expectedRevisionID: f.revision.id) }
        await barrier.waitUntilPaused()
        task.cancel()
        await barrier.resume()
        do { _ = try await task.value; XCTFail("task must be canceled") }
        catch { XCTAssertTrue(error is CancellationError || error as? BoundedReadIndexError == .canceled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pointer.path))
        _ = try await f.workspace.commit(expectedRevisionID: f.revision.id, changes: [], validator: { _ in })
    }

    func testWorkspaceWritersCannotChangeRevisionUnderBuild() async throws {
        let f = try await fixture()
        let barrier = PublicationBarrier()
        let p = publication(f, exporter: { source, entry, derived, name in
            await barrier.pause()
            return try await BoundedLedgerPublicationTests.export(source, entry, derived, name)
        })
        p.unlock()
        let task = Task { try await p.rebuild(expectedRevisionID: f.revision.id) }
        await barrier.waitUntilPaused()
        do {
            _ = try await f.workspace.commit(expectedRevisionID: f.revision.id, changes: [], validator: { _ in })
            XCTFail("same-instance writer must not overtake build")
        } catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .transactionInProgress) }
        #if canImport(Darwin)
        let other = LocalLedgerWorkspace(rootDirectory: f.root)
        do {
            _ = try await other.commit(expectedRevisionID: f.revision.id, changes: [], validator: { _ in })
            XCTFail("cross-instance writer must not overtake build")
        } catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .transactionInProgress) }
        #endif
        await barrier.resume()
        let manifest = try await task.value
        XCTAssertEqual(manifest.sourceRevisionID, f.revision.id)
    }

    func testReadScopeRemainsPinnedAcrossNewPublicationAndLockSuppressesResult() async throws {
        let f = try await fixture()
        let p = publication(f)
        p.unlock()
        let first = try await p.rebuild(expectedRevisionID: f.revision.id)
        let barrier = PublicationBarrier()
        let reading = Task {
            try await p.withReadLease { lease, client in
                BoundedLedgerPublicationTests.assertQueries(client, manifest: first.index)
                await barrier.pause()
                XCTAssertEqual(lease.manifest, first)
                BoundedLedgerPublicationTests.assertQueries(client, manifest: first.index)
                return try client.transactions().revision
            }
        }
        await barrier.waitUntilPaused()
        let second = try await f.workspace.commit(expectedRevisionID: f.revision.id,
            changes: [.write(Data("; synthetic B\n".utf8), to: "main.bean")], validator: { _ in })
        let other = publication(f)
        other.unlock()
        let newer = try await other.rebuild(expectedRevisionID: second.id)
        XCTAssertNotEqual(newer.index.revision, first.index.revision)
        try await other.withReadLease { lease, reader in
            XCTAssertEqual(lease.manifest, newer)
            BoundedLedgerPublicationTests.assertQueries(reader, manifest: newer.index)
        }
        await barrier.resume()
        let readRevision = try await reading.value
        XCTAssertEqual(readRevision, first.index.revision)
        try await p.withReadLease { lease, reader in
            XCTAssertEqual(lease.manifest, newer)
            BoundedLedgerPublicationTests.assertQueries(reader, manifest: newer.index)
        }
        // Lock while a consumer (not native code) is suspended must still
        // invalidate its value, even if the consumer ignores cancellation.
        let blocked = PublicationBarrier()
        let stale = Task {
            try await p.withReadLease { _, _ in
                await blocked.pause()
                return "must not escape after lock"
            }
        }
        await blocked.waitUntilPaused()
        p.lock()
        p.unlock()
        await blocked.resume()
        await expectError(.canceled) { _ = try await stale.value }
    }

    func testReaderRejectsMixedRevisionAndCannotEscapeItsScope() async throws {
        let f = try await fixture()
        let p = publication(f)
        p.unlock()
        _ = try await p.rebuild(expectedRevisionID: f.revision.id)
        let wrong = publication(f, behavior: .wrongPageRevision)
        wrong.unlock()
        await expectError(.revisionMismatch) {
            _ = try await wrong.withReadLease { _, reader in try reader.transactions() }
        }
        await expectError(.revisionMismatch) {
            _ = try await wrong.withReadLease { _, reader in try reader.detail(id: 1) }
        }
        await expectError(.revisionMismatch) {
            _ = try await wrong.withReadLease { _, reader in try reader.detailRecords(id: 1) }
        }
        await expectError(.revisionMismatch) {
            _ = try await wrong.withReadLease { _, reader in try reader.accounts() }
        }
        await expectError(.revisionMismatch) {
            _ = try await wrong.withReadLease { _, reader in try reader.accountBalances(account: "Assets:Test") }
        }
        await expectError(.revisionMismatch) {
            _ = try await wrong.withReadLease { _, reader in try reader.accountSummary(account: "Assets:Test", currency: "USD") }
        }
        await expectError(.revisionMismatch) {
            _ = try await wrong.withReadLease { _, reader in try reader.accountActivity(account: "Assets:Test", currency: "USD") }
        }
        await expectError(.revisionMismatch) {
            _ = try await wrong.withReadLease { _, reader in try reader.priceLookup(base: "EUR", quote: "USD") }
        }
        await expectError(.revisionMismatch) {
            _ = try await wrong.withReadLease { _, reader in try reader.valueLegacyCents(amount: 1, base: "EUR", quote: "USD") }
        }
        let wrongContinuation = publication(f, behavior: .wrongDetailContinuationRevision)
        wrongContinuation.unlock()
        await expectError(.revisionMismatch) {
            _ = try await wrongContinuation.withReadLease { _, reader in
                let first = try reader.detailRecords(id: 1, limit: 1)
                return try reader.detailRecords(id: 1, limit: 1, cursor: first.nextCursor)
            }
        }
        let escaped = try await p.withReadLease { _, reader in reader }
        XCTAssertThrowsError(try escaped.priceLookup(base: "EUR", quote: "USD")) {
            XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable)
        }
        XCTAssertThrowsError(try escaped.valueLegacyCents(amount: 1, base: "EUR", quote: "USD")) {
            XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable)
        }
        XCTAssertThrowsError(try escaped.accounts()) {
            XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable)
        }
        XCTAssertThrowsError(try escaped.accountBalances(account: "Assets:Test")) {
            XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable)
        }
        XCTAssertThrowsError(try escaped.accountSummary(account: "Assets:Test", currency: "USD")) {
            XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable)
        }
        XCTAssertThrowsError(try escaped.accountActivity(account: "Assets:Test", currency: "USD")) {
            XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable)
        }
        XCTAssertThrowsError(try escaped.transactions()) {
            XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable)
        }
        XCTAssertThrowsError(try escaped.detailRecords(id: 1)) {
            XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable)
        }
    }

    func testOrphanBuildDoesNotBecomeCurrentAndExporterErrorsAreRedacted() async throws {
        let f = try await fixture()
        let p = publication(f)
        p.unlock()
        let first = try await p.rebuild(expectedRevisionID: f.revision.id)
        let bytes = try Data(contentsOf: f.pointer)
        let orphan = f.pointer.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try Data("incomplete fixture".utf8).write(to: orphan.appendingPathComponent("index.sqlite"))
        let failed = publication(f, exporter: { _, _, _, _ in
            throw NSError(domain: "fixture-private-path-must-not-escape", code: 1)
        })
        failed.unlock()
        await expectError(.unavailable) { _ = try await failed.rebuild(expectedRevisionID: f.revision.id) }
        XCTAssertEqual(try Data(contentsOf: f.pointer), bytes)
        let reopened = try await p.withReadLease { lease, _ in lease.manifest }
        XCTAssertEqual(reopened, first)
        // No speculative deletion/selection among old generations or orphans.
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    private static func assertQueries(_ reader: BoundedLedgerReader, manifest: BoundedIndexManifest,
                                      file: StaticString = #filePath, line: UInt = #line) {
        do {
            XCTAssertEqual(try reader.accounts().revision, manifest.revision, file: file, line: line)
            let native = try reader.accountBalances(account: "Assets:Test")
            XCTAssertEqual(native.revision, manifest.revision, file: file, line: line)
            XCTAssertEqual(native.balances.first?.quantity, "12345678901234567890.00001", file: file, line: line)
            let price = try reader.priceLookup(base: "EUR", quote: "USD")
            XCTAssertEqual(price.revision, manifest.revision, file: file, line: line)
            XCTAssertFalse(price.found, file: file, line: line)
            let cents = try reader.valueLegacyCents(amount: Int64.max, base: "USD", quote: "USD")
            XCTAssertEqual(cents.revision, manifest.revision, file: file, line: line)
            XCTAssertEqual(cents.amount, Int64.max, file: file, line: line)
            let summary = try reader.accountSummary(account: "Assets:Test", currency: "USD")
            XCTAssertEqual(summary.revision, manifest.revision, file: file, line: line)
            XCTAssertEqual(summary.currentBalance, "12345678901234567890.00001", file: file, line: line)
            let activity = try reader.accountActivity(account: "Assets:Test", currency: "USD")
            XCTAssertEqual(activity.revision, manifest.revision, file: file, line: line)
            XCTAssertTrue(activity.rows.isEmpty, file: file, line: line)
            let page = try reader.transactions()
            XCTAssertEqual(page.revision, manifest.revision, file: file, line: line)
            XCTAssertEqual(page.transactions.count, 1, file: file, line: line)
            let row = try XCTUnwrap(page.transactions.first, file: file, line: line)
            let detailPage = try reader.detailRecords(id: row.id, limit: 100)
            XCTAssertEqual(detailPage.revision, manifest.revision, file: file, line: line)
            XCTAssertEqual(detailPage.id, row.id, file: file, line: line)
            XCTAssertEqual(detailPage.records.count, 1, file: file, line: line)
            XCTAssertEqual(detailPage.nextCursor, "fixture-next", file: file, line: line)
            let continuation = try reader.detailRecords(id: row.id, limit: 1, cursor: detailPage.nextCursor)
            XCTAssertEqual(continuation.revision, manifest.revision, file: file, line: line)
            XCTAssertEqual(continuation.records.count, 1, file: file, line: line)
            XCTAssertNil(continuation.nextCursor, file: file, line: line)
            guard case let .posting(entryID, ordinal, value) = continuation.records[0].value else {
                return XCTFail("expected continuation posting", file: file, line: line)
            }
            XCTAssertEqual(entryID, row.id, file: file, line: line)
            XCTAssertEqual(ordinal, 0, file: file, line: line)
            XCTAssertEqual(value.quantity.number, "1.00000000000001", file: file, line: line)
            let detail = try reader.detail(id: row.id)
            XCTAssertEqual(detail.revision, manifest.revision, file: file, line: line)
            XCTAssertEqual(detail.id, row.id, file: file, line: line)
            XCTAssertEqual(detail.records.count, 1, file: file, line: line)
            for record in [row.record] + detail.records {
                guard case let .directive(id, value) = record.value else {
                    XCTFail("expected a fixture directive", file: file, line: line)
                    continue
                }
                XCTAssertEqual(id, row.id, file: file, line: line)
                XCTAssertEqual(value.narration, manifest.sourceDigest, file: file, line: line)
            }
        } catch { XCTFail("query failed: \(error)", file: file, line: line) }
    }

    func testManifestEncodeHasPreallocationCaps() throws {
        let index = try PublicationBackend.manifest(behavior: .oversized)
        let manifest = BoundedLedgerManifest(version: 1, generationID: UUID(), sourceRevisionID: UUID(),
            sourceIdentity: String(repeating: "a", count: 64), index: index)
        XCTAssertThrowsError(try manifest.encoded()) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
    }
}

/// Scalar fake: no Beancount, Go, SQLite or native runtime needed. Cancellation
/// deliberately does not affect results, exercising the Swift lifecycle gate.
private final class PublicationBackend: BoundedReadIndexBackend, @unchecked Sendable {
    enum Behavior: Sendable, Equatable { case success, oldSchema, schemaTwo, buildFailure, openFailure, wrongSource, wrongStream, wrongCount, wrongEntrypoint, sidecar, oversized, wrongPageRevision, wrongDetailContinuationRevision }
    let behavior: Behavior
    private let root: URL
    private let gate = NSLock()
    private var opened: BoundedIndexManifest?

    init(directory: URL, behavior: Behavior) throws {
        self.behavior = behavior
        // Mirror the production client's canonical root, not its caller's URL.
        root = URL(fileURLWithPath: try BoundedIndexWire.resolvedDirectory(directory), isDirectory: true)
    }

    static func manifest(behavior: Behavior, identity: String = String(repeating: "a", count: 64)) throws -> BoundedIndexManifest {
        BoundedIndexManifest(schemaVersion: behavior == .oldSchema ? 1 : behavior == .schemaTwo ? 2 : 3, streamVersion: 1,
            sourceDigest: behavior == .wrongSource ? String(repeating: "c", count: 64) : identity,
            runtime: behavior == .oversized ? String(repeating: "x", count: BoundedIndexWire.manifestLimit + 1) : "fixture",
            exporter: "bounded-v1", entrypoint: behavior == .wrongEntrypoint ? "other.bean" : "main.bean",
            streamDigest: behavior == .wrongStream ? String(repeating: "c", count: 64) : identity,
            records: behavior == .wrongCount ? 4 : 3, directives: 1, postings: 1,
            options: 0, commodities: 0, metadata: 0, transactions: 1, bytes: 100, maxRecordBytes: 50,
            revision: "fixture-index-" + identity)
    }

    // Only the two fixed direct-child artifacts are needed by this fake. As in
    // Go checkedPath, do NOT resolve an absolute argument's aliases before the
    // lexical confinement check; doing so would hide the publication bug.
    private func artifact(_ path: String, name: String) throws -> URL {
        _ = try BoundedIndexWire.path(path)
        let expected = root.appendingPathComponent(name)
        guard path == name || path == expected.path else { throw BoundedReadIndexError.invalidRequest }
        if FileManager.default.fileExists(atPath: expected.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: expected.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw BoundedReadIndexError.unavailable
            }
        }
        return expected
    }

    private func errorJSON(_ error: Error) -> String {
        let code = (error as? BoundedReadIndexError ?? .unavailable).rawValue
        return "{\"error\":{\"code\":\"\(code)\"}}"
    }

    func build(_ streamPath: String, destination: String) -> String {
        do {
            let stream = try artifact(streamPath, name: "stream.jsonl")
            let database = try artifact(destination, name: "index.sqlite")
            if behavior == .buildFailure { throw BoundedReadIndexError.unavailable }
            let identity = try String(contentsOf: stream, encoding: .utf8)
            let manifest = try Self.manifest(behavior: behavior, identity: identity)
            let data = try JSONEncoder().encode(manifest)
            // Persist generation identity, so a fresh backend actually reopens
            // the selected artifact rather than echoing a caller's manifest.
            try data.write(to: database, options: .withoutOverwriting)
            if behavior == .sidecar { try Data().write(to: URL(fileURLWithPath: database.path + "-wal")) }
            return String(decoding: data, as: UTF8.self)
        } catch { return errorJSON(error) }
    }
    func open(_ databasePath: String, manifestJSON: String) -> String {
        gate.withLock {
            opened = nil
            do {
                let database = try artifact(databasePath, name: "index.sqlite")
                if behavior == .openFailure { throw BoundedReadIndexError.corrupt }
                let actual = try JSONDecoder().decode(BoundedIndexManifest.self, from: Data(contentsOf: database))
                let expected = try JSONDecoder().decode(BoundedIndexManifest.self, from: Data(manifestJSON.utf8))
                guard actual == expected else { throw BoundedReadIndexError.revisionMismatch }
                opened = actual
                return "{\"revision\":\"\(actual.revision)\"}"
            } catch { return errorJSON(error) }
        }
    }
    private func record(_ manifest: BoundedIndexManifest) -> [String: Any] {
        ["type": "directive", "id": 1, "value": [
            "Kind": "transaction", "Date": "2026-09-21", "File": "main.bean", "Line": 1,
            "Narration": manifest.sourceDigest,
        ]]
    }
    func transactions(_ requestJSON: String) -> String {
        gate.withLock {
            guard let manifest = opened else { return errorJSON(BoundedReadIndexError.unavailable) }
            let response: [String: Any] = [
                "revision": behavior == .wrongPageRevision ? "wrong-revision" : manifest.revision,
                "transactions": [["id": 1, "date": "2026-09-21", "record": record(manifest)]],
                "next_cursor": NSNull(),
            ]
            do { return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self) }
            catch { return errorJSON(error) }
        }
    }
    func priceLookup(_ requestJSON: String) -> String {
        gate.withLock {
            guard let manifest = opened else { return errorJSON(BoundedReadIndexError.unavailable) }
            let revision = behavior == .wrongPageRevision ? "wrong" : manifest.revision
            return #"{"revision":"\#(revision)","tie_policy":"source_sequence_last","found":false}"#
        }
    }
    func valueLegacyCents(_ requestJSON: String) -> String {
        gate.withLock {
            guard let manifest = opened else { return errorJSON(BoundedReadIndexError.unavailable) }
            let revision = behavior == .wrongPageRevision ? "wrong" : manifest.revision
            return #"{"revision":"\#(revision)","basis":"legacy_cents","tie_policy":"source_sequence_last","amount":9223372036854775807,"found":true}"#
        }
    }
    func accounts(_ requestJSON: String) -> String {
        gate.withLock {
            guard let manifest = opened else { return errorJSON(BoundedReadIndexError.unavailable) }
            let revision = behavior == .wrongPageRevision ? "wrong" : manifest.revision
            return #"{"revision":"\#(revision)","accounts":[{"account":"Assets:Test","open_id":1,"open_date":"2026-09-21","open_record":{"type":"directive","id":1,"value":{"Kind":"open","Date":"2026-09-21","File":"main.bean","Line":1,"Account":"Assets:Test"}}}]}"#
        }
    }
    func accountBalances(_ requestJSON: String) -> String {
        gate.withLock {
            guard let manifest = opened else { return errorJSON(BoundedReadIndexError.unavailable) }
            let revision = behavior == .wrongPageRevision ? "wrong" : manifest.revision
            return #"{"revision":"\#(revision)","account":"Assets:Test","basis":"native_nominal","balances":[{"currency":"USD","quantity":"12345678901234567890.00001"}]}"#
        }
    }
    func accountSummary(_ requestJSON: String) -> String {
        gate.withLock {
            guard let manifest = opened else { return errorJSON(BoundedReadIndexError.unavailable) }
            let revision = behavior == .wrongPageRevision ? "wrong" : manifest.revision
            return #"{"revision":"\#(revision)","account":"Assets:Test","currency":"USD","basis":"native_nominal","current_balance":"12345678901234567890.00001","opening_balance":"0","closing_balance":"12345678901234567890.00001","period_change":"12345678901234567890.00001"}"#
        }
    }
    func accountActivity(_ requestJSON: String) -> String {
        gate.withLock {
            guard let manifest = opened else { return errorJSON(BoundedReadIndexError.unavailable) }
            let revision = behavior == .wrongPageRevision ? "wrong" : manifest.revision
            return #"{"revision":"\#(revision)","account":"Assets:Test","currency":"USD","basis":"native_nominal","rows":null}"#
        }
    }
    func detailRecords(_ requestJSON: String) -> String {
        struct Request: Decodable { let id: Int64; let limit: Int; let cursor: String? }
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(requestJSON.utf8))
            guard request.id == 1 else { throw BoundedReadIndexError.notFound }
            if request.cursor == nil || request.cursor == "" {
                var result = try JSONSerialization.jsonObject(with: Data(detail(request.id).utf8)) as? [String: Any] ?? [:]
                if result["error"] == nil { result["next_cursor"] = "fixture-next" }
                return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
            }
            guard request.cursor == "fixture-next" else { throw BoundedReadIndexError.invalidCursor }
            return gate.withLock {
                guard let manifest = opened else { return errorJSON(BoundedReadIndexError.unavailable) }
                let revision = behavior == .wrongDetailContinuationRevision ? "wrong" : manifest.revision
                return #"{"revision":"\#(revision)","id":1,"records":[{"type":"posting","entry_id":1,"ordinal":0,"value":{"account":"Assets:Test","Quantity":{"Number":"1.00000000000001","Currency":"USD"}}}]}"#
            }
        } catch { return errorJSON(error) }
    }
    func detail(_ id: Int64) -> String {
        gate.withLock {
            guard let manifest = opened else { return errorJSON(BoundedReadIndexError.unavailable) }
            guard id == 1 else { return errorJSON(BoundedReadIndexError.notFound) }
            let response: [String: Any] = [
                "revision": behavior == .wrongPageRevision ? "wrong-revision" : manifest.revision,
                "id": id, "records": [record(manifest)],
            ]
            do { return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self) }
            catch { return errorJSON(error) }
        }
    }
    func unlock() {}
    func cancel() {}
    func lock() {}
    func close() { gate.withLock { opened = nil } }
}

/// Inject faults only after a successful A publication and a source B commit.
/// No production fault hooks or changes to the workspace implementation needed.
private final class PublicationFileFaults: @unchecked Sendable {
    enum Failure: Sendable { case databaseProtection, pointerProtection, pointerRename }
    private let gate = NSLock()
    private var failure: Failure?
    private var injected = false
    private var restrictedParent: String?
    var didInject: Bool { gate.withLock { injected } }

    func arm(_ failure: Failure) { gate.withLock { self.failure = failure; injected = false } }

    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try gate.withLock {
            let url = URL(fileURLWithPath: path)
            let isPointer = url.lastPathComponent.hasPrefix(".current-") &&
                url.deletingLastPathComponent().lastPathComponent == "bounded"
            switch failure {
            case .databaseProtection where url.lastPathComponent == "index.sqlite":
                failure = nil
                injected = true
                throw CocoaError(.fileWriteNoPermission)
            case .pointerProtection where isPointer:
                failure = nil
                injected = true
                throw CocoaError(.fileWriteNoPermission)
            case .pointerRename where isPointer:
                try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
                // Pending bytes and protection succeed; only the final rename
                // is denied. Keep the existing pointer untouched and readable.
                let parent = url.deletingLastPathComponent().path
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent)
                restrictedParent = parent
                failure = nil
                injected = true
            default:
                try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
            }
        }
    }

    func restorePermissions() {
        gate.withLock {
            guard let parent = restrictedParent else { return }
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent)
                restrictedParent = nil
            } catch { XCTFail("could not restore fixture directory permissions") }
        }
    }
}

// The workspace exclusively owns this manager; only locked fault state is shared
// with the test, including on SDKs where FileManager is non-Sendable.
private final class PublicationFailureFileManager: FileManager, @unchecked Sendable {
    private let faults: PublicationFileFaults

    init(faults: PublicationFileFaults) {
        self.faults = faults
        super.init()
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try faults.setAttributes(attributes, ofItemAtPath: path)
    }

    override func removeItem(at url: URL) throws {
        // writeAtomicPointer's deferred pending-file cleanup runs only after
        // the failed rename. Restore permissions then, allowing normal cleanup
        // of both the pending pointer and the rejected generation.
        faults.restorePermissions()
        try super.removeItem(at: url)
    }
}

/// Deterministic async interleaving without sleeps or blocking an executor.
private actor PublicationBarrier {
    private var paused = false
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            release = continuation
            paused = true
            entered?.resume()
            entered = nil
        }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { entered = $0 }
    }
    func resume() {
        release?.resume()
        release = nil
    }
}
