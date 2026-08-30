import Foundation
import XCTest
@testable import LedgerMobile

@MainActor
final class LedgerSessionTests: XCTestCase {
    func testBackgroundRefreshKeepsAmountsConcealed() async {
        let suiteName = "ledger-mobile-session-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.amountsVisible)

        session.updateActivity(isActive: false)
        await session.refresh()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertFalse(session.amountsVisible)
    }

    func testApplyingRangeRequestsSelectedDates() async {
        let suiteName = "ledger-mobile-range-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        let july = LedgerDateRange.month(year: 2026, month: 7)
        await session.applyRange(july)

        let requests = await api.bootstrapRequests()
        XCTAssertEqual(requests.last?.start, "2026-07-01")
        XCTAssertEqual(requests.last?.end, "2026-07-31")
        XCTAssertEqual(session.selectedRange, july)
    }

    func testLogoutClearsLoadedLedgerImmediately() async {
        let suiteName = "ledger-mobile-logout-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = LedgerSession(api: SessionMockAPI(payload: Self.payload), defaults: defaults)
        await session.resume()
        XCTAssertNotNil(session.ledger)

        session.logout()

        XCTAssertNil(session.ledger)
        XCTAssertEqual(session.phase, .locked(authenticated: false))
        XCTAssertFalse(session.amountsVisible)
    }

    func testIncompatibleServerDoesNotExposeLoginOrPersistOrigin() async {
        let suiteName = "ledger-mobile-incompatible-server-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(
            healthStatus: HealthStatus(apiVersion: 2, capabilities: ["cookie-auth", "full-backend"]),
            payload: Self.payload
        )
        let session = LedgerSession(api: api, defaults: defaults)
        session.serverInput = "https://example.com"

        await session.saveServer()

        XCTAssertEqual(session.phase, .configuration)
        XCTAssertNil(defaults.string(forKey: "ledger.mobile.server-origin"))
        XCTAssertNotNil(session.errorMessage)

        session.password = "must-not-be-sent"
        await session.login()
        let calls = await api.callCounts()
        XCTAssertEqual(calls.authStatus, 0)
        XCTAssertEqual(calls.login, 0)
    }

    func testFailedRemoteLockRemainsLockedAfterRestart() async {
        let suiteName = "ledger-mobile-local-lock-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstAPI = SessionMockAPI(payload: Self.payload, lockShouldFail: true)
        let firstSession = LedgerSession(api: firstAPI, defaults: defaults)
        await firstSession.resume()
        XCTAssertEqual(firstSession.phase, .ready)

        await firstSession.lock()
        XCTAssertEqual(firstSession.phase, .locked(authenticated: true))
        XCTAssertNil(firstSession.ledger)
        XCTAssertNotNil(firstSession.errorMessage)

        let restartedAPI = SessionMockAPI(payload: Self.payload)
        let restartedSession = LedgerSession(api: restartedAPI, defaults: defaults)
        await restartedSession.resume()

        XCTAssertEqual(restartedSession.phase, .locked(authenticated: true))
        XCTAssertNil(restartedSession.ledger)
        let calls = await restartedAPI.callCounts()
        XCTAssertEqual(calls.bootstrap, 0)

        defaults.set("https://second-ledger.example.com", forKey: "ledger.mobile.server-origin")
        let otherOriginSession = LedgerSession(api: SessionMockAPI(payload: Self.payload), defaults: defaults)
        await otherOriginSession.resume()
        XCTAssertEqual(otherOriginSession.phase, .ready)
    }

    func testFaceIDUnlockVerifiesProtectedCredentialAndLoadsLedger() async {
        let suiteName = "ledger-mobile-face-id-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let origin = URL(string: "https://ledger.example.com")!
        let credential = QuickUnlockCredential(deviceID: "device-12345678", token: "protected-token")
        let store = MockBiometricCredentialStore(credential: credential)
        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults, biometricStore: store)
        await session.resume()
        session.setLockInterval(.immediately)
        session.updateActivity(isActive: false)

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertNil(session.ledger)
        session.updateActivity(isActive: true)

        await session.unlockWithBiometrics()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertNotNil(session.ledger)
        let calls = await api.callCounts()
        XCTAssertEqual(calls.quickUnlockVerify, 1)
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(store.lastReadOrigin, origin)
    }

    func testSettingsCanEnableAndDisableFaceIDCredential() async {
        let suiteName = "ledger-mobile-face-id-enrollment-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockBiometricCredentialStore()
        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults, biometricStore: store)
        await session.resume()

        await session.setBiometricUnlockEnabled(true)

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(store.savedCredential, QuickUnlockCredential(deviceID: "registered-device", token: "registered-token"))
        XCTAssertTrue(session.hasBiometricUnlock)

        store.readShouldFail = true
        await session.setBiometricUnlockEnabled(false)
        XCTAssertTrue(session.hasBiometricUnlock)
        XCTAssertNotNil(session.errorMessage)

        store.readShouldFail = false
        await session.setBiometricUnlockEnabled(false)
        XCTAssertFalse(session.hasBiometricUnlock)
        let calls = await api.callCounts()
        XCTAssertEqual(calls.quickUnlockRegister, 1)
        XCTAssertEqual(calls.quickUnlockRevoke, 1)
    }

    func testPasskeyLoginVerifiesAssertionAndLoadsLedger() async {
        let suiteName = "ledger-mobile-passkey-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://beancount.borry.org", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let assertion = PasskeyAssertion(
            credentialID: Data([1, 2, 3]),
            clientDataJSON: Data("client".utf8),
            authenticatorData: Data("auth".utf8),
            signature: Data("signature".utf8),
            userHandle: Data([4, 5, 6])
        )
        let authenticator = MockPasskeyAuthenticator(assertion: assertion)
        let api = SessionMockAPI(
            authStatus: AuthStatus(authenticated: false, sensitiveUnlocked: false, authDisabled: false),
            passkeyStatus: PasskeyStatus(registered: true, count: 1),
            payload: Self.payload
        )
        let session = LedgerSession(api: api, defaults: defaults, passkeyAuthenticator: authenticator)
        await session.resume()

        XCTAssertEqual(session.phase, .locked(authenticated: false))
        XCTAssertTrue(session.passkeyAvailable)

        await session.loginWithPasskey()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(authenticator.receivedRelyingPartyID, LedgerSession.passkeyRelyingPartyID)
        let calls = await api.callCounts()
        XCTAssertEqual(calls.passkeyOptions, 1)
        XCTAssertEqual(calls.passkeyVerify, 1)
    }

    func testPasskeyCancellationReturnsToPasswordFallback() async {
        let suiteName = "ledger-mobile-passkey-cancel-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://beancount.borry.org", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(
            authStatus: AuthStatus(authenticated: false, sensitiveUnlocked: false, authDisabled: false),
            passkeyStatus: PasskeyStatus(registered: true, count: 1),
            payload: Self.payload
        )
        let session = LedgerSession(
            api: api,
            defaults: defaults,
            passkeyAuthenticator: FailingPasskeyAuthenticator()
        )
        await session.resume()

        await session.loginWithPasskey()

        XCTAssertEqual(session.phase, .locked(authenticated: false))
        XCTAssertEqual(session.errorMessage, PasskeyAuthenticationError.cancelled.localizedDescription)
        let calls = await api.callCounts()
        XCTAssertEqual(calls.passkeyOptions, 1)
        XCTAssertEqual(calls.passkeyVerify, 0)
    }

    func testUntrustedAPIOriginCannotAdvertiseOrStartNativePasskey() async {
        let suiteName = "ledger-mobile-passkey-origin-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://relay.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(
            authStatus: AuthStatus(authenticated: false, sensitiveUnlocked: false, authDisabled: false),
            passkeyStatus: PasskeyStatus(registered: true, count: 1),
            payload: Self.payload
        )
        let session = LedgerSession(
            api: api,
            defaults: defaults,
            passkeyAuthenticator: FailingPasskeyAuthenticator()
        )
        await session.resume()

        XCTAssertFalse(session.passkeyAvailable)
        await session.loginWithPasskey()

        XCTAssertEqual(session.phase, .locked(authenticated: false))
        let calls = await api.callCounts()
        XCTAssertEqual(calls.passkeyStatus, 0)
        XCTAssertEqual(calls.passkeyOptions, 0)
        XCTAssertEqual(calls.passkeyVerify, 0)
    }

    func testColdStartLocksAfterConfiguredBackgroundInterval() async {
        let suiteName = "ledger-mobile-timeout-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let origin = "https://ledger.example.com"
        defaults.set(origin, forKey: "ledger.mobile.server-origin")
        defaults.set([origin: LedgerLockInterval.fiveMinutes.rawValue], forKey: "ledger.mobile.lock-intervals")
        defaults.set([origin: Date().addingTimeInterval(-301).timeIntervalSince1970], forKey: "ledger.mobile.background-dates")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults)

        await session.resume()

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertNil(session.ledger)
        let calls = await api.callCounts()
        XCTAssertEqual(calls.bootstrap, 0)
    }

    func testChangingServerDeletesOldOriginBiometricCredential() async {
        let suiteName = "ledger-mobile-change-server-biometric-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockBiometricCredentialStore(
            credential: QuickUnlockCredential(deviceID: "old-device", token: "old-token")
        )
        let session = LedgerSession(
            api: SessionMockAPI(payload: Self.payload),
            defaults: defaults,
            biometricStore: store
        )
        await session.resume()
        XCTAssertTrue(session.hasBiometricUnlock)

        session.changeServer()

        XCTAssertEqual(session.phase, .configuration)
        XCTAssertNil(store.credential)
    }

    private static let payload = LedgerBootstrap(
        start: "2026-08-01",
        end: "2026-08-31",
        summary: LedgerSummary(currency: "CNY", income: 0, expense: 0, net: 0),
        accountBalances: [],
        transactions: [],
        accounts: [],
        valuationCurrency: "CNY",
        sensitiveUnlocked: true
    )
}

private actor SessionMockAPI: LedgerAPI {
    struct BootstrapRequest: Equatable, Sendable {
        let start: String
        let end: String
        let today: String
    }

    struct CallCounts: Sendable {
        let authStatus: Int
        let login: Int
        let bootstrap: Int
        let quickUnlockRegister: Int
        let quickUnlockVerify: Int
        let quickUnlockRevoke: Int
        let passkeyStatus: Int
        let passkeyOptions: Int
        let passkeyVerify: Int
    }

    enum Failure: Error {
        case lock
    }

    let healthStatus: HealthStatus
    let currentAuthStatus: AuthStatus
    let currentPasskeyStatus: PasskeyStatus
    let payload: LedgerBootstrap
    let lockShouldFail: Bool
    private var authStatusCalls = 0
    private var loginCalls = 0
    private var bootstrapCalls = 0
    private var quickUnlockRegisterCalls = 0
    private var quickUnlockVerifyCalls = 0
    private var quickUnlockRevokeCalls = 0
    private var passkeyStatusCalls = 0
    private var passkeyOptionsCalls = 0
    private var passkeyVerifyCalls = 0
    private var requests: [BootstrapRequest] = []

    init(
        healthStatus: HealthStatus = HealthStatus(
            apiVersion: 1,
            capabilities: ["full-backend", "cookie-auth"]
        ),
        authStatus: AuthStatus = AuthStatus(authenticated: true, sensitiveUnlocked: true, authDisabled: false),
        passkeyStatus: PasskeyStatus = PasskeyStatus(registered: false, count: 0),
        payload: LedgerBootstrap,
        lockShouldFail: Bool = false
    ) {
        self.healthStatus = healthStatus
        currentAuthStatus = authStatus
        currentPasskeyStatus = passkeyStatus
        self.payload = payload
        self.lockShouldFail = lockShouldFail
    }

    func health(baseURL: URL) async throws -> HealthStatus {
        healthStatus
    }

    func authStatus(baseURL: URL) async throws -> AuthStatus {
        authStatusCalls += 1
        return currentAuthStatus
    }

    func login(baseURL: URL, password: String) async throws {
        loginCalls += 1
    }

    func passkeyStatus(baseURL: URL) async throws -> PasskeyStatus {
        passkeyStatusCalls += 1
        return currentPasskeyStatus
    }

    func passkeyLoginOptions(baseURL: URL) async throws -> PasskeyRequestOptions {
        passkeyOptionsCalls += 1
        return PasskeyRequestOptions(
            challenge: Data("challenge".utf8).base64URLEncodedString(),
            relyingPartyID: LedgerSession.passkeyRelyingPartyID
        )
    }

    func verifyPasskey(baseURL: URL, assertion: PasskeyAssertion) async throws {
        passkeyVerifyCalls += 1
    }

    func registerQuickUnlock(baseURL: URL, deviceName: String) async throws -> QuickUnlockCredential {
        quickUnlockRegisterCalls += 1
        return QuickUnlockCredential(deviceID: "registered-device", token: "registered-token")
    }

    func verifyQuickUnlock(baseURL: URL, credential: QuickUnlockCredential) async throws {
        quickUnlockVerifyCalls += 1
    }

    func revokeQuickUnlock(baseURL: URL, deviceID: String) async throws {
        quickUnlockRevokeCalls += 1
    }

    func bootstrap(baseURL: URL, start: String, end: String, today: String) async throws -> LedgerBootstrap {
        bootstrapCalls += 1
        requests.append(BootstrapRequest(start: start, end: end, today: today))
        return payload
    }

    func lock(baseURL: URL) async throws {
        if lockShouldFail { throw Failure.lock }
    }
    func logout(baseURL: URL) async throws {}

    func callCounts() -> CallCounts {
        CallCounts(
            authStatus: authStatusCalls,
            login: loginCalls,
            bootstrap: bootstrapCalls,
            quickUnlockRegister: quickUnlockRegisterCalls,
            quickUnlockVerify: quickUnlockVerifyCalls,
            quickUnlockRevoke: quickUnlockRevokeCalls,
            passkeyStatus: passkeyStatusCalls,
            passkeyOptions: passkeyOptionsCalls,
            passkeyVerify: passkeyVerifyCalls
        )
    }

    func bootstrapRequests() -> [BootstrapRequest] {
        requests
    }
}

@MainActor
private final class MockPasskeyAuthenticator: PasskeyAuthenticating {
    let assertion: PasskeyAssertion
    private(set) var receivedRelyingPartyID: String?

    init(assertion: PasskeyAssertion) {
        self.assertion = assertion
    }

    func authenticate(options: PasskeyRequestOptions, relyingPartyID: String) async throws -> PasskeyAssertion {
        receivedRelyingPartyID = relyingPartyID
        return assertion
    }
}

@MainActor
private final class FailingPasskeyAuthenticator: PasskeyAuthenticating {
    func authenticate(options: PasskeyRequestOptions, relyingPartyID: String) async throws -> PasskeyAssertion {
        throw PasskeyAuthenticationError.cancelled
    }
}

@MainActor
private final class MockBiometricCredentialStore: BiometricCredentialStore {
    let biometricKind: LedgerBiometricKind = .faceID
    var credential: QuickUnlockCredential?
    private(set) var savedCredential: QuickUnlockCredential?
    private(set) var readCount = 0
    private(set) var lastReadOrigin: URL?
    var readShouldFail = false

    init(credential: QuickUnlockCredential? = nil) {
        self.credential = credential
    }

    func containsCredential(for origin: URL) -> Bool {
        credential != nil
    }

    func save(_ credential: QuickUnlockCredential, for origin: URL) throws {
        self.credential = credential
        savedCredential = credential
    }

    func readCredential(for origin: URL, reason: String) async throws -> QuickUnlockCredential {
        readCount += 1
        lastReadOrigin = origin
        if readShouldFail { throw BiometricCredentialError.invalidCredential }
        guard let credential else { throw BiometricCredentialError.invalidCredential }
        return credential
    }

    func deleteCredential(for origin: URL) {
        credential = nil
    }
}
