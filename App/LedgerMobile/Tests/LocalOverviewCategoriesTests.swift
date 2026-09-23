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
        XCTAssertEqual(result.positiveTotalMinorUnits, 2_000) // includes categories outside the top four
        XCTAssertEqual(result.categories.map(\.label), ["A", "B", "C", "D"])
        XCTAssertEqual(result.categories.first?.positiveTransactionCount, 2)
        XCTAssertEqual(result.categories.first?.representative.postings.map(\.amount), [500, -100, -400])
        XCTAssertEqual(result.revision, "native-model:42") // not the workspace UUID
        let decoded = try JSONDecoder().decode(LedgerOverviewCategories.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.categories.first?.representative, result.categories.first?.representative)
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
        _ = try await read.value
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
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: OverviewCategoriesFixture.data(start: start, end: end)) as? [String: Any])
        var invalids = [Data("{}".utf8), Data("not JSON".utf8)]
        for (key, value) in [("categories", NSNull()), ("sensitiveUnlocked", false), ("start", "2026-08-01"),
                             ("positiveTotalMinorUnits", -1), ("revision", "")] as [(String, Any)] {
            var changed = valid
            changed[key] = value
            invalids.append(try JSONSerialization.data(withJSONObject: changed))
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
