import Foundation
import XCTest
@testable import LedgerMobile

@MainActor
final class BoundedLedgerBrowserModelTests: XCTestCase, @unchecked Sendable {
    private final class Authentication: LocalLedgerAuthenticating {
        var isAvailable = true
        var failure = false
        var calls = 0
        var suspend = false
        var continuation: CheckedContinuation<Void, Never>?
        func authenticate() async throws {
            calls += 1
            if suspend { await withCheckedContinuation { continuation = $0 } }
            if failure { throw BoundedReadIndexError.unavailable }
        }
    }

    /// Blocking fake mimics a native query that cannot instantly be interrupted.
    /// The test never uses a real catalog, ledger, exporter, keychain or network.
    private final class Workspace: BoundedBrowserWorkspace, @unchecked Sendable {
        private let gate = NSLock()
        private var _opens = 0
        private var _closes = 0
        private var _builds = 0
        private var _locks = 0
        private var _pages: [String?] = []
        private var _details = 0
        private var _offMain = true
        var oversized = false // configured before handing the fake to the worker
        var blockNext = false
        var blockDetail = false
        var blockBuild = false
        let queryStarted = DispatchSemaphore(value: 0)
        let queryRelease = DispatchSemaphore(value: 0)
        let revisionID = UUID()

        var opens: Int { gate.withLock { _opens } }
        var closes: Int { gate.withLock { _closes } }
        var builds: Int { gate.withLock { _builds } }
        var locks: Int { gate.withLock { _locks } }
        var pageCount: Int { gate.withLock { _pages.count } }
        var details: Int { gate.withLock { _details } }
        var offMain: Bool { gate.withLock { _offMain } }

        func revision() async throws -> UUID { revisionID }
        func rebuild(revision: UUID) async throws {
            guard revision == revisionID else { throw BoundedReadIndexError.revisionMismatch }
            gate.withLock { _builds += 1; _offMain = _offMain && !Thread.isMainThread }
            if blockBuild {
                queryStarted.signal()
                guard queryRelease.wait(timeout: .now() + 5) == .success else {
                    throw BoundedReadIndexError.canceled
                }
            }
        }
        func lock() { gate.withLock { _locks += 1; _offMain = _offMain && !Thread.isMainThread } }
        func read(_ body: @escaping @Sendable (BoundedBrowserLeaseInfo, BoundedBrowserQueries) async throws -> Void) async throws {
            gate.withLock { _opens += 1; _offMain = _offMain && !Thread.isMainThread }
            defer { gate.withLock { _closes += 1 } }
            try await body(.init(revision: "fixture", isStale: false), .init(page: { cursor in
                self.gate.withLock { self._pages.append(cursor); self._offMain = self._offMain && !Thread.isMainThread }
                if cursor != nil, self.blockNext {
                    self.queryStarted.signal()
                    guard self.queryRelease.wait(timeout: .now() + 5) == .success else {
                        throw BoundedReadIndexError.canceled
                    }
                }
                let ids = self.oversized ? Array(1...101) : [cursor == nil ? 1 : 2]
                let rows = ids.map { id in
                    """
                    {"id":\(id),"date":"2026-01-01","record":{"type":"directive","id":\(id),"value":{"Kind":"transaction","Date":"2026-01-01","File":"main.bean","Line":1}}}
                    """
                }.joined(separator: ",")
                return try JSONDecoder().decode(BoundedIndexPage.self, from: Data("""
                    {"revision":"fixture","transactions":[\(rows)],"next_cursor":\(cursor == nil ? "\"next\"" : "null")}
                    """.utf8))
            }, detail: { id in
                self.gate.withLock { self._details += 1; self._offMain = self._offMain && !Thread.isMainThread }
                if self.blockDetail {
                    self.queryStarted.signal()
                    guard self.queryRelease.wait(timeout: .now() + 5) == .success else {
                        throw BoundedReadIndexError.canceled
                    }
                }
                return try JSONDecoder().decode(BoundedIndexDetail.self, from: Data("""
                    {"revision":"fixture","id":\(id),"records":[]}
                    """.utf8))
            }))
        }
    }

    private final class Counter: @unchecked Sendable {
        private let gate = NSLock()
        private var value = 0
        func increment() { gate.withLock { value += 1 } }
        var count: Int { gate.withLock { value } }
    }

    private func fixture(available: Bool = true, auth: Authentication = Authentication(),
                         workspace: Workspace = Workspace()) -> (BoundedLedgerBrowserModel, Workspace, Counter) {
        let calls = Counter()
        let descriptor = LocalLedgerDescriptor(id: UUID(), name: "Synthetic fixture", entrypoint: "main.bean", createdAt: Date())
        let dependencies = BoundedBrowserDependencies(available: available, list: {
            calls.increment()
            return .init(root: URL(fileURLWithPath: "/synthetic-unused"), descriptors: [descriptor])
        }, workspace: { _, _ in workspace })
        return (BoundedLedgerBrowserModel(authenticator: auth, dependencies: dependencies), workspace, calls)
    }

    private func eventually(_ predicate: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition did not become true", file: file, line: line)
    }

    private func select(_ model: BoundedLedgerBrowserModel) async throws {
        model.unlock()
        await eventually { !model.locked && !model.busy }
        model.select(try XCTUnwrap(model.descriptors.first))
    }

    func testLockWhileAuthenticatingSuppressesLateCatalogAccess() async {
        let auth = Authentication()
        auth.suspend = true
        let (model, _, calls) = fixture(auth: auth)
        model.unlock()
        await eventually { auth.continuation != nil }
        model.lock()
        auth.continuation?.resume()
        auth.continuation = nil
        // Let the stale authentication task complete; it must not list.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.locked)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(calls.count, 0)
        XCTAssertTrue(model.descriptors.isEmpty)
    }

    func testLockDuringBuildNeverOpensReader() async throws {
        let workspace = Workspace()
        workspace.blockBuild = true
        let (model, _, _) = fixture(workspace: workspace)
        try await select(model)
        model.prepareBuild()
        await eventually { model.confirmation != nil }
        model.confirmBuild()
        let started = await Task.detached { workspace.queryStarted.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(started)
        model.lock()
        await eventually { workspace.locks >= 2 }
        workspace.queryRelease.signal()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(workspace.opens, 0)
        XCTAssertTrue(model.locked)
        XCTAssertNil(model.page)
        XCTAssertNil(model.confirmation)
    }

    func testDetailTransportRejectsMoreThanOneMiBBeforeDecode() async {
        XCTAssertEqual(BoundedIndexWire.responseLimit, 1 << 20)
        XCTAssertThrowsError(try BoundedIndexWire.decode(BoundedIndexDetail.self,
            json: String(repeating: " ", count: (1 << 20) + 1), limit: BoundedIndexWire.responseLimit)) { error in
            XCTAssertEqual(error as? BoundedReadIndexError, .resourceLimit)
        }
    }

    func testUnavailableDoesNotAuthenticateOrList() async {
        let auth = Authentication()
        let (model, workspace, calls) = fixture(available: false, auth: auth)
        model.unlock()
        XCTAssertTrue(model.locked)
        XCTAssertEqual(auth.calls, 0)
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(workspace.opens, 0)
    }

    func testRejectedAuthenticationDoesNotList() async {
        let auth = Authentication()
        auth.failure = true
        let (model, _, calls) = fixture(auth: auth)
        model.unlock()
        await eventually { !model.busy }
        XCTAssertTrue(model.locked)
        XCTAssertEqual(calls.count, 0)
        XCTAssertTrue(model.descriptors.isEmpty)
    }

    func testSelectionDoesNotOpenOrBuildAndPagesReuseOneScope() async throws {
        let (model, workspace, calls) = fixture()
        try await select(model)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(workspace.opens, 0)
        XCTAssertEqual(workspace.builds, 0)
        model.open()
        await eventually { model.page != nil }
        XCTAssertEqual(model.page?.transactions.map(\.id), [1])
        model.nextPage()
        XCTAssertNil(model.page)
        await eventually { model.page?.transactions.first?.id == 2 }
        XCTAssertEqual(model.page?.transactions.count, 1)
        model.firstPage()
        await eventually { model.page?.transactions.first?.id == 1 }
        XCTAssertEqual(workspace.opens, 1)
        XCTAssertEqual(workspace.pageCount, 3)
        XCTAssertEqual(workspace.closes, 0)
        model.lock()
        XCTAssertNil(model.page)
        XCTAssertNil(model.detail)
        XCTAssertTrue(model.descriptors.isEmpty)
        await eventually { workspace.closes == 1 && workspace.locks > 0 }
        XCTAssertTrue(workspace.offMain)
    }

    func testBuildRequiresExplicitConfirmationAndDrainsScope() async throws {
        let (model, workspace, _) = fixture()
        try await select(model)
        model.open()
        await eventually { model.page != nil }
        model.prepareBuild()
        await eventually { model.confirmation != nil }
        XCTAssertEqual(workspace.builds, 0)
        model.dismissConfirmation()
        XCTAssertEqual(workspace.builds, 0)
        model.prepareBuild()
        await eventually { model.confirmation != nil }
        model.confirmBuild()
        await eventually { workspace.builds == 1 && model.page != nil }
        XCTAssertEqual(workspace.opens, 2)
        XCTAssertEqual(workspace.closes, 1)
        model.lock()
        await eventually { workspace.closes == 2 }
    }

    func testOversizedPageFailsClosed() async throws {
        let workspace = Workspace()
        workspace.oversized = true
        let (model, _, _) = fixture(workspace: workspace)
        try await select(model)
        model.open()
        await eventually { !model.busy }
        XCTAssertNil(model.page)
        XCTAssertNil(model.lease)
        XCTAssertNotNil(model.message)
        model.lock()
    }

    func testOneOutstandingRequestAndLockSuppressesLatePageAfterUnlock() async throws {
        let workspace = Workspace()
        workspace.blockNext = true
        let (model, _, _) = fixture(workspace: workspace)
        try await select(model)
        model.open()
        await eventually { model.page != nil }
        model.nextPage()
        let started = await Task.detached { workspace.queryStarted.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(started)
        model.firstPage()
        model.nextPage()
        XCTAssertEqual(workspace.pageCount, 2)
        model.lock()
        XCTAssertNil(model.page)
        XCTAssertNil(model.detail)
        XCTAssertNil(model.selected)
        model.unlock()
        await eventually { !model.locked }
        workspace.queryRelease.signal()
        await eventually { workspace.closes == 1 }
        XCTAssertNil(model.page)
        XCTAssertNil(model.lease)
        model.lock()
    }

    func testLockSuppressesLateDetail() async throws {
        let workspace = Workspace()
        workspace.blockDetail = true
        let (model, _, _) = fixture(workspace: workspace)
        try await select(model)
        model.open()
        await eventually { model.page != nil }
        model.showDetail(999) // Not on the current page: rejected locally.
        XCTAssertEqual(workspace.details, 0)
        model.showDetail(1)
        let started = await Task.detached { workspace.queryStarted.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(started)
        model.lock()
        XCTAssertNil(model.detail)
        workspace.queryRelease.signal()
        await eventually { workspace.closes == 1 }
        XCTAssertNil(model.detail)
        XCTAssertNil(model.page)
    }
}
