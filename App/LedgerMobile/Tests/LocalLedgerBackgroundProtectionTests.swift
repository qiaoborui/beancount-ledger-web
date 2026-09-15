import Foundation
import XCTest
@testable import LedgerMobile

final class LocalLedgerBackgroundProtectionTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLedgerBackgroundProtectionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPreparationPreservesContentsAndExecutionBitsAcrossWorkspaceTree() async throws {
        let root = try fixture()
        let paths = ["ledger.json", "generations/example/workspace/main.bean", "runtime/cache.json",
                     "sync/example/repository.git/objects/object", "staging/example/helper.sh"]
        for path in paths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: path.hasSuffix(".sh") ? 0o700 : 0o600], ofItemAtPath: file.path)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            #endif
        }
        let credentials = CredentialFixture()
        let configurationID = UUID()
        for _ in 0..<2 {
            try await LocalLedgerBackgroundProtection.prepareForBackgroundSync(
                rootDirectory: root, configurationID: configurationID, credentials: credentials)
        }
        XCTAssertEqual(credentials.preparedIDs, [configurationID, configurationID])
        XCTAssertFalse(credentials.preparedOnMainThread)
        for path in paths {
            let file = root.appendingPathComponent(path)
            XCTAssertEqual(try Data(contentsOf: file), Data(path.utf8))
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, path.hasSuffix(".sh") ? 0o700 : 0o600)
        }
    }

    #if os(iOS)
    func testMigratesExistingFileAndDirectoryProtectionClass() async throws {
        let root = try fixture()
        let file = root.appendingPathComponent("main.bean")
        try Data("; synthetic protection fixture\n".utf8).write(to: file)
        for item in [root, file] {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: item.path)
            let baseline = try FileManager.default.attributesOfItem(atPath: item.path)
            #if targetEnvironment(simulator)
            if baseline[.protectionKey] == nil {
                throw XCTSkip("Simulator accepts protection writes but omits the Data Protection attribute; class migration requires a device filesystem")
            }
            #endif
            XCTAssertEqual(baseline[.protectionKey] as? String, FileProtectionType.complete.rawValue)
        }
        try await LocalLedgerBackgroundProtection.prepareForBackgroundSync(
            rootDirectory: root, configurationID: UUID(), credentials: CredentialFixture())
        for item in [root, file] {
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            XCTAssertEqual(attributes[.protectionKey] as? String,
                FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        }
    }
    #endif

    func testRejectsRootAncestorAndChildSymlinksBeforeCredentialMigration() async throws {
        let fixture = try fixture()
        let actual = fixture.appendingPathComponent("actual")
        let root = actual.appendingPathComponent("ledger")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let alias = fixture.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let credentials = CredentialFixture()
        for candidate in [alias, alias.appendingPathComponent("ledger")] {
            do {
                try await LocalLedgerBackgroundProtection.prepareForBackgroundSync(
                    rootDirectory: candidate, configurationID: UUID(), credentials: credentials)
                XCTFail("Expected symbolic link rejection")
            } catch let error as LocalStorageError {
                XCTAssertEqual(error, .unsafeFile("alias"))
            }
        }
        let outside = fixture.appendingPathComponent("outside.bean")
        try Data("external".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.bean"), withDestinationURL: outside)
        do {
            try await LocalLedgerBackgroundProtection.prepareForBackgroundSync(
                rootDirectory: root, configurationID: UUID(), credentials: credentials)
            XCTFail("Expected symbolic link rejection")
        } catch let error as LocalStorageError {
            XCTAssertEqual(error, .unsafeFile("linked.bean"))
        }
        XCTAssertTrue(credentials.preparedIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), Data("external".utf8))
    }
}

private final class CredentialFixture: LocalGitCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []
    private var onMainThread = false
    var preparedIDs: [UUID] { lock.withLock { ids } }
    var preparedOnMainThread: Bool { lock.withLock { onMainThread } }
    func load(for id: UUID) throws -> LocalGitCredential? { nil }
    func save(_ credential: LocalGitCredential, for id: UUID) throws {}
    func remove(for id: UUID) throws {}
    func prepareForBackgroundSync(for id: UUID) throws {
        lock.withLock {
            ids.append(id)
            onMainThread = onMainThread || Thread.isMainThread
        }
    }
}
