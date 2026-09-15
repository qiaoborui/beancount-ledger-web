import Foundation
import XCTest
@testable import LedgerMobile

@MainActor
final class LocalOnlySessionTests: XCTestCase {
    private struct Engine: LocalLedgerEngine {
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            if request.path == "/api/ledger/bootstrap" {
                return Data("""
                {"start":"2026-09-01","end":"2026-10-01","summary":{"currency":"CNY","income":0,"expense":0,"net":0},"accountBalances":[],"transactions":[],"accounts":[],"valuationCurrency":"CNY","sensitiveUnlocked":true}
                """.utf8)
            }
            return Data("{}".utf8)
        }
    }

    private final class Authenticator: LocalLedgerAuthenticating {
        let isAvailable = true
        func authenticate() async throws { }
    }

    private struct WidgetCredentials: LedgerWidgetCredentialStoring {
        let isAvailable = false
        func load() throws -> LedgerWidgetCredential? { nil }
        func save(_ credential: LedgerWidgetCredential) throws { }
        func suspend() throws { }
        func pendingRevocation() throws -> LedgerWidgetCredential? { nil }
        func completeRevocation(deviceID: String) throws { }
    }

    func testProductionLocalOnlyIgnoresPersistedServerAndRejectsRemoteRepository() async throws {
        let suite = "local-only-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://previous.example.com", forKey: "ledger.mobile.server-origin")
        defaults.set("remote", forKey: "ledger.mobile.storage-mode")
        var calls = 0
        let session = LedgerSession(repositoryFactory: { location in
            calls += 1
            throw LedgerRepositoryError.unsupportedLocation(location)
        }, localOnly: true, defaults: defaults)
        await session.start()
        XCTAssertEqual(session.phase, .configuration)
        XCTAssertNil(session.location)
        XCTAssertNil(session.serverURL)
        session.serverInput = "https://previous.example.com"
        await session.saveServer()
        XCTAssertNil(session.serverURL)
        XCTAssertEqual(session.phase, .configuration)
        XCTAssertThrowsError(try session.repository(at: .remote(URL(string: "https://previous.example.com")!)))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(defaults.string(forKey: "ledger.mobile.server-origin"), "https://previous.example.com", "Prior preferences stay recoverable")
    }

    func testColdLocalStartDuringInactiveSceneLeavesAnUnlockableState() async throws {
        let suite = "local-cold-start-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: Engine(), validator: { _, _ in })
        let ledger = try await catalog.create(name: "Cold start fixture")
        defaults.set(ledger.id.uuidString, forKey: "ledger.mobile.active-local-ledger")
        let session = LedgerSession(repositoryFactory: { location in
            throw LedgerRepositoryError.unsupportedLocation(location)
        }, localCatalog: catalog, defaults: defaults)
        await session.updateActivity(isActive: false, isBackground: false)
        await session.start()
        XCTAssertEqual(session.phase, .locked(authenticated: true), "An inactive cold launch must leave an unlockable screen instead of an indefinite spinner")
        XCTAssertNil(session.ledger)
        XCTAssertFalse(session.amountsVisible)
    }

    func testStorageConfigurationSerializesAgainstSyncAndDisconnect() async throws {
        let suite = "local-storage-session-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: Engine(), validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Storage session fixture")
        let session = LedgerSession(repositoryFactory: { location in
            XCTFail("Storage settings created a remote ledger repository")
            throw LedgerRepositoryError.unsupportedLocation(location)
        }, localOnly: true, localCatalog: catalog, localAuthenticator: Authenticator(), defaults: defaults,
            widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: suite, lockDirectory: root),
            widgetCredentialStore: WidgetCredentials())
        await session.openLocalLedger(descriptor)
        XCTAssertEqual(session.phase, .ready, session.errorMessage ?? "")
        let held = expectation(description: "catalog actor held")
        let release = DispatchSemaphore(value: 0)
        let holding = Task { await catalog.holdForStorageSessionTest(entered: held, release: release) }
        await fulfillment(of: [held], timeout: 3)
        let entered = expectation(description: "configuration awaiting catalog")
        let configuring = Task {
            entered.fulfill()
            try await session.configureLocalGit(repositoryURL: "https://example.invalid/fixture.git", branch: "main", credential: nil)
        }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(session.isStorageSyncBusy)
        do { try await session.disconnectLocalGit(); XCTFail("Disconnect overlapped configuration") } catch { }
        do { _ = try await session.synchronizeLocalStorage(); XCTFail("Sync overlapped configuration") } catch { }
        release.signal()
        await holding.value
        try await configuring.value
        XCTAssertFalse(session.isStorageSyncBusy)
        XCTAssertEqual(session.localGitConfiguration?.repositoryURL.absoluteString, "https://example.invalid/fixture.git")
        XCTAssertEqual(session.phase, .ready)
    }
}

private extension LocalLedgerCatalog {
    func holdForStorageSessionTest(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        _ = release.wait(timeout: .now() + 5)
    }
}
