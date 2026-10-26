import Foundation
import XCTest
@testable import LedgerMobile

final class LocalCanonicalStreamCacheTests: XCTestCase {
    private let version = String(repeating: "ab", count: 32)

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CanonicalCache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func stream(_ text: String, in root: URL) throws -> (URL, EmbeddedBeancountValidator.StreamDescriptor) {
        let url = root.appendingPathComponent(UUID().uuidString + ".records")
        try Data(text.utf8).write(to: url)
        return (url, .init(version: 1, entries: 1, bytes: text.utf8.count, sha256: String(repeating: "0", count: 64)))
    }

    func testRestoresStoredStreamByteForByte() throws {
        let root = try makeRoot()
        let cache = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        let (source, descriptor) = try stream("{\"type\":\"header\"}\n", in: root)
        XCTAssertFalse(cache.contains(version))
        cache.store(source, sourceVersion: version, descriptor: descriptor)
        XCTAssertTrue(cache.contains(version))
        let output = root.appendingPathComponent("restored.records")
        XCTAssertTrue(cache.restore(version, to: output))
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: source))
    }

    /// A hit re-hashes the whole stream, and `contains` + `restore` did it twice
    /// per request. The result is now remembered against the file identity, so a
    /// stream rewritten behind the cache's back must still be rejected.
    func testRewrittenStreamInvalidatesRememberedVerification() throws {
        let root = try makeRoot()
        let cache = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        let (source, descriptor) = try stream("{\"type\":\"header\"}\n", in: root)
        cache.store(source, sourceVersion: version, descriptor: descriptor)
        XCTAssertTrue(cache.contains(version), "first verification passes")
        XCTAssertTrue(cache.contains(version), "repeat verification reuses the remembered result")

        // Replace the cached stream with different bytes of the same length.
        let cachedStream = root.appendingPathComponent("canonical-cache", isDirectory: true)
            .appendingPathComponent("build-a", isDirectory: true)
            .appendingPathComponent(version + ".records")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedStream.path))
        let original = try Data(contentsOf: cachedStream)
        var tampered = original
        tampered[tampered.count - 1] = tampered[tampered.count - 1] &+ 1
        try tampered.write(to: cachedStream)

        let stillContains = cache.contains(version)
        XCTAssertFalse(stillContains,
            "a rewritten stream must not inherit the remembered verification (got \(stillContains))")
    }

    func testRejectsStreamWhoseSizeDisagreesWithDescriptor() throws {
        let root = try makeRoot()
        let cache = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        let (source, descriptor) = try stream("abc\n", in: root)
        let wrong = EmbeddedBeancountValidator.StreamDescriptor(version: 1, entries: 1,
            bytes: descriptor.bytes + 1, sha256: descriptor.sha256)
        cache.store(source, sourceVersion: version, descriptor: wrong)
        XCTAssertFalse(cache.contains(version))
    }

    func testCorruptedEntryIsDroppedInsteadOfRestored() throws {
        let root = try makeRoot()
        let cache = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        let (source, descriptor) = try stream("original\n", in: root)
        cache.store(source, sourceVersion: version, descriptor: descriptor)
        let cached = cache.directory.appendingPathComponent(version + ".records")
        // Same length, different bytes: only the digest can catch it.
        try FileManager.default.removeItem(at: cached)
        try Data("tampered\n".utf8).write(to: cached)
        let output = root.appendingPathComponent("restored.records")
        XCTAssertFalse(cache.restore(version, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
    }

    func testAnotherBuildNeverSeesAndThenRemovesOlderStreams() throws {
        let root = try makeRoot()
        let old = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        let (source, descriptor) = try stream("x\n", in: root)
        old.store(source, sourceVersion: version, descriptor: descriptor)
        let new = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-b")
        XCTAssertFalse(new.contains(version))
        new.store(source, sourceVersion: String(repeating: "cd", count: 32), descriptor: descriptor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directory.path))
    }

    func testKeepsOnlyTheMostRecentEntries() throws {
        let root = try makeRoot()
        let cache = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        // One more entry than the cache retains, so exactly the oldest is evicted.
        let capacity = LocalCanonicalStreamCache.capacity
        let versions = (0..<(capacity + 1)).map {
            String(format: "%02d", $0) + String(repeating: "0", count: 62)
        }
        for version in versions {
            let (source, descriptor) = try stream(version + "\n", in: root)
            cache.store(source, sourceVersion: version, descriptor: descriptor)
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(cache.contains(versions[0]), "the oldest stream must be evicted")
        for version in versions.dropFirst() {
            XCTAssertTrue(cache.contains(version), "recent streams must survive")
        }
    }

    func testRejectsMalformedSourceVersion() throws {
        let root = try makeRoot()
        let cache = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        let (source, descriptor) = try stream("x\n", in: root)
        cache.store(source, sourceVersion: "../escape", descriptor: descriptor)
        XCTAssertFalse(cache.contains("../escape"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.path))
    }

    /// Go writes a `.snap1` beside the stream it registered; the cache keeps it
    /// so the next registration links the snapshot instead of the stream.
    func testStoresAndRestoresSnapshotBesideStream() throws {
        let root = try makeRoot()
        let cache = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        let (source, descriptor) = try stream("{\"type\":\"header\"}\n", in: root)
        cache.store(source, sourceVersion: version, descriptor: descriptor)
        XCTAssertFalse(cache.contains(version, format: .snapshot))

        let snapshot = root.appendingPathComponent(UUID().uuidString + ".snap1")
        try Data("BRSNAP01 binary model".utf8).write(to: snapshot)
        cache.storeSnapshot(snapshot, sourceVersion: version)
        XCTAssertTrue(cache.contains(version, format: .snapshot))
        XCTAssertTrue(cache.contains(version, format: .records), "the stream stays as the fallback")

        let output = root.appendingPathComponent("restored.snap1")
        XCTAssertTrue(cache.restore(version, format: .snapshot, to: output))
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: snapshot))
    }

    func testRemovingRejectedSnapshotKeepsStream() throws {
        let root = try makeRoot()
        let cache = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        let (source, descriptor) = try stream("x\n", in: root)
        cache.store(source, sourceVersion: version, descriptor: descriptor)
        let snapshot = root.appendingPathComponent("model.snap1")
        try Data("snapshot".utf8).write(to: snapshot)
        cache.storeSnapshot(snapshot, sourceVersion: version)

        cache.remove(version, format: .snapshot)
        XCTAssertFalse(cache.contains(version, format: .snapshot))
        XCTAssertTrue(cache.contains(version))
        XCTAssertTrue(cache.restore(version, to: root.appendingPathComponent("fallback.records")))
    }

    func testTamperedSnapshotIsDroppedInsteadOfRestored() throws {
        let root = try makeRoot()
        let cache = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        let snapshot = root.appendingPathComponent("model.snap1")
        try Data("original".utf8).write(to: snapshot)
        cache.storeSnapshot(snapshot, sourceVersion: version)
        let cached = cache.directory.appendingPathComponent(version + ".snap1")
        try FileManager.default.removeItem(at: cached)
        try Data("tampered".utf8).write(to: cached)
        let output = root.appendingPathComponent("restored.snap1")
        XCTAssertFalse(cache.restore(version, format: .snapshot, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(cache.contains(version))
    }

    /// A snapshot alone also proves the source passed canonical validation.
    func testSnapshotOnlyEntryCountsAsValidated() throws {
        let root = try makeRoot()
        let cache = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        let snapshot = root.appendingPathComponent("model.snap1")
        try Data("snapshot".utf8).write(to: snapshot)
        cache.storeSnapshot(snapshot, sourceVersion: version)
        XCTAssertTrue(cache.contains(version))
        XCTAssertFalse(cache.contains(version, format: .records))
    }

    /// A version's stream and snapshot are one cache entry, evicted together.
    func testEvictionCountsStreamAndSnapshotAsOneEntry() throws {
        let root = try makeRoot()
        let cache = LocalCanonicalStreamCache(runtimeRoot: root, fingerprint: "build-a")
        let capacity = LocalCanonicalStreamCache.capacity
        let versions = (0..<(capacity + 1)).map {
            String(format: "%02d", $0) + String(repeating: "0", count: 62)
        }
        for version in versions {
            let (source, descriptor) = try stream(version + "\n", in: root)
            cache.store(source, sourceVersion: version, descriptor: descriptor)
            let snapshot = root.appendingPathComponent(version + ".snap1")
            try Data(version.utf8).write(to: snapshot)
            cache.storeSnapshot(snapshot, sourceVersion: version)
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(cache.contains(versions[0]), "the oldest version loses both files")
        for version in versions.dropFirst() {
            XCTAssertTrue(cache.contains(version, format: .records), "recent streams must survive")
            XCTAssertTrue(cache.contains(version, format: .snapshot), "recent snapshots must survive")
        }
    }

    /// Only committed generations get a pickle cache; a stage is moved into
    /// `generations` after one validation, so its pickle could never be reused.
    func testLoaderCacheIsOnlyOfferedToGenerations() throws {
        let ledger = try makeRoot().appendingPathComponent("ledger-id")
        let generation = ledger.appendingPathComponent("generations/0001/workspace")
        let stage = ledger.appendingPathComponent("staging/0002/workspace")
        for directory in [generation, stage] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let expected = ledger.appendingPathComponent("runtime/loader-cache").resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(EmbeddedBeancountValidator.loaderCacheDirectory(for: generation)?
            .resolvingSymlinksInPath().standardizedFileURL.path, expected.path)
        XCTAssertNil(EmbeddedBeancountValidator.loaderCacheDirectory(for: stage))
        XCTAssertNil(EmbeddedBeancountValidator.loaderCacheDirectory(for: ledger))
    }

    /// The booking checkpoint is shared by a ledger's stages and generations,
    /// because a write's preview validates the stage.
    func testBookingCheckpointIsSharedByStagesAndGenerations() throws {
        let ledger = try makeRoot().appendingPathComponent("ledger-id")
        let generation = ledger.appendingPathComponent("generations/0001/workspace")
        let stage = ledger.appendingPathComponent("staging/0002/workspace")
        for directory in [generation, stage] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let expected = ledger.appendingPathComponent("runtime/booking-checkpoint").resolvingSymlinksInPath().standardizedFileURL
        for workspace in [generation, stage] {
            XCTAssertEqual(EmbeddedBeancountValidator.bookingCheckpointDirectory(for: workspace)?
                .resolvingSymlinksInPath().standardizedFileURL.path, expected.path)
        }
        XCTAssertNil(EmbeddedBeancountValidator.bookingCheckpointDirectory(for: ledger))
        XCTAssertNil(EmbeddedBeancountValidator.bookingCheckpointDirectory(
            for: ledger.appendingPathComponent("imports/0003/workspace")))
    }

    /// The parse cache is shared the same way: a stage and the generation it
    /// becomes have the same files, under different directories.
    func testParseCacheIsSharedByStagesAndGenerations() throws {
        let ledger = try makeRoot().appendingPathComponent("ledger-id")
        let generation = ledger.appendingPathComponent("generations/0001/workspace")
        let stage = ledger.appendingPathComponent("staging/0002/workspace")
        for directory in [generation, stage] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let expected = ledger.appendingPathComponent("runtime/parse-cache").resolvingSymlinksInPath().standardizedFileURL
        for workspace in [generation, stage] {
            XCTAssertEqual(EmbeddedBeancountValidator.parseCacheDirectory(for: workspace)?
                .resolvingSymlinksInPath().standardizedFileURL.path, expected.path)
        }
        XCTAssertNil(EmbeddedBeancountValidator.parseCacheDirectory(for: ledger))
        XCTAssertNil(EmbeddedBeancountValidator.parseCacheDirectory(
            for: ledger.appendingPathComponent("imports/0003/workspace")))
    }

    /// End to end through the bundled runtimes: an invalid ledger is still
    /// rejected with its location, and the published generation reuses the
    /// stream its validation exported.
    func testPublicationValidationKeepsDiagnosticsAndSeedsCache() async throws {
        #if os(iOS)
        let root = try makeRoot()
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("""
        option "operating_currency" "CNY"
        2026-01-01 open Assets:Cash
        2026-01-01 open Expenses:Food
        2026-01-02 * "Canteen" "Lunch"
          Expenses:Food  12.00 CNY
          Assets:Cash   -12.00 CNY

        """.utf8).write(to: source.appendingPathComponent("main.bean"))
        let catalog = LocalLedgerCatalog(rootDirectory: root.appendingPathComponent("managed"), engine: EmbeddedLocalLedgerEngine())
        let descriptor = try await catalog.importLedger(from: source, name: "Cache fixture")
        let repository = catalog.repository(for: descriptor)
        let runtime = repository.workspace.rootDirectory.appendingPathComponent("runtime")
        let cache = LocalCanonicalStreamCache(runtimeRoot: runtime)
        let cached = try FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "records" }
        XCTAssertEqual(cached.count, 1, "import validation should leave the exported stream for the first load")
        let page = try await repository.bootstrap(start: "2026-01-01", end: "2026-02-01", today: "2026-01-15", valuationCurrency: "CNY")
        XCTAssertEqual(page.transactions.count, 1)

        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("""
        2026-01-02 * "Unopened"
          Expenses:Nowhere  12.00 CNY
          Assets:Nowhere   -12.00 CNY

        """.utf8).write(to: broken.appendingPathComponent("main.bean"))
        do {
            _ = try await catalog.importLedger(from: broken, name: "Broken fixture")
            XCTFail("an invalid ledger must not publish")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("main.bean:"), error.localizedDescription)
        }
        #else
        throw XCTSkip("Requires app-linked Go and Beancount runtimes")
        #endif
    }
}
