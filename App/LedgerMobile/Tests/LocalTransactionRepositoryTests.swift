import Foundation
import XCTest
@testable import LedgerMobile

final class LocalTransactionRepositoryTests: XCTestCase {
    private let start = "2026-09-01"
    private let end = "2026-10-01"

    private actor Engine: LocalLedgerEngine {
        var requests: [LocalLedgerEngineRequest] = []
        let pages: [Data]
        let beforeReturn: (@Sendable (Int) async throws -> Void)?

        init(_ pages: [Data], beforeReturn: (@Sendable (Int) async throws -> Void)? = nil) {
            self.pages = pages
            self.beforeReturn = beforeReturn
        }

        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            let index = requests.count
            requests.append(request)
            guard index < pages.count else { throw LocalLedgerError.operationFailed("Unexpected extra page") }
            try await beforeReturn?(index)
            return pages[index]
        }
    }

    private func workspace() async throws -> (LocalLedgerWorkspace, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = LocalLedgerWorkspace(rootDirectory: root)
        _ = try await workspace.commit(changes: [.write(Data("; synthetic fixture\n".utf8), to: "main.bean")]) { _ in }
        let current = try await workspace.currentRevision()
        let revision = try XCTUnwrap(current)
        return (workspace, revision.id)
    }

    private func repository(_ workspace: LocalLedgerWorkspace, _ engine: Engine) -> LocalLedgerRepository {
        LocalLedgerRepository(descriptor: .init(id: UUID(), name: "Candidate fixture", entrypoint: "main.bean", createdAt: Date()),
                              workspace: workspace, engine: engine, validator: { _, _ in })
    }

    private func page(revision: String = "native-one", cursor: String? = nil,
                      rows: Int = 0, unlocked: Bool = true, payee: String = "Café") throws -> Data {
        var object: [String: Any] = [
            "revision": revision, "sensitiveUnlocked": unlocked,
            "transactions": (0..<rows).map { index in
                ["date": "2026-09-23", "payee": payee, "narration": "Synthetic \(index)",
                 "source": ["file": "main.bean", "line": index + 1],
                 "tags": ["fixture"], "postings": [
                    ["account": "Expenses:Food", "amount": 100, "currency": "CNY"],
                    ["account": "Assets:Cash", "amount": -100, "currency": "CNY"]]] as [String: Any]
            }
        ]
        if let cursor { object["nextCursor"] = cursor }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testCandidateDialectHasOnlyDatesCursorAndLimitAndNeverPresentsRevision() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([try page(cursor: "raw-next")])
        let repository = repository(workspace, engine)
        let result = try await repository.candidatePage(start: start, end: end, cursor: "raw-before", limit: 27,
                                                        expectedRevisionID: revision)
        XCTAssertEqual(result.nextCursor, "raw-next")
        let requests = await engine.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "GET")
        XCTAssertEqual(requests[0].path, "/api/ledger/transactions/page")
        XCTAssertEqual(requests[0].query, ["dialect": "native-candidates-v1", "start": start, "end": end,
                                          "cursor": "raw-before", "limit": "27"])
        let presented = await repository.presentedRevisionID
        XCTAssertNil(presented)
    }

    func testScanFollowsEmptyIntermediatePagesAndFiltersOnlyInSwift() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([try page(cursor: "one", rows: 1, payee: "Other"),
                             try page(cursor: "two"), try page(rows: 2)])
        let repository = repository(workspace, engine)
        let filter = LedgerTransactionFilter(query: "cafe\u{301}", kind: .expense, account: "Expenses", tags: ["fixture"])
        let result = try await repository.scanTransactions(start: start, end: end, filter: filter, expectedRevisionID: revision)
        XCTAssertEqual(result.revision, "native-one")
        XCTAssertEqual(result.fullRangeCount, 3)
        XCTAssertEqual(result.matchedCount, 2)
        XCTAssertEqual(result.visibleTransactions.count, 2)
        XCTAssertEqual(result.days.first?.expense, 200)
        let requests = await engine.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.map(\.workspaceRoot)).count, 1)
        XCTAssertEqual(requests.map { $0.query["cursor"] }, [nil, "one", "two"])
        for request in requests {
            XCTAssertEqual(Set(request.query.keys), request.query["cursor"] == nil
                ? ["dialect", "start", "end", "limit"] : ["dialect", "start", "end", "limit", "cursor"])
            XCTAssertEqual(request.query["dialect"], "native-candidates-v1")
            XCTAssertEqual(request.query["limit"], "500")
        }
        let presented = await repository.presentedRevisionID
        XCTAssertNil(presented)
    }

    func testOldExpectedUUIDRejectsBeforeEngineDispatch() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([try page()])
        let repository = repository(workspace, engine)
        _ = try await workspace.commit(expectedRevisionID: revision, changes: [.write(Data("; new revision".utf8), to: "main.bean")]) { _ in }
        do {
            _ = try await repository.scanTransactions(start: start, end: end, filter: .init(), expectedRevisionID: revision)
            XCTFail("Stale workspace accepted")
        } catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
        let requests = await engine.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCommitDuringPageAwaitRejectsEvenAtEOF() async throws {
        for cursor in [nil, "more"] as [String?] {
            let (workspace, revision) = try await workspace()
            let engine = Engine([try page(cursor: cursor, rows: 1)]) { _ in
                _ = try await workspace.commit(expectedRevisionID: revision, changes: [.write(Data("; changed during read".utf8), to: "main.bean")]) { _ in }
            }
            let repository = repository(workspace, engine)
            do {
                _ = try await repository.scanTransactions(start: start, end: end, filter: .init(), expectedRevisionID: revision)
                XCTFail("Pinned but superseded page escaped")
            } catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
            let requests = await engine.requests
            XCTAssertEqual(requests.count, 1)
            let current = try await workspace.currentRevision()
            XCTAssertNotEqual(current?.id, revision)
        }
    }

    func testNativeRevisionMismatchRejectsWholeScan() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([try page(cursor: "next", rows: 1), try page(revision: "native-two", rows: 1)])
        let repository = repository(workspace, engine)
        do {
            _ = try await repository.scanTransactions(start: start, end: end, filter: .init(), expectedRevisionID: revision)
            XCTFail("Mixed native revisions accepted")
        } catch { XCTAssertEqual(error as? LocalTransactionScan.ScanError, .revisionMismatch) }
    }

    func testLockedFirstAndLaterPagesRejectWholeScan() async throws {
        for lockedFirst in [true, false] {
            let (workspace, revision) = try await workspace()
            let pages = lockedFirst ? [try page(unlocked: false)]
                : [try page(cursor: "next", rows: 1), try page(rows: 1, unlocked: false)]
            let repository = repository(workspace, Engine(pages))
            do {
                _ = try await repository.scanTransactions(start: start, end: end, filter: .init(), expectedRevisionID: revision)
                XCTFail("Locked page accepted")
            } catch LedgerAPIError.server(let status, _) { XCTAssertEqual(status, 423) }
        }
    }

    func testCandidatePageRejectsRowsAboveRequestedLimitAndMalformedJSON() async throws {
        for data in [try page(rows: 2), Data("{not-json".utf8), Data("{\"revision\":42}".utf8)] {
            let (workspace, revision) = try await workspace()
            let repository = repository(workspace, Engine([data]))
            do {
                _ = try await repository.candidatePage(start: start, end: end, limit: 1, expectedRevisionID: revision)
                XCTFail("Invalid or over-limit response accepted")
            } catch { /* Fail closed; decoding and contract errors are both expected. */ }
        }
    }

    func testInvalidPageMetadataAndOversizedRowsFailClosed() async throws {
        for data in [try page(revision: ""), try page(cursor: ""), try page(cursor: String(repeating: "x", count: 1_025)),
                     try page(rows: 501)] {
            let (workspace, revision) = try await workspace()
            let repository = repository(workspace, Engine([data]))
            do {
                _ = try await repository.candidatePage(start: start, end: end, expectedRevisionID: revision)
                XCTFail("Invalid candidate response accepted")
            } catch LocalLedgerError.operationFailed { }
        }
    }

    func testInvalidRequestLimitAndCursorNeverReachEngine() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([])
        let repository = repository(workspace, engine)
        for (cursor, limit) in [(nil, 0), (nil, 501), ("", 500), (String(repeating: "x", count: 1_025), 500)] as [(String?, Int)] {
            do {
                _ = try await repository.candidatePage(start: start, end: end, cursor: cursor, limit: limit, expectedRevisionID: revision)
                XCTFail("Invalid request reached engine")
            } catch LocalLedgerError.invalidConfiguration { }
        }
        let requests = await engine.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCursorCycleRejectsRatherThanReturningPartialResult() async throws {
        let (workspace, revision) = try await workspace()
        let repository = repository(workspace, Engine([try page(cursor: "a"), try page(cursor: "b"), try page(cursor: "a")]))
        do {
            _ = try await repository.scanTransactions(start: start, end: end, filter: .init(), expectedRevisionID: revision)
            XCTFail("Cursor cycle accepted")
        } catch { XCTAssertEqual(error as? LocalTransactionScan.ScanError, .repeatedCursor) }
    }

    func testPreCancelledScanMakesNoEngineRequest() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([])
        let repository = repository(workspace, engine)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.scanTransactions(start: "2026-09-01", end: "2026-10-01", filter: .init(), expectedRevisionID: revision)
        }
        do { _ = try await task.value; XCTFail("Cancelled scan returned") }
        catch is CancellationError { }
        let requests = await engine.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationDuringEngineAwaitCannotReturnFinalResult() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([try page(rows: 1)]) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let repository = repository(workspace, engine)
        let task = Task {
            try await repository.scanTransactions(start: "2026-09-01", end: "2026-10-01", filter: .init(), expectedRevisionID: revision)
        }
        do { _ = try await task.value; XCTFail("Cancelled final page returned") }
        catch is CancellationError { }
        let requests = await engine.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testCandidateReadsPreserveExistingWriteAuthorizationRevision() async throws {
        let (workspace, _) = try await workspace()
        let engine = Engine([try page(), try page()])
        let repository = repository(workspace, engine)
        let draft = try await repository.readFile(path: "main.bean")
        try await repository.saveFile(draft, text: "; presented revision\n")
        let presented = try await workspace.currentRevision()
        let old = try XCTUnwrap(presented).id
        _ = try await workspace.commit(expectedRevisionID: old,
            changes: [.write(Data("; newer unpresented revision\n".utf8), to: "main.bean")]) { _ in }
        let current = try await workspace.currentRevision()
        let expected = try XCTUnwrap(current).id
        XCTAssertNotEqual(old, expected)
        _ = try await repository.candidatePage(start: start, end: end, expectedRevisionID: expected)
        _ = try await repository.scanTransactions(start: start, end: end, filter: .init(), expectedRevisionID: expected)
        let after = await repository.presentedRevisionID
        XCTAssertEqual(after, old)
    }

    func testNonAdvancingCursorIsRejected() async throws {
        let (workspace, revision) = try await workspace()
        let repository = repository(workspace, Engine([try page(cursor: "same")]))
        do {
            _ = try await repository.candidatePage(start: start, end: end, cursor: "same", expectedRevisionID: revision)
            XCTFail("Non-advancing cursor accepted")
        } catch LocalLedgerError.operationFailed { }
    }

    func testCustomLimitsAreAppliedAcrossPages() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([try page(cursor: "next", rows: 2), try page(rows: 2)])
        let repository = repository(workspace, engine)
        let result = try await repository.scanTransactions(start: start, end: end, filter: .init(), expectedRevisionID: revision,
                                                           limits: .init(maxVisibleCount: 1))
        XCTAssertEqual(result.fullRangeCount, 4)
        XCTAssertEqual(result.matchedCount, 4)
        XCTAssertEqual(result.visibleTransactions.count, 1)
        XCTAssertTrue(result.hasMoreMatches)
    }
}
