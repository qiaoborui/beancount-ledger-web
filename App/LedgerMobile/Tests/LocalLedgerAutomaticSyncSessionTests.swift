import Foundation
import XCTest
@testable import LedgerMobile

@MainActor
final class LocalLedgerAutomaticSyncSessionTests: XCTestCase {
    private static let activeKey = "ledger.mobile.active-local-ledger"
    private static let authorizationKey = "ledger.mobile.background-git-authorization"
    private static let disabledPrefix = "ledger.mobile.auto-sync-disabled."
    private static let pausedPrefix = "ledger.mobile.auto-sync-paused."

    private actor Gate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func suspend() async {
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private final class Authenticator: LocalLedgerAuthenticating {
        let isAvailable = true
        var accepts = false
        private(set) var calls = 0
        func authenticate() async throws {
            calls += 1
            if !accepts { throw LocalLedgerAuthenticationError.cancelled }
        }
    }

    private struct Credentials: LocalGitCredentialStoring {
        func load(for id: UUID) throws -> LocalGitCredential? { nil }
        func save(_ credential: LocalGitCredential, for id: UUID) throws {}
        func remove(for id: UUID) throws {}
    }

    private struct WidgetCredentials: LedgerWidgetCredentialStoring {
        let isAvailable = false
        func load() throws -> LedgerWidgetCredential? { nil }
        func save(_ credential: LedgerWidgetCredential) throws {}
        func suspend() throws {}
        func pendingRevocation() throws -> LedgerWidgetCredential? { nil }
        func completeRevocation(deviceID: String) throws {}
    }

    private actor Validator {
        private(set) var contents: [String] = []
        func validate(_ root: URL, entry: String) throws {
            let text = try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8)
            contents.append(text)
            guard text.hasPrefix("; synthetic expense "),
                  Double(text.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") != nil else {
                throw EmbeddedBeancountValidator.ValidationError(message: "Synthetic validator rejected candidate")
            }
        }
    }

    private actor Engine: LocalLedgerEngine {
        private(set) var requests: [LocalLedgerEngineRequest] = []
        private var reportGate: Gate?
        func suspendReport(_ gate: Gate) { reportGate = gate }
        func resetRequests() { requests = [] }
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            requests.append(request)
            let text = try String(contentsOf: URL(fileURLWithPath: request.workspaceRoot)
                .appendingPathComponent(request.entrypoint), encoding: .utf8)
            let expense = Double(text.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
            switch request.path {
            case "/api/ledger/version": return Data("{}".utf8)
            case "/api/ledger/bootstrap": return Data(LedgerModelsTests.bootstrapJSON.utf8)
            case "/api/ledger/imports/documents": return Data(#"{"documents":[]}"#.utf8)
            case "/api/ledger/home-report":
                if let gate = reportGate { reportGate = nil; await gate.suspend() }
                return try JSONSerialization.data(withJSONObject: [
                    "start": request.query["start"] ?? "", "end": request.query["end"] ?? "",
                    "currency": request.query["valuationCurrency"] ?? "CNY",
                    "current": ["kpis": ["expense": expense, "transactionCount": 1], "categorySeries": []],
                    "previous": ["kpis": ["expense": 0, "transactionCount": 0], "categorySeries": []],
                    "dailyExpenseSeries": [], "generatedAt": "2026-09-15T04:00:00Z"
                ])
            default: throw LocalLedgerError.operationFailed("Unexpected synthetic engine request")
            }
        }
    }

    /// Represents an HTTPS remote entirely in memory; requests never leave the fixture.
    private actor Git: LocalGitTransport {
        private var commits = ["baseline": "; synthetic expense 10\n"]
        private var head = "baseline"
        private var authenticationFailure = false
        private var parents: [String: String] = [:]
        private var nextFetch: XCTestExpectation?
        private var nextPush: XCTestExpectation?
        private var fetchGate: Gate?
        private(set) var requests: [LocalGitRequest] = []
        func setRemote(_ text: String) { head = "web-update"; commits[head] = text }
        func failAuthentication(_ value: Bool) { authenticationFailure = value }
        func resetRequests() { requests = [] }
        func observeNextFetch(_ expectation: XCTestExpectation) { nextFetch = expectation }
        func observeNextPush(_ expectation: XCTestExpectation) { nextPush = expectation }
        func suspendFetch(_ gate: Gate) { fetchGate = gate }
        func remoteContents() -> String? { commits[head] }
        func dispatch(_ request: LocalGitRequest) async throws -> Data {
            requests.append(request)
            switch request.operation {
            case "fetch":
                nextFetch?.fulfill()
                nextFetch = nil
                if let gate = fetchGate { fetchGate = nil; await gate.suspend() }
                if authenticationFailure {
                    throw LocalGitTransportFailure(code: "git.authentication", message: "Synthetic credential expired")
                }
                return try JSONSerialization.data(withJSONObject: ["remoteHead": head, "branchExists": true])
            case "export":
                let root = URL(fileURLWithPath: try XCTUnwrap(request.directory))
                let text = try XCTUnwrap(commits[try XCTUnwrap(request.commit)])
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data(text.utf8).write(to: root.appendingPathComponent("main.bean"))
                return Data("{}".utf8)
            case "commit":
                let root = URL(fileURLWithPath: try XCTUnwrap(request.directory))
                let commit = UUID().uuidString
                commits[commit] = try String(contentsOf: root.appendingPathComponent("main.bean"), encoding: .utf8)
                parents[commit] = try XCTUnwrap(request.parent)
                return try JSONSerialization.data(withJSONObject: ["commit": commit])
            case "push":
                let commit = try XCTUnwrap(request.commit)
                guard request.expectedRemoteHead == head, parents[commit] == head else {
                    throw LocalStorageError.gitFailure("Synthetic remote head changed")
                }
                head = commit
                nextPush?.fulfill()
                nextPush = nil
                return try JSONSerialization.data(withJSONObject: ["remoteHead": head])
            default:
                XCTFail("Unexpected Git operation \(request.operation)")
                throw LocalStorageError.gitFailure("Unexpected synthetic Git operation")
            }
        }
    }

    private struct Fixture {
        let catalog: LocalLedgerCatalog
        let descriptor: LocalLedgerDescriptor
        let defaults: UserDefaults
        let store: LedgerWidgetSnapshotStore
        let git: Git
        let engine: Engine
        let validator: Validator
        let authenticator: Authenticator

        @MainActor
        func session(enabled: Bool = true) -> LedgerSession {
            LedgerSession(localOnly: true, automaticLocalSyncServicesEnabled: enabled,
                localCatalog: catalog, localAuthenticator: authenticator, defaults: defaults,
                widgetSnapshotStore: store, widgetCredentialStore: WidgetCredentials(),
                ledgerNow: { ISO8601DateFormatter().date(from: "2026-09-15T04:00:00Z")! })
        }
    }

    private func fixture() async throws -> Fixture {
        let suite = "local-background-session-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let git = Git(), engine = Engine(), validator = Validator()
        let catalog = LocalLedgerCatalog(rootDirectory: root.appendingPathComponent("Ledgers"),
            engine: engine, gitTransport: git, gitCredentials: Credentials(),
            validator: { try await validator.validate($0, entry: $1) })
        let descriptor = try await catalog.importGit(repositoryURL: "https://example.invalid/synthetic-ledger.git",
            name: "Synthetic background ledger")
        defaults.set(descriptor.id.uuidString, forKey: Self.activeKey)
        defaults.set(descriptor.id.uuidString + ":" + (try XCTUnwrap(descriptor.git).id.uuidString), forKey: Self.authorizationKey)
        await git.resetRequests()
        await engine.resetRequests()
        return Fixture(catalog: catalog, descriptor: descriptor, defaults: defaults,
            store: LedgerWidgetSnapshotStore(suiteName: suite, lockDirectory: root),
            git: git, engine: engine, validator: validator, authenticator: Authenticator())
    }

    func testColdAuthorizedBackgroundFetchPublishesValidatedRemoteRevisionWithoutUnlockingUI() async throws {
        let fixture = try await fixture()
        let repository = fixture.catalog.repository(for: fixture.descriptor)
        let previous = try await repository.workspace.currentRevision()
        await fixture.git.setRemote("; synthetic expense 42\n")
        let session = fixture.session()
        XCTAssertEqual(session.phase, .checking)
        let succeeded = await session.performBackgroundLocalSync()
        XCTAssertTrue(succeeded, session.localSyncStatus?.message ?? "Background publication failed")
        XCTAssertEqual(session.phase, .checking)
        XCTAssertNil(session.ledger)
        XCTAssertFalse(session.amountsVisible)
        XCTAssertEqual(fixture.authenticator.calls, 0)
        let draft = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(draft.text, "; synthetic expense 42\n")
        XCTAssertNotEqual(draft.revisionID, previous?.id)
        XCTAssertEqual(fixture.store.load()?.expense.amount, 42)
        let validated = await fixture.validator.contents
        XCTAssertEqual(validated.last, draft.text)
        let requests = await fixture.engine.requests.filter { $0.path != "/api/ledger/version" }
        XCTAssertEqual(requests.count, 6)
        let root = try await repository.workspace.withCurrentSnapshot { _, root in root.path }
        XCTAssertEqual(Set(requests.map(\.workspaceRoot)), [root])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && !$0.staging })
        let gitRequests = await fixture.git.requests
        XCTAssertEqual(gitRequests.map(\.operation), ["fetch", "export", "export"])
        XCTAssertTrue(gitRequests.allSatisfy { $0.url == "https://example.invalid/synthetic-ledger.git" })
    }

    func testForegroundSaveNotificationAutomaticallyPushesValidatedLocalChange() async throws {
        try await assertForegroundSaveAutomaticallyPushes(recoverAuthentication: false)
    }

    func testSuccessfulManualAuthenticationRecoveryRestartsAutomaticPushes() async throws {
        try await assertForegroundSaveAutomaticallyPushes(recoverAuthentication: true)
    }

    private func assertForegroundSaveAutomaticallyPushes(recoverAuthentication: Bool) async throws {
        let fixture = try await fixture()
        fixture.authenticator.accepts = true
        await fixture.git.failAuthentication(recoverAuthentication)
        let firstFetch = expectation(description: "foreground eligibility starts initial fetch")
        await fixture.git.observeNextFetch(firstFetch)
        let session = fixture.session()
        defer { session.chooseLedger() }
        await session.start()
        XCTAssertEqual(session.phase, .ready, session.errorMessage ?? "")
        XCTAssertEqual(fixture.authenticator.calls, 1)
        await fulfillment(of: [firstFetch], timeout: 3)
        try await waitForSyncToSettle(session, git: fixture.git)

        if recoverAuthentication {
            let pauseKey = Self.pausedPrefix + (try XCTUnwrap(fixture.descriptor.git).id.uuidString)
            XCTAssertTrue(fixture.defaults.bool(forKey: pauseKey))
            await fixture.git.failAuthentication(false)
            let status = try await session.synchronizeLocalStorage()
            XCTAssertEqual(status.phase, .synced)
            XCTAssertFalse(fixture.defaults.bool(forKey: pauseKey))
            // Recovery queues an immediate automatic pass after the manual slot exits.
            await Task.yield()
            try await waitForSyncToSettle(session, git: fixture.git)
        }

        let pushed = expectation(description: "save notification produces an automatic Git push")
        await fixture.git.observeNextPush(pushed)
        let repository = try XCTUnwrap(session.localRepository)
        let draft = try await repository.readFile(path: "main.bean")
        let edited = "; synthetic expense 73\n"
        try await repository.saveFile(draft, text: edited)
        // No explicit synchronization follows the write; the repository notification
        // must pass through the session observer and coordinator's two-second debounce.
        await fulfillment(of: [pushed], timeout: 5)
        try await waitForSyncToSettle(session, git: fixture.git)
        let remote = await fixture.git.remoteContents()
        XCTAssertEqual(remote, edited)
        let local = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(local.text, edited)
        let pushes = await fixture.git.requests.filter { $0.operation == "push" }
        XCTAssertEqual(pushes.count, 1)
        XCTAssertEqual(pushes.first?.expectedRemoteHead, "baseline")
        XCTAssertEqual(fixture.authenticator.calls, 1)
    }

    private func waitForSyncToSettle(_ session: LedgerSession, git: Git) async throws {
        var previousRequestCount: Int?
        var idleSamples = 0
        for _ in 0..<300 {
            let requestCount = await git.requests.count
            // Foreground eligibility and preparation can queue successive initial
            // passes. A single false busy flag can be the gap between those passes.
            if !session.isStorageSyncBusy, requestCount == previousRequestCount {
                idleSamples += 1
                if idleSamples == 2 { return }
            } else {
                idleSamples = 0
            }
            previousRequestCount = requestCount
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Automatic synchronization did not settle within three seconds")
    }

    func testManualAuthenticationRecoveryWhileBackgroundingResumesOnForeground() async throws {
        let fixture = try await fixture()
        fixture.authenticator.accepts = true
        await fixture.git.failAuthentication(true)
        let failedFetch = expectation(description: "initial foreground sync encounters expired credential")
        await fixture.git.observeNextFetch(failedFetch)
        let session = fixture.session()
        defer { session.chooseLedger() }
        await session.start()
        XCTAssertEqual(session.phase, .ready, session.errorMessage ?? "")
        await fulfillment(of: [failedFetch], timeout: 3)
        try await waitForSyncToSettle(session, git: fixture.git)
        let pauseKey = Self.pausedPrefix + (try XCTUnwrap(fixture.descriptor.git).id.uuidString)
        XCTAssertTrue(fixture.defaults.bool(forKey: pauseKey))

        await fixture.git.failAuthentication(false)
        await fixture.git.setRemote("; synthetic expense 55\n")
        let entered = expectation(description: "manual recovery fetch is in flight")
        let gate = Gate(entered)
        await fixture.git.suspendFetch(gate)
        let manual = Task { try await session.synchronizeLocalStorage() }
        await fulfillment(of: [entered], timeout: 3)
        await session.updateActivity(isActive: false, isBackground: true)
        XCTAssertFalse(session.amountsVisible)
        await gate.release()
        let status = try await manual.value
        XCTAssertEqual(status.phase, .synced)
        XCTAssertFalse(fixture.defaults.bool(forKey: pauseKey))

        let resumed = expectation(description: "foreground resumes automatic sync after background recovery")
        await fixture.git.observeNextFetch(resumed)
        await session.updateActivity(isActive: true, isBackground: false)
        await fulfillment(of: [resumed], timeout: 3)
        try await waitForSyncToSettle(session, git: fixture.git)
        let repository = try XCTUnwrap(session.localRepository)
        let draft = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(draft.text, "; synthetic expense 55\n")
        XCTAssertEqual(fixture.authenticator.calls, 1)
    }

    func testDisabledUnauthorizedWrongActiveAndUnconfiguredServicesNeverFetch() async throws {
        for condition in ["disabled", "unauthorized", "wrong-active", "services-disabled"] {
            let fixture = try await fixture()
            let config = try XCTUnwrap(fixture.descriptor.git)
            switch condition {
            case "disabled": fixture.defaults.set(true, forKey: Self.disabledPrefix + config.id.uuidString)
            case "unauthorized": fixture.defaults.set(fixture.descriptor.id.uuidString + ":" + UUID().uuidString,
                                                       forKey: Self.authorizationKey)
            case "wrong-active": fixture.defaults.set(UUID().uuidString, forKey: Self.activeKey)
            default: break
            }
            let session = fixture.session(enabled: condition != "services-disabled")
            let succeeded = await session.performBackgroundLocalSync()
            XCTAssertFalse(succeeded, condition)
            let requests = await fixture.git.requests
            XCTAssertTrue(requests.isEmpty, condition)
            XCTAssertNil(fixture.store.load(), condition)
            XCTAssertEqual(fixture.authenticator.calls, 0, condition)
        }
    }

    func testAuthenticationFailurePausesAcrossColdSessionRestart() async throws {
        let fixture = try await fixture()
        await fixture.git.failAuthentication(true)
        let first = await fixture.session().performBackgroundLocalSync()
        XCTAssertFalse(first)
        let key = Self.pausedPrefix + (try XCTUnwrap(fixture.descriptor.git).id.uuidString)
        XCTAssertTrue(fixture.defaults.bool(forKey: key))
        await fixture.git.failAuthentication(false)
        let restarted = await fixture.session().performBackgroundLocalSync()
        XCTAssertFalse(restarted)
        let requests = await fixture.git.requests
        XCTAssertEqual(requests.map(\.operation), ["fetch"])
        XCTAssertNil(fixture.store.load())
        XCTAssertEqual(fixture.authenticator.calls, 0)
    }

    func testRejectedRemotePreservesGenerationAndExistingWidget() async throws {
        let fixture = try await fixture()
        let session = fixture.session()
        let initial = await session.performBackgroundLocalSync()
        XCTAssertTrue(initial, session.localSyncStatus?.message ?? "Initial background publication failed")
        let snapshot = fixture.store.loadState()
        let repository = fixture.catalog.repository(for: fixture.descriptor)
        let revision = try await repository.workspace.currentRevision()
        await fixture.git.setRemote("INVALID SYNTHETIC LEDGER")
        let succeeded = await session.performBackgroundLocalSync()
        XCTAssertFalse(succeeded)
        let after = try await repository.workspace.currentRevision()
        XCTAssertEqual(after, revision)
        XCTAssertEqual(fixture.store.loadState(), snapshot)
        let key = Self.pausedPrefix + (try XCTUnwrap(fixture.descriptor.git).id.uuidString)
        XCTAssertTrue(fixture.defaults.bool(forKey: key))
    }

    func testManualSyncFailureReplacesPreviousSyncedStatusAndPreservesConflicts() async throws {
        for conflict in [false, true] {
            let fixture = try await fixture()
            fixture.authenticator.accepts = true
            let session = fixture.session(enabled: false)
            defer { session.chooseLedger() }
            await session.start()
            _ = try await session.synchronizeLocalStorage()
            XCTAssertEqual(session.localSyncStatus?.phase, .synced)
            if conflict {
                let repository = try XCTUnwrap(session.localRepository)
                let draft = try await repository.readFile(path: "main.bean")
                try await repository.saveFile(draft, text: "; synthetic expense 20\n")
                await fixture.git.setRemote("; synthetic expense 30\n")
            } else {
                await fixture.git.failAuthentication(true)
            }
            do {
                _ = try await session.synchronizeLocalStorage()
                XCTFail("Expected synthetic manual synchronization failure")
            } catch {}
            XCTAssertFalse(session.isStorageSyncBusy)
            XCTAssertEqual(session.localSyncStatus?.phase, conflict ? .conflicted : .failed)
            if conflict { XCTAssertEqual(session.localSyncStatus?.conflictPaths, ["main.bean"]) }
            else { XCTAssertEqual(session.localSyncStatus?.message, "Synthetic credential expired") }
        }
    }

    func testExpirationAndLedgerSwitchDuringWidgetReadSuppressStalePublication() async throws {
        for switchingLedger in [false, true] {
            let fixture = try await fixture()
            await fixture.git.setRemote("; synthetic expense 99\n")
            let entered = expectation(description: "widget report is in flight")
            let gate = Gate(entered)
            await fixture.engine.suspendReport(gate)
            let session = fixture.session()
            let work = Task { await session.performBackgroundLocalSync() }
            await fulfillment(of: [entered], timeout: 3)
            if switchingLedger { session.chooseLedger() } else { work.cancel() }
            await gate.release()
            let succeeded = await work.value
            XCTAssertFalse(succeeded)
            XCTAssertNil(fixture.store.load())
            XCTAssertNil(session.ledger)
            XCTAssertFalse(session.amountsVisible)
            XCTAssertEqual(fixture.authenticator.calls, 0)
            if switchingLedger {
                XCTAssertEqual(session.phase, .configuration)
                XCTAssertNil(session.location)
                XCTAssertNil(fixture.defaults.string(forKey: Self.authorizationKey))
            }
        }
    }
}
