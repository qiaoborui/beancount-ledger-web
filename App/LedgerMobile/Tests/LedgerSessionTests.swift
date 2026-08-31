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

        let dashboardResource = try await session.analysisResource(.dashboard)
        guard case let .dashboard(dashboard) = dashboardResource else {
            return XCTFail("Expected dashboard resource")
        }
        XCTAssertEqual(dashboard.start, "2026-07-01")
        XCTAssertEqual(dashboard.end, "2026-08-01")
        XCTAssertEqual(dashboard.currency, "USD")
        var calls = await api.callCounts()
        XCTAssertEqual(calls.dashboard, 1)
        XCTAssertEqual(calls.incomeStatement, 0)
        XCTAssertEqual(calls.investments, 0)

        let incomeResource = try await session.analysisResource(.incomeStatement)
        guard case let .incomeStatement(incomeStatement) = incomeResource else {
            return XCTFail("Expected income statement resource")
        }
        XCTAssertEqual(incomeStatement.start, "2026-07-01")
        XCTAssertEqual(incomeStatement.end, "2026-08-01")
        XCTAssertEqual(incomeStatement.valuationCurrency, "USD")

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
            _ = try await session.analysisResource(.dashboard)
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

        let analysisRequest = Task { try await session.analysisResource(.dashboard) }
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
        session.updateActivity(isActive: false)
        await currencyLoad.value

        XCTAssertEqual(session.phase, .locked(authenticated: true))
        XCTAssertNil(session.ledger)
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
    private var authStatusCalls = 0
    private var loginCalls = 0
    private var bootstrapCalls = 0
    private var quickUnlockRegisterCalls = 0
    private var quickUnlockVerifyCalls = 0
    private var quickUnlockRevokeCalls = 0
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
        bootstrapErrorStatuses: [String: Int] = [:]
    ) {
        self.healthStatus = healthStatus
        currentAuthStatus = authStatus
        currentPasskeyStatus = passkeyStatus
        self.payload = payload
        self.widgetReport = widgetReport
        self.widgetImportDocuments = widgetImportDocuments
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
        if valuationCurrency == payload.valuationCurrency { return payload }
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
            transactions: payload.transactions,
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
            bql: bqlCalls
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

    private func waitForAnalysisResponse() async throws {
        if analysisDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: analysisDelayNanoseconds)
        }
        if let analysisErrorStatus {
            throw LedgerAPIError.server(status: analysisErrorStatus, message: "Sensitive data locked")
        }
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
