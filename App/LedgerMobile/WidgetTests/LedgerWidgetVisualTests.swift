import SwiftUI
import UIKit
import WidgetKit
import XCTest

@MainActor
final class LedgerWidgetVisualTests: XCTestCase {
    override func tearDown() {
        WidgetMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testRefreshClientUsesScopedEndpointAndKeepsImportsOnPartialResponse() async throws {
        WidgetMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://ledger.example.com/api/widget/snapshot")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let data = try WidgetMockURLProtocol.bodyData(from: request)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(body["deviceId"], "widget-device")
            XCTAssertEqual(body["token"], "widget-token")
            XCTAssertEqual(body["today"], "2026-09-06")
            XCTAssertEqual(body["valuationCurrency"], "CNY")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(Self.widgetSnapshotJSON.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WidgetMockURLProtocol.self]
        let client = LedgerWidgetRefreshClient(session: URLSession(configuration: configuration))
        let previous = LedgerWidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expense: .init(
                periodTitle: "旧数据",
                start: "2026-08-01",
                end: "2026-09-01",
                currency: "CNY",
                amount: 1,
                transactionCount: 1,
                yearOverYearPercentage: nil,
                categories: [],
                dailySeries: []
            ),
            accounts: [],
            imports: [.init(provider: "alipay", label: "支付宝", coverageStart: "2026-08-01", coverageEnd: "2026-08-31")],
            importsUpdatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!

        let snapshot = try await client.fetch(
            credential: LedgerWidgetCredential(
                serverOrigin: "https://ledger.example.com",
                deviceID: "widget-device",
                token: "widget-token",
                valuationCurrency: "CNY",
                enabled: true
            ),
            previous: previous,
            now: ISO8601DateFormatter().date(from: "2026-09-06T04:00:00Z")!,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.expense.periodTitle, "2026年9月")
        XCTAssertEqual(snapshot.expense.amount, 12_345)
        XCTAssertEqual(snapshot.accounts.first?.account, "Assets:Cash")
        XCTAssertEqual(snapshot.imports, previous.imports)
        XCTAssertEqual(snapshot.importsUpdatedAt, previous.importsUpdatedAt)
    }

    func testTimelineLoaderDoesNotRestoreSnapshotAfterCredentialDeletion() async throws {
        let suiteName = "ledger-widget-credential-race-\(UUID().uuidString)"
        let snapshotStore = LedgerWidgetSnapshotStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let credentialStore = WidgetTestCredentialStore()
        try credentialStore.save(
            LedgerWidgetCredential(
                serverOrigin: "https://ledger.example.com",
                deviceID: "widget-device",
                token: "widget-token",
                valuationCurrency: "CNY",
                enabled: true
            )
        )
        let client = WidgetDelayedRefreshClient(snapshot: .placeholder)
        let loader = LedgerWidgetTimelineLoader(
            credentialStore: credentialStore,
            snapshotStore: snapshotStore,
            client: client
        )

        let load = Task { await loader.load(now: Date(timeIntervalSince1970: 2_000_000_000)) }
        await client.waitUntilStarted()
        try credentialStore.suspend()
        snapshotStore.clear()
        await client.complete()
        let result = await load.value

        XCTAssertNil(result.snapshot)
        XCTAssertNil(snapshotStore.load())
        XCTAssertEqual(result.refreshInterval, LedgerWidgetTimelineLoader.failureRefreshInterval)
    }

    func testTimelineLoaderRefreshesFutureDatedCache() async throws {
        let suiteName = "ledger-widget-future-cache-\(UUID().uuidString)"
        let snapshotStore = LedgerWidgetSnapshotStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let futureSnapshot = LedgerWidgetSnapshot(
            updatedAt: now.addingTimeInterval(60 * 60),
            expense: LedgerWidgetSnapshot.placeholder.expense,
            accounts: LedgerWidgetSnapshot.placeholder.accounts,
            imports: LedgerWidgetSnapshot.placeholder.imports,
            importsUpdatedAt: LedgerWidgetSnapshot.placeholder.importsUpdatedAt
        )
        // Model a device whose clock was an hour ahead when the cache was written.
        try snapshotStore.saveIfNewer(futureSnapshot, attemptedAt: now.addingTimeInterval(60 * 60))
        let credentialStore = WidgetTestCredentialStore()
        try credentialStore.save(
            LedgerWidgetCredential(
                serverOrigin: "https://ledger.example.com",
                deviceID: "widget-device",
                token: "widget-token",
                valuationCurrency: "CNY",
                enabled: true
            )
        )
        let refreshed = LedgerWidgetSnapshot(
            updatedAt: now,
            expense: LedgerWidgetSnapshot.placeholder.expense,
            accounts: LedgerWidgetSnapshot.placeholder.accounts,
            imports: LedgerWidgetSnapshot.placeholder.imports,
            importsUpdatedAt: LedgerWidgetSnapshot.placeholder.importsUpdatedAt
        )
        let client = WidgetRecordingRefreshClient(snapshot: refreshed)
        let loader = LedgerWidgetTimelineLoader(
            credentialStore: credentialStore,
            snapshotStore: snapshotStore,
            client: client
        )

        let result = await loader.load(now: now)
        let callCount = await client.callCount()

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(result.snapshot?.updatedAt, now)
        XCTAssertEqual(snapshotStore.load()?.updatedAt, now)
    }

    func testFutureCacheRecoveryKeepsConcurrentWidgetWrite() async throws {
        let suiteName = "ledger-widget-future-race-\(UUID().uuidString)"
        let store = LedgerWidgetSnapshotStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let future = snapshot(updatedAt: now.addingTimeInterval(3_600))
        try store.saveIfNewer(future, attemptedAt: future.updatedAt)
        let credentials = WidgetTestCredentialStore()
        try credentials.save(LedgerWidgetCredential(
            serverOrigin: "https://ledger.example.com", deviceID: "widget-device", token: "widget-token",
            valuationCurrency: "CNY", enabled: true
        ))
        let client = WidgetDelayedRefreshClient(snapshot: snapshot(updatedAt: now))
        let loader = LedgerWidgetTimelineLoader(credentialStore: credentials, snapshotStore: store, client: client)
        let load = Task { await loader.load(now: now) }
        await client.waitUntilStarted()
        let concurrent = snapshot(updatedAt: now.addingTimeInterval(7_200))
        try store.saveIfNewer(concurrent, attemptedAt: concurrent.updatedAt)
        await client.complete()
        let result = await load.value
        XCTAssertEqual(result.snapshot, concurrent)
        XCTAssertEqual(store.load(), concurrent)
    }

    func testClockSkewRecoveryRequiresOriginalStateAndNormalReplacementTimestamp() throws {
        let suiteName = "ledger-widget-future-store-\(UUID().uuidString)"
        let store = LedgerWidgetSnapshotStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let future = snapshot(updatedAt: now.addingTimeInterval(3_600))
        try store.save(future)
        let observed = store.loadState()
        XCTAssertFalse(try store.saveIfNewer(snapshot(updatedAt: now), attemptedAt: now))
        XCTAssertFalse(try store.saveIfNewer(
            snapshot(updatedAt: now.addingTimeInterval(60)), attemptedAt: now, recoveringFutureState: observed
        ))
        XCTAssertTrue(try store.saveIfNewer(snapshot(updatedAt: now), attemptedAt: now, recoveringFutureState: observed))
        // A slow recovery attempt cannot replace a newer normal cache.
        let newer = snapshot(updatedAt: now.addingTimeInterval(10))
        XCTAssertTrue(try store.saveIfNewer(newer, attemptedAt: now.addingTimeInterval(10)))
        XCTAssertFalse(try store.saveIfNewer(snapshot(updatedAt: now), attemptedAt: now, recoveringFutureState: observed))
        XCTAssertEqual(store.load(), newer)
    }

    func testFutureAttemptRecoveryDetectsConcurrentRewriteOfIdenticalSnapshot() throws {
        let suiteName = "ledger-widget-future-attempt-\(UUID().uuidString)"
        let store = LedgerWidgetSnapshotStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cached = snapshot(updatedAt: now.addingTimeInterval(-30))
        try store.saveIfNewer(cached, attemptedAt: now.addingTimeInterval(3_600))
        let observed = store.loadState()
        XCTAssertTrue(observed.isFuture(relativeTo: now))
        // The payload can be identical while a later writer owns a new attempt.
        try store.saveIfNewer(cached, attemptedAt: now.addingTimeInterval(7_200))
        XCTAssertFalse(try store.saveIfNewer(snapshot(updatedAt: now), attemptedAt: now, recoveringFutureState: observed))
        XCTAssertEqual(store.loadState().attemptedAt, now.addingTimeInterval(7_200))
        XCTAssertTrue(try store.saveIfNewer(snapshot(updatedAt: now), attemptedAt: now, recoveringFutureState: store.loadState()))
        XCTAssertEqual(store.loadState().attemptedAt, now)
    }

    private func snapshot(updatedAt: Date) -> LedgerWidgetSnapshot {
        LedgerWidgetSnapshot(
            updatedAt: updatedAt, expense: LedgerWidgetSnapshot.placeholder.expense,
            accounts: LedgerWidgetSnapshot.placeholder.accounts, imports: LedgerWidgetSnapshot.placeholder.imports,
            importsUpdatedAt: LedgerWidgetSnapshot.placeholder.importsUpdatedAt
        )
    }

    func testRenderSupportedWidgetFamilies() throws {
        let snapshot = LedgerWidgetSnapshot.placeholder
        let expenseEntry = ExpenseOverviewEntry(date: snapshot.updatedAt, snapshot: snapshot)
        let accountEntry = AccountBalanceEntry(
            date: snapshot.updatedAt,
            snapshot: snapshot,
            selectedAccountID: snapshot.accounts.first?.id
        )
        let calendarEntry = ExpenseCalendarEntry(date: snapshot.updatedAt, snapshot: snapshot)
        let importEntry = ImportStatusEntry(date: snapshot.updatedAt, snapshot: snapshot)

        try render(
            ExpenseOverviewWidgetView(entry: expenseEntry, familyOverride: .systemSmall),
            size: CGSize(width: 158, height: 158),
            name: "expense-small"
        )
        try render(
            ExpenseOverviewWidgetView(entry: expenseEntry, familyOverride: .systemMedium),
            size: CGSize(width: 338, height: 158),
            name: "expense-medium"
        )
        try render(
            AccountBalanceWidgetView(entry: accountEntry, familyOverride: .systemSmall),
            size: CGSize(width: 158, height: 158),
            name: "account-small"
        )
        try render(
            AccountBalanceWidgetView(entry: accountEntry, familyOverride: .systemMedium),
            size: CGSize(width: 338, height: 158),
            name: "account-medium"
        )
        try render(
            ExpenseCalendarWidgetView(entry: calendarEntry, familyOverride: .systemMedium),
            size: CGSize(width: 338, height: 158),
            name: "expense-calendar-medium"
        )
        try render(
            ExpenseCalendarWidgetView(entry: calendarEntry, familyOverride: .systemLarge),
            size: CGSize(width: 338, height: 354),
            name: "expense-calendar-large"
        )
        try render(
            ImportStatusWidgetView(entry: importEntry, familyOverride: .systemMedium),
            size: CGSize(width: 338, height: 158),
            name: "import-status-medium"
        )
        try render(
            ImportStatusWidgetView(entry: importEntry, familyOverride: .systemLarge),
            size: CGSize(width: 338, height: 354),
            name: "import-status-large"
        )
    }

    func testExpenseCalendarHandlesLeapMonthAndAggregatesDailyValues() {
        let expense = LedgerWidgetExpenseSnapshot(
            periodTitle: "2028年2月",
            start: "2028-02-01",
            end: "2028-03-01",
            currency: "CNY",
            amount: 6_000,
            transactionCount: 3,
            yearOverYearPercentage: nil,
            categories: [],
            dailySeries: [
                LedgerWidgetDailyExpense(date: "2028-02-29", amount: 1_000),
                LedgerWidgetDailyExpense(date: "2028-02-29", amount: 2_000),
                LedgerWidgetDailyExpense(date: "2028-02-28", amount: 3_000),
                LedgerWidgetDailyExpense(date: "2028-03-01", amount: 9_999),
            ]
        )

        let layout = ExpenseCalendarLayout(expense: expense)

        XCTAssertEqual(layout.cells.count, 42)
        XCTAssertEqual(layout.cells.compactMap { $0 }.count, 29)
        XCTAssertNil(layout.cells.first ?? nil)
        XCTAssertEqual(layout.cells[1], 1)
        XCTAssertEqual(layout.amounts[29], 3_000)
        XCTAssertEqual(layout.peakDay, 28)
        XCTAssertEqual(layout.spendingDayCount, 2)
        XCTAssertEqual(layout.dateString(for: 29), "2028-02-29")
        XCTAssertNil(layout.dateString(for: 30))
        XCTAssertNil(layout.dateString(for: 0))
    }

    func testAccountWidgetDeepLinkRoundTripsReservedCharactersAndHidesRedactedAccount() throws {
        let account = LedgerWidgetAccountSnapshot(
            account: "Assets:银行:日常 & 储蓄?#",
            label: "储蓄", group: "银行", currency: "CNY", balance: 100,
            valuationCurrency: "CNY", valuation: nil
        )
        let url = try XCTUnwrap(LedgerWidgetNavigation.account(account))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "ledger")
        XCTAssertEqual(components.host, "accounts")
        XCTAssertEqual(components.queryItems?.first { $0.name == "account" }?.value, account.account)
        XCTAssertEqual(components.queryItems?.first { $0.name == "currency" }?.value, "CNY")
        XCTAssertEqual(LedgerWidgetNavigation.account(account, isRedacted: true)?.absoluteString, "ledger://accounts")
    }

    func testCalendarWidgetDeepLinkKeepsDayAndHidesRedactedDate() {
        XCTAssertEqual(
            LedgerWidgetNavigation.transactions(date: "2028-02-29")?.absoluteString,
            "ledger://transactions?date=2028-02-29"
        )
        XCTAssertEqual(
            LedgerWidgetNavigation.transactions(date: "2028-02-29", isRedacted: true)?.absoluteString,
            "ledger://transactions"
        )
    }

    private func render<V: View>(
        _ view: V,
        size: CGSize,
        name: String
    ) throws {
        let content = view
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(LedgerWidgetColors.panel)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size, size)

        let directory = URL(fileURLWithPath: "/tmp/ledger-widget-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url, options: .atomic)

        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
    }

    private static let widgetSnapshotJSON = #"""
    {
      "schemaVersion": 2,
      "updatedAt": "2026-09-06T03:00:00Z",
      "expense": {
        "periodTitle": "2026年9月",
        "start": "2026-09-01",
        "end": "2026-10-01",
        "currency": "CNY",
        "amount": 12345,
        "transactionCount": 3,
        "yearOverYearPercentage": 0.25,
        "categories": [{"account":"Expenses:Food","label":"餐饮","amount":12345}],
        "dailySeries": [{"date":"2026-09-06","amount":12345}]
      },
      "accounts": [{
        "account": "Assets:Cash",
        "label": "现金",
        "group": "cash",
        "currency": "CNY",
        "balance": 100000,
        "valuationCurrency": "CNY",
        "valuation": 100000
      }],
      "imports": null,
      "importsUpdatedAt": null
    }
    """#
}

private final class WidgetTestCredentialStore: LedgerWidgetCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: LedgerWidgetCredential?
    private var suspended = false
    let isAvailable = true

    func load() throws -> LedgerWidgetCredential? {
        lock.lock()
        defer { lock.unlock() }
        return suspended ? nil : credential
    }

    func save(_ credential: LedgerWidgetCredential) throws {
        lock.lock()
        defer { lock.unlock() }
        self.credential = credential
        suspended = false
    }

    func suspend() throws {
        lock.lock()
        defer { lock.unlock() }
        suspended = credential != nil
    }

    func pendingRevocation() throws -> LedgerWidgetCredential? {
        lock.lock()
        defer { lock.unlock() }
        return suspended ? credential : nil
    }

    func completeRevocation(deviceID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if credential?.deviceID == deviceID {
            credential = nil
        }
        suspended = false
    }
}

private actor WidgetDelayedRefreshClient: LedgerWidgetRefreshing {
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

private actor WidgetRecordingRefreshClient: LedgerWidgetRefreshing {
    private let snapshot: LedgerWidgetSnapshot
    private var fetchCount = 0

    init(snapshot: LedgerWidgetSnapshot) {
        self.snapshot = snapshot
    }

    func fetch(
        credential: LedgerWidgetCredential,
        previous: LedgerWidgetSnapshot?,
        now: Date,
        calendar: Calendar
    ) async throws -> LedgerWidgetSnapshot {
        fetchCount += 1
        return snapshot
    }

    func callCount() -> Int {
        fetchCount
    }
}

private final class WidgetMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func bodyData(from request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: LedgerWidgetRefreshError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
