import Foundation
import XCTest
@testable import LedgerMobile

final class LocalLedgerBackupTests: XCTestCase {
    private actor Engine: LocalLedgerEngine {
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            throw LocalLedgerError.operationFailed("unused")
        }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("LocalLedgerBackupTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func ledger(_ files: [String: String]) async throws -> (LocalLedgerWorkspace, LocalLedgerDescriptor, URL) {
        let root = try directory()
        let workspace = LocalLedgerWorkspace(rootDirectory: root.appendingPathComponent("workspace"))
        try await workspace.commit(changes: files.map { LocalLedgerWorkspace.Change.write(Data($0.value.utf8), to: $0.key) }) { _ in }
        let descriptor = LocalLedgerDescriptor(id: UUID(), name: "家庭_账本", entrypoint: "main.bean", createdAt: Date())
        return (workspace, descriptor, root)
    }

    private static func contents(of directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        while let url = enumerator.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(directory.resolvingSymlinksInPath().path.count + 1))
            result[path] = try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }

    private func archive(_ files: [String: String], in root: URL) throws -> (URL, LedgerBackupManifest) {
        let source = root.appendingPathComponent("source-" + UUID().uuidString)
        for (path, text) in files {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let scanned = try LedgerBackupArchive.scan(directory: source)
        let manifest = LedgerBackupManifest(formatVersion: 1, ledgerID: UUID(), ledgerName: "Test", entrypoint: "main.bean",
            revisionID: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            contentDigest: LedgerBackupArchive.contentDigest(of: scanned.map(\.entry)), files: scanned.map(\.entry))
        let output = root.appendingPathComponent(UUID().uuidString + ".ledgerbackup")
        try LedgerBackupArchive.write(scanned, manifest: manifest, to: output)
        return (output, manifest)
    }

    func testArchiveRoundTripsTreeAndExcludesGitMetadata() throws {
        let root = try directory()
        let files = ["main.bean": "option \"title\" \"T\"\n", "years/2026.bean": "; 2026\n", "documents/empty.txt": "",
                     ".git/config": "[core]\n"]
        let (url, manifest) = try archive(files, in: root)
        XCTAssertEqual(manifest.files.map(\.path), ["documents/empty.txt", "main.bean", "years/2026.bean"])
        XCTAssertEqual(try LedgerBackupArchive.readManifest(at: url), manifest)

        let target = root.appendingPathComponent("restored")
        XCTAssertEqual(try LedgerBackupArchive.extract(url, to: target), manifest)
        var expected = files
        expected.removeValue(forKey: ".git/config")
        XCTAssertEqual(try Self.contents(of: target), expected)
    }

    func testTamperedOrTruncatedArchiveIsRejected() throws {
        let root = try directory()
        let (url, _) = try archive(["main.bean": "1970-01-01 open Assets:Cash\n"], in: root)
        var data = try Data(contentsOf: url)
        data[data.count - 2] ^= 0x01
        let tampered = root.appendingPathComponent("tampered.ledgerbackup")
        try data.write(to: tampered)
        XCTAssertThrowsError(try LedgerBackupArchive.extract(tampered, to: root.appendingPathComponent("a"))) { error in
            guard case .corrupt = error as? LedgerBackupError else { return XCTFail("\(error)") }
        }

        let truncated = root.appendingPathComponent("truncated.ledgerbackup")
        try data.dropLast(3).write(to: truncated)
        XCTAssertThrowsError(try LedgerBackupArchive.readManifest(at: truncated))

        let foreign = root.appendingPathComponent("foreign.ledgerbackup")
        try Data("not a backup at all".utf8).write(to: foreign)
        XCTAssertThrowsError(try LedgerBackupArchive.readManifest(at: foreign)) { error in
            XCTAssertEqual(error as? LedgerBackupError, .notABackup)
        }
    }

    func testManifestCannotEscapeExtractionDirectory() throws {
        let root = try directory()
        for path in ["../escape.bean", "/abs.bean", "a//b.bean", ".git/hooks/post-checkout", "A.bean|a.bean"] {
            let paths = path.split(separator: "|").map(String.init)
            let entries = paths.map { LedgerBackupManifest.File(path: $0, size: 1, sha256: String(repeating: "0", count: 64)) }
            let manifest = LedgerBackupManifest(formatVersion: 1, ledgerID: UUID(), ledgerName: "Evil", entrypoint: "main.bean",
                revisionID: UUID(), createdAt: Date(timeIntervalSince1970: 0),
                contentDigest: LedgerBackupArchive.contentDigest(of: entries), files: entries)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let json = try encoder.encode(manifest)
            var data = LedgerBackupArchive.magic
            data.append(contentsOf: [0, 0, 0, 1])
            withUnsafeBytes(of: UInt32(json.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(json)
            data.append(Data(repeating: 0x41, count: entries.count))
            let url = root.appendingPathComponent(UUID().uuidString + ".ledgerbackup")
            try data.write(to: url)
            XCTAssertThrowsError(try LedgerBackupArchive.extract(url, to: root.appendingPathComponent(UUID().uuidString)), path) { error in
                guard case .corrupt = error as? LedgerBackupError else { return XCTFail("\(path): \(error)") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.bean").path))
    }

    func testEntryNamesSurviveUnderscoresProviderCopiesAndPlaceholders() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let digest = String(repeating: "ab", count: 32)
        let name = LedgerBackupEntry.fileName(ledgerName: "家庭_账本/2026", createdAt: date, contentDigest: digest)
        XCTAssertEqual(name, "家庭-账本-2026_20270115T080000Z_abababababab.ledgerbackup")
        let folder = URL(fileURLWithPath: "/backups")
        let id = UUID()
        for variant in [name, name.replacingOccurrences(of: ".ledgerbackup", with: " 2.ledgerbackup"), "." + name + ".icloud"] {
            let entry = try XCTUnwrap(LedgerBackupEntry(url: folder.appendingPathComponent(variant), ledgerID: id, size: nil), variant)
            XCTAssertEqual(entry.ledgerName, "家庭-账本-2026")
            XCTAssertEqual(entry.createdAt, date)
            XCTAssertEqual(entry.digestPrefix, "abababababab")
        }
        XCTAssertNil(LedgerBackupEntry(url: folder.appendingPathComponent("notes.txt"), ledgerID: id, size: nil))
        XCTAssertNil(LedgerBackupEntry(url: folder.appendingPathComponent("x_yesterday_abc.ledgerbackup"), ledgerID: id, size: nil))
    }

    func testUnchangedContentIsNotBackedUpTwiceAndRetentionPrunesOldest() async throws {
        let (workspace, descriptor, root) = try await ledger(["main.bean": "; v0\n"])
        let store = LedgerBackupStore(rootDirectory: root.appendingPathComponent("iCloud"), retention: 2,
            temporaryDirectory: root)
        try FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: false)

        let first = try await store.backup(workspace: workspace, descriptor: descriptor, now: Date(timeIntervalSince1970: 1_000))
        guard case .created = first else { return XCTFail("\(first)") }
        let repeated = try await store.backup(workspace: workspace, descriptor: descriptor, now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(repeated, .unchanged(first.entry))

        for version in 1...3 {
            let current = try await workspace.currentRevision()
            try await workspace.commit(expectedRevisionID: current?.id,
                changes: [.write(Data("; v\(version)\n".utf8), to: "main.bean")]) { _ in }
            let outcome = try await store.backup(workspace: workspace, descriptor: descriptor,
                now: Date(timeIntervalSince1970: TimeInterval(2_000 + version * 1_000)))
            guard case .created = outcome else { return XCTFail("\(outcome)") }
        }
        let listed = try await store.list()
        XCTAssertEqual(listed.map(\.createdAt), [Date(timeIntervalSince1970: 5_000), Date(timeIntervalSince1970: 4_000)])
        XCTAssertTrue(listed.allSatisfy { $0.ledgerID == descriptor.id })
        // An unrelated file in the ledger folder is never pruned.
        let foreign = store.rootDirectory.appendingPathComponent(descriptor.id.uuidString).appendingPathComponent("README.txt")
        try Data().write(to: foreign)
        let current = try await workspace.currentRevision()
        try await workspace.commit(expectedRevisionID: current?.id, changes: [.write(Data("; v4\n".utf8), to: "main.bean")]) { _ in }
        _ = try await store.backup(workspace: workspace, descriptor: descriptor, now: Date(timeIntervalSince1970: 6_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testRestoreReplacesTreeAsNewRevisionAndRejectsStaleConfirmation() async throws {
        let (workspace, descriptor, root) = try await ledger(["main.bean": "; original\n", "old.bean": "; removed later\n"])
        let store = LedgerBackupStore(rootDirectory: root.appendingPathComponent("iCloud"), temporaryDirectory: root)
        try FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: false)
        let backup = try await store.backup(workspace: workspace, descriptor: descriptor).entry

        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: Engine(), validator: { _, _ in })
        let edited = try await workspace.currentRevision()
        try await workspace.commit(expectedRevisionID: edited?.id, changes: [
            .write(Data("; edited\n".utf8), to: "main.bean"), .remove("old.bean"), .write(Data("; new\n".utf8), to: "new.bean")
        ]) { _ in }
        let beforeRestore = try await workspace.currentRevision()

        let extracted = try await store.extract(backup)
        defer { LedgerBackupStore.discardExtraction(extracted.directory) }
        do {
            try await repository.restoreBackup(from: extracted.directory, expectedRevisionID: edited?.id)
            XCTFail("Restore accepted a stale confirmation")
        } catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }

        try await repository.restoreBackup(from: extracted.directory, expectedRevisionID: beforeRestore?.id)
        let restored = try await workspace.currentRevision()
        XCTAssertEqual(restored?.parentID, beforeRestore?.id)
        let tree = try await workspace.withCurrentSnapshot { _, directory in try Self.contents(of: directory) }
        XCTAssertEqual(tree, ["main.bean": "; original\n", "old.bean": "; removed later\n"])
    }

    func testRestoreRequiresCurrentEntrypoint() async throws {
        let (workspace, descriptor, root) = try await ledger(["main.bean": "; a\n"])
        let source = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("; b\n".utf8).write(to: source.appendingPathComponent("ledger.bean"))
        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: Engine(), validator: { _, _ in })
        let current = try await workspace.currentRevision()
        do {
            try await repository.restoreBackup(from: source, expectedRevisionID: current?.id)
            XCTFail("Restore accepted a tree without the entry file")
        } catch { XCTAssertEqual(error as? LedgerBackupError, .entrypointMissing("main.bean")) }
    }
}
