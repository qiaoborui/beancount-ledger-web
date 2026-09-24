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

    private func accountPageData(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object: [String: Any] = ["revision": "native-account", "sensitiveUnlocked": true, "rowCount": 2,
            "detail": ["account": "Assets:Cash", "label": "Cash", "group": "Assets", "active": true,
                "currency": "CNY", "currentBalance": 200, "openingBalance": 0, "closingBalance": 200, "periodChange": 200,
                "start": start, "end": end,
                "rows": (1...2).map { index in
                    ["date": "2026-09-23", "payee": "Synthetic", "narration": "Account", "change": 100, "balance": index * 100,
                     "txn": ["date": "2026-09-23", "payee": "Synthetic", "narration": "Account",
                         "postings": [["account": "Assets:Cash", "amount": 100, "currency": "CNY"]],
                         "source": ["file": "main.bean", "line": index, "hash": "h"]]] as [String: Any]
                }] as [String: Any]]
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testAccountPagePinnedTypedQueryAndNoWriteAuthorityAdvance() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([try accountPageData()])
        let repository = repository(workspace, engine)
        let result = try await repository.accountPage(account: "Assets:Cash", currency: "CNY", start: start, end: end, expectedRevisionID: revision)
        XCTAssertEqual(result.detail.rows.map(\.balance), [100, 200]); XCTAssertEqual(result.rowCount, 2)
        let requests = await engine.requests
        XCTAssertEqual(requests[0].path, "/api/ledger/accounts/detail/page")
        XCTAssertEqual(requests[0].query, ["account": "Assets:Cash", "currency": "CNY", "start": start, "end": end, "limit": "100"])
        let presented = await repository.presentedRevisionID
        XCTAssertNil(presented)
    }

    func testAccountPageRejectsMalformedFactsBoundsAndLockedPayload() async throws {
        for mutation in 0..<12 {
            let (workspace, revision) = try await workspace()
            let data = try accountPageData { object in
                var detail = object["detail"] as! [String: Any]
                switch mutation {
                case 0: object["sensitiveUnlocked"] = false
                case 1: object["revision"] = ""
                case 2: object["rowCount"] = 1
                case 3: detail["currency"] = "USD"
                case 4: detail["periodChange"] = 1
                case 5: object["nextCursor"] = ""
                case 6: detail["start"] = "2026-08-01"
                case 7:
                    var rows = detail["rows"] as! [[String: Any]]
                    rows[1]["balance"] = 999
                    detail["rows"] = rows
                case 8: object["nextCursor"] = "more" // complete count cannot claim continuation
                case 9:
                    var rows = detail["rows"] as! [[String: Any]]
                    rows[0]["balance"] = 1100; rows[1]["balance"] = 1200
                    detail["rows"] = rows
                case 10: detail["rows"] = Array((detail["rows"] as! [[String: Any]]).prefix(1))
                default: detail["rows"] = [] as [[String: Any]]
                }
                object["detail"] = detail
            }
            let repository = repository(workspace, Engine([data]))
            do {
                _ = try await repository.accountPage(account: "Assets:Cash", currency: "CNY", start: start, end: end, expectedRevisionID: revision)
                XCTFail("malformed account page accepted \(mutation)")
            } catch {}
        }
        let oversized = Data(repeating: 32, count: (1 << 20) + 1)
        XCTAssertThrowsError(try LocalLedgerResponse(result: oversized).decodeAccountPage())
        XCTAssertThrowsError(try LocalLedgerResponse(envelope: Data(#"{"ok":false,"status":409,"diagnostics":[],"result":{"error":"stale"}}"#.utf8)).decodeAccountPage()) {
            XCTAssertEqual($0 as? LocalLedgerError, .staleTransactionCursor)
        }
    }

    func testAccountPageRejectsSupersededRevisionOnReturn() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([try accountPageData()]) { _ in
            _ = try await workspace.commit(expectedRevisionID: revision, changes: [.write(Data("; changed".utf8), to: "main.bean")]) { _ in }
        }
        let repository = repository(workspace, engine)
        do {
            _ = try await repository.accountPage(account: "Assets:Cash", currency: "CNY", start: start, end: end, expectedRevisionID: revision)
            XCTFail("superseded account page returned")
        } catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
    }

    func testPendingCandidateEvidenceRequiredAndNoEditorAuthority() async throws {
        for evidence: Bool? in [nil, false, true] {
            let (workspace, revision) = try await workspace()
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: page(rows: 1)) as? [String: Any])
            var rows = try XCTUnwrap(object["transactions"] as? [[String: Any]])
            rows[0]["pendingReviewFlag"] = evidence
            rows[0]["metadata"] = ["status": "Pending", "needs_review": "TRUE"]
            object["transactions"] = rows
            let engine = Engine([try JSONSerialization.data(withJSONObject: object)])
            let repository = repository(workspace, engine)
            do {
                let page = try await repository.pendingCandidatePage(start: start, end: end, expectedRevisionID: revision)
                XCTAssertNotNil(evidence)
                XCTAssertEqual(page.transactions[0].pendingReviewFlag, evidence)
                XCTAssertNil(page.transactions[0].editableEntry)
                XCTAssertTrue(page.transactions[0].pendingReasons.contains(.needsReviewFlag))
            } catch { XCTAssertNil(evidence, "\(error)") }
            let requests = await engine.requests
            XCTAssertEqual(requests[0].query["dialect"], "native-pending-candidates-v1")
            let authority = await repository.presentedRevisionID
            XCTAssertNil(authority)
        }
    }

    private func bootstrapPageData(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var bootstrap = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(LedgerModelsTests.bootstrapJSON.utf8)) as? [String: Any])
        bootstrap["start"] = start; bootstrap["end"] = end; bootstrap["transactions"] = []
        var object: [String: Any] = ["bootstrap": bootstrap,
            "transactionPage": try JSONSerialization.jsonObject(with: page(rows: 1))]
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testBootstrapPageRejectsInvalidDatesBeforeDispatchAndKeepsExistingAuthority() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([try page(), try bootstrapPageData()])
        let repository = repository(workspace, engine)
        _ = try await repository.transactionPage(start: start, end: end)
        let authority = await repository.presentedRevisionID
        XCTAssertEqual(authority, revision)
        for dates in [("bad", end, "2026-09-23"), (start, "2026-02-30", "2026-09-23"),
                      (start, end, "2026-02-30"), (end, start, "2026-09-23")] {
            do {
                _ = try await repository.bootstrapPage(start: dates.0, end: dates.1, today: dates.2,
                    valuationCurrency: "CNY", expectedRevisionID: revision)
                XCTFail("invalid bootstrap date reached engine")
            } catch LocalLedgerError.invalidConfiguration { }
        }
        let before = await engine.requests
        XCTAssertEqual(before.count, 1)
        _ = try await repository.bootstrapPage(start: start, end: end, today: "2026-09-23",
            valuationCurrency: "CNY", expectedRevisionID: revision)
        let after = await repository.presentedRevisionID
        XCTAssertEqual(after, authority)
    }

    func testBootstrapPageRejectsReplacementRevisionAndCancelledRead() async throws {
        for replacement in [false, true] {
            let (workspace, revision) = try await workspace()
            let engine = Engine([try bootstrapPageData()]) { _ in
                if replacement {
                    _ = try await workspace.commit(expectedRevisionID: revision,
                        changes: [.write(Data("; changed".utf8), to: "main.bean")]) { _ in }
                } else { withUnsafeCurrentTask { $0?.cancel() } }
            }
            let repository = repository(workspace, engine)
            let start = self.start, end = self.end
            let task = Task { try await repository.bootstrapPage(start: start, end: end, today: "2026-09-23",
                valuationCurrency: "CNY", expectedRevisionID: revision) }
            do { _ = try await task.value; XCTFail("obsolete bootstrap returned") }
            catch {
                if replacement { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            let authority = await repository.presentedRevisionID
            XCTAssertNil(authority)
        }
    }

    func testBootstrapPageRejectsInvalidContinuationAndOutOfRangeRows() async throws {
        for mutation in 0..<6 {
            let (workspace, revision) = try await workspace()
            let data = try bootstrapPageData { object in
                var candidate = object["transactionPage"] as! [String: Any]
                switch mutation {
                case 0: candidate["nextCursor"] = ""
                case 1: candidate["nextCursor"] = String(repeating: "x", count: 1_025)
                case 2: candidate["nextCursor"] = "n"; candidate["transactions"] = []
                default:
                    var rows = candidate["transactions"] as! [[String: Any]]
                    rows[0]["date"] = ["2026-10-01", "2026-09-31", "2026-09-23junk"][mutation - 3]
                    candidate["transactions"] = rows
                }
                object["transactionPage"] = candidate
            }
            let repository = repository(workspace, Engine([data]))
            do {
                _ = try await repository.bootstrapPage(start: start, end: end, today: "2026-09-23",
                    valuationCurrency: "CNY", expectedRevisionID: revision)
                XCTFail("invalid bootstrap continuation/row accepted")
            } catch LocalLedgerError.operationFailed { }
        }
    }

    func testBootstrapEnvelopeBoundAndIntegerPrecision() throws {
        let raw = try bootstrapPageData { object in
            var bootstrap = object["bootstrap"] as! [String: Any]
            bootstrap["summary"] = ["currency": "CNY", "income": 9007199254740993, "expense": 2, "net": 9007199254740991]
            object["bootstrap"] = bootstrap
        }
        var envelope = Data(#"{"ok":true,"status":200,"diagnostics":[],"result":"#.utf8)
        envelope.append(raw); envelope.append(Data("}".utf8))
        // Whitespace is valid JSON; near-limit envelope must not lose its 4KiB
        // transport headroom by applying the result-only budget a second time.
        envelope.append(Data(repeating: 32, count: (1 << 20) - envelope.count))
        let decoded = try LocalLedgerResponse(envelope: envelope).decodeBootstrapPage()
        XCTAssertEqual(decoded.bootstrap.summary.income, 9007199254740993)
        envelope.append(32)
        XCTAssertThrowsError(try LocalLedgerResponse(envelope: envelope).decodeBootstrapPage())
        XCTAssertThrowsError(try LocalLedgerResponse(result: raw).decodeBootstrapPage(maximumBytes: -1))
        XCTAssertThrowsError(try LocalLedgerResponse(envelope: Data(#"{"ok":false,"status":409,"diagnostics":[],"result":{"error":"stale"}}"#.utf8)).decodeBootstrapPage()) {
            XCTAssertEqual($0 as? LocalLedgerError, .staleTransactionCursor)
        }
    }

    func testBootstrapPageUsesTypedAccountingAndExplicitCandidatePageWithoutAuthorityAdvance() async throws {
        let (workspace, revision) = try await workspace()
        let object: [String: Any] = ["bootstrap": ["start": start, "end": end, "summary": ["currency": "CNY", "income": 9007199254740993, "expense": 2, "net": 9007199254740991],
            "accountBalances": [], "netWorthHistory": [], "monthEndNetWorth": [], "transactions": [], "reconciliationRows": [],
            "accounts": [], "commodities": [], "prices": [], "valuationCurrency": "CNY", "accountStatuses": [], "sensitiveUnlocked": true],
            "transactionPage": ["revision": "native-one", "transactions": [["date": "2026-09-23", "payee": "Synthetic", "narration": "", "postings": [], "source": ["file": "main.bean", "line": 1]]], "sensitiveUnlocked": true]]
        let engine = Engine([try JSONSerialization.data(withJSONObject: object)])
        let repository = repository(workspace, engine)
        let page = try await repository.bootstrapPage(start: start, end: end, today: "2026-09-23", valuationCurrency: "CNY", limit: 1, expectedRevisionID: revision)
        XCTAssertTrue(page.bootstrap.transactions.isEmpty); XCTAssertEqual(page.transactionPage.transactions.count, 1)
        XCTAssertEqual(page.bootstrap.summary.income, 9007199254740993)
        let existing = try await repository.workspace.currentRevision()
        XCTAssertEqual(existing?.id, revision)
        let request = await engine.requests.first
        XCTAssertEqual(request?.path, "/api/ledger/bootstrap/page")
        XCTAssertEqual(request?.query["limit"], "1")
        let presented = await repository.presentedRevisionID
        XCTAssertNil(presented)
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

    func testSearchCandidateDialectPreservesMetadataAndDoesNotPresentRevision() async throws {
        let (workspace, revision) = try await workspace()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: page(rows: 1)) as? [String: Any])
        var rows = try XCTUnwrap(object["transactions"] as? [[String: Any]])
        rows[0]["metadata"] = ["receipt": "ＣＡＦÉ", "number": 12.5, "bool": true, "null-key": NSNull()]
        object["transactions"] = rows
        let engine = Engine([try JSONSerialization.data(withJSONObject: object)])
        let repository = repository(workspace, engine)
        let result = try await repository.searchCandidatePage(limit: 27, expectedRevisionID: revision)
        XCTAssertEqual(result.transactions[0].metadata,
            ["receipt": .string("ＣＡＦÉ"), "number": .number(12.5), "bool": .bool(true), "null-key": .null])
        let requests = await engine.requests
        XCTAssertEqual(requests[0].query, ["dialect": "native-search-candidates-v1",
            "start": "0001-01-01", "end": "9999-12-31", "limit": "27"])
        let presented = await repository.presentedRevisionID
        XCTAssertNil(presented)
        do {
            _ = try await repository.searchCandidatePage(expectedRevisionID: UUID())
            XCTFail("stale search revision accepted")
        } catch {}
        let finalRequests = await engine.requests
        XCTAssertEqual(finalRequests.count, 1)
    }

    func testGlobalSearchWindowScansAllCandidatesAndRejectsChangedNativeRevision() async throws {
        let (workspace, revision) = try await workspace()
        let engine = Engine([try page(cursor: "n", rows: 1, payee: "Other"), try page(rows: 1, payee: "Needle")])
        let repository = repository(workspace, engine)
        let result = try await repository.globalSearchWindow(query: "Needle", accounts: [], scope: .transactions,
            filters: .init(), expectedRevisionID: revision, limits: .init(rows: 1))
        XCTAssertEqual(result.matchedCount, 1)
        XCTAssertEqual(result.transactions.map(\.payee), ["Needle"])
        let requests = await engine.requests
        XCTAssertEqual(requests.map { $0.query["cursor"] }, [nil, "n"])
        XCTAssertTrue(requests.allSatisfy { $0.query["dialect"] == "native-search-candidates-v1" && $0.query["q"] == nil })
        let presented = await repository.presentedRevisionID
        XCTAssertNil(presented)
        let changed = self.repository(workspace, Engine([try page(revision: "replacement", rows: 1)]))
        do {
            _ = try await changed.globalSearchWindow(query: "Needle", accounts: [], scope: .transactions,
                filters: .init(), after: result.transactions.first.map(LocalGlobalSearchScan.Anchor.init),
                nativeRevision: result.revision, expectedRevisionID: revision)
            XCTFail("changed native model accepted anchor")
        } catch {
            XCTAssertEqual(error as? LocalGlobalSearchScan.ScanError, .revisionMismatch)
        }
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

    func testBootstrapPageRejectsLockedMalformedRowsAndNonemptyLegacyTransactions() async throws {
        for mutation in 0..<6 {
            let (workspace, revision) = try await workspace()
            var object: [String: Any] = ["bootstrap": ["start": start, "end": end, "summary": ["currency":"CNY","income":0,"expense":0,"net":0], "accountBalances":[],"netWorthHistory":[],"monthEndNetWorth":[],"transactions":[],"reconciliationRows":[],"accounts":[],"commodities":[],"prices":[],"valuationCurrency":"CNY","accountStatuses":[],"sensitiveUnlocked":true], "transactionPage":["revision":"r","transactions":[],"sensitiveUnlocked":true]]
            var bootstrap = object["bootstrap"] as! [String: Any]
            var page = object["transactionPage"] as! [String: Any]
            switch mutation {
            case 0: page["sensitiveUnlocked"] = false
            case 1: page["revision"] = ""
            case 2: page["transactions"] = [["date":"2026-09-23","payee":"x","narration":"","postings":[],"source":["file":"x","line":1]], ["date":"2026-09-23","payee":"x","narration":"","postings":[],"source":["file":"x","line":2]]]
            case 3: bootstrap["transactions"] = [["date":"2026-09-23","payee":"legacy","narration":"","postings":[],"source":["file":"x","line":1]]]
            case 4: bootstrap["sensitiveUnlocked"] = false
            case 5: bootstrap["start"] = "changed"
            default: break
            }
            object["bootstrap"] = bootstrap; object["transactionPage"] = page
            let repository = repository(workspace, Engine([try JSONSerialization.data(withJSONObject: object)]))
            do { _ = try await repository.bootstrapPage(start: start,end: end,today:"2026-09-23",valuationCurrency:"CNY",limit:1,expectedRevisionID:revision); XCTFail("malformed bootstrap accepted") } catch {}
        }
    }


}
