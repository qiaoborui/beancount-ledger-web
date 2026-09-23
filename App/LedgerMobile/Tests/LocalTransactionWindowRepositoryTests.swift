import Foundation
import XCTest
@testable import LedgerMobile

final class LocalTransactionWindowRepositoryTests: XCTestCase {
    private let source = TransactionSource(file: "main.bean", line: 1, hash: "exact")
    private actor Engine: LocalLedgerEngine {
        var requests: [LocalLedgerEngineRequest] = []
        var paused = false
        var pending: CheckedContinuation<Void, Never>?
        var entered: CheckedContinuation<Void, Never>?
        var nativeRevision = "native-one"
        var detailHash = "exact"
        func pause() { paused = true }
        func wait() async { if pending == nil { await withCheckedContinuation { entered = $0 } } }
        func resume() { paused = false; pending?.resume(); pending = nil }
        func changeNativeRevision() { nativeRevision = "native-two" }
        func mismatch() { detailHash = "wrong" }
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            requests.append(request)
            if paused {
                await withCheckedContinuation { pending = $0; entered?.resume(); entered = nil }
            }
            let row = #"{"date":"2026-09-23","payee":"Synthetic","narration":"detail","postings":[],"source":{"file":"main.bean","line":1,"hash":"\#(detailHash)"}}"#
            if request.path.hasSuffix("/detail") { return Data(row.utf8) }
            let next = request.query["cursor"] == nil ? "\"opaque-next\"" : "null"
            return Data(#"{"revision":"\#(nativeRevision)","transactions":[\#(row),\#(row),\#(row)],"nextCursor":\#(next),"sensitiveUnlocked":true}"#.utf8)
        }
    }
    private func fixture() async throws -> (LocalLedgerRepository, Engine, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = LocalLedgerWorkspace(rootDirectory: root)
        let revision = try await workspace.commit(changes: [.write(Data("; synthetic".utf8), to: "main.bean")]) { _ in }
        let engine = Engine()
        let descriptor = LocalLedgerDescriptor(id: UUID(), name: "Synthetic", entrypoint: "main.bean", createdAt: Date())
        return (LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine,
                                      validator: { _, _ in }), engine, revision.id)
    }
    private func advance(_ repository: LocalLedgerRepository, _ revision: UUID) async throws {
        _ = try await repository.workspace.commit(expectedRevisionID: revision,
            changes: [.write(Data("; newer synthetic".utf8), to: "main.bean")]) { _ in }
    }
    private func window(_ repository: LocalLedgerRepository, _ revision: UUID) async throws -> LocalTransactionWindow {
        var limits = LocalTransactionWindow.Limits(); limits.maxRows = 1
        return try await repository.makeTransactionWindow(start: "2026-09-01", end: "2026-09-30",
                                                          expectedRevisionID: revision, limits: limits)
    }
    func testPinnedReadsNeverAdvancePresentationAndPreserveQuery() async throws {
        let (repository, engine, revision) = try await fixture()
        _ = try await repository.transactionPage()
        try await advance(repository, revision)
        let current = try await repository.workspace.currentRevision()
        let pinned = try XCTUnwrap(current).id
        let detail = try await repository.transactionDetail(source: source, expectedRevisionID: pinned)
        XCTAssertEqual(detail.source, source)
        let reader = try await window(repository, pinned)
        _ = try await reader.nextWindow()
        let presented = await repository.presentedRevisionID
        XCTAssertEqual(presented, revision)
        let requests = await engine.requests
        XCTAssertEqual(requests[1].query, ["file": "main.bean", "line": "1", "hash": "exact"])
        XCTAssertEqual(requests[2].query, ["dialect": "native-candidates-v1", "start": "2026-09-01",
                                          "end": "2026-09-30", "limit": "500"])
    }
    func testStaleUUIDDuringDetailAndCandidateRead() async throws {
        for detail in [true, false] {
            let (repository, engine, revision) = try await fixture()
            let reader = try await window(repository, revision)
            await engine.pause()
            let source = self.source
            let task = Task {
                if detail { _ = try await repository.transactionDetail(source: source, expectedRevisionID: revision) }
                else { _ = try await reader.nextWindow() }
            }
            await engine.wait()
            try await advance(repository, revision)
            await engine.resume()
            do { try await task.value; XCTFail("accepted stale read") }
            catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
            let presented = await repository.presentedRevisionID
            XCTAssertNil(presented)
        }
    }
    func testCancellationDuringDetailAndCandidateRead() async throws {
        for detail in [true, false] {
            let (repository, engine, revision) = try await fixture()
            let reader = try await window(repository, revision)
            await engine.pause()
            let source = self.source
            let task = Task {
                if detail { _ = try await repository.transactionDetail(source: source, expectedRevisionID: revision) }
                else { _ = try await reader.nextWindow() }
            }
            await engine.wait(); task.cancel(); await engine.resume()
            do { try await task.value; XCTFail("accepted cancelled read") } catch is CancellationError { }
        }
    }
    func testRejectsInvalidAndMismatchedSource() async throws {
        let (repository, engine, revision) = try await fixture()
        for invalid in [TransactionSource(file: "../main.bean", line: 1, hash: "exact"),
                        TransactionSource(file: "/main.bean", line: 1, hash: "exact"),
                        TransactionSource(file: "a\\main.bean", line: 1, hash: "exact"),
                        TransactionSource(file: "main.bean", line: -1, hash: "exact"),
                        TransactionSource(file: "main.bean", line: 1, hash: "")] {
            do { _ = try await repository.transactionDetail(source: invalid, expectedRevisionID: revision); XCTFail() }
            catch is LocalLedgerError { }
        }
        let requests = await engine.requests
        XCTAssertTrue(requests.isEmpty)
        await engine.mismatch()
        do { _ = try await repository.transactionDetail(source: source, expectedRevisionID: revision); XCTFail() }
        catch { XCTAssertEqual(error as? LocalLedgerError, .staleTransactionCursor) }
    }
    func testFactoryRejectsStaleRevisionBeforeReading() async throws {
        let (repository, engine, revision) = try await fixture()
        try await advance(repository, revision)
        do { _ = try await window(repository, revision); XCTFail() }
        catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
        let requests = await engine.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testCachedPageRequiresOwnerInvalidationAndNewPageChecksFreshness() async throws {
        let (repository, engine, revision) = try await fixture()
        let reader = try await window(repository, revision)
        _ = try await reader.nextWindow()
        try await advance(repository, revision)
        _ = try await reader.nextWindow() // Cached rows do not invoke the provider.
        let requests = await engine.requests
        XCTAssertEqual(requests.count, 1)
        do { _ = try await reader.nextWindow(); XCTFail("new page accepted stale UUID") }
        catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
        await reader.invalidate()
        do { _ = try await reader.nextWindow(); XCTFail() }
        catch { XCTAssertEqual(error as? LocalTransactionWindow.WindowError, .failed) }
    }
    func testNativeRevisionChangeAndOpaqueCursor() async throws {
        let (repository, engine, revision) = try await fixture()
        let reader = try await window(repository, revision)
        _ = try await reader.nextWindow()
        await engine.changeNativeRevision()
        _ = try await reader.nextWindow()
        do { _ = try await reader.nextWindow(); XCTFail() }
        catch { XCTAssertEqual(error as? LocalTransactionWindow.WindowError, .revisionMismatch) }
        let requests = await engine.requests
        XCTAssertEqual(requests.last?.query["cursor"], "opaque-next")
    }
}
