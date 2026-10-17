import XCTest
@testable import LedgerMobile

/// `GitLocalStorage.status()` runs after every local save notification and used to
/// re-read and re-decode `state.json` each time. The decoded state is now cached
/// against the file's modification date and size, so the cache must still miss
/// whenever the file is replaced.
final class GitSyncStateCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-state-cache-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Mirrors `GitLocalStorage.State`. `conflictPaths` must be present: the
    /// synthesised decoder rejects a payload that omits it even though the
    /// property has a default.
    private struct State: Codable {
        var version = 1
        var lastSyncedAt: Date?
        var conflictPaths: [String] = []
    }

    private static func state(lastSyncedAt: TimeInterval) -> String {
        let data = try! JSONEncoder().encode(State(lastSyncedAt: Date(timeIntervalSinceReferenceDate: lastSyncedAt)))
        return String(decoding: data, as: UTF8.self)
    }

    private func makeStorage() throws -> GitLocalStorage {
        let workspace = LocalLedgerWorkspace(rootDirectory: root.appendingPathComponent("workspace"))
        let configuration = try LocalGitConfiguration(repositoryURL: "https://example.invalid/cache.git")
        return GitLocalStorage(workspace: workspace, configuration: configuration,
            transport: NoopTransport(), credentials: NoopCredentials())
    }

    private func stateURL(_ storage: GitLocalStorage) -> URL {
        storage.workspace.rootDirectory.appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent(storage.configuration.id.uuidString, isDirectory: true)
            .appendingPathComponent("state.json")
    }

    /// A missing state file means default state, and it must not be cached in a
    /// way that hides a state file appearing later.
    func testStatusReflectsStateFileAppearingLater() async throws {
        let storage = try makeStorage()
        let empty = try await storage.status()
        XCTAssertNil(empty.lastSyncedAt)

        let url = stateURL(storage)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(Self.state(lastSyncedAt: 800_000_000).utf8).write(to: url)

        let after = try await storage.status()
        XCTAssertNotNil(after.lastSyncedAt, "a new state file must invalidate the cache")
    }

    /// Replacing the file with different contents must be observed even when the
    /// size is identical.
    func testStatusReflectsRewrittenStateFile() async throws {
        let storage = try makeStorage()
        let url = stateURL(storage)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        try Data(Self.state(lastSyncedAt: 800_000_000).utf8).write(to: url)
        let first = try await storage.status()
        XCTAssertNotNil(first.lastSyncedAt)

        // Same shape, different value.
        try Data(Self.state(lastSyncedAt: 900_000_000).utf8).write(to: url)
        let second = try await storage.status()
        XCTAssertNotEqual(first.lastSyncedAt, second.lastSyncedAt,
            "a rewritten state file must invalidate the cache")
    }
}

private struct NoopTransport: LocalGitTransport {
    func dispatch(_ request: LocalGitRequest) async throws -> Data {
        throw LocalStorageError.gitFailure("not used")
    }
}

private struct NoopCredentials: LocalGitCredentialStoring {
    func load(for id: UUID) throws -> LocalGitCredential? { nil }
    func save(_ credential: LocalGitCredential, for id: UUID) throws {}
    func remove(for id: UUID) throws {}
    func prepareForBackgroundSync(for id: UUID) throws {}
}
