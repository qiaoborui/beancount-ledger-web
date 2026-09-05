import Foundation
import XCTest
@testable import LedgerMobile

@MainActor
final class LedgerSessionTests: XCTestCase {
    func testInjectedLedgerClockKeepsCalendarRangesStable() {
        let suiteName = "ledger-mobile-clock-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = ISO8601DateFormatter().date(from: "2026-08-31T12:00:00Z")!

        let session = LedgerSession(
            api: SessionMockAPI(payload: Self.payload),
            defaults: defaults,
            ledgerNow: { now }
        )

        XCTAssertEqual(session.selectedRange, .month(year: 2026, month: 8))
        session.presentRangePicker()
        session.selectDraftPreset(.quarter)
        XCTAssertEqual(session.draftRange, LedgerDateRange.current(.quarter, now: now))
    }

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

        await session.updateActivity(isActive: false, isBackground: true)
        await session.refresh()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertFalse(session.amountsVisible)
    }

    func testForegroundActivationRefreshesReadyLedger() async {
        let suiteName = "ledger-mobile-foreground-refresh-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        await session.updateActivity(isActive: true, isBackground: false)
        var calls = await api.callCounts()
        XCTAssertEqual(calls.bootstrap, 1)

        await session.updateActivity(isActive: false, isBackground: true)
        await session.updateActivity(isActive: true, isBackground: false)

        calls = await api.callCounts()
        XCTAssertEqual(calls.bootstrap, 2)
    }

    func testForegroundRefreshConvergesServerSensitiveLock() async {
        let suiteName = "ledger-mobile-foreground-server-lock-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(payload: Self.payload, bootstrapErrorStatusAfterFirstCall: 423)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        XCTAssertEqual(session.phase, .ready)

        await session.updateActivity(isActive: false, isBackground: true)
        await session.updateActivity(isActive: true, isBackground: false)

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertNil(session.ledger)
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
        XCTAssertEqual(requests.last?.end, "2026-08-01")
        XCTAssertEqual(session.selectedRange, july)
    }

    func testAccountDetailUsesSelectedRange() async throws {
        let suiteName = "ledger-mobile-account-range-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        await session.applyRange(.month(year: 2026, month: 7))

        _ = try await session.accountDetail(for: "Assets:Bank:Daily", currency: "CNY")

        let request = await api.accountDetailRequests().last
        XCTAssertEqual(request?.account, "Assets:Bank:Daily")
        XCTAssertEqual(request?.currency, "CNY")
        XCTAssertEqual(request?.start, "2026-07-01")
        XCTAssertEqual(request?.end, "2026-08-01")
    }

    func testLegacyAccountDetailIsFilteredToSelectedRange() async throws {
        let suiteName = "ledger-mobile-legacy-account-range-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let transaction = LedgerTransaction(
            date: "2026-07-10",
            payee: "测试",
            narration: "",
            tags: nil,
            postings: [LedgerPosting(account: "Assets:Bank:Daily", amount: 300, currency: "CNY")],
            source: TransactionSource(file: "transactions/2026/07.bean", line: 1, hash: nil, gitSHA: nil)
        )
        let legacyDetail = LedgerAccountDetail(
            account: "Assets:Bank:Daily",
            label: "日常账户",
            alias: nil,
            group: "cash",
            active: true,
            currency: "CNY",
            currentBalance: 1_500,
            rows: [
                LedgerAccountDetailRow(
                    date: "2026-06-30",
                    payee: "期初前",
                    narration: "",
                    change: 1_000,
                    balance: 1_000,
                    transaction: transaction
                ),
                LedgerAccountDetailRow(
                    date: "2026-07-10",
                    payee: "期间内",
                    narration: "",
                    change: 300,
                    balance: 1_300,
                    transaction: transaction
                ),
                LedgerAccountDetailRow(
                    date: "2026-08-01",
                    payee: "期间后",
                    narration: "",
                    change: 200,
                    balance: 1_500,
                    transaction: transaction
                ),
            ]
        )
        let api = SessionMockAPI(
            healthStatus: HealthStatus(
                apiVersion: 1,
                capabilities: ["full-backend", "cookie-auth", HealthStatus.accountPeriodBalancesCapability]
            ),
            payload: Self.payload,
            accountDetailPayload: legacyDetail
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        await session.applyRange(.month(year: 2026, month: 7))

        let detail = try await session.accountDetail(for: "Assets:Bank:Daily", currency: "CNY")

        XCTAssertTrue(session.accountPeriodBalancesAvailable)
        XCTAssertEqual(detail.rows.map(\.date), ["2026-07-10"])
        XCTAssertEqual(detail.openingBalance, 1_000)
        XCTAssertEqual(detail.closingBalance, 1_300)
        XCTAssertEqual(detail.periodChange, 300)
        XCTAssertEqual(detail.start, "2026-07-01")
        XCTAssertEqual(detail.end, "2026-08-01")
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

    func testAccountDetailSensitiveLockClearsLoadedLedger() async {
        let suiteName = "ledger-mobile-account-detail-lock-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(payload: Self.payload, accountDetailErrorStatus: 423)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        XCTAssertEqual(session.phase, .ready)

        do {
            _ = try await session.accountDetail(for: "Assets:Bank:Daily", currency: "CNY")
            XCTFail("Expected sensitive lock response")
        } catch let error as LedgerAPIError {
            guard case let .server(status, _) = error else {
                return XCTFail("Unexpected API error: \(error)")
            }
            XCTAssertEqual(status, 423)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertNil(session.ledger)
        XCTAssertFalse(session.amountsVisible)
    }

    func testLateAccountDetailLockCannotChangeLoggedOutSession() async throws {
        let suiteName = "ledger-mobile-account-detail-race-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(
            payload: Self.payload,
            accountDetailErrorStatus: 423,
            accountDetailDelayNanoseconds: 100_000_000
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        let detailRequest = Task {
            try await session.accountDetail(for: "Assets:Bank:Daily", currency: "CNY")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        session.logout()
        _ = try? await detailRequest.value

        XCTAssertEqual(session.phase, .locked(authenticated: false))
        XCTAssertNil(session.ledger)
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

    func testManualLockIsLocalAndRemainsLockedAfterRestart() async {
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
        XCTAssertNotNil(firstSession.ledger)
        XCTAssertNil(firstSession.errorMessage)
        let lockCalls = await firstAPI.callCounts()
        XCTAssertEqual(lockCalls.lock, 0)

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
        await session.updateActivity(isActive: false, isBackground: true)

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertNotNil(session.ledger)
        await session.updateActivity(isActive: true, isBackground: false)

        await session.unlockWithBiometrics()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertNotNil(session.ledger)
        for _ in 0..<100 {
            if store.savedCredential?.deviceID == "local-biometric" { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let calls = await api.callCounts()
        XCTAssertEqual(calls.quickUnlockVerify, 0)
        XCTAssertEqual(calls.quickUnlockRevoke, 1)
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(store.lastReadOrigin, origin)
        XCTAssertEqual(store.savedCredential?.deviceID, "local-biometric")
    }

    func testColdLegacyFaceIDRestoresServerAccessBeforeMigratingLocally() async {
        let suiteName = "ledger-mobile-legacy-face-id-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let origin = "https://ledger.example.com"
        defaults.set(origin, forKey: "ledger.mobile.server-origin")
        defaults.set([origin], forKey: "ledger.mobile.locally-locked-origins")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockBiometricCredentialStore(
            credential: QuickUnlockCredential(deviceID: "legacy-device", token: "legacy-token")
        )
        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults, biometricStore: store)
        await session.resume()
        XCTAssertEqual(session.phase, .locked(authenticated: true))

        await session.unlockWithBiometrics()
        for _ in 0..<100 {
            if store.savedCredential?.deviceID == "local-biometric" { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertEqual(session.phase, .ready)
        XCTAssertNotNil(session.ledger)
        let calls = await api.callCounts()
        XCTAssertEqual(calls.quickUnlockVerify, 1)
        XCTAssertEqual(calls.quickUnlockRevoke, 1)
        XCTAssertEqual(store.savedCredential?.deviceID, "local-biometric")
    }

    func testWarmLegacyFaceIDKeepsRetryPathWhenServerRefreshLocks() async {
        let suiteName = "ledger-mobile-legacy-face-id-retry-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockBiometricCredentialStore(
            credential: QuickUnlockCredential(deviceID: "legacy-device", token: "legacy-token")
        )
        let api = SessionMockAPI(payload: Self.payload, bootstrapErrorStatusAfterFirstCall: 423)
        let session = LedgerSession(api: api, defaults: defaults, biometricStore: store)
        await session.resume()
        await session.lock()

        await session.unlockWithBiometrics()

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertNil(session.ledger)
        XCTAssertTrue(session.canUseBiometricUnlock)
        let calls = await api.callCounts()
        XCTAssertEqual(calls.quickUnlockVerify, 0)
        XCTAssertEqual(calls.quickUnlockRevoke, 0)
        XCTAssertNil(store.savedCredential)
    }

    func testFaceIDPromptLifecycleDoesNotRelockImmediateSession() async throws {
        let suiteName = "ledger-mobile-face-id-lifecycle-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockBiometricCredentialStore(
            credential: QuickUnlockCredential(deviceID: "local-biometric", token: "protected-marker")
        )
        store.readDelayNanoseconds = 100_000_000
        let session = LedgerSession(
            api: SessionMockAPI(payload: Self.payload),
            defaults: defaults,
            biometricStore: store
        )
        await session.resume()
        session.setLockInterval(.immediately)
        await session.updateActivity(isActive: false, isBackground: false)
        await session.updateActivity(isActive: true, isBackground: false)

        let unlock = Task { await session.unlockWithBiometrics() }
        for _ in 0..<100 {
            if store.readCount == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        await session.updateActivity(isActive: false, isBackground: false)
        await session.updateActivity(isActive: true, isBackground: false)
        await unlock.value

        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.amountsVisible)
        XCTAssertFalse(session.privacyShielded)
    }

    func testDisablingFaceIDInvalidatesLegacyCredentialMigration() async throws {
        let suiteName = "ledger-mobile-face-id-migration-race-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockBiometricCredentialStore(
            credential: QuickUnlockCredential(deviceID: "legacy-device", token: "legacy-token")
        )
        let api = SessionMockAPI(
            payload: Self.payload,
            quickUnlockRevokeDelayNanoseconds: 100_000_000
        )
        let session = LedgerSession(api: api, defaults: defaults, biometricStore: store)
        await session.resume()
        await session.lock()
        await session.unlockWithBiometrics()

        await session.setBiometricUnlockEnabled(false)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertFalse(session.hasBiometricUnlock)
        XCTAssertNil(store.credential)
        let calls = await api.callCounts()
        XCTAssertEqual(calls.quickUnlockRevoke, 2)
    }

    func testSettingsCanEnableAndDisableFaceIDCredential() async throws {
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
        XCTAssertNotNil(store.savedCredential)
        XCTAssertTrue(session.hasBiometricUnlock)

        store.readShouldFail = true
        await session.setBiometricUnlockEnabled(false)
        XCTAssertTrue(session.hasBiometricUnlock)
        XCTAssertNotNil(session.errorMessage)

        store.readShouldFail = false
        store.readDelayNanoseconds = 100_000_000
        session.setLockInterval(.immediately)
        let disable = Task { await session.setBiometricUnlockEnabled(false) }
        for _ in 0..<100 {
            if store.readCount == 2 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        await session.updateActivity(isActive: false, isBackground: false)
        await session.updateActivity(isActive: true, isBackground: false)
        await disable.value

        XCTAssertEqual(session.phase, .ready)
        XCTAssertFalse(session.hasBiometricUnlock)
        let calls = await api.callCounts()
        XCTAssertEqual(calls.quickUnlockRegister, 0)
        XCTAssertEqual(calls.quickUnlockRevoke, 0)
    }

    func testPasskeyLoginVerifiesAssertionAndLoadsLedger() async throws {
        try XCTSkipIf(!LedgerSession.nativePasskeyEnabledForCurrentBuild, "个人团队构建未启用关联域名通行密钥")
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

    func testPasskeyCancellationReturnsToPasswordFallback() async throws {
        try XCTSkipIf(!LedgerSession.nativePasskeyEnabledForCurrentBuild, "个人团队构建未启用关联域名通行密钥")
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
        XCTAssertEqual(calls.authStatus, 0)
        XCTAssertEqual(calls.bootstrap, 0)
    }

    func testBackgroundedCheckingSessionStillLocksBeforeFirstServerRequest() async {
        let suiteName = "ledger-mobile-checking-timeout-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let origin = "https://ledger.example.com"
        defaults.set(origin, forKey: "ledger.mobile.server-origin")
        defaults.set([origin: LedgerLockInterval.fiveMinutes.rawValue], forKey: "ledger.mobile.lock-intervals")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults, ledgerNow: { now })

        await session.updateActivity(isActive: false, isBackground: true)
        now = now.addingTimeInterval(301)
        await session.resume()

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        let calls = await api.callCounts()
        XCTAssertEqual(calls.authStatus, 0)
        XCTAssertNil(session.ledger)
    }

    func testInitialInactiveEventPreservesExpiredBackgroundLock() async {
        let suiteName = "ledger-mobile-expired-background-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let origin = "https://ledger.example.com"
        defaults.set(origin, forKey: "ledger.mobile.server-origin")
        defaults.set([origin: LedgerLockInterval.fiveMinutes.rawValue], forKey: "ledger.mobile.lock-intervals")
        defaults.set([origin: 1_800_000_000.0], forKey: "ledger.mobile.background-dates")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(
            api: api,
            defaults: defaults,
            ledgerNow: { Date(timeIntervalSince1970: 1_800_000_301) }
        )

        await session.updateActivity(isActive: false, isBackground: false)
        await session.resume()

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        let calls = await api.callCounts()
        XCTAssertEqual(calls.authStatus, 0)
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

    func testAnalysisResourcesLoadOnlySelectedSourceForCurrentRange() async throws {
        let suiteName = "ledger-mobile-analysis-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        await session.setValuationCurrency("USD")
        let july = LedgerDateRange.month(year: 2026, month: 7)
        await session.applyRange(july)

        let assetsResource = try await session.analysisResource(.assets)
        guard case let .assets(assets) = assetsResource else {
            return XCTFail("Expected assets resource")
        }
        XCTAssertEqual(assets.valuationCurrency, "USD")
        var calls = await api.callCounts()
        XCTAssertEqual(calls.dashboard, 0)
        XCTAssertEqual(calls.incomeStatement, 0)
        XCTAssertEqual(calls.investments, 0)

        let incomeResource = try await session.analysisResource(.incomeExpense)
        guard case let .incomeExpense(incomeExpense) = incomeResource else {
            return XCTFail("Expected income and expense resource")
        }
        XCTAssertEqual(incomeExpense.dashboard.start, "2026-07-01")
        XCTAssertEqual(incomeExpense.statement.end, "2026-08-01")
        XCTAssertEqual(incomeExpense.statement.valuationCurrency, "USD")

        _ = try await session.analysisResource(.investments)
        calls = await api.callCounts()
        XCTAssertEqual(calls.dashboard, 1)
        XCTAssertEqual(calls.incomeStatement, 1)
        XCTAssertEqual(calls.investments, 1)
    }

    func testAnalysisSensitiveLockClearsLoadedLedger() async {
        let suiteName = "ledger-mobile-analysis-lock-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(payload: Self.payload, analysisErrorStatus: 423)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        do {
            _ = try await session.analysisResource(.incomeExpense)
            XCTFail("Expected sensitive lock response")
        } catch let error as LedgerAPIError {
            guard case let .server(status, _) = error else {
                return XCTFail("Unexpected API error: \(error)")
            }
            XCTAssertEqual(status, 423)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertNil(session.ledger)
        XCTAssertFalse(session.amountsVisible)
    }

    func testLateAnalysisLockCannotChangeLoggedOutSession() async throws {
        let suiteName = "ledger-mobile-analysis-race-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(
            payload: Self.payload,
            analysisErrorStatus: 423,
            analysisDelayNanoseconds: 100_000_000
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        let analysisRequest = Task { try await session.analysisResource(.incomeExpense) }
        try await Task.sleep(nanoseconds: 10_000_000)
        session.logout()
        _ = try? await analysisRequest.value

        XCTAssertEqual(session.phase, .locked(authenticated: false))
        XCTAssertNil(session.ledger)
        XCTAssertFalse(session.amountsVisible)
    }

    func testBQLUsesLedgerCurrencyAndReturnsDynamicRows() async throws {
        let suiteName = "ledger-mobile-bql-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        let result = try await session.runBQL(query: "SELECT month, sum(value) AS total FROM postings GROUP BY month")

        XCTAssertEqual(result.rowCount, 1)
        XCTAssertEqual(result.rows.first, [.string("2026-08"), .number(125_000)])
        let requests = await api.bqlRequests()
        XCTAssertEqual(requests.first?.query, "SELECT month, sum(value) AS total FROM postings GROUP BY month")
        XCTAssertEqual(requests.first?.valuationCurrency, "CNY")
    }

    func testBQLSensitiveLockClearsLoadedLedger() async {
        let suiteName = "ledger-mobile-bql-lock-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(payload: Self.payload, bqlErrorStatus: 423)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        _ = try? await session.runBQL(query: "SELECT * FROM transactions")

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertNil(session.ledger)
        XCTAssertFalse(session.amountsVisible)
    }

    func testLateBQLLockCannotChangeLoggedOutSession() async throws {
        let suiteName = "ledger-mobile-bql-race-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(
            payload: Self.payload,
            bqlErrorStatus: 423,
            bqlDelayNanoseconds: 100_000_000
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        let request = Task { try await session.runBQL(query: "SELECT * FROM transactions") }
        try await Task.sleep(nanoseconds: 10_000_000)
        session.logout()
        _ = try? await request.value

        XCTAssertEqual(session.phase, .locked(authenticated: false))
        XCTAssertNil(session.ledger)
        XCTAssertFalse(session.amountsVisible)
    }

    func testValuationCurrencyReloadsAndPersistsPerServerOrigin() async throws {
        let suiteName = "ledger-mobile-currency-persistence-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(payload: Self.payload)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        await session.setValuationCurrency("usd")

        XCTAssertEqual(session.ledger?.valuationCurrency, "USD")
        XCTAssertFalse(session.isValuationCurrencyLoading)
        XCTAssertEqual((defaults.dictionary(forKey: "ledger.mobile.valuation-currencies") as? [String: String])?["https://ledger.example.com"], "USD")

        let restored = LedgerSession(api: api, defaults: defaults)
        await restored.resume()
        let requests = await api.bootstrapRequests()
        XCTAssertEqual(requests.last?.valuationCurrency, "USD")
        XCTAssertEqual(restored.ledger?.valuationCurrency, "USD")
    }

    func testLatestValuationCurrencySelectionWinsSlowResponseRace() async throws {
        let suiteName = "ledger-mobile-currency-race-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(
            payload: Self.payload,
            bootstrapDelays: ["USD": 100_000_000, "EUR": 10_000_000]
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        let slow = Task { await session.setValuationCurrency("USD") }
        try await Task.sleep(nanoseconds: 5_000_000)
        let latest = Task { await session.setValuationCurrency("EUR") }
        await slow.value
        await latest.value

        XCTAssertEqual(session.ledger?.valuationCurrency, "EUR")
        XCTAssertFalse(session.isValuationCurrencyLoading)
    }

    func testRangeLoadPreventsCurrencyChangeFromInvalidatingItsLoadingState() async throws {
        let suiteName = "ledger-mobile-range-currency-race-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(
            payload: Self.payload,
            bootstrapDelaysByStart: ["2026-07-01": 100_000_000]
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        let july = LedgerDateRange.month(year: 2026, month: 7)
        let rangeLoad = Task { await session.applyRange(july) }
        try await Task.sleep(nanoseconds: 10_000_000)
        await session.setValuationCurrency("USD")
        await rangeLoad.value

        XCTAssertEqual(session.selectedRange, july)
        XCTAssertEqual(session.ledger?.valuationCurrency, "CNY")
        XCTAssertFalse(session.isRangeLoading)
        XCTAssertFalse(session.isValuationCurrencyLoading)
    }

    func testBackgroundLockClearsInFlightValuationCurrencyLoadingState() async throws {
        let suiteName = "ledger-mobile-background-currency-race-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(
            payload: Self.payload,
            bootstrapDelays: ["USD": 100_000_000]
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        session.setLockInterval(.immediately)

        let currencyLoad = Task { await session.setValuationCurrency("USD") }
        try await Task.sleep(nanoseconds: 10_000_000)
        await session.updateActivity(isActive: false, isBackground: true)
        await currencyLoad.value

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertNotNil(session.ledger)
        XCTAssertFalse(session.isValuationCurrencyLoading)
    }

    func testValuationCurrencySensitiveLockClearsLoadedLedger() async throws {
        let suiteName = "ledger-mobile-currency-lock-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(payload: Self.payload, bootstrapErrorStatuses: ["USD": 423])
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        await session.setValuationCurrency("USD")

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertNil(session.ledger)
        XCTAssertFalse(session.amountsVisible)
    }

    func testReadySessionPublishesWidgetSnapshotAndLogoutClearsIt() async {
        let defaultsSuite = "ledger-mobile-widget-session-tests-\(UUID().uuidString)"
        let widgetSuite = "ledger-mobile-widget-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        let widgetStore = LedgerWidgetSnapshotStore(suiteName: widgetSuite)
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            UserDefaults(suiteName: widgetSuite)?.removePersistentDomain(forName: widgetSuite)
        }

        let session = LedgerSession(
            api: SessionMockAPI(
                payload: Self.payload,
                widgetReport: Self.widgetReport,
                widgetImportDocuments: Self.widgetImportDocuments
            ),
            defaults: defaults,
            widgetSnapshotStore: widgetStore
        )
        await session.resume()

        XCTAssertEqual(widgetStore.load()?.expense.amount, 555_180)
        XCTAssertEqual(widgetStore.load()?.expense.transactionCount, 9)
        XCTAssertEqual(widgetStore.load()?.imports.first?.provider, "alipay")
        XCTAssertEqual(widgetStore.load()?.imports.first?.latestCoverageDate, "2026-08-28")
        XCTAssertNotNil(widgetStore.load()?.importsUpdatedAt)

        session.logout()

        XCTAssertNil(widgetStore.load())
    }

    func testImportHistoryFailurePreservesPreviousWidgetImportStatus() async throws {
        let defaultsSuite = "ledger-mobile-widget-import-fallback-tests-\(UUID().uuidString)"
        let widgetSuite = "ledger-mobile-widget-import-fallback-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        let widgetStore = LedgerWidgetSnapshotStore(suiteName: widgetSuite)
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            UserDefaults(suiteName: widgetSuite)?.removePersistentDomain(forName: widgetSuite)
        }
        let previous = LedgerWidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1),
            expense: LedgerWidgetExpenseSnapshot(
                periodTitle: "2026年7月",
                start: "2026-07-01",
                end: "2026-08-01",
                currency: "CNY",
                amount: 1,
                transactionCount: 1,
                yearOverYearPercentage: nil,
                categories: [],
                dailySeries: []
            ),
            accounts: [],
            imports: [
                LedgerWidgetImportSnapshot(
                    provider: "wechat",
                    label: "微信支付",
                    coverageStart: "2026-07-01",
                    coverageEnd: "2026-07-31"
                ),
            ],
            importsUpdatedAt: Date(timeIntervalSince1970: 2)
        )
        try widgetStore.save(previous)

        let session = LedgerSession(
            api: SessionMockAPI(
                payload: Self.payload,
                widgetReport: Self.widgetReport,
                importDocumentsShouldFail: true
            ),
            defaults: defaults,
            widgetSnapshotStore: widgetStore
        )
        await session.resume()

        XCTAssertEqual(widgetStore.load()?.expense.amount, 555_180)
        XCTAssertEqual(widgetStore.load()?.imports, previous.imports)
        XCTAssertEqual(widgetStore.load()?.importsUpdatedAt, previous.importsUpdatedAt)
    }

    func testNativeImportUsesReadySessionAndCommitsSelectedEntries() async throws {
        let suiteName = "ledger-mobile-native-import-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(
            payload: Self.payload,
            importProvidersPayload: Self.importProviders,
            importPreviewPayload: Self.importPreview,
            importCommitPayload: Self.importCommitResult
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        let providers = try await session.importProviders()
        let file = LedgerImportSelectedFile(name: "statement.zip", data: Data("safe".utf8))
        let preview = try await session.previewImport(
            file: file,
            provider: "wechat",
            alipayFundRounding: true,
            archivePassword: "archive-secret"
        )
        let selectedEntries = Array(preview.entries.suffix(1))
        let result = try await session.commitImport(preview: preview, entries: selectedEntries)
        let requests = await api.importRequests()

        XCTAssertEqual(providers, Self.importProviders)
        XCTAssertEqual(requests.providerCalls, 1)
        XCTAssertEqual(requests.preview?.fileName, "statement.zip")
        XCTAssertEqual(requests.preview?.provider, "wechat")
        XCTAssertEqual(requests.preview?.alipayFundRounding, true)
        XCTAssertEqual(requests.preview?.archivePassword, "archive-secret")
        XCTAssertEqual(requests.commit?.importID, preview.importID)
        XCTAssertEqual(requests.commit?.provider, preview.provider)
        XCTAssertEqual(requests.commit?.entryIDs, selectedEntries.map(\.id))
        XCTAssertEqual(result, Self.importCommitResult)
    }

    func testTransactionWritesUseReadySessionAndRefreshLedger() async throws {
        let suiteName = "ledger-mobile-transaction-write-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(payload: Self.transactionPayload)
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        let source = Self.editableTransaction.source
        let entry = LedgerTransactionEntry(
            date: "2026-08-20",
            payee: "海底捞",
            narration: "晚餐",
            metadata: [:],
            tags: ["dining"],
            postings: [
                LedgerTransactionEntryPosting(account: "Expenses:Food:Dining", amount: "85.00", currency: "CNY"),
                LedgerTransactionEntryPosting(account: "Assets:Bank:Daily", amount: "-85.00", currency: "CNY"),
            ]
        )

        try await session.updateTransaction(source: source, entry: entry)
        let writes = await api.transactionWrites()
        XCTAssertEqual(writes.update?.source, source)
        XCTAssertEqual(writes.update?.entry.tags, ["dining"])
        XCTAssertEqual(session.visibleTransactions.first?.payee, "海底捞")
    }

    func testTransactionEditProjectsBeforeDelayedWriteCompletesAndSurvivesStaleRefresh() async throws {
        let suiteName = "ledger-mobile-delayed-edit-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(
            payload: Self.transactionPayload,
            transactionWriteDelayNanoseconds: 250_000_000
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        let source = Self.editableTransaction.source
        let entry = LedgerTransactionEntry(
            date: "2026-08-18",
            payee: "新城市书房",
            narration: "九月阅读计划",
            metadata: [:],
            tags: ["learning", "travel"],
            postings: Self.editableTransaction.editableEntry!.postings
        )

        let write = Task { try await session.updateTransaction(source: source, entry: entry) }
        for _ in 0..<100 {
            let counts = await api.transactionWriteCounts()
            if counts.started == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertEqual(session.ledger?.transactions.first?.payee, "城市书房")
        XCTAssertEqual(session.visibleTransactions.first?.payee, "新城市书房")
        XCTAssertEqual(session.transactionMutationPhase(for: session.ledger!.transactions[0]), .pending)
        let countsBeforeCompletion = await api.transactionWriteCounts()
        XCTAssertEqual(countsBeforeCompletion.completed, 0)

        do {
            try await session.updateTransaction(source: source, entry: entry)
            XCTFail("duplicate submission should be rejected")
        } catch {
            XCTAssertEqual(error as? LedgerTransactionMutationError, .alreadyInProgress)
        }
        let countsAfterDuplicate = await api.transactionWriteCounts()
        XCTAssertEqual(countsAfterDuplicate.started, 1)

        await session.refresh()
        XCTAssertEqual(session.ledger?.transactions.first?.payee, "城市书房")
        XCTAssertEqual(session.visibleTransactions.first?.payee, "新城市书房")
        XCTAssertEqual(session.transactionMutationPhase(for: session.ledger!.transactions[0]), .pending)

        try await write.value
        for _ in 0..<100 {
            if session.ledger?.transactions.first?.source.hash == "confirmed-1" { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(session.ledger?.transactions.first?.source.hash, "confirmed-1")
        XCTAssertEqual(session.ledger?.transactions.first?.source.line, source.line + 1)
        XCTAssertNil(session.transactionMutationPhase(for: session.ledger!.transactions[0]))
    }

    func testBulkTagsProjectThenRollbackWithRetryContextOnFailure() async throws {
        let suiteName = "ledger-mobile-tag-rollback-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(
            payload: Self.transactionPayload,
            transactionWriteDelayNanoseconds: 150_000_000,
            transactionWritesShouldFail: true
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        let source = Self.editableTransaction.source

        let write = Task { try await session.addTransactionTags(sources: [source], tags: ["reviewed"]) }
        for _ in 0..<100 {
            let counts = await api.transactionWriteCounts()
            if counts.started == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertEqual(session.ledger?.transactions.first?.tags, ["learning"])
        XCTAssertTrue(session.visibleTransactions.first?.tags?.contains("reviewed") == true)
        XCTAssertEqual(session.transactionMutationPhase(for: session.ledger!.transactions[0]), .pending)
        do {
            try await write.value
            XCTFail("failed server write should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("账本来源已变化"))
        }

        XCTAssertEqual(session.visibleTransactions.first?.tags, ["learning"])
        guard case let .failed(message)? = session.transactionMutationPhase(for: session.ledger!.transactions[0]) else {
            return XCTFail("rollback should retain a failed state for retry UI")
        }
        XCTAssertTrue(message.contains("账本来源已变化"))
    }

    func testDisjointTransactionWritesCanRemainPendingConcurrently() async throws {
        let suiteName = "ledger-mobile-concurrent-write-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(
            payload: Self.transactionPayload,
            transactionWriteDelayNanoseconds: 150_000_000
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        let edited = LedgerTransactionEntry(
            date: "2026-08-18",
            payee: "新城市书房",
            narration: "读书",
            metadata: [:],
            tags: ["learning"],
            postings: Self.editableTransaction.editableEntry!.postings
        )

        async let edit: Void = session.updateTransaction(source: Self.editableTransaction.source, entry: edited)
        async let tags: Void = session.addTransactionTags(
            sources: [Self.secondEditableTransaction.source],
            tags: ["reviewed"]
        )
        for _ in 0..<100 {
            let counts = await api.transactionWriteCounts()
            if counts.started == 2 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        let concurrentCounts = await api.transactionWriteCounts()
        XCTAssertEqual(concurrentCounts.started, 2)
        XCTAssertEqual(session.ledger?.transactions[0].payee, "城市书房")
        XCTAssertEqual(session.visibleTransactions[0].payee, "新城市书房")
        XCTAssertTrue(session.visibleTransactions[1].tags?.contains("reviewed") == true)
        _ = try await (edit, tags)
    }

    func testConfirmedWriteResumesReconciliationAfterRangeLoadFinishes() async throws {
        let suiteName = "ledger-mobile-write-range-reconciliation-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(
            payload: Self.transactionPayload,
            bootstrapDelaysByStart: ["2026-07-01": 150_000_000],
            transactionWriteDelayNanoseconds: 20_000_000
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        let july = LedgerDateRange.month(year: 2026, month: 7)
        let rangeLoad = Task { await session.applyRange(july) }
        for _ in 0..<100 {
            if session.isRangeLoading { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let entry = LedgerTransactionEntry(
            date: "2026-08-18",
            payee: "范围加载期间写入",
            narration: "完成后继续收敛",
            metadata: [:],
            tags: ["learning"],
            postings: Self.editableTransaction.editableEntry!.postings
        )

        try await session.updateTransaction(source: Self.editableTransaction.source, entry: entry)
        XCTAssertTrue(session.isRangeLoading)
        await rangeLoad.value
        for _ in 0..<100 {
            let calls = await api.callCounts()
            if calls.bootstrap >= 3 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        let calls = await api.callCounts()
        XCTAssertGreaterThanOrEqual(calls.bootstrap, 3)
        XCTAssertFalse(session.isRangeLoading)
    }

    func testWriteCompletionFromPreviousSessionEpochIsDiscarded() async throws {
        let suiteName = "ledger-mobile-write-session-epoch-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(
            payload: Self.transactionPayload,
            transactionWriteDelayNanoseconds: 250_000_000
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        let entry = LedgerTransactionEntry(
            date: "2026-08-18",
            payee: "旧会话编辑",
            narration: "不应进入新会话状态",
            metadata: [:],
            tags: ["learning"],
            postings: Self.editableTransaction.editableEntry!.postings
        )

        let write = Task {
            try await session.updateTransaction(source: Self.editableTransaction.source, entry: entry)
        }
        for _ in 0..<100 {
            let counts = await api.transactionWriteCounts()
            if counts.started == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        session.logout()
        session.password = "ledger-password"
        await session.login()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.visibleTransactions.first?.payee, "城市书房")

        do {
            try await write.value
            XCTFail("a prior session write must not publish completion into the new session")
        } catch is CancellationError {
            // Expected: the server request belongs to an invalidated session epoch.
        }
        XCTAssertTrue(session.transactionMutationStates.isEmpty)
        XCTAssertEqual(session.visibleTransactions.first?.payee, "城市书房")
    }

    func testFailedWriteMarksDetailSourceUnavailableAfterExternalSupersession() async throws {
        let suiteName = "ledger-mobile-write-supersession-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(
            payload: Self.transactionPayload,
            transactionWriteDelayNanoseconds: 150_000_000,
            transactionWritesShouldFail: true
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()
        let source = Self.editableTransaction.source
        let entry = LedgerTransactionEntry(
            date: "2026-08-18",
            payee: "不会提交的编辑",
            narration: "保留重试草稿",
            metadata: [:],
            tags: ["learning"],
            postings: Self.editableTransaction.editableEntry!.postings
        )

        let write = Task { try await session.updateTransaction(source: source, entry: entry) }
        for _ in 0..<100 {
            let counts = await api.transactionWriteCounts()
            if counts.started == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        await api.supersedeTransactionSource(source)
        await session.refresh()

        guard case let .visible(pending) = session.transactionResolution(for: source) else {
            return XCTFail("pending detail should retain its local projection")
        }
        XCTAssertEqual(pending.payee, "不会提交的编辑")

        do {
            try await write.value
            XCTFail("the controlled write should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("账本来源已变化"))
        }
        XCTAssertEqual(session.transactionResolution(for: source), .unavailable)
        XCTAssertEqual(session.visibleTransactions.first?.payee, "城市书房")
    }

    func testGmailAutomationUsesReadySessionWithoutBypassingPendingPreview() async throws {
        let suiteName = "ledger-mobile-gmail-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gmailStatus = LedgerGmailStatus(
            configured: true,
            deliveryMode: "webhook",
            connected: true,
            email: "ledger@example.com",
            label: "Bills",
            watchExpiration: nil,
            lastSyncAt: nil,
            lastError: nil,
            allowedSenders: [],
            oauthRedirectURL: nil
        )
        let pending = LedgerGmailPendingImport(
            id: "pending-1",
            importID: Self.importPreview.importID,
            messageID: "message-1",
            threadID: nil,
            sender: "billing@example.com",
            subject: "账单",
            receivedAt: "2026-09-01T08:00:00Z",
            filename: "statement.zip",
            provider: "wechat",
            candidateCount: 2,
            status: "ready",
            error: nil,
            createdAt: "2026-09-01T08:00:00Z",
            updatedAt: "2026-09-01T08:00:00Z"
        )
        let api = SessionMockAPI(
            payload: Self.payload,
            importPreviewPayload: Self.importPreview,
            gmailStatusPayload: gmailStatus,
            gmailPendingPayload: [pending]
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        let (status, items) = try await session.gmailAutomation()
        let oauthURL = try await session.connectGmail()
        _ = try await session.syncGmail(pendingID: pending.id)
        let detail = try await session.gmailPendingImport(id: pending.id)
        try await session.dismissGmailPendingImport(id: pending.id)
        try await session.disconnectGmail()

        XCTAssertEqual(status, gmailStatus)
        XCTAssertEqual(items, [pending])
        XCTAssertEqual(oauthURL.host, "accounts.google.com")
        XCTAssertEqual(detail.preview, Self.importPreview)
        let requests = await api.gmailRequests()
        XCTAssertEqual(requests.syncPendingIDs, [pending.id])
        XCTAssertEqual(requests.detailIDs, [pending.id])
        XCTAssertEqual(requests.dismissedIDs, [pending.id])
        XCTAssertEqual(requests.disconnectCalls, 1)
    }

    func testImportIndexTrackingCompletesWhenTargetRequestIsIndexedByNewerRevision() async {
        let suiteName = "ledger-mobile-import-index-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let targetGitSHA = "new-index-revision"
        let api = SessionMockAPI(
            payload: Self.payload,
            indexInfoPayload: LedgerIndexInfo(
                enabled: true,
                active: true,
                gitSHA: "newer-index-revision",
                indexedAt: "2026-09-01T08:30:00Z",
                requestCompleted: true
            )
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        session.startImportIndexTracking(
            result: LedgerImportCommitResult(
                ok: true,
                outputFile: "transactions/2026/imports/import.bean",
                includeFile: "transactions/2026/09.bean",
                documentFile: nil,
                count: 2,
                beanText: nil,
                readModelPending: true,
                indexGitSHA: targetGitSHA,
                runtimeCleanupError: nil,
                gmailPendingStatusWarning: nil
            ),
            providerLabel: "支付宝",
            baselineGitSHA: "old-index-revision"
        )

        for _ in 0..<100 where session.importIndexProgress?.phase != .indexed {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            session.importIndexProgress,
            LedgerImportIndexProgress(providerLabel: "支付宝", entryCount: 2, phase: .indexed)
        )
        let indexInfoCalls = await api.indexInfoCallCount()
        XCTAssertGreaterThan(indexInfoCalls, 0)
        await session.lock()
        XCTAssertNil(session.importIndexProgress)
    }

    func testImportIndexTrackingDoesNotUseUncorrelatedRevisionWithoutTargetOrBaseline() async {
        let suiteName = "ledger-mobile-import-index-uncorrelated-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = SessionMockAPI(
            payload: Self.payload,
            indexInfoPayload: LedgerIndexInfo(
                enabled: true,
                active: true,
                gitSHA: "unrelated-index-revision",
                indexedAt: "2026-09-01T08:30:00Z",
                requestCompleted: true
            )
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        session.startImportIndexTracking(
            result: LedgerImportCommitResult(
                ok: true,
                outputFile: "transactions/2026/imports/import.bean",
                includeFile: "transactions/2026/09.bean",
                documentFile: nil,
                count: 2,
                beanText: nil,
                readModelPending: true,
                indexGitSHA: nil,
                runtimeCleanupError: nil,
                gmailPendingStatusWarning: nil
            ),
            providerLabel: "支付宝",
            baselineGitSHA: nil
        )

        XCTAssertNil(session.importIndexProgress)
        let indexInfoCalls = await api.indexInfoCallCount()
        XCTAssertEqual(indexInfoCalls, 0)
    }

    func testImportLiveActivityURLRoutesToImportHistory() {
        let session = LedgerSession()

        session.openWidgetURL(URL(string: "ledger://imports")!)

        XCTAssertEqual(session.primaryDestinationID, "imports")
    }

    func testGmailOAuthCallbackUsesNativeImportDestinationAndCorrelation() async throws {
        let suiteName = "ledger-mobile-gmail-oauth-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = LedgerSession(api: SessionMockAPI(payload: Self.payload), defaults: defaults)
        await session.resume()

        session.openWidgetURL(URL(string: "ledger://gmail-import?gmail=connected&state=forged")!)
        XCTAssertNil(session.gmailOAuthResult)

        _ = try await session.connectGmail()

        session.openWidgetURL(URL(string: "ledger://gmail-import?gmail=connected&state=ios.test-state")!)

        XCTAssertEqual(session.primaryDestinationID, "imports")
        XCTAssertEqual(session.gmailOAuthResult?.status, .connected)
        XCTAssertNil(session.gmailOAuthResult?.reason)

        let resultID = try XCTUnwrap(session.gmailOAuthResult?.id)
        session.consumeGmailOAuthResult(id: resultID)
        XCTAssertNil(session.gmailOAuthResult)

        _ = try await session.connectGmail()
        session.openWidgetURL(URL(string: "ledger://gmail-import?gmail=error&reason=cancelled&state=ios.test-state")!)
        XCTAssertEqual(session.gmailOAuthResult?.status, .error)
        XCTAssertEqual(session.gmailOAuthResult?.reason, "cancelled")
    }

    func testGmailOAuthCorrelationKeepsConcurrentNativeFlows() async throws {
        let suiteName = "ledger-mobile-gmail-concurrent-oauth-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = SessionMockAPI(
            payload: Self.payload,
            gmailConnectStates: ["ios.first-state", "ios.second-state"]
        )
        let session = LedgerSession(api: api, defaults: defaults)
        await session.resume()

        _ = try await session.connectGmail()
        _ = try await session.connectGmail()
        session.openWidgetURL(URL(string: "ledger://gmail-import?gmail=error&reason=cancelled&state=ios.first-state")!)
        XCTAssertEqual(session.gmailOAuthResult?.reason, "cancelled")

        session.openWidgetURL(URL(string: "ledger://gmail-import?gmail=connected&state=ios.second-state")!)
        XCTAssertEqual(session.gmailOAuthResult?.status, .connected)
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

    private static let editableTransaction = LedgerTransaction(
        date: "2026-08-18",
        payee: "城市书房",
        narration: "读书",
        tags: ["learning"],
        postings: [
            LedgerPosting(account: "Expenses:Education:Books", amount: 8_500, currency: "CNY"),
            LedgerPosting(account: "Assets:Bank:Daily", amount: -8_500, currency: "CNY"),
        ],
        editableEntry: LedgerTransactionEntry(
            date: "2026-08-18",
            payee: "城市书房",
            narration: "读书",
            metadata: [:],
            tags: ["learning"],
            postings: [
                LedgerTransactionEntryPosting(account: "Expenses:Education:Books", amount: "85.00", currency: "CNY"),
                LedgerTransactionEntryPosting(account: "Assets:Bank:Daily", amount: "-85.00", currency: "CNY"),
            ]
        ),
        source: TransactionSource(
            file: "transactions/2026/08.bean",
            line: 18,
            hash: "expense-hash",
            gitSHA: "abc123"
        )
    )

    private static let secondEditableTransaction = LedgerTransaction(
        date: "2026-08-19",
        payee: "青禾市场",
        narration: "食材",
        tags: ["groceries"],
        postings: [
            LedgerPosting(account: "Expenses:Food:Groceries", amount: 4_200, currency: "CNY"),
            LedgerPosting(account: "Assets:Bank:Daily", amount: -4_200, currency: "CNY"),
        ],
        editableEntry: LedgerTransactionEntry(
            date: "2026-08-19",
            payee: "青禾市场",
            narration: "食材",
            metadata: [:],
            tags: ["groceries"],
            postings: [
                LedgerTransactionEntryPosting(account: "Expenses:Food:Groceries", amount: "42.00", currency: "CNY"),
                LedgerTransactionEntryPosting(account: "Assets:Bank:Daily", amount: "-42.00", currency: "CNY"),
            ]
        ),
        source: TransactionSource(
            file: "transactions/2026/08.bean",
            line: 26,
            hash: "groceries-hash",
            gitSHA: "abc123"
        )
    )

    private static let transactionPayload = LedgerBootstrap(
        start: "2026-08-01",
        end: "2026-08-31",
        summary: LedgerSummary(currency: "CNY", income: 0, expense: 12_700, net: -12_700),
        accountBalances: [],
        transactions: [editableTransaction, secondEditableTransaction],
        accounts: [],
        valuationCurrency: "CNY",
        sensitiveUnlocked: true
    )

    private static let widgetReport = LedgerHomeReport(
        start: "2026-08-01",
        end: "2026-09-01",
        currency: "CNY",
        current: LedgerHomeReportPeriod(
            kpis: LedgerHomeReportExpenseKPI(expense: 555_180, transactionCount: 9),
            categorySeries: []
        ),
        previous: LedgerHomeReportPeriod(
            kpis: LedgerHomeReportExpenseKPI(expense: 635_200, transactionCount: 12),
            categorySeries: []
        ),
        dailyExpenseSeries: [],
        generatedAt: "2026-08-31T05:30:00Z"
    )

    private static let widgetImportDocuments = [
        LedgerImportDocument(
            provider: "alipay",
            dateStart: "2026-08-01",
            dateEnd: "2026-08-28",
            modTime: "2026-08-29T08:00:00Z"
        ),
    ]

    private static let importProviders = [
        LedgerImportProviderInfo(
            id: "wechat",
            label: "微信支付",
            detail: "微信支付导出的明细表",
            extensions: [".xlsx", ".xls"],
            accept: ".xlsx / .xls",
            engine: "deg-module"
        ),
    ]

    private static let importEntries = [
        LedgerImportEntry(
            id: "import-entry-1",
            date: "2026-08-28",
            flag: "*",
            payee: "城市书房",
            narration: "年度阅读计划",
            source: "wechat",
            orderID: "order-1",
            merchantID: nil,
            payTime: nil,
            method: "零钱",
            transactionType: "支出",
            status: "支付成功",
            type: nil,
            categoryAccount: "Expenses:Education:Books",
            fundingAccount: "Assets:Bank:Daily",
            amount: 328,
            currency: "CNY",
            metadata: [:],
            postings: []
        ),
        LedgerImportEntry(
            id: "import-entry-2",
            date: "2026-08-30",
            flag: "*",
            payee: "青禾市场",
            narration: "周末食材",
            source: "wechat",
            orderID: "order-2",
            merchantID: nil,
            payTime: nil,
            method: "银行卡",
            transactionType: "支出",
            status: "支付成功",
            type: nil,
            categoryAccount: "Expenses:Food:Groceries",
            fundingAccount: "Liabilities:CreditCard",
            amount: 186.8,
            currency: "CNY",
            metadata: [:],
            postings: []
        ),
    ]

    private static let importPreview = LedgerImportPreview(
        importID: "preview-123",
        provider: "wechat",
        providerDetection: LedgerImportProviderDetection(
            provider: "wechat",
            reason: "文件结构匹配",
            confidence: "high"
        ),
        originalFilename: "statement.zip",
        dedupReport: "待写入 2 条",
        entries: importEntries,
        candidateCount: 2,
        rawRowCount: 3,
        filteredRowCount: 3,
        generatedCount: 3,
        excludedRowCount: 0,
        skippedDuplicateCount: 1,
        dateStart: "2026-08-01",
        dateEnd: "2026-08-30",
        warnings: []
    )

    private static let importCommitResult = LedgerImportCommitResult(
        ok: true,
        outputFile: "transactions/2026/imports/import.bean",
        includeFile: "transactions/2026/08.bean",
        documentFile: "transactions/2026/documents/imports/statement.zip",
        count: 1,
        beanText: nil,
        readModelPending: false,
        indexGitSHA: nil,
        runtimeCleanupError: nil,
        gmailPendingStatusWarning: nil
    )
}

private actor SessionMockAPI: LedgerAPI {
    struct BootstrapRequest: Equatable, Sendable {
        let start: String
        let end: String
        let today: String
        let valuationCurrency: String
    }

    struct BQLCall: Equatable, Sendable {
        let query: String
        let valuationCurrency: String
    }

    struct AccountDetailCall: Equatable, Sendable {
        let account: String
        let currency: String
        let start: String
        let end: String
    }

    struct ImportPreviewCall: Equatable, Sendable {
        let fileName: String
        let provider: String?
        let alipayFundRounding: Bool
        let archivePassword: String
    }

    struct ImportCommitCall: Equatable, Sendable {
        let importID: String
        let provider: String
        let entryIDs: [String]
    }

    struct ImportRequests: Equatable, Sendable {
        let providerCalls: Int
        let preview: ImportPreviewCall?
        let commit: ImportCommitCall?
    }

    struct TransactionWrites: Equatable, Sendable {
        let update: LedgerTransactionUpdateRequest?
        let tags: LedgerTransactionTagsRequest?
    }

    struct GmailRequests: Equatable, Sendable {
        let syncPendingIDs: [String]
        let detailIDs: [String]
        let dismissedIDs: [String]
        let disconnectCalls: Int
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
        let dashboard: Int
        let incomeStatement: Int
        let investments: Int
        let bql: Int
        let lock: Int
    }

    enum Failure: Error {
        case lock
    }

    let healthStatus: HealthStatus
    let currentAuthStatus: AuthStatus
    let currentPasskeyStatus: PasskeyStatus
    let payload: LedgerBootstrap
    let widgetReport: LedgerHomeReport?
    let widgetImportDocuments: [LedgerImportDocument]
    let importProvidersPayload: [LedgerImportProviderInfo]
    let importPreviewPayload: LedgerImportPreview?
    let importCommitPayload: LedgerImportCommitResult?
    let gmailStatusPayload: LedgerGmailStatus?
    let gmailPendingPayload: [LedgerGmailPendingImport]
    let gmailConnectStates: [String]
    let indexInfoPayload: LedgerIndexInfo?
    let importDocumentsShouldFail: Bool
    let lockShouldFail: Bool
    let accountDetailErrorStatus: Int?
    let accountDetailDelayNanoseconds: UInt64
    let accountDetailPayload: LedgerAccountDetail?
    let analysisErrorStatus: Int?
    let analysisDelayNanoseconds: UInt64
    let bqlErrorStatus: Int?
    let bqlDelayNanoseconds: UInt64
    let bootstrapDelays: [String: UInt64]
    let bootstrapDelaysByStart: [String: UInt64]
    let bootstrapErrorStatuses: [String: Int]
    let bootstrapErrorStatusAfterFirstCall: Int?
    let quickUnlockRevokeDelayNanoseconds: UInt64
    let transactionWriteDelayNanoseconds: UInt64
    let transactionWritesShouldFail: Bool
    private var authStatusCalls = 0
    private var loginCalls = 0
    private var bootstrapCalls = 0
    private var quickUnlockRegisterCalls = 0
    private var quickUnlockVerifyCalls = 0
    private var quickUnlockRevokeCalls = 0
    private var lockCalls = 0
    private var passkeyStatusCalls = 0
    private var passkeyOptionsCalls = 0
    private var passkeyVerifyCalls = 0
    private var dashboardCalls = 0
    private var incomeStatementCalls = 0
    private var investmentsCalls = 0
    private var bqlCalls = 0
    private var requests: [BootstrapRequest] = []
    private var requestedBQL: [BQLCall] = []
    private var requestedAccountDetails: [AccountDetailCall] = []
    private var importProviderCalls = 0
    private var requestedImportPreview: ImportPreviewCall?
    private var requestedImportCommit: ImportCommitCall?
    private var requestedTransactionUpdate: LedgerTransactionUpdateRequest?
    private var requestedTransactionTags: LedgerTransactionTagsRequest?
    private var serverTransactions: [LedgerTransaction]
    private var transactionWriteStartedCount = 0
    private var transactionWriteCompletedCount = 0
    private var indexInfoCalls = 0
    private var gmailSyncPendingIDs: [String] = []
    private var gmailDetailIDs: [String] = []
    private var gmailDismissedIDs: [String] = []
    private var gmailDisconnectCalls = 0
    private var gmailConnectCalls = 0

    init(
        healthStatus: HealthStatus = HealthStatus(
            apiVersion: 1,
            capabilities: ["full-backend", "cookie-auth", HealthStatus.accountPeriodBalancesCapability]
        ),
        authStatus: AuthStatus = AuthStatus(authenticated: true, sensitiveUnlocked: true, authDisabled: false),
        passkeyStatus: PasskeyStatus = PasskeyStatus(registered: false, count: 0),
        payload: LedgerBootstrap,
        widgetReport: LedgerHomeReport? = nil,
        widgetImportDocuments: [LedgerImportDocument] = [],
        importProvidersPayload: [LedgerImportProviderInfo] = [],
        importPreviewPayload: LedgerImportPreview? = nil,
        importCommitPayload: LedgerImportCommitResult? = nil,
        gmailStatusPayload: LedgerGmailStatus? = nil,
        gmailPendingPayload: [LedgerGmailPendingImport] = [],
        gmailConnectStates: [String] = ["ios.test-state"],
        indexInfoPayload: LedgerIndexInfo? = nil,
        importDocumentsShouldFail: Bool = false,
        lockShouldFail: Bool = false,
        accountDetailErrorStatus: Int? = nil,
        accountDetailDelayNanoseconds: UInt64 = 0,
        accountDetailPayload: LedgerAccountDetail? = nil,
        analysisErrorStatus: Int? = nil,
        analysisDelayNanoseconds: UInt64 = 0,
        bqlErrorStatus: Int? = nil,
        bqlDelayNanoseconds: UInt64 = 0,
        bootstrapDelays: [String: UInt64] = [:],
        bootstrapDelaysByStart: [String: UInt64] = [:],
        bootstrapErrorStatuses: [String: Int] = [:],
        bootstrapErrorStatusAfterFirstCall: Int? = nil,
        quickUnlockRevokeDelayNanoseconds: UInt64 = 0,
        transactionWriteDelayNanoseconds: UInt64 = 0,
        transactionWritesShouldFail: Bool = false
    ) {
        self.healthStatus = healthStatus
        currentAuthStatus = authStatus
        currentPasskeyStatus = passkeyStatus
        self.payload = payload
        self.widgetReport = widgetReport
        self.widgetImportDocuments = widgetImportDocuments
        self.importProvidersPayload = importProvidersPayload
        self.importPreviewPayload = importPreviewPayload
        self.importCommitPayload = importCommitPayload
        self.gmailStatusPayload = gmailStatusPayload
        self.gmailPendingPayload = gmailPendingPayload
        self.gmailConnectStates = gmailConnectStates
        self.indexInfoPayload = indexInfoPayload
        self.importDocumentsShouldFail = importDocumentsShouldFail
        self.lockShouldFail = lockShouldFail
        self.accountDetailErrorStatus = accountDetailErrorStatus
        self.accountDetailDelayNanoseconds = accountDetailDelayNanoseconds
        self.accountDetailPayload = accountDetailPayload
        self.analysisErrorStatus = analysisErrorStatus
        self.analysisDelayNanoseconds = analysisDelayNanoseconds
        self.bqlErrorStatus = bqlErrorStatus
        self.bqlDelayNanoseconds = bqlDelayNanoseconds
        self.bootstrapDelays = bootstrapDelays
        self.bootstrapDelaysByStart = bootstrapDelaysByStart
        self.bootstrapErrorStatuses = bootstrapErrorStatuses
        self.bootstrapErrorStatusAfterFirstCall = bootstrapErrorStatusAfterFirstCall
        self.quickUnlockRevokeDelayNanoseconds = quickUnlockRevokeDelayNanoseconds
        self.transactionWriteDelayNanoseconds = transactionWriteDelayNanoseconds
        self.transactionWritesShouldFail = transactionWritesShouldFail
        serverTransactions = payload.transactions
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
        if quickUnlockRevokeDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: quickUnlockRevokeDelayNanoseconds)
        }
    }

    func bootstrap(
        baseURL: URL,
        start: String,
        end: String,
        today: String,
        valuationCurrency: String
    ) async throws -> LedgerBootstrap {
        bootstrapCalls += 1
        requests.append(BootstrapRequest(
            start: start,
            end: end,
            today: today,
            valuationCurrency: valuationCurrency
        ))
        if let delay = bootstrapDelays[valuationCurrency], delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        if let delay = bootstrapDelaysByStart[start], delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        if let status = bootstrapErrorStatuses[valuationCurrency] {
            throw LedgerAPIError.server(status: status, message: "Sensitive data locked")
        }
        if bootstrapCalls > 1, let status = bootstrapErrorStatusAfterFirstCall {
            throw LedgerAPIError.server(status: status, message: "Sensitive data locked")
        }
        if valuationCurrency == payload.valuationCurrency {
            return payload.replacingTransactions(with: serverTransactions)
        }
        return LedgerBootstrap(
            start: payload.start,
            end: payload.end,
            summary: LedgerSummary(
                currency: valuationCurrency,
                income: payload.summary.income,
                expense: payload.summary.expense,
                net: payload.summary.net
            ),
            accountBalances: payload.accountBalances,
            transactions: serverTransactions,
            accounts: payload.accounts,
            commodities: payload.commodities,
            prices: payload.prices,
            valuationCurrency: valuationCurrency,
            sensitiveUnlocked: payload.sensitiveUnlocked
        )
    }

    func homeReport(
        baseURL: URL,
        start: String,
        end: String,
        valuationCurrency: String
    ) async throws -> LedgerHomeReport {
        guard let widgetReport else {
            throw LedgerAPIError.incompatibleServer("服务器暂不支持首页消费报告")
        }
        return widgetReport
    }

    func importDocuments(baseURL: URL) async throws -> [LedgerImportDocument] {
        if importDocumentsShouldFail {
            throw LedgerAPIError.transport("import history unavailable")
        }
        return widgetImportDocuments
    }

    func importProviders(baseURL: URL) async throws -> [LedgerImportProviderInfo] {
        importProviderCalls += 1
        return importProvidersPayload
    }

    func gmailStatus(baseURL: URL) async throws -> LedgerGmailStatus {
        guard let gmailStatusPayload else {
            throw LedgerAPIError.incompatibleServer("missing Gmail status fixture")
        }
        return gmailStatusPayload
    }

    func gmailConnect(baseURL: URL) async throws -> LedgerGmailConnectResponse {
        let index = min(gmailConnectCalls, gmailConnectStates.count - 1)
        gmailConnectCalls += 1
        let state = gmailConnectStates[index]
        return LedgerGmailConnectResponse(
            url: URL(string: "https://accounts.google.com/o/oauth2/auth?state=\(state)")!
        )
    }

    func gmailSync(baseURL: URL, pendingID: String?) async throws -> LedgerGmailSyncResult {
        if let pendingID { gmailSyncPendingIDs.append(pendingID) }
        return LedgerGmailSyncResult(ok: true, processed: nil, retryPending: false, item: nil)
    }

    func gmailDisconnect(baseURL: URL) async throws {
        gmailDisconnectCalls += 1
    }

    func gmailPendingImports(baseURL: URL) async throws -> [LedgerGmailPendingImport] {
        gmailPendingPayload
    }

    func gmailPendingImport(baseURL: URL, id: String) async throws -> LedgerGmailPendingDetail {
        gmailDetailIDs.append(id)
        guard let item = gmailPendingPayload.first(where: { $0.id == id }) else {
            throw LedgerAPIError.server(status: 404, message: "missing pending fixture")
        }
        return LedgerGmailPendingDetail(item: item, preview: importPreviewPayload)
    }

    func dismissGmailPendingImport(baseURL: URL, id: String) async throws {
        gmailDismissedIDs.append(id)
    }

    func previewImport(
        baseURL: URL,
        file: LedgerImportSelectedFile,
        provider: String?,
        alipayFundRounding: Bool,
        archivePassword: String
    ) async throws -> LedgerImportPreview {
        requestedImportPreview = ImportPreviewCall(
            fileName: file.name,
            provider: provider,
            alipayFundRounding: alipayFundRounding,
            archivePassword: archivePassword
        )
        guard let importPreviewPayload else {
            throw LedgerAPIError.incompatibleServer("missing import preview fixture")
        }
        return importPreviewPayload
    }

    func commitImport(
        baseURL: URL,
        request: LedgerImportCommitRequest
    ) async throws -> LedgerImportCommitResult {
        requestedImportCommit = ImportCommitCall(
            importID: request.importID,
            provider: request.provider,
            entryIDs: request.entries.map(\.id)
        )
        guard let importCommitPayload else {
            throw LedgerAPIError.incompatibleServer("missing import commit fixture")
        }
        return importCommitPayload
    }

    func updateTransaction(
        baseURL: URL,
        source: TransactionSource,
        entry: LedgerTransactionEntry
    ) async throws {
        transactionWriteStartedCount += 1
        requestedTransactionUpdate = LedgerTransactionUpdateRequest(source: source, entry: entry)
        try await finishTransactionWrite()
        guard let index = serverTransactions.firstIndex(where: { $0.source == source }) else { return }
        serverTransactions[index] = serverTransactions[index]
            .projecting(entry: entry)
            .confirmingServerSource(sequence: transactionWriteCompletedCount)
    }

    func addTransactionTags(
        baseURL: URL,
        sources: [TransactionSource],
        tags: [String]
    ) async throws {
        transactionWriteStartedCount += 1
        requestedTransactionTags = LedgerTransactionTagsRequest(sources: sources, tags: tags)
        try await finishTransactionWrite()
        for source in sources {
            guard let index = serverTransactions.firstIndex(where: { $0.source == source }) else { continue }
            serverTransactions[index] = serverTransactions[index]
                .projecting(addingTags: tags)
                .confirmingServerSource(sequence: transactionWriteCompletedCount)
        }
    }

    func indexInfo(baseURL: URL, targetGitSHA: String?) async throws -> LedgerIndexInfo {
        indexInfoCalls += 1
        guard let indexInfoPayload else {
            throw LedgerAPIError.incompatibleServer("missing index info fixture")
        }
        return indexInfoPayload
    }

    func accountDetail(baseURL: URL, account: String, currency: String, start: String, end: String) async throws -> LedgerAccountDetail {
        requestedAccountDetails.append(AccountDetailCall(account: account, currency: currency, start: start, end: end))
        if accountDetailDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: accountDetailDelayNanoseconds)
        }
        if let accountDetailErrorStatus {
            throw LedgerAPIError.server(status: accountDetailErrorStatus, message: "Sensitive data locked")
        }
        if let accountDetailPayload {
            return accountDetailPayload
        }
        return LedgerAccountDetail(
            account: account,
            label: account,
            alias: nil,
            group: "asset",
            active: true,
            currency: currency,
            currentBalance: 0,
            rows: []
        )
    }

    func dashboard(
        baseURL: URL,
        start: String,
        end: String,
        valuationCurrency: String
    ) async throws -> LedgerDashboard {
        dashboardCalls += 1
        try await waitForAnalysisResponse()
        return LedgerDashboard(
            start: start,
            end: end,
            currency: valuationCurrency,
            kpis: LedgerDashboardKPI(
                assets: 100_000,
                liabilities: 20_000,
                netWorth: 80_000,
                income: 50_000,
                expense: 10_000,
                net: 40_000,
                savingsRate: 0.8
            ),
            netWorthSeries: [],
            cashflowSeries: [],
            categorySeries: [],
            topPayees: [],
            topPaymentAccounts: [],
            anomalies: []
        )
    }

    func incomeStatement(
        baseURL: URL,
        start: String,
        end: String,
        valuationCurrency: String
    ) async throws -> LedgerIncomeStatement {
        incomeStatementCalls += 1
        try await waitForAnalysisResponse()
        return LedgerIncomeStatement(
            start: start,
            end: end,
            income: [],
            expense: [],
            totalIncome: 50_000,
            totalExpense: 10_000,
            netIncome: 40_000,
            valuationCurrency: valuationCurrency
        )
    }

    func investments(baseURL: URL) async throws -> LedgerInvestmentSummary {
        investmentsCalls += 1
        try await waitForAnalysisResponse()
        return LedgerInvestmentSummary(
            totalMarketValueCny: 25_000,
            realizedPnlCny: nil,
            holdings: [],
            positions: [],
            updatedAt: nil
        )
    }

    func runBQL(baseURL: URL, query: String, valuationCurrency: String) async throws -> BQLResult {
        bqlCalls += 1
        requestedBQL.append(BQLCall(query: query, valuationCurrency: valuationCurrency))
        if bqlDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: bqlDelayNanoseconds)
        }
        if let bqlErrorStatus {
            throw LedgerAPIError.server(status: bqlErrorStatus, message: "Sensitive data locked")
        }
        return BQLResult(
            columns: [BQLColumn(name: "month", type: "date"), BQLColumn(name: "total", type: "money")],
            rows: [[.string("2026-08"), .number(125_000)]],
            query: query,
            valuationCurrency: valuationCurrency,
            limit: 100,
            rowCount: 1
        )
    }

    func lock(baseURL: URL) async throws {
        lockCalls += 1
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
            passkeyVerify: passkeyVerifyCalls,
            dashboard: dashboardCalls,
            incomeStatement: incomeStatementCalls,
            investments: investmentsCalls,
            bql: bqlCalls,
            lock: lockCalls
        )
    }

    func bootstrapRequests() -> [BootstrapRequest] {
        requests
    }

    func bqlRequests() -> [BQLCall] {
        requestedBQL
    }

    func accountDetailRequests() -> [AccountDetailCall] {
        requestedAccountDetails
    }

    func importRequests() -> ImportRequests {
        ImportRequests(
            providerCalls: importProviderCalls,
            preview: requestedImportPreview,
            commit: requestedImportCommit
        )
    }

    func transactionWrites() -> TransactionWrites {
        TransactionWrites(update: requestedTransactionUpdate, tags: requestedTransactionTags)
    }

    func transactionWriteCounts() -> (started: Int, completed: Int) {
        (transactionWriteStartedCount, transactionWriteCompletedCount)
    }

    func supersedeTransactionSource(_ source: TransactionSource) {
        guard let index = serverTransactions.firstIndex(where: { $0.source == source }) else { return }
        serverTransactions[index] = serverTransactions[index].confirmingServerSource(sequence: 99)
    }

    func gmailRequests() -> GmailRequests {
        GmailRequests(
            syncPendingIDs: gmailSyncPendingIDs,
            detailIDs: gmailDetailIDs,
            dismissedIDs: gmailDismissedIDs,
            disconnectCalls: gmailDisconnectCalls
        )
    }

    func indexInfoCallCount() -> Int {
        indexInfoCalls
    }

    private func waitForAnalysisResponse() async throws {
        if analysisDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: analysisDelayNanoseconds)
        }
        if let analysisErrorStatus {
            throw LedgerAPIError.server(status: analysisErrorStatus, message: "Sensitive data locked")
        }
    }

    private func finishTransactionWrite() async throws {
        if transactionWriteDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: transactionWriteDelayNanoseconds)
        }
        if transactionWritesShouldFail {
            throw LedgerAPIError.server(status: 409, message: "账本来源已变化")
        }
        transactionWriteCompletedCount += 1
    }
}

private extension LedgerTransaction {
    func confirmingServerSource(sequence: Int) -> LedgerTransaction {
        LedgerTransaction(
            date: date,
            payee: payee,
            narration: narration,
            metadata: metadata,
            tags: tags,
            postings: postings,
            editableEntry: editableEntry,
            source: TransactionSource(
                file: source.file,
                line: source.line + 1,
                hash: "confirmed-\(sequence)",
                gitSHA: "server-\(sequence)"
            )
        )
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
    var readDelayNanoseconds: UInt64 = 0

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
        if readDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: readDelayNanoseconds)
        }
        if readShouldFail { throw BiometricCredentialError.invalidCredential }
        guard let credential else { throw BiometricCredentialError.invalidCredential }
        return credential
    }

    func deleteCredential(for origin: URL) {
        credential = nil
    }
}
