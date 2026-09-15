import Foundation
import XCTest
@testable import LedgerMobile

@MainActor
final class LocalLedgerWidgetPublisherTests: XCTestCase {
    private actor Engine: LocalLedgerEngine {
        var requests: [LocalLedgerEngineRequest] = []
        var onReport: (@Sendable () async throws -> Void)?
        var rejectImports = false

        func configure(onReport: (@Sendable () async throws -> Void)? = nil, rejectImports: Bool = false) {
            self.onReport = onReport
            self.rejectImports = rejectImports
        }

        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            requests.append(request)
            switch request.path {
            case "/api/ledger/version": return Data("{}".utf8)
            case "/api/ledger/bootstrap": return Data(LedgerModelsTests.bootstrapJSON.utf8)
            case "/api/ledger/imports/documents":
                if rejectImports { throw LocalLedgerError.operationFailed("fixture imports failure") }
                return Data(#"{"documents":[{"provider":"alipay","dateStart":"2026-08-01","dateEnd":"2026-08-28","modTime":"2026-08-29T08:00:00Z"}]}"#.utf8)
            case "/api/ledger/home-report":
                let hook = onReport
                onReport = nil
                try await hook?()
                return try JSONSerialization.data(withJSONObject: [
                    "start": request.query["start"] ?? "", "end": request.query["end"] ?? "",
                    "currency": request.query["valuationCurrency"] ?? "",
                    "current": ["kpis": ["expense": 1250, "transactionCount": 2], "categorySeries": []],
                    "previous": ["kpis": ["expense": 1000, "transactionCount": 1], "categorySeries": []],
                    "dailyExpenseSeries": [], "generatedAt": "2026-08-31T05:30:00Z"
                ])
            default: throw LocalLedgerError.operationFailed("unexpected fixture request")
            }
        }
    }

    private struct Fixture {
        let repository: LocalLedgerRepository
        let engine: Engine
        let store: LedgerWidgetSnapshotStore
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalWidget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let engine = Engine()
        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: engine, validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Synthetic widget ledger")
        let suite = "local-widget-tests-" + UUID().uuidString
        let lockDirectory = try temporaryWidgetLockDirectory(for: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return Fixture(repository: catalog.repository(for: descriptor), engine: engine,
            store: LedgerWidgetSnapshotStore(suiteName: suite, lockDirectory: lockDirectory))
    }

    private var now: Date { ISO8601DateFormatter().date(from: "2026-08-31T06:00:00Z")! }

    @MainActor
    func testPublishesAllPeriodsBalancesAndImportsFromLocalRepository() async throws {
        let fixture = try await fixture()
        let published = try await LocalLedgerWidgetPublisher.refresh(repository: fixture.repository,
            valuationCurrency: "CNY", store: fixture.store, now: now, isAuthorized: { true })
        XCTAssertTrue(published)
        let snapshot = try XCTUnwrap(fixture.store.load())
        XCTAssertEqual(snapshot.expense.amount, 1250)
        XCTAssertEqual(snapshot.imports.first?.latestCoverageDate, "2026-08-28")
        XCTAssertEqual(snapshot.importsUpdatedAt, now)
        XCTAssertFalse(snapshot.accounts.isEmpty)
        XCTAssertEqual(snapshot.insights?.week.start, "2026-08-31")
        XCTAssertEqual(snapshot.insights?.year.start, "2026-01-01")
        XCTAssertEqual(snapshot.insights?.history.end, "2026-09-01")
        let requests = await fixture.engine.requests.filter { $0.path != "/api/ledger/version" }
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(Set(requests.map(\.workspaceRoot)).count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && !$0.staging })
    }

    @MainActor
    func testDisabledAuthorizationAvoidsReadingOrPublishingLedger() async throws {
        let fixture = try await fixture()
        let published = try await LocalLedgerWidgetPublisher.refresh(repository: fixture.repository,
            valuationCurrency: "CNY", store: fixture.store, now: now, isAuthorized: { false })
        XCTAssertFalse(published)
        XCTAssertNil(fixture.store.load())
        let requests = await fixture.engine.requests
        XCTAssertEqual(requests.map(\.path), ["/api/ledger/version"])
    }

    @MainActor
    func testExplicitLockDuringReadSuppressesPublication() async throws {
        let fixture = try await fixture()
        @MainActor final class Authorization { var enabled = true }
        let authorization = Authorization()
        await fixture.engine.configure(onReport: { await MainActor.run { authorization.enabled = false } })
        let published = try await LocalLedgerWidgetPublisher.refresh(repository: fixture.repository,
            valuationCurrency: "CNY", store: fixture.store, now: now,
            isAuthorized: { authorization.enabled })
        XCTAssertFalse(published)
        XCTAssertNil(fixture.store.load())
    }

    func testRevisionChangeDuringReadsRejectsMixedSnapshot() async throws {
        let fixture = try await fixture()
        let repository = fixture.repository
        let draft = try await repository.readFile(path: "main.bean")
        await fixture.engine.configure(onReport: {
            try await repository.saveFile(draft, text: draft.text + "; concurrent synthetic edit\n")
        })
        do {
            _ = try await LocalLedgerWidgetPublisher.prepare(repository: repository,
                valuationCurrency: "CNY", now: now)
            XCTFail("A mixed revision snapshot must be rejected")
        } catch {
            XCTAssertEqual(error as? LocalLedgerWidgetPublisher.PublicationError, .revisionChanged)
        }
        XCTAssertNil(fixture.store.load())
    }

    func testBackgroundCancellationStopsRemainingReadsAndPublication() async throws {
        let fixture = try await fixture()
        await fixture.engine.configure(onReport: { withUnsafeCurrentTask { $0?.cancel() } })
        let refreshDate = now
        let task = Task {
            try await LocalLedgerWidgetPublisher.refresh(repository: fixture.repository,
                valuationCurrency: "CNY", store: fixture.store, now: refreshDate, isAuthorized: { true })
        }
        do {
            _ = try await task.value
            XCTFail("An expired background task must cancel publication")
        } catch { XCTAssertTrue(error is CancellationError) }
        let requests = await fixture.engine.requests.filter { $0.path != "/api/ledger/version" }
        XCTAssertEqual(requests.map(\.path), ["/api/ledger/bootstrap", "/api/ledger/home-report"])
        XCTAssertNil(fixture.store.load())
    }

    @MainActor
    func testChangedRevisionAndDifferentLedgerCannotReplaceStoredSnapshot() async throws {
        let fixture = try await fixture()
        let prepared = try await LocalLedgerWidgetPublisher.prepare(repository: fixture.repository,
            valuationCurrency: "CNY", now: now)
        let other = try await self.fixture()
        let wrongLedger = try await LocalLedgerWidgetPublisher.publish(prepared, repository: other.repository,
            store: fixture.store, isAuthorized: { true })
        XCTAssertFalse(wrongLedger)
        try fixture.store.save(prepared.snapshot)
        let draft = try await fixture.repository.readFile(path: "main.bean")
        try await fixture.repository.saveFile(draft, text: draft.text + "; newer revision\n")
        let stale = try await LocalLedgerWidgetPublisher.publish(prepared, repository: fixture.repository,
            store: fixture.store, isAuthorized: { true })
        XCTAssertFalse(stale)
        XCTAssertEqual(fixture.store.load(), prepared.snapshot)
    }

    @MainActor
    func testNewerPublicationWinsAndFailedImportReadPreservesSnapshot() async throws {
        let fixture = try await fixture()
        let prepared = try await LocalLedgerWidgetPublisher.prepare(repository: fixture.repository,
            valuationCurrency: "CNY", now: now)
        try fixture.store.saveIfNewer(prepared.snapshot, attemptedAt: now.addingTimeInterval(60))
        let stale = try await LocalLedgerWidgetPublisher.publish(prepared, repository: fixture.repository,
            store: fixture.store, isAuthorized: { true })
        XCTAssertFalse(stale)
        let savedState = fixture.store.loadState()
        await fixture.engine.configure(rejectImports: true)
        do {
            _ = try await LocalLedgerWidgetPublisher.refresh(repository: fixture.repository,
                valuationCurrency: "CNY", store: fixture.store, now: now.addingTimeInterval(120),
                isAuthorized: { true })
            XCTFail("Incomplete refresh must preserve the previous snapshot")
        } catch {
            XCTAssertEqual(error as? LocalLedgerError, .operationFailed("fixture imports failure"))
        }
        XCTAssertEqual(fixture.store.loadState(), savedState)
    }
}
