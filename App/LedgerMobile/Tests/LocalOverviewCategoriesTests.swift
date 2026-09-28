import Foundation
import XCTest
@testable import LedgerMobile

/// Shared synthetic native contract fixture; never reads a private ledger.
enum OverviewCategoriesFixture {
    static func data(start: String, end: String, empty: Bool = false) throws -> Data {
        let transaction = LedgerTransaction(date: start, payee: "Synthetic", narration: "Representative",
            postings: [.init(account: "Expenses:Food", amount: 500, currency: "CNY"),
                       .init(account: "Expenses:Food", amount: -100, currency: "CNY"),
                       .init(account: "Assets:Cash", amount: -400, currency: "CNY")],
            source: .init(file: "main.bean", line: 5, hash: "synthetic"))
        return try JSONEncoder().encode(LedgerOverviewCategories(revision: "native-model:42",
            start: start, end: end, sensitiveUnlocked: true, positiveTotalMinorUnits: empty ? 0 : 2_000,
            transactionCount: empty ? 0 : 100_000,
            highestExpense: empty ? nil : .init(title: "Outside bootstrap", minorUnits: 900_000),
            categories: empty ? [] : ["A", "B", "C", "D"].map {
                .init(label: $0, totalMinorUnits: 400, positiveTransactionCount: 2, representative: transaction)
            }))
    }
}

final class LocalOverviewCategoriesTests: XCTestCase {
    private actor Engine: LocalLedgerEngine {
        private(set) var requests: [LocalLedgerEngineRequest] = []
        var raw: Data?
        var gate: CheckedContinuation<Void, Never>?
        var entered: XCTestExpectation?
        func configure(raw: Data? = nil, entered: XCTestExpectation? = nil) {
            self.raw = raw
            self.entered = entered
        }
        func release() { gate?.resume(); gate = nil }
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            requests.append(request)
            if let entered {
                self.entered = nil
                await withCheckedContinuation { gate = $0; entered.fulfill() }
            }
            if let raw { return raw }
            return try OverviewCategoriesFixture.data(start: request.query["start"]!, end: request.query["end"]!)
        }
    }

    private func fixture() async throws -> (LocalLedgerRepository, Engine, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = LocalLedgerWorkspace(rootDirectory: root)
        let revision = try await workspace.commit(changes: [.write(Data("; synthetic\n".utf8), to: "main.bean")]) { _ in }
        let engine = Engine()
        let descriptor = LocalLedgerDescriptor(id: UUID(), name: "Aggregate", entrypoint: "main.bean", createdAt: Date())
        return (LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine,
            validator: { _, _ in }), engine, revision.id)
    }

    func testContractRoundTripAndPinnedRequestPreserveFullTotalsAndRepresentativePostings() async throws {
        let (repository, engine, revision) = try await fixture()
        let result = try await repository.overviewCategories(start: "2026-09-01", end: "2026-10-01", expectedRevisionID: revision)
        XCTAssertEqual(result.transactionCount, 100_000)
        XCTAssertEqual(result.highestExpense, .init(title: "Outside bootstrap", minorUnits: 900_000))
        XCTAssertEqual(result.positiveTotalMinorUnits, 2_000) // includes categories outside the top four
        XCTAssertEqual(result.categories.map(\.label), ["A", "B", "C", "D"])
        XCTAssertEqual(result.categories.first?.positiveTransactionCount, 2)
        XCTAssertEqual(result.categories.first?.representative.postings.map(\.amount), [500, -100, -400])
        XCTAssertEqual(result.revision, "native-model:42") // not the workspace UUID
        let decoded = try JSONDecoder().decode(LedgerOverviewCategories.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.categories.first?.representative, result.categories.first?.representative)
        XCTAssertEqual(decoded.transactionCount, result.transactionCount)
        XCTAssertEqual(decoded.highestExpense, result.highestExpense)
        let requests = await engine.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.path, "/api/ledger/overview/categories")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.query, ["start": "2026-09-01", "end": "2026-10-01"])
        XCTAssertFalse(request.staging)
        let presented = await repository.presentedRevisionID
        XCTAssertNil(presented, "An aggregate must not retarget financial write authorization")
    }

    func testRevisionMismatchIsRejectedBeforeDispatch() async throws {
        let (repository, engine, revision) = try await fixture()
        _ = try await repository.workspace.commit(expectedRevisionID: revision,
            changes: [.write(Data("; next".utf8), to: "main.bean")]) { _ in }
        do {
            _ = try await repository.overviewCategories(start: "2026-09-01", end: "2026-10-01", expectedRevisionID: revision)
            XCTFail("Mixed bootstrap and aggregate revisions")
        } catch LocalLedgerWorkspace.WorkspaceError.staleRevision { }
        let requests = await engine.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testInFlightReadKeepsPinnedSnapshotWhenWriterPublishes() async throws {
        let (repository, engine, revision) = try await fixture()
        let entered = expectation(description: "pinned aggregate dispatched")
        await engine.configure(entered: entered)
        let read = Task { try await repository.overviewCategories(start: "2026-09-01", end: "2026-10-01", expectedRevisionID: revision) }
        await fulfillment(of: [entered], timeout: 3)
        let next = try await repository.workspace.commit(expectedRevisionID: revision,
            changes: [.write(Data("; next".utf8), to: "main.bean")]) { _ in }
        await engine.release()
        let result = try await read.value
        XCTAssertEqual(result.transactionCount, 100_000)
        XCTAssertEqual(result.highestExpense?.title, "Outside bootstrap")
        let requests = await engine.requests
        let root = try XCTUnwrap(requests.first?.workspaceRoot)
        XCTAssertEqual(try String(contentsOfFile: root + "/main.bean", encoding: .utf8), "; synthetic\n")
        XCTAssertNotEqual(revision, next.id)
    }

    func testEmptyIsDistinctFromMalformedLockedOversizedAndWrongRangeResponses() async throws {
        let (repository, engine, revision) = try await fixture()
        let start = "2026-09-01", end = "2026-10-01"
        let empty = try OverviewCategoriesFixture.data(start: start, end: end, empty: true)
        await engine.configure(raw: empty)
        let result = try await repository.overviewCategories(start: start, end: end, expectedRevisionID: revision)
        XCTAssertEqual(result.positiveTotalMinorUnits, 0)
        XCTAssertTrue(result.categories.isEmpty)
        XCTAssertEqual(result.transactionCount, 0)
        XCTAssertNil(result.highestExpense)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: empty) as? [String: Any])
        XCTAssertTrue(encoded["highestExpense"] is NSNull)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: OverviewCategoriesFixture.data(start: start, end: end)) as? [String: Any])
        var invalids = [Data("{}".utf8), Data("not JSON".utf8)]
        for (key, value) in [("categories", NSNull()), ("sensitiveUnlocked", false), ("start", "2026-08-01"),
                             ("positiveTotalMinorUnits", -1), ("revision", ""),
                             ("transactionCount", -1), ("transactionCount", 0),
                             ("transactionCount", NSNull()), ("transactionCount", "100"),
                             ("transactionCount", 1.5),
                             ("highestExpense", ["title": "Bad", "minorUnits": 0]),
                             ("highestExpense", ["title": "Bad", "minorUnits": -1]),
                             ("highestExpense", ["title": "Bad"]),
                             ("highestExpense", ["minorUnits": 1]),
                             ("highestExpense", "Bad")] as [(String, Any)] {
            var changed = valid
            changed[key] = value
            invalids.append(try JSONSerialization.data(withJSONObject: changed))
        }
        for key in ["transactionCount", "highestExpense"] {
            var missing = valid
            missing.removeValue(forKey: key)
            invalids.append(try JSONSerialization.data(withJSONObject: missing))
        }
        var oversized = valid
        oversized["categories"] = Array(repeating: (valid["categories"] as! [Any])[0], count: 5)
        invalids.append(try JSONSerialization.data(withJSONObject: oversized))
        for raw in invalids {
            await engine.configure(raw: raw)
            do {
                _ = try await repository.overviewCategories(start: start, end: end, expectedRevisionID: revision)
                XCTFail("Invalid aggregate became successful empty data")
            } catch { }
        }
    }

    func testStatsAdapterUsesExactLocalAggregateAndKeepsRemoteArrayBehavior() throws {
        let bootstrap = try JSONDecoder().decode(LedgerBootstrap.self,
            from: Data(LedgerModelsTests.bootstrapJSON.utf8))
        let aggregate = try JSONDecoder().decode(LedgerOverviewCategories.self,
            from: OverviewCategoriesFixture.data(start: "2026-09-01", end: "2026-10-01"))
        let local = try XCTUnwrap(OverviewTransactionStats(isLocal: true, aggregate: aggregate,
            transactions: bootstrap.transactions))
        XCTAssertEqual(local.transactionCount, 100_000)
        XCTAssertEqual(local.highestExpense, .init(title: "Outside bootstrap", minorUnits: 900_000))
        XCTAssertFalse(bootstrap.transactions.contains { $0.payee == local.highestExpense?.title })
        XCTAssertEqual(local, OverviewTransactionStats(isLocal: true, aggregate: aggregate, transactions: []))
        XCTAssertNil(OverviewTransactionStats(isLocal: true, aggregate: nil, transactions: bootstrap.transactions),
            "Loading/failure must never fall back to bootstrap rows")
        let remote = try XCTUnwrap(OverviewTransactionStats(isLocal: false, aggregate: aggregate,
            transactions: bootstrap.transactions))
        XCTAssertEqual(remote.transactionCount, bootstrap.transactions.count)
        XCTAssertEqual(remote.highestExpense, .init(title: "海底捞", minorUnits: 8_500))
        XCTAssertEqual(remote, OverviewTransactionStats(isLocal: false, aggregate: nil,
            transactions: bootstrap.transactions))
    }

    func testRequiredNullHighestIsSuccessfulForEmptyAndNonExpenseRanges() throws {
        for count in [0, 4] {
            let raw = Data("""
            {"revision":"native:1","start":"2026-09-01","end":"2026-10-01",
             "sensitiveUnlocked":true,"positiveTotalMinorUnits":0,"categories":[],
             "transactionCount":\(count),"highestExpense":null}
            """.utf8)
            let aggregate = try JSONDecoder().decode(LedgerOverviewCategories.self, from: raw)
            let stats = try XCTUnwrap(OverviewTransactionStats(isLocal: true, aggregate: aggregate, transactions: []))
            XCTAssertEqual(stats.transactionCount, count)
            XCTAssertNil(stats.highestExpense)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(aggregate)) as? [String: Any])
            XCTAssertTrue(encoded["highestExpense"] is NSNull)
        }
    }

    // Mirrors TestLocalOverviewCategoriesStatsPresentationSemantics in the native
    // contract tests, keeping Swift's existing TransactionPresentation the oracle.
    func testNativeStatsParityFixturesMatchTransactionPresentation() throws {
        typealias Posting = LedgerPosting
        func p(_ account: String, _ amount: Int, _ currency: String = "CNY") -> Posting {
            .init(account: account, amount: amount, currency: currency)
        }
        let cases: [(String, [Posting], Int?)] = [
            ("positive expense precedes larger income", [p("Income:Salary", 900), p("Expenses:A", 30), p("Expenses:A", -10)], 20),
            ("refund excludes positive income", [p("Expenses:A", -30), p("Expenses:A", 10), p("Income:Salary", 900)], nil),
            ("zero expense falls through", [p("Expenses:A", 30), p("Expenses:A", -30), p("Income:Salary", 90), p("Income:Salary", -10)], 80),
            ("zero posting falls through", [p("Expenses:A", 0), p("Income:Salary", 90)], 90),
            ("income reversal", [p("Income:A", 100), p("Income:B", -20)], 80),
            ("income", [p("Income:A", -100), p("Income:B", 20)], nil),
            ("zero income", [p("Income:A", -100), p("Income:B", 100)], nil),
            ("zero expense only", [p("Expenses:A", -100), p("Expenses:A", 100)], nil),
            ("transfer", [p("Assets:Cash", 900), p("Liabilities:Card", -900)], nil),
            ("empty row", [], nil),
            ("exact prefixes", [p("Expenses", 900), p("expenses:A", 900), p("Income", 900), p("income:A", 900)], nil),
            ("raw expense currencies", [p("Expenses:A", 12), p("Expenses:A", 23, "USD")], 35),
            ("raw income currencies", [p("Income:A", 12), p("Income:B", 23, "USD")], 35),
        ]
        for (name, postings, expected) in cases {
            let row = LedgerTransaction(date: "2026-09-01", payee: "退款", narration: "退款",
                metadata: ["type": .string("退款")], postings: postings,
                source: .init(file: "main.bean", line: 1))
            let payload: [String: Any] = ["revision": "native:1", "start": row.date, "end": "2026-10-01",
                "sensitiveUnlocked": true, "positiveTotalMinorUnits": 0, "categories": [], "transactionCount": 1,
                "highestExpense": expected.map { ["title": "退款", "minorUnits": $0] as [String: Any] } as Any? ?? NSNull()]
            let aggregate = try JSONDecoder().decode(LedgerOverviewCategories.self,
                from: JSONSerialization.data(withJSONObject: payload))
            let local = OverviewTransactionStats(isLocal: true, aggregate: aggregate, transactions: [])
            let remote = OverviewTransactionStats(isLocal: false, aggregate: nil, transactions: [row])
            XCTAssertEqual(local, remote, name)
            XCTAssertEqual(local?.transactionCount, 1, name)
            XCTAssertEqual(local?.highestExpense?.minorUnits, expected, name)
        }
    }

    func testStatsTitlesAndFirstDescendingTieMatchNativeContract() throws {
        for (payee, narration, title) in [("Payee", "Narration", "Payee"), ("", "Narration", "Narration"),
            ("", "", "未命名交易"), (" \t\n", "Narration", " \t\n"), ("", " \t\n", " \t\n"), ("e\u{0301}", "é", "e\u{0301}")] {
            let row = LedgerTransaction(date: "2026-09-30", payee: payee, narration: narration,
                postings: [.init(account: "Income:Returned", amount: 100, currency: "USD")],
                source: .init(file: "main.bean", line: 1))
            let laterTie = LedgerTransaction(date: "2026-09-30", payee: "later tie", narration: "",
                postings: [.init(account: "Expenses:A", amount: 100, currency: "CNY")],
                source: .init(file: "main.bean", line: 5))
            let stats = try XCTUnwrap(OverviewTransactionStats(isLocal: false, aggregate: nil, transactions: [row, laterTie]))
            XCTAssertEqual(stats.transactionCount, 2)
            XCTAssertEqual(stats.highestExpense, .init(title: title, minorUnits: 100))
        }
    }

    func testCapacityErrorEnvelopePropagates() async throws {
        struct CapacityEngine: LocalLedgerEngine {
            func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data { Data() }
            func response(_ request: LocalLedgerEngineRequest) async throws -> LocalLedgerResponse {
                .init(envelope: Data(#"{"ok":false,"status":413,"result":{"error":"narrow the date range"}}"#.utf8))
            }
        }
        let (fixture, _, revision) = try await fixture()
        let repository = LocalLedgerRepository(descriptor: fixture.descriptor, workspace: fixture.workspace,
            engine: CapacityEngine(), validator: { _, _ in })
        do {
            _ = try await repository.overviewCategories(start: "2026-09-01", end: "2026-10-01", expectedRevisionID: revision)
            XCTFail("Capacity error became an empty aggregate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("narrow the date range"))
        }
    }
}
