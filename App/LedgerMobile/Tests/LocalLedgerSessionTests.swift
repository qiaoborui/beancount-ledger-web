import Foundation
import XCTest
import Combine
@testable import LedgerMobile

@MainActor
final class LocalLedgerSessionTests: XCTestCase {
    @MainActor
    private final class ActivityProbe {
        var waitingForActiveScene = true
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        let entered: XCTestExpectation
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func suspend() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    private final class Authenticator: LocalLedgerAuthenticating {
        let isAvailable = true
        var gate: Gate?
        var rejects = false
        private(set) var calls = 0
        init(gate: Gate? = nil) { self.gate = gate }
        func authenticate() async throws {
            calls += 1
            if let gate { await gate.suspend() }
            if rejects { throw LocalLedgerAuthenticationError.cancelled }
        }
    }

    private struct InertWidgetStore: LedgerWidgetCredentialStoring {
        let isAvailable = false
        func load() throws -> LedgerWidgetCredential? { nil }
        func save(_ credential: LedgerWidgetCredential) throws { }
        func suspend() throws { }
        func pendingRevocation() throws -> LedgerWidgetCredential? { nil }
        func completeRevocation(deviceID: String) throws { }
    }

    private struct PendingRemoteWidgetStore: LedgerWidgetCredentialStoring {
        let isAvailable = true
        let credential = LedgerWidgetCredential(serverOrigin: "https://old-ledger.example.com",
            deviceID: "old-widget", token: "test-only", valuationCurrency: "CNY", enabled: false)
        func load() throws -> LedgerWidgetCredential? { nil }
        func save(_ credential: LedgerWidgetCredential) throws { }
        func suspend() throws { }
        func pendingRevocation() throws -> LedgerWidgetCredential? { credential }
        func completeRevocation(deviceID: String) throws { }
    }

    private actor UnusedEngine: LocalLedgerEngine {
        private(set) var calls = 0
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            if request.path == "/api/ledger/version" { return Data("{}".utf8) }
            calls += 1
            throw LocalLedgerError.operationFailed("A stale context must never load ledger data")
        }
    }

    private struct LockedBootstrapEngine: LocalLedgerEngine {
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            if request.path == "/api/ledger/bootstrap" {
                return Data("""
                {"start":"2026-09-01","end":"2026-10-01","summary":{"currency":"CNY","income":0,"expense":0,"net":0},"accountBalances":[],"transactions":[],"accounts":[],"valuationCurrency":"CNY","sensitiveUnlocked":false}
                """.utf8)
            }
            return Data("{}".utf8)
        }
    }

    private actor ResumeEngine: LocalLedgerEngine {
        private(set) var bootstrapCalls = 0
        private var bootstrapGate: Gate?
        private var bootstrapExpectation: XCTestExpectation?
        func observeBootstrap(_ expectation: XCTestExpectation?, gate: Gate? = nil) {
            bootstrapExpectation = expectation
            bootstrapGate = gate
        }
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            if request.path == "/api/ledger/version" { return Data("{}".utf8) }
            guard request.path == "/api/ledger/bootstrap" else {
                throw LocalLedgerError.operationFailed("Synthetic optional report unavailable")
            }
            bootstrapCalls += 1
            bootstrapExpectation?.fulfill()
            bootstrapExpectation = nil
            if let gate = bootstrapGate { bootstrapGate = nil; await gate.suspend() }
            let text = try String(contentsOf: URL(fileURLWithPath: request.workspaceRoot)
                .appendingPathComponent(request.entrypoint), encoding: .utf8)
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(LedgerModelsTests.bootstrapJSON.utf8)) as? [String: Any])
            if text.contains("; warm-update") {
                var summary = try XCTUnwrap(payload["summary"] as? [String: Any])
                summary["expense"] = 777
                payload["summary"] = summary
            }
            return try JSONSerialization.data(withJSONObject: payload)
        }
    }

    private func fixture() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let suite = "local-session-tests-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return (root, defaults, suite)
    }

    func testWarmLocalUnlockKeepsReadyShellAndSkipsUnchangedBootstrap() async throws {
        let fixture = try await openedResumeFixture()
        let engine = fixture.engine, session = fixture.session, authenticator = fixture.authenticator
        let summary = session.ledger?.summary
        await session.lock()
        XCTAssertFalse(session.amountsVisible)
        XCTAssertEqual(session.phase, .locked(authenticated: true))
        let extraBootstrap = expectation(description: "unchanged warm ledger avoids rebuilding bootstrap")
        extraBootstrap.isInverted = true
        await engine.observeBootstrap(extraBootstrap)
        var sawChecking = false
        let observation = session.$phase.sink { if $0 == .checking { sawChecking = true } }
        defer { observation.cancel(); session.chooseLedger() }
        let authenticationEntered = expectation(description: "warm device authentication is pending")
        let authenticationGate = Gate(authenticationEntered)
        authenticator.gate = authenticationGate
        let unlocking = Task { await session.unlockLocalLedger() }
        await fulfillment(of: [authenticationEntered], timeout: 3)
        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertFalse(session.amountsVisible)
        await authenticationGate.release()
        await unlocking.value
        authenticator.gate = nil
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.ledger?.summary, summary)
        XCTAssertTrue(session.amountsVisible)
        XCTAssertFalse(sawChecking)
        await fulfillment(of: [extraBootstrap], timeout: 0.1)
        let calls = await engine.bootstrapCalls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(authenticator.calls, 2)
    }

    private func openedResumeFixture() async throws -> (session: LedgerSession, engine: ResumeEngine,
        authenticator: Authenticator, catalog: LocalLedgerCatalog) {
        let fixture = try fixture()
        let engine = ResumeEngine()
        let catalog = LocalLedgerCatalog(rootDirectory: fixture.root.appendingPathComponent("managed"),
            engine: engine, validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Warm local fixture")
        let authenticator = Authenticator()
        let session = LedgerSession(localOnly: true, localCatalog: catalog, localAuthenticator: authenticator,
            defaults: fixture.defaults,
            widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: fixture.suite, lockDirectory: fixture.root),
            widgetCredentialStore: InertWidgetStore())
        await session.openLocalLedger(descriptor)
        XCTAssertEqual(session.phase, .ready)
        return (session, engine, authenticator, catalog)
    }

    func testWarmLocalUnlockShowsAuthenticatedRetainedContentWhileChangedRevisionRefreshes() async throws {
        let fixture = try await openedResumeFixture()
        let session = fixture.session
        defer { session.chooseLedger() }
        let summary = session.ledger?.summary
        let repository = try XCTUnwrap(session.localRepository)
        await session.lock()
        let draft = try await repository.readFile(path: "main.bean")
        try await repository.saveFile(draft, text: draft.text + "; warm-update\n")
        let entered = expectation(description: "changed revision refresh reaches bootstrap")
        let gate = Gate(entered)
        await fixture.engine.observeBootstrap(nil, gate: gate)
        let unlocking = Task { await session.unlockLocalLedger() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.amountsVisible)
        XCTAssertEqual(session.ledger?.summary, summary)
        let refreshed = expectation(description: "new revision replaces retained presentation")
        let observation = session.$ledger.sink { if $0?.summary.expense == 777 { refreshed.fulfill() } }
        defer { observation.cancel() }
        await gate.release()
        await unlocking.value
        await fulfillment(of: [refreshed], timeout: 3)
        XCTAssertEqual(session.phase, .ready)
    }

    func testWarmRefreshCannotPublishAfterChoosingAnotherLedger() async throws {
        let fixture = try await openedResumeFixture()
        let session = fixture.session
        let repository = try XCTUnwrap(session.localRepository)
        await session.lock()
        let draft = try await repository.readFile(path: "main.bean")
        try await repository.saveFile(draft, text: draft.text + "; warm-update\n")
        let entered = expectation(description: "warm refresh is suspended")
        let gate = Gate(entered)
        await fixture.engine.observeBootstrap(nil, gate: gate)
        let unlocking = Task { await session.unlockLocalLedger() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(session.phase, .ready)
        session.chooseLedger()
        let stalePublication = expectation(description: "previous ledger stays hidden after choosing ledger")
        stalePublication.isInverted = true
        let observation = session.$ledger.sink { if $0 != nil { stalePublication.fulfill() } }
        defer { observation.cancel() }
        await gate.release()
        await unlocking.value
        await fulfillment(of: [stalePublication], timeout: 0.1)
        XCTAssertEqual(session.phase, .configuration)
        XCTAssertNil(session.ledger)
        XCTAssertFalse(session.amountsVisible)
    }

    func testFailedWarmAuthenticationAndDifferentLedgerKeepRetainedContentHidden() async throws {
        let fixture = try await openedResumeFixture()
        let session = fixture.session
        defer { session.chooseLedger() }
        await session.lock()
        fixture.authenticator.rejects = true
        await session.unlockLocalLedger()
        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertFalse(session.amountsVisible)
        let calls = await fixture.engine.bootstrapCalls
        XCTAssertEqual(calls, 1)
        fixture.authenticator.rejects = false
        let other = try await fixture.catalog.create(name: "Different local fixture")
        let entered = expectation(description: "different ledger cold bootstrap is suspended")
        let gate = Gate(entered)
        await fixture.engine.observeBootstrap(nil, gate: gate)
        let opening = Task { await session.openLocalLedger(other) }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(session.location, .local(other.id))
        XCTAssertEqual(session.phase, .checking)
        XCTAssertNil(session.ledger)
        XCTAssertFalse(session.amountsVisible)
        await gate.release()
        await opening.value
        XCTAssertEqual(session.phase, .ready)
    }

    func testForegroundReturnWithUnchangedLocalRevisionSkipsBootstrap() async throws {
        let fixture = try await openedResumeFixture()
        let session = fixture.session
        defer { session.chooseLedger() }
        await session.updateActivity(isActive: false, isBackground: true)
        XCTAssertFalse(session.amountsVisible)
        let unnecessaryRead = expectation(description: "same revision foreground return avoids bootstrap")
        unnecessaryRead.isInverted = true
        await fixture.engine.observeBootstrap(unnecessaryRead)
        await session.updateActivity(isActive: true, isBackground: false)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.amountsVisible)
        await fulfillment(of: [unnecessaryRead], timeout: 0.1)
    }

    private func assertInterruptedValidation(importing: Bool, background: Bool) async throws {
        let fixture = try fixture()
        let entered = expectation(description: "canonical validation has begun")
        let gate = Gate(entered)
        let engine = UnusedEngine()
        let catalog = LocalLedgerCatalog(rootDirectory: fixture.root.appendingPathComponent("managed"),
            engine: engine, validator: { _, _ in await gate.suspend() })
        var factoryCalls = 0
        let session = LedgerSession(repositoryFactory: { location in
            factoryCalls += 1
            throw LedgerRepositoryError.unsupportedLocation(location)
        }, localCatalog: catalog, localAuthenticator: Authenticator(), defaults: fixture.defaults,
            widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: fixture.suite, lockDirectory: fixture.root),
            widgetCredentialStore: InertWidgetStore())
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("; imported test ledger\n".utf8).write(to: source.appendingPathComponent("main.bean"))
        let operation = Task {
            if importing {
                await session.importLocalLedger(from: source, name: "Imported", entrypoint: "main.bean")
            } else {
                await session.createLocalLedger(name: "Created", currency: "CNY")
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(session.isLocalOperationBusy)
        if background {
            await session.updateActivity(isActive: false, isBackground: true)
        } else {
            session.chooseLedger()
        }
        await gate.release()
        await operation.value
        XCTAssertEqual(session.phase, .configuration)
        XCTAssertNil(session.location)
        XCTAssertNil(session.serverURL)
        XCTAssertNil(session.ledger)
        XCTAssertFalse(session.amountsVisible)
        XCTAssertFalse(session.isLocalOperationBusy)
        XCTAssertEqual(factoryCalls, 0)
        let engineCalls = await engine.calls
        XCTAssertEqual(engineCalls, 0)
        // The completed, validated ledger remains available for an explicit later open.
        let descriptors = try await catalog.list()
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertNil(fixture.defaults.string(forKey: "ledger.mobile.active-local-ledger"))
    }

    func testCreateCompletionAfterChoosingLedgerKeepsConfigurationContext() async throws {
        try await assertInterruptedValidation(importing: false, background: false)
    }
    func testCreateCompletionInBackgroundKeepsConfigurationContext() async throws {
        try await assertInterruptedValidation(importing: false, background: true)
    }
    func testImportCompletionAfterChoosingLedgerKeepsConfigurationContext() async throws {
        try await assertInterruptedValidation(importing: true, background: false)
    }
    func testImportCompletionInBackgroundKeepsConfigurationContext() async throws {
        try await assertInterruptedValidation(importing: true, background: true)
    }

    func testAuthenticationCompletionAfterChoosingLedgerCannotStartCreation() async throws {
        try await assertInterruptedAuthentication(background: false)
    }
    func testAuthenticationCompletionInBackgroundCannotStartCreation() async throws {
        try await assertInterruptedAuthentication(background: true)
    }

    func testImportAuthenticationWaitsForSceneToBecomeActive() async throws {
        try await assertAuthenticationWaitsForSceneToBecomeActive(importing: true)
    }

    func testCreateAuthenticationWaitsForSceneToBecomeActive() async throws {
        try await assertAuthenticationWaitsForSceneToBecomeActive(importing: false)
    }

    private func assertAuthenticationWaitsForSceneToBecomeActive(importing: Bool) async throws {
        let fixture = try fixture()
        let authenticationEntered = expectation(description: "authentication entered")
        let authentication = Gate(authenticationEntered)
        let validationEntered = expectation(description: "import reaches canonical validation after scene becomes active")
        let completedWhileInactive = expectation(description: "temporary inactivity keeps import pending")
        completedWhileInactive.isInverted = true
        let operationCompleted = expectation(description: "import operation completes")
        let engine = UnusedEngine()
        let catalog = LocalLedgerCatalog(rootDirectory: fixture.root.appendingPathComponent("managed"),
            engine: engine, validator: { root, entry in
                if importing {
                    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8), "; selected folder\n")
                }
                validationEntered.fulfill()
                // End the test at the import boundary, before the unrelated bootstrap path.
                throw LocalLedgerError.operationFailed("test-import-validation-reached")
            })
        let session = LedgerSession(repositoryFactory: { location in
            XCTFail("Local import invoked the remote factory")
            throw LedgerRepositoryError.unsupportedLocation(location)
        }, localCatalog: catalog, localAuthenticator: Authenticator(gate: authentication), defaults: fixture.defaults,
            widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: fixture.suite, lockDirectory: fixture.root),
            widgetCredentialStore: InertWidgetStore())
        let source = fixture.root.appendingPathComponent("selected-folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("; selected folder\n".utf8).write(to: source.appendingPathComponent("main.bean"))
        let activityProbe = ActivityProbe()
        let operation = Task {
            if importing {
                await session.importLocalLedger(from: source, name: "Selected folder", entrypoint: "main.bean")
            } else {
                await session.createLocalLedger(name: "Created ledger", currency: "CNY")
            }
            if activityProbe.waitingForActiveScene { completedWhileInactive.fulfill() }
            operationCompleted.fulfill()
        }
        await fulfillment(of: [authenticationEntered], timeout: 3)
        await session.updateActivity(isActive: false, isBackground: false)
        await authentication.release()
        await fulfillment(of: [completedWhileInactive], timeout: 0.1)
        XCTAssertTrue(session.isLocalOperationBusy)
        activityProbe.waitingForActiveScene = false
        await session.updateActivity(isActive: true, isBackground: false)
        await fulfillment(of: [validationEntered, operationCompleted], timeout: 3)
        operation.cancel()
        XCTAssertEqual(session.errorMessage, "test-import-validation-reached")
        XCTAssertFalse(session.isLocalOperationBusy)
    }

    private enum AuthenticationEntry: CaseIterable { case create, importLedger, open, unlock }
    private enum ForegroundWaitCancellation { case background, chooseLedger, cancelTask }

    func testEveryLocalAuthenticationWaiterCancelsOnBackground() async throws {
        for entry in AuthenticationEntry.allCases {
            try await assertForegroundWaitCancellation(entry: entry, cancellation: .background)
        }
    }

    func testEveryLocalAuthenticationWaiterCancelsOnChoosingLedger() async throws {
        for entry in AuthenticationEntry.allCases {
            try await assertForegroundWaitCancellation(entry: entry, cancellation: .chooseLedger)
        }
    }

    func testEveryLocalAuthenticationWaiterCancelsWithItsTask() async throws {
        for entry in AuthenticationEntry.allCases {
            try await assertForegroundWaitCancellation(entry: entry, cancellation: .cancelTask)
        }
    }

    private func assertForegroundWaitCancellation(entry: AuthenticationEntry, cancellation: ForegroundWaitCancellation) async throws {
        let fixture = try fixture()
        let authenticationEntered = expectation(description: "\(entry) authentication entered")
        let authentication = Gate(authenticationEntered)
        let authenticator = Authenticator(gate: authentication)
        let engine = UnusedEngine()
        let catalog = LocalLedgerCatalog(rootDirectory: fixture.root.appendingPathComponent("managed"),
            engine: engine, validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Existing ledger")
        if entry == .unlock {
            fixture.defaults.set(descriptor.id.uuidString, forKey: "ledger.mobile.active-local-ledger")
        }
        let session = LedgerSession(repositoryFactory: { location in
            XCTFail("\(entry) foreground waiter invoked remote factory")
            throw LedgerRepositoryError.unsupportedLocation(location)
        }, localCatalog: catalog, localAuthenticator: authenticator, defaults: fixture.defaults,
            widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: fixture.suite, lockDirectory: fixture.root),
            widgetCredentialStore: InertWidgetStore())
        if entry == .unlock { await session.lock() }
        let source = fixture.root.appendingPathComponent("selected-folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("; selected folder\n".utf8).write(to: source.appendingPathComponent("main.bean"))
        let completedWhileInactive = expectation(description: "\(entry) waits for foreground")
        completedWhileInactive.isInverted = true
        let completed = expectation(description: "\(entry) waiter cancels promptly")
        let probe = ActivityProbe()
        let operation = Task {
            switch entry {
            case .create: await session.createLocalLedger(name: "New ledger", currency: "CNY")
            case .importLedger: await session.importLocalLedger(from: source, name: "Imported", entrypoint: "main.bean")
            case .open: await session.openLocalLedger(descriptor)
            case .unlock: await session.unlockLocalLedger()
            }
            if probe.waitingForActiveScene { completedWhileInactive.fulfill() }
            completed.fulfill()
        }
        await fulfillment(of: [authenticationEntered], timeout: 3)
        await session.updateActivity(isActive: false, isBackground: false)
        await authentication.release()
        await fulfillment(of: [completedWhileInactive], timeout: 0.05)
        XCTAssertTrue(session.isAuthenticationBusy, "\(entry) must keep foreground waiter active")
        probe.waitingForActiveScene = false
        switch cancellation {
        case .background: await session.updateActivity(isActive: false, isBackground: true)
        case .chooseLedger: session.chooseLedger()
        case .cancelTask: operation.cancel()
        }
        await fulfillment(of: [completed], timeout: 1)
        await session.updateActivity(isActive: true, isBackground: false)
        await operation.value
        XCTAssertFalse(session.isAuthenticationBusy)
        XCTAssertFalse(session.isLocalOperationBusy)
        XCTAssertNil(session.ledger)
        XCTAssertNotEqual(session.phase, .ready)
        if cancellation == .chooseLedger || entry != .unlock {
            XCTAssertNil(session.location)
            XCTAssertEqual(session.phase, .configuration)
        } else {
            XCTAssertEqual(session.location, .local(descriptor.id))
            XCTAssertEqual(session.phase, .locked(authenticated: true))
        }
        XCTAssertEqual(authenticator.calls, 1)
        let descriptors = try await catalog.list()
        XCTAssertEqual(descriptors, [descriptor])
        let calls = await engine.calls
        XCTAssertEqual(calls, 0)
    }

    func testImportAuthenticationCompletionAfterRealBackgroundCancelsImport() async throws {
        try await assertInterruptedImportAuthentication(background: true)
    }

    func testImportAuthenticationCompletionAfterChoosingLedgerCancelsImport() async throws {
        try await assertInterruptedImportAuthentication(background: false)
    }

    private func assertInterruptedImportAuthentication(background: Bool) async throws {
        let fixture = try fixture()
        let entered = expectation(description: "import authentication entered")
        let gate = Gate(entered)
        let catalog = LocalLedgerCatalog(rootDirectory: fixture.root.appendingPathComponent("managed"),
            engine: UnusedEngine(), validator: { _, _ in XCTFail("Cancelled import reached validation") })
        let session = LedgerSession(repositoryFactory: { location in
            XCTFail("Cancelled import invoked remote factory")
            throw LedgerRepositoryError.unsupportedLocation(location)
        }, localCatalog: catalog, localAuthenticator: Authenticator(gate: gate), defaults: fixture.defaults,
            widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: fixture.suite, lockDirectory: fixture.root),
            widgetCredentialStore: InertWidgetStore())
        let source = fixture.root.appendingPathComponent("selected-folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("; selected folder\n".utf8).write(to: source.appendingPathComponent("main.bean"))
        let operation = Task { await session.importLocalLedger(from: source, name: "Cancelled import", entrypoint: "main.bean") }
        await fulfillment(of: [entered], timeout: 3)
        await session.updateActivity(isActive: false, isBackground: false)
        if background { await session.updateActivity(isActive: false, isBackground: true) }
        else { session.chooseLedger() }
        await gate.release()
        await operation.value
        await session.updateActivity(isActive: true, isBackground: false)
        XCTAssertEqual(session.phase, .configuration)
        XCTAssertNil(session.location)
        XCTAssertFalse(session.isLocalOperationBusy)
        let descriptors = try await catalog.list()
        XCTAssertTrue(descriptors.isEmpty)
    }

    private func assertInterruptedAuthentication(background: Bool) async throws {
        let fixture = try fixture()
        let entered = expectation(description: "device authentication has begun")
        let gate = Gate(entered)
        let engine = UnusedEngine()
        let catalog = LocalLedgerCatalog(rootDirectory: fixture.root.appendingPathComponent("managed"),
            engine: engine, validator: { _, _ in XCTFail("Stale authentication reached ledger creation") })
        var factoryCalls = 0
        let session = LedgerSession(repositoryFactory: { location in
            factoryCalls += 1
            throw LedgerRepositoryError.unsupportedLocation(location)
        }, localCatalog: catalog, localAuthenticator: Authenticator(gate: gate), defaults: fixture.defaults,
            widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: fixture.suite, lockDirectory: fixture.root),
            widgetCredentialStore: InertWidgetStore())
        let operation = Task { await session.createLocalLedger(name: "Stale authentication", currency: "CNY") }
        await fulfillment(of: [entered], timeout: 3)
        if background { await session.updateActivity(isActive: false, isBackground: true) }
        else { session.chooseLedger() }
        await gate.release()
        await operation.value
        XCTAssertEqual(session.phase, .configuration)
        XCTAssertNil(session.location)
        XCTAssertNil(session.ledger)
        XCTAssertEqual(factoryCalls, 0)
        let descriptors = try await catalog.list()
        XCTAssertTrue(descriptors.isEmpty)
        let engineCalls = await engine.calls
        XCTAssertEqual(engineCalls, 0)
    }

    func testProductionLocalSessionCreateRestartLockUnlockRefreshAndSearch() async throws {
        #if os(iOS)
        let fixture = try fixture()
        let catalog = LocalLedgerCatalog(rootDirectory: fixture.root.appendingPathComponent("managed"))
        let authenticator = Authenticator()
        var factoryCalls = 0
        func session() -> LedgerSession {
            LedgerSession(repositoryFactory: { location in
                factoryCalls += 1
                throw LedgerRepositoryError.unsupportedLocation(location)
            }, localCatalog: catalog, localAuthenticator: authenticator, defaults: fixture.defaults,
                widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: fixture.suite, lockDirectory: fixture.root),
                widgetCredentialStore: InertWidgetStore())
        }
        let initial = session()
        await initial.start()
        XCTAssertEqual(initial.phase, .configuration)
        await initial.createLocalLedger(name: "Offline session integration", currency: "CNY")
        XCTAssertEqual(initial.phase, .ready, initial.errorMessage ?? "")
        XCTAssertTrue(initial.isLocal)
        XCTAssertNil(initial.serverURL)
        let location = try XCTUnwrap(initial.location)
        let restored = session()
        await restored.start()
        XCTAssertEqual(restored.phase, .ready, restored.errorMessage ?? "")
        XCTAssertEqual(restored.location, location)
        XCTAssertNil(restored.serverURL)
        await restored.lock()
        XCTAssertEqual(restored.phase, .locked(authenticated: true))
        XCTAssertFalse(restored.amountsVisible)
        await restored.unlockLocalLedger()
        XCTAssertEqual(restored.phase, .ready, restored.errorMessage ?? "")
        await restored.refresh()
        await restored.moveRange(by: -1)
        try await restored.loadGlobalTransactions(forceRefresh: true)
        XCTAssertEqual(restored.phase, .ready, restored.errorMessage ?? "")
        XCTAssertTrue(restored.hasCachedGlobalTransactions)
        XCTAssertTrue(restored.globalTransactions.isEmpty)
        XCTAssertNil(restored.serverURL)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(authenticator.calls, 3)
        #else
        throw XCTSkip("Requires app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }

    func testLocalStartupCannotRestoreLockedPhaseAfterChoosingLedger() async throws {
        let fixture = try fixture()
        let catalog = LocalLedgerCatalog(rootDirectory: fixture.root.appendingPathComponent("managed"),
            engine: UnusedEngine(), validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Startup context")
        fixture.defaults.set(descriptor.id.uuidString, forKey: "ledger.mobile.active-local-ledger")
        let authenticator = Authenticator()
        let session = LedgerSession(repositoryFactory: { location in
            XCTFail("Local startup called remote repository factory")
            throw LedgerRepositoryError.unsupportedLocation(location)
        }, localCatalog: catalog, localAuthenticator: authenticator, defaults: fixture.defaults,
            widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: fixture.suite, lockDirectory: fixture.root),
            widgetCredentialStore: InertWidgetStore())
        let actorHeld = expectation(description: "catalog actor held before startup list")
        let release = DispatchSemaphore(value: 0)
        let holding = Task { await catalog.holdForStartupTest(entered: actorHeld, release: release) }
        await fulfillment(of: [actorHeld], timeout: 3)
        let startupEntered = expectation(description: "startup entered")
        let startup = Task {
            startupEntered.fulfill()
            await session.start()
        }
        await fulfillment(of: [startupEntered], timeout: 3)
        session.chooseLedger()
        release.signal()
        await holding.value
        await startup.value
        XCTAssertEqual(session.phase, .configuration)
        XCTAssertNil(session.location)
        XCTAssertNil(session.ledger)
        XCTAssertEqual(authenticator.calls, 0)
    }

    func testLocalActivationDefersPendingRemoteWidgetRevocation() async throws {
        let fixture = try fixture()
        let catalog = LocalLedgerCatalog(rootDirectory: fixture.root.appendingPathComponent("managed"),
            engine: LockedBootstrapEngine(), validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Offline activation")
        fixture.defaults.set(descriptor.id.uuidString, forKey: "ledger.mobile.active-local-ledger")
        let remoteCalled = expectation(description: "remote factory remains unused")
        remoteCalled.isInverted = true
        let session = LedgerSession(repositoryFactory: { location in
            remoteCalled.fulfill()
            throw LedgerRepositoryError.unsupportedLocation(location)
        }, localCatalog: catalog, localAuthenticator: Authenticator(), defaults: fixture.defaults,
            widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: fixture.suite, lockDirectory: fixture.root),
            widgetCredentialStore: PendingRemoteWidgetStore())
        #if os(iOS)
        await session.openLocalLedger(descriptor)
        #endif
        XCTAssertEqual(session.location, .local(descriptor.id))
        XCTAssertNil(session.serverURL)
        await session.lock()
        session.chooseLedger()
        await fulfillment(of: [remoteCalled], timeout: 0.1)
    }
}

private extension LocalLedgerCatalog {
    // A bounded synchronous hold lets the test put start() precisely at its
    // await of catalog.list(), without adding a production suspension hook.
    func holdForStartupTest(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        _ = release.wait(timeout: .now() + 5)
    }
}
