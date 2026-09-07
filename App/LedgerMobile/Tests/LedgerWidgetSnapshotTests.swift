import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerWidgetSnapshotTests: XCTestCase {
    func testWidgetHistoryCivilDatesAndCoverage() {
        XCTAssertEqual(LedgerWidgetDates.weekStart("2027-01-01"), "2026-12-28")
        XCTAssertEqual(LedgerWidgetDates.weekStart("2026-09-06"), "2026-08-31")
        XCTAssertEqual(LedgerWidgetDates.weekStart("2026-09-07"), "2026-09-07")
        XCTAssertEqual(LedgerWidgetDates.adding(1, to: "2028-02-28"), "2028-02-29")
        let expense = LedgerWidgetExpenseSnapshot(periodTitle: "测试", start: "2028-02-28", end: "2028-03-02",
            currency: "CNY", amount: 80, transactionCount: 2, yearOverYearPercentage: nil, categories: [],
            dailySeries: [.init(date: "2028-02-29", amount: 100), .init(date: "2028-02-29", amount: -20)])
        let points = LedgerWidgetDates.series(expense, start: expense.start, end: expense.end)
        XCTAssertEqual(points.map(\.date), ["2028-02-28", "2028-02-29", "2028-03-01"])
        XCTAssertEqual(points.map(\.amount), [0, 80, 0])
        XCTAssertTrue(LedgerWidgetDates.series(expense, start: "2028-02-27", end: expense.end).isEmpty)
        XCTAssertTrue(LedgerWidgetDates.series(expense, start: expense.start, end: "2028-03-03").isEmpty)
    }

    func testWidgetInsightsRoundTripAndOldSnapshotCompatibility() throws {
        var snapshot = Self.snapshot(updatedAt: Date(), amount: 842)
        XCTAssertNil(LedgerWidgetPeriod.week.expense(in: snapshot))
        XCTAssertNil(LedgerWidgetPeriod.year.expense(in: snapshot))
        XCTAssertEqual(LedgerWidgetPeriod.month.expense(in: snapshot)?.amount, 842)
        snapshot.insights = LedgerWidgetExpenseInsights(updatedAt: "2026-09-07T04:00:00Z",
            week: snapshot.expense, year: snapshot.expense, history: snapshot.expense)
        let roundTrip = try JSONDecoder().decode(LedgerWidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(roundTrip, snapshot)
        XCTAssertNotNil(roundTrip.insights?.date)
        XCTAssertEqual(LedgerWidgetPeriod.week.expense(in: roundTrip)?.amount, 842)
        XCTAssertNil(LedgerWidgetPeriod.week.currentExpense(in: roundTrip,
            now: LedgerWidgetDates.date("2027-01-01")!))
    }

    func testWidgetOldServerKeepsInsightTimestampAndRejectsCurrencyMismatch() throws {
        var previous = Self.snapshot(updatedAt: Date(), amount: 842)
        previous.insights = LedgerWidgetExpenseInsights(updatedAt: "2026-09-07T04:00:00Z",
            week: previous.expense, year: previous.expense, history: previous.expense)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
        json["updatedAt"] = "2026-09-08T04:00:00Z"
        json.removeValue(forKey: "insights")
        let remote = try JSONDecoder().decode(LedgerWidgetRemoteSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        let merged = try remote.snapshot(previous: previous)
        XCTAssertEqual(merged.insights, previous.insights)
        XCTAssertNotEqual(merged.insights?.date, merged.updatedAt)
        var expense = try XCTUnwrap(json["expense"] as? [String: Any])
        expense["currency"] = "USD"
        json["expense"] = expense
        let foreign = try JSONDecoder().decode(LedgerWidgetRemoteSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(try foreign.snapshot(previous: previous).insights)
    }

    func testBuilderKeepsExpenseAndSelectableBalancesWithoutIncomeData() throws {
        let ledger = try JSONDecoder().decode(
            LedgerBootstrap.self,
            from: Data(LedgerModelsTests.bootstrapJSON.utf8)
        )
        let snapshot = LedgerWidgetSnapshotBuilder.make(
            report: Self.report,
            ledger: ledger,
            importDocuments: Self.importDocuments,
            fallbackDate: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.expense.amount, 555_180)
        XCTAssertEqual(snapshot.expense.transactionCount, 9)
        XCTAssertEqual(snapshot.expense.yearOverYearPercentage ?? 0, -0.125_976, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.expense.categories.map(\.label), ["居住", "餐饮", "出行"])
        XCTAssertTrue(snapshot.accounts.allSatisfy {
            $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")
        })
        XCTAssertFalse(snapshot.accounts.contains { $0.account.hasPrefix("Income:") })
        XCTAssertEqual(snapshot.imports.map(\.provider), ["alipay", "wechat"])
        XCTAssertEqual(snapshot.imports.first?.latestCoverageDate, "2026-08-28")

        let encoded = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.lowercased().contains("income"))
        XCTAssertFalse(json.contains("工资"))
        XCTAssertFalse(json.contains("private-alipay.csv"))
        XCTAssertFalse(json.contains("transactions/2026/documents"))
        XCTAssertFalse(json.contains("2026-08-29T08:00:00Z"))
    }

    func testStoreRoundTripsCurrentSchemaAndRejectsUnsupportedSchemas() throws {
        let suiteName = "ledger-widget-snapshot-tests-\(UUID().uuidString)"
        let store = LedgerWidgetSnapshotStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let current = LedgerWidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 123),
            expense: LedgerWidgetExpenseSnapshot(
                periodTitle: "2026年8月",
                start: "2026-08-01",
                end: "2026-09-01",
                currency: "CNY",
                amount: 555_180,
                transactionCount: 9,
                yearOverYearPercentage: -0.12,
                categories: [],
                dailySeries: []
            ),
            accounts: []
        )
        try store.save(current)
        XCTAssertEqual(store.load(), current)

        for unsupportedVersion in [-1, 0, 99] {
            try store.save(
                LedgerWidgetSnapshot(
                    schemaVersion: unsupportedVersion,
                    updatedAt: current.updatedAt,
                    expense: current.expense,
                    accounts: current.accounts,
                    imports: current.imports
                )
            )
            XCTAssertNil(store.load())
        }

        store.clear()
        XCTAssertNil(store.load())
    }

    func testStoreMigratesSchemaOneWithoutDiscardingCachedExpenseAndAccounts() throws {
        let suiteName = "ledger-widget-snapshot-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = LedgerWidgetSnapshotStore(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let updatedAt = Date(timeIntervalSince1970: 123)
        let expense = LedgerWidgetExpenseSnapshot(
            periodTitle: "2026年8月",
            start: "2026-08-01",
            end: "2026-09-01",
            currency: "CNY",
            amount: 555_180,
            transactionCount: 9,
            yearOverYearPercentage: -0.12,
            categories: [],
            dailySeries: []
        )
        let account = LedgerWidgetAccountSnapshot(
            account: "Assets:Bank:CMB",
            label: "招商银行",
            group: "资产",
            currency: "CNY",
            balance: 1_234_500,
            valuationCurrency: "CNY",
            valuation: 1_234_500
        )
        let legacySnapshot = SchemaOneSnapshot(
            schemaVersion: 1,
            updatedAt: updatedAt,
            expense: expense,
            accounts: [account]
        )
        defaults.set(try JSONEncoder().encode(legacySnapshot), forKey: LedgerWidgetSnapshotStore.snapshotKey)

        let migrated = try XCTUnwrap(store.load())

        XCTAssertEqual(migrated.schemaVersion, LedgerWidgetSnapshot.currentSchemaVersion)
        XCTAssertEqual(migrated.updatedAt, updatedAt)
        XCTAssertEqual(migrated.expense, expense)
        XCTAssertEqual(migrated.accounts, [account])
        XCTAssertEqual(migrated.imports, [])
        XCTAssertNil(migrated.importsUpdatedAt)

        let rewrittenData = try XCTUnwrap(defaults.data(forKey: LedgerWidgetSnapshotStore.snapshotKey))
        let rewritten = try JSONDecoder().decode(LedgerWidgetSnapshot.self, from: rewrittenData)
        XCTAssertEqual(rewritten, migrated)
        XCTAssertEqual(rewritten.schemaVersion, LedgerWidgetSnapshot.currentSchemaVersion)
    }

    func testStoreRejectsAnOlderSnapshotThatFinishesLater() throws {
        let suiteName = "ledger-widget-snapshot-order-tests-\(UUID().uuidString)"
        let store = LedgerWidgetSnapshotStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let updatedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let olderAttempt = updatedAt
        let newerAttempt = updatedAt.addingTimeInterval(1)
        let newer = Self.snapshot(updatedAt: updatedAt, amount: 200)
        let older = Self.snapshot(updatedAt: updatedAt, amount: 100)

        XCTAssertTrue(try store.saveIfNewer(newer, attemptedAt: newerAttempt))
        XCTAssertFalse(try store.saveIfNewer(older, attemptedAt: olderAttempt))
        store.clear(ifCurrentEquals: older, attemptedAt: olderAttempt)
        XCTAssertEqual(store.load(), newer)
    }

    func testRefreshStatusStoresShareAnInstallationScopedNotificationName() {
        let suiteName = "ledger-widget-notification-name-tests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let first = LedgerWidgetRefreshStatusStore(suiteName: suiteName)
        let second = LedgerWidgetRefreshStatusStore(suiteName: suiteName)

        XCTAssertEqual(first.changeNotificationNameValue, second.changeNotificationNameValue)
        XCTAssertFalse(first.changeNotificationNameValue.contains(suiteName))
    }

    func testTimelineLoaderPersistsServerVersionFailureAndKeepsCachedSnapshot() async throws {
        let suiteName = "ledger-widget-refresh-status-tests-\(UUID().uuidString)"
        let snapshotStore = LedgerWidgetSnapshotStore(suiteName: suiteName)
        let statusStore = LedgerWidgetRefreshStatusStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let previousSuccess = now.addingTimeInterval(-3_600)
        let cached = Self.snapshot(updatedAt: now.addingTimeInterval(-600), amount: 100)
        try snapshotStore.save(cached)
        try statusStore.record(.success, attemptedAt: previousSuccess, succeededAt: previousSuccess)
        let credentialStore = WidgetRefreshTestCredentialStore(credential: Self.widgetCredential)
        let client = WidgetRefreshTestClient(outcome: .server(404))
        let loader = LedgerWidgetTimelineLoader(
            credentialStore: credentialStore,
            snapshotStore: snapshotStore,
            statusStore: statusStore,
            client: client
        )

        let result = await loader.load(now: now)
        let status = try XCTUnwrap(statusStore.load())

        XCTAssertEqual(result.snapshot, cached)
        XCTAssertEqual(result.refreshInterval, LedgerWidgetTimelineLoader.failureRefreshInterval)
        XCTAssertEqual(status.phase, .serverOutdated)
        XCTAssertEqual(status.httpStatus, 404)
        XCTAssertEqual(status.lastAttemptAt, now)
        XCTAssertEqual(status.lastSuccessAt, previousSuccess)
    }

    func testForcedTimelineRefreshBypassesFreshCacheAndRecordsSuccess() async throws {
        let suiteName = "ledger-widget-forced-refresh-tests-\(UUID().uuidString)"
        let snapshotStore = LedgerWidgetSnapshotStore(suiteName: suiteName)
        let statusStore = LedgerWidgetRefreshStatusStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try snapshotStore.save(Self.snapshot(updatedAt: now, amount: 100))
        let refreshed = Self.snapshot(updatedAt: now.addingTimeInterval(1), amount: 200)
        let credentialStore = WidgetRefreshTestCredentialStore(credential: Self.widgetCredential)
        let client = WidgetRefreshTestClient(outcome: .success(refreshed))
        let loader = LedgerWidgetTimelineLoader(
            credentialStore: credentialStore,
            snapshotStore: snapshotStore,
            statusStore: statusStore,
            client: client
        )

        let result = await loader.load(now: now, forceRefresh: true)
        let status = try XCTUnwrap(statusStore.load())
        let callCount = await client.callCount()

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(result.snapshot, refreshed)
        XCTAssertEqual(snapshotStore.load(), refreshed)
        XCTAssertEqual(status.phase, .success)
        XCTAssertEqual(status.lastAttemptAt, now)
        XCTAssertEqual(status.lastSuccessAt, now)
    }

    func testAuthorizationFailureSuspendsCredentialAndRecordsRecoveryState() async throws {
        let suiteName = "ledger-widget-authorization-status-tests-\(UUID().uuidString)"
        let snapshotStore = LedgerWidgetSnapshotStore(suiteName: suiteName)
        let statusStore = LedgerWidgetRefreshStatusStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let credentialStore = WidgetRefreshTestCredentialStore(credential: Self.widgetCredential)
        let client = WidgetRefreshTestClient(outcome: .server(401))
        let loader = LedgerWidgetTimelineLoader(
            credentialStore: credentialStore,
            snapshotStore: snapshotStore,
            statusStore: statusStore,
            client: client
        )

        _ = await loader.load(now: now)
        let status = try XCTUnwrap(statusStore.load())

        XCTAssertNil(try credentialStore.load())
        XCTAssertNotNil(try credentialStore.pendingRevocation())
        XCTAssertEqual(status.phase, .authorizationRejected)
        XCTAssertEqual(status.httpStatus, 401)
    }

    func testLockedAuthorizationFailureSuspendsCredentialAndRecordsRecoveryState() async throws {
        let suiteName = "ledger-widget-locked-status-tests-\(UUID().uuidString)"
        let snapshotStore = LedgerWidgetSnapshotStore(suiteName: suiteName)
        let statusStore = LedgerWidgetRefreshStatusStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let credentialStore = WidgetRefreshTestCredentialStore(credential: Self.widgetCredential)
        let client = WidgetRefreshTestClient(outcome: .server(423))
        let loader = LedgerWidgetTimelineLoader(
            credentialStore: credentialStore,
            snapshotStore: snapshotStore,
            statusStore: statusStore,
            client: client
        )

        _ = await loader.load(now: now)
        let status = try XCTUnwrap(statusStore.load())

        XCTAssertNil(try credentialStore.load())
        XCTAssertNotNil(try credentialStore.pendingRevocation())
        XCTAssertEqual(status.phase, .authorizationRejected)
        XCTAssertEqual(status.httpStatus, 423)
    }

    func testRefreshStatusDoesNotRegressWhenOlderAttemptFinishesLater() throws {
        let suiteName = "ledger-widget-status-order-tests-\(UUID().uuidString)"
        let statusStore = LedgerWidgetRefreshStatusStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let olderAttempt = Date(timeIntervalSince1970: 2_000_000_000)
        let newerAttempt = olderAttempt.addingTimeInterval(1)
        try statusStore.record(.success, attemptedAt: newerAttempt, succeededAt: newerAttempt)
        try statusStore.record(.networkUnavailable, attemptedAt: olderAttempt)

        let status = try XCTUnwrap(statusStore.load())
        XCTAssertEqual(status.phase, .success)
        XCTAssertEqual(status.lastAttemptAt, newerAttempt)
        XCTAssertEqual(status.lastSuccessAt, newerAttempt)
    }

    func testObsoleteCredentialCompletionKeepsReplacementReadyStatus() async throws {
        let suiteName = "ledger-widget-credential-race-tests-\(UUID().uuidString)"
        let snapshotStore = LedgerWidgetSnapshotStore(suiteName: suiteName)
        let statusStore = LedgerWidgetRefreshStatusStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let credentialStore = WidgetRefreshTestCredentialStore(credential: Self.widgetCredential)
        let client = WidgetDelayedRefreshTestClient(
            snapshot: Self.snapshot(updatedAt: now, amount: 200)
        )
        let loader = LedgerWidgetTimelineLoader(
            credentialStore: credentialStore,
            snapshotStore: snapshotStore,
            statusStore: statusStore,
            client: client
        )

        let refresh = Task { await loader.load(now: now, forceRefresh: true) }
        await client.waitUntilStarted()
        let replacement = LedgerWidgetCredential(
            serverOrigin: Self.widgetCredential.serverOrigin,
            deviceID: "replacement-widget",
            token: "replacement-token",
            valuationCurrency: "CNY",
            enabled: true
        )
        try credentialStore.save(replacement)
        try statusStore.record(.ready)
        await client.complete()
        _ = await refresh.value

        XCTAssertEqual(try credentialStore.load(), replacement)
        XCTAssertEqual(statusStore.load()?.phase, .ready)
    }

    private static let widgetCredential = LedgerWidgetCredential(
        serverOrigin: "https://ledger.example.com",
        deviceID: "widget-device",
        token: "widget-token",
        valuationCurrency: "CNY",
        enabled: true
    )

    private static func snapshot(updatedAt: Date, amount: Int) -> LedgerWidgetSnapshot {
        LedgerWidgetSnapshot(
            updatedAt: updatedAt,
            expense: LedgerWidgetExpenseSnapshot(
                periodTitle: "2026年5月",
                start: "2026-05-01",
                end: "2026-06-01",
                currency: "CNY",
                amount: amount,
                transactionCount: 1,
                yearOverYearPercentage: nil,
                categories: [],
                dailySeries: []
            ),
            accounts: []
        )
    }

    private static let report = LedgerHomeReport(
        start: "2026-08-01",
        end: "2026-09-01",
        currency: "CNY",
        current: LedgerHomeReportPeriod(
            kpis: LedgerHomeReportExpenseKPI(expense: 555_180, transactionCount: 9),
            categorySeries: [
                LedgerCategorySeries(account: "Expenses:Food", alias: "餐饮", label: "餐饮", total: 84_780, values: []),
                LedgerCategorySeries(account: "Expenses:Travel", alias: "出行", label: "出行", total: 57_600, values: []),
                LedgerCategorySeries(account: "Expenses:Housing", alias: "居住", label: "居住", total: 380_000, values: []),
                LedgerCategorySeries(account: "Expenses:Education", alias: "教育", label: "教育", total: 32_800, values: []),
            ]
        ),
        previous: LedgerHomeReportPeriod(
            kpis: LedgerHomeReportExpenseKPI(expense: 635_200, transactionCount: 12),
            categorySeries: []
        ),
        dailyExpenseSeries: [
            LedgerDailyExpense(date: "2026-08-28", weekday: "周五", amount: 32_800, txCount: 1),
            LedgerDailyExpense(date: "2026-08-09", weekday: "周日", amount: 380_000, txCount: 1),
        ],
        generatedAt: "2026-08-31T05:30:00Z"
    )

    private static let importDocuments = [
        LedgerImportDocument(
            provider: "alipay",
            dateStart: "2026-08-01",
            dateEnd: "2026-08-20",
            modTime: "2026-08-30T08:00:00Z"
        ),
        LedgerImportDocument(
            provider: "alipay",
            dateStart: "2026-08-01",
            dateEnd: "2026-08-28",
            modTime: "2026-08-29T08:00:00Z"
        ),
        LedgerImportDocument(
            provider: "wechat",
            dateStart: "2026-08-01",
            dateEnd: "2026-08-25",
            modTime: "2026-08-26T08:00:00Z"
        ),
        LedgerImportDocument(
            provider: nil,
            dateStart: nil,
            dateEnd: nil,
            modTime: "2026-08-31T08:00:00Z"
        ),
    ]

    private struct SchemaOneSnapshot: Encodable {
        let schemaVersion: Int
        let updatedAt: Date
        let expense: LedgerWidgetExpenseSnapshot
        let accounts: [LedgerWidgetAccountSnapshot]
    }
}

private final class WidgetRefreshTestCredentialStore: LedgerWidgetCredentialStoring, @unchecked Sendable {
    let isAvailable = true
    private var credential: LedgerWidgetCredential?
    private var suspended = false

    init(credential: LedgerWidgetCredential?) {
        self.credential = credential
    }

    func load() throws -> LedgerWidgetCredential? {
        suspended ? nil : credential
    }

    func save(_ credential: LedgerWidgetCredential) throws {
        self.credential = credential
        suspended = false
    }

    func suspend() throws {
        suspended = credential != nil
    }

    func pendingRevocation() throws -> LedgerWidgetCredential? {
        suspended ? credential : nil
    }

    func completeRevocation(deviceID: String) throws {
        if credential?.deviceID == deviceID { credential = nil }
        suspended = false
    }
}

private actor WidgetRefreshTestClient: LedgerWidgetRefreshing {
    enum Outcome: Sendable {
        case success(LedgerWidgetSnapshot)
        case server(Int)
    }

    private let outcome: Outcome
    private var calls = 0

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func fetch(
        credential: LedgerWidgetCredential,
        previous: LedgerWidgetSnapshot?,
        now: Date,
        calendar: Calendar
    ) async throws -> LedgerWidgetSnapshot {
        calls += 1
        switch outcome {
        case let .success(snapshot):
            return snapshot
        case let .server(status):
            throw LedgerWidgetRefreshError.server(status)
        }
    }

    func callCount() -> Int { calls }
}

private actor WidgetDelayedRefreshTestClient: LedgerWidgetRefreshing {
    private let snapshot: LedgerWidgetSnapshot
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    init(snapshot: LedgerWidgetSnapshot) {
        self.snapshot = snapshot
    }

    func fetch(
        credential: LedgerWidgetCredential,
        previous: LedgerWidgetSnapshot?,
        now: Date,
        calendar: Calendar
    ) async throws -> LedgerWidgetSnapshot {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            completion = continuation
        }
        return snapshot
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func complete() {
        completion?.resume()
        completion = nil
    }
}
