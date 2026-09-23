import Foundation
import XCTest
import Combine
@testable import LedgerMobile

@MainActor
final class LocalTransactionWindowSessionTests: XCTestCase {
    private actor Gate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func suspend() async {
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor private final class Authenticator: LocalLedgerAuthenticating {
        let isAvailable = true
        func authenticate() async throws { }
    }

    private struct InertWidgetStore: LedgerWidgetCredentialStoring {
        let isAvailable = false
        func load() throws -> LedgerWidgetCredential? { nil }
        func save(_ credential: LedgerWidgetCredential) throws { }
        func suspend() throws { }
        func pendingRevocation() throws -> LedgerWidgetCredential? { nil }
        func completeRevocation(deviceID: String) throws { }
    }

    private actor Engine: LocalLedgerEngine {
        private var gate: Gate?
        private var successfulEdits = false
        private var successfulOtherWrites = false
        func enableSuccessfulOtherWrites() { successfulOtherWrites = true }
        func enableSuccessfulEdits() { successfulEdits = true }
        private var gatedPath = ""
        private var failAfterGate = false
        private(set) var pageRequests: [LocalLedgerEngineRequest] = []
        func pause(_ path: String = "/api/ledger/transactions/page", gate: Gate, fail: Bool = false) {
            self.gate = gate
            gatedPath = path
            failAfterGate = fail
        }
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            if request.path == "/api/ledger/version" { return Data("{}".utf8) }
            if request.path == "/api/ledger/overview/categories" {
                return try OverviewCategoriesFixture.data(start: request.query["start"]!, end: request.query["end"]!)
            }
            if request.path == "/api/ledger/transactions/page" { pageRequests.append(request) }
            if request.path == gatedPath, let gate {
                self.gate = nil
                let fail = failAfterGate
                await gate.suspend() // Intentionally ignores cancellation, like an embedded interpreter.
                if fail { throw LocalLedgerError.operationFailed("Synthetic late failure") }
            }
            let saved = URL(fileURLWithPath: request.workspaceRoot).appendingPathComponent("window-edit.json")
            var rows = (1...3).map { Self.row($0) }
            if successfulEdits, let data = try? Data(contentsOf: saved) {
                rows[0] = try JSONDecoder().decode(LedgerTransaction.self, from: data)
            }
            if successfulEdits, request.path == "/api/ledger/transactions", request.method == "PUT",
               case let .object(body) = request.body, let value = body["entry"] {
                let entry = try JSONDecoder().decode(LedgerTransactionEntry.self, from: JSONEncoder().encode(value))
                let updated = LedgerTransaction(date: entry.date, payee: entry.payee, narration: entry.narration,
                    postings: rows[0].postings, editableEntry: entry,
                    source: TransactionSource(file: "synthetic.bean", line: 1, hash: "committed-row-1"))
                try JSONEncoder().encode(updated).write(to: saved)
                return Data(#"{"ok":true}"#.utf8)
            }
            if successfulOtherWrites, request.method == "DELETE" || request.path == "/api/ledger/transactions/tags" {
                try Data("; successful synthetic write".utf8).write(to:
                    URL(fileURLWithPath: request.workspaceRoot).appendingPathComponent("action-write.bean"))
                return Data(#"{"ok":true}"#.utf8)
            }
            if request.path == "/api/ledger/bootstrap" {
                guard successfulEdits else { return Data(LedgerModelsTests.bootstrapJSON.utf8) }
                var payload = try JSONSerialization.jsonObject(with: Data(LedgerModelsTests.bootstrapJSON.utf8)) as! [String: Any]
                payload["transactions"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows.filter {
                    $0.date >= request.query["start"]! && $0.date < request.query["end"]!
                }))
                return try JSONSerialization.data(withJSONObject: payload)
            }
            if request.path == "/api/ledger/transactions/detail" {
                return try JSONEncoder().encode(rows.first { $0.source.line == Int(request.query["line"] ?? "1") }!)
            }
            if request.path == "/api/ledger/transactions/page" {
                if successfulEdits {
                    rows = rows.filter { $0.date >= request.query["start"]! && $0.date < request.query["end"]! }
                }
                return try JSONSerialization.data(withJSONObject: ["revision": "native-synthetic",
                    "transactions": JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)),
                    "nextCursor": NSNull(), "sensitiveUnlocked": true])
            }
            throw LocalLedgerError.operationFailed("Synthetic optional operation unavailable")
        }
        private static func row(_ line: Int) -> LedgerTransaction {
            LedgerTransaction(date: "2026-09-23", payee: line == 2 ? "Needle" : "Synthetic", narration: "window only",
                postings: [LedgerPosting(account: "Expenses:Food", amount: 125, currency: "CNY")],
                source: TransactionSource(file: "synthetic.bean", line: line, hash: "row-\(line)"))
        }
    }

    private func fixture() async throws -> (LedgerSession, Engine, LocalLedgerRepository) {
        let suite = "window-session-tests-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let engine = Engine()
        let catalog = LocalLedgerCatalog(rootDirectory: root.appendingPathComponent("managed"),
            engine: engine, validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Synthetic window fixture")
        let session = LedgerSession(localOnly: true, localCatalog: catalog, localAuthenticator: Authenticator(),
            defaults: defaults,
            widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: suite, lockDirectory: root),
            widgetCredentialStore: InertWidgetStore())
        await session.openLocalLedger(descriptor)
        XCTAssertEqual(session.phase, .ready)
        return (session, engine, try XCTUnwrap(session.localRepository))
    }

    private func advance(_ repository: LocalLedgerRepository) async throws {
        let revision = try await repository.workspace.currentRevision()
        _ = try await repository.workspace.commit(expectedRevisionID: try XCTUnwrap(revision).id,
            changes: [.write(Data("; newer synthetic revision".utf8), to: "window-test.bean")]) { _ in }
    }

    private func assertCleared(_ session: LedgerSession, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(session.localTransactionWindow, file: file, line: line)
        XCTAssertNil(session.localTransactionWindowError, file: file, line: line)
        XCTAssertFalse(session.isLocalTransactionWindowLoading, file: file, line: line)
    }

    private func actionSource(_ line: Int = 1) -> TransactionSource {
        .init(file: "synthetic.bean", line: line, hash: "row-\(line)")
    }

    func testPreparedActionDoesNotPopulateLegacyArraysAndEditsUnknownExactOriginal() async throws {
        let (session, engine, repository) = try await fixture()
        defer { session.chooseLedger() }
        await engine.enableSuccessfulEdits()
        let source = actionSource()
        XCTAssertNil(session.visibleTransaction(matching: source))
        let rows = session.ledger?.transactions
        let global = session.globalTransactions
        let action = try await session.prepareLocalTransactionAction(sources: [source], kind: .edit)
        XCTAssertEqual(action.originals.map(\.source), [source])
        XCTAssertEqual(session.ledger?.transactions, rows)
        XCTAssertEqual(session.globalTransactions, global)
        XCTAssertNil(session.visibleTransaction(matching: source))
        let before = try await repository.workspace.currentRevision()
        let entry = LedgerTransactionEntry(date: "2026-09-24", payee: "Action edited", narration: "Synthetic",
            postings: [.init(account: "Expenses:Food", amount: "1.25", currency: "CNY")])
        try await session.updateLocalTransaction(action: action, entry: entry)
        let after = try await repository.workspace.currentRevision()
        XCTAssertNotEqual(before?.id, after?.id)
        do {
            try await session.updateLocalTransaction(action: action, entry: entry)
            XCTFail("Consumed action replayed")
        } catch is CancellationError { }
    }

    func testPreparedDeleteAndTagsUsePinnedWorkspaceCommit() async throws {
        for kind in [LedgerSession.LocalTransactionActionKind.delete, .addTags] {
            let (session, engine, repository) = try await fixture()
            defer { session.chooseLedger() }
            await engine.enableSuccessfulOtherWrites()
            let sources = kind == .delete ? [actionSource()] : [actionSource(), actionSource(2)]
            let action = try await session.prepareLocalTransactionAction(sources: sources, kind: kind)
            let before = try await repository.workspace.currentRevision()
            if kind == .delete { try await session.deleteLocalTransaction(action: action, reason: "Synthetic") }
            else { try await session.addLocalTransactionTags(action: action, tags: ["synthetic"]) }
            let after = try await repository.workspace.currentRevision()
            XCTAssertNotEqual(before?.id, after?.id)
            for original in action.originals {
                XCTAssertNotEqual(session.transactionMutationPhase(for: original), .pending)
            }
            do {
                if kind == .delete { try await session.deleteLocalTransaction(action: action, reason: "Replay") }
                else { try await session.addLocalTransactionTags(action: action, tags: ["replay"]) }
                XCTFail("Action replay accepted")
            } catch is CancellationError { }
        }
    }

    func testPreparedActionRevokedByResetPrivacyRangeAndCancellation() async throws {
        for revocation in ["reset", "privacy", "range", "cancel", "choose"] {
            let (session, _, repository) = try await fixture()
            let action = try await session.prepareLocalTransactionAction(sources: [actionSource()], kind: .delete)
            let before = try await repository.workspace.currentRevision()
            switch revocation {
            case "reset": session.resetLocalTransactionWindow()
            case "privacy": await session.updateActivity(isActive: false, isBackground: true)
            case "range": await session.applyRange(.month(year: 2026, month: 8))
            case "cancel": session.cancelLocalTransactionAction(action)
            default: session.chooseLedger()
            }
            do {
                try await session.deleteLocalTransaction(action: action, reason: "Synthetic")
                XCTFail("Revoked action accepted: \(revocation)")
            } catch is CancellationError { }
            let after = try await repository.workspace.currentRevision()
            XCTAssertEqual(before?.id, after?.id)
            session.chooseLedger()
        }
    }

    func testPreparedActionCannotBorrowNewerOrdinaryReadAuthority() async throws {
        let (session, _, repository) = try await fixture()
        defer { session.chooseLedger() }
        let action = try await session.prepareLocalTransactionAction(sources: [actionSource()], kind: .delete)
        try await advance(repository)
        _ = try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-23", valuationCurrency: "CNY")
        let before = try await repository.workspace.currentRevision()
        do {
            try await session.deleteLocalTransaction(action: action, reason: "Stale action")
            XCTFail("Stale action borrowed presentedRevisionID")
        } catch LocalLedgerWorkspace.WorkspaceError.staleRevision { }
        let after = try await repository.workspace.currentRevision()
        XCTAssertEqual(before?.id, after?.id)
        XCTAssertNil(session.transactionMutationPhase(for: action.originals[0]))
    }

    func testPreparedActionRejectsWrongKindAndSupersededNonceWithoutOverlay() async throws {
        let (session, _, _) = try await fixture()
        defer { session.chooseLedger() }
        let first = try await session.prepareLocalTransactionAction(sources: [actionSource()], kind: .delete)
        let second = try await session.prepareLocalTransactionAction(sources: [actionSource(2)], kind: .addTags)
        session.cancelLocalTransactionAction(first) // Must not revoke the newer action.
        for action in [first, second] {
            do {
                try await session.deleteLocalTransaction(action: action, reason: "Wrong authority")
                XCTFail("Wrong or superseded authority accepted")
            } catch is CancellationError { }
            XCTAssertNil(session.transactionMutationPhase(for: action.originals[0]))
        }
        // Valid new action reaches the deliberately failing mock write, not cancellation.
        do {
            try await session.addLocalTransactionTags(action: second, tags: ["synthetic"])
            XCTFail("Mock should fail")
        } catch is CancellationError { XCTFail("Old cancellation revoked newer action") }
          catch { }
        if case .failed = session.transactionMutationPhase(for: second.originals[0]) { }
        else { XCTFail("Expected failed overlay after mock rollback") }
    }

    func testActionPreparationRejectsInvalidBatchesAndLateHydration() async throws {
        let (session, engine, _) = try await fixture()
        defer { session.chooseLedger() }
        for sources in [[], [actionSource(), actionSource()]] as [[TransactionSource]] {
            do {
                _ = try await session.prepareLocalTransactionAction(sources: sources, kind: .addTags)
                XCTFail("Invalid batch accepted")
            } catch LedgerTransactionMutationError.sourceUnavailable { }
        }
        do {
            _ = try await session.prepareLocalTransactionAction(sources: [actionSource(), actionSource(2)], kind: .edit)
            XCTFail("Multiple edit originals accepted")
        } catch LedgerTransactionMutationError.sourceUnavailable { }
        let entered = expectation(description: "action hydration paused")
        let gate = Gate(entered)
        await engine.pause("/api/ledger/transactions/detail", gate: gate)
        let loading = Task { try await session.prepareLocalTransactionAction(sources: [actionSource()], kind: .delete) }
        await fulfillment(of: [entered], timeout: 3)
        session.resetLocalTransactionWindow()
        await gate.release()
        do {
            _ = try await loading.value
            XCTFail("Late hydration granted authority")
        } catch is CancellationError { }
        XCTAssertNil(session.visibleTransaction(matching: actionSource()))
    }

    func testOverlappingPreparationReportsBusyWithoutRevokingInFlightAuthority() async throws {
        let (session, engine, _) = try await fixture()
        defer { session.chooseLedger() }
        let entered = expectation(description: "first preparation paused")
        let gate = Gate(entered)
        await engine.pause("/api/ledger/transactions/detail", gate: gate)
        let first = Task { try await session.prepareLocalTransactionAction(sources: [actionSource()], kind: .delete) }
        await fulfillment(of: [entered], timeout: 3)
        do {
            _ = try await session.prepareLocalTransactionAction(sources: [actionSource(2)], kind: .delete)
            XCTFail("Concurrent hydration accepted")
        } catch LocalTransactionWindow.WindowError.busy { }
        await gate.release()
        let action = try await first.value
        XCTAssertEqual(action.originals.map(\.source), [actionSource()])
        do {
            try await session.deleteLocalTransaction(action: action, reason: "Synthetic")
            XCTFail("Mock should fail")
        } catch is CancellationError { XCTFail("Busy preparation revoked original authority") }
          catch { }
    }

    func testPreparedBatchHydratesAllOriginalsBeforeAnyOverlayAndRollsBackFailure() async throws {
        let (session, _, repository) = try await fixture()
        defer { session.chooseLedger() }
        let sources = [actionSource(), actionSource(2), actionSource(3)]
        let action = try await session.prepareLocalTransactionAction(sources: sources, kind: .addTags)
        XCTAssertEqual(action.originals.map(\.source), sources)
        let before = try await repository.workspace.currentRevision()
        for original in action.originals { XCTAssertNil(session.transactionMutationPhase(for: original)) }
        do {
            try await session.addLocalTransactionTags(action: action, tags: ["synthetic"])
            XCTFail("Mock should fail")
        } catch { }
        let after = try await repository.workspace.currentRevision()
        XCTAssertEqual(before?.id, after?.id)
        for original in action.originals {
            if case .failed = session.transactionMutationPhase(for: original) { }
            else { XCTFail("Expected rolled back batch") }
        }
    }

    func testCompleteSummaryDoesNotRequireScrollingOrRetainVisibleRows() async throws {
        let (session, _, _) = try await fixture()
        defer { session.chooseLedger() }
        await session.loadLocalTransactionWindow(filter: .init(query: "Needle"), limits: .init(maxRows: 1))
        // One matched row can reach EOF immediately; explicit summary is idempotent.
        await session.loadLocalTransactionSummary()
        XCTAssertEqual(session.localTransactionSummary?.matchedCount, 1)
        XCTAssertEqual(session.localTransactionSummary?.fullRangeCount, 3)
        await session.loadLocalTransactionWindow(limits: .init(maxRows: 1))
        XCTAssertNil(session.localTransactionSummary)
        let visible = session.localTransactionWindow?.transactions
        await session.loadLocalTransactionSummary()
        XCTAssertEqual(session.localTransactionSummary?.matchedCount, 3)
        XCTAssertEqual(session.localTransactionSummary?.fullRangeCount, 3)
        XCTAssertEqual(session.localTransactionSummary?.visibleTransactions.count, 0)
        XCTAssertEqual(session.localTransactionSummary?.days.first?.expense, 375)
        XCTAssertEqual(session.localTransactionWindow?.transactions, visible)
        XCTAssertNotNil(session.localTransactionWindow?.continuation)
        XCTAssertFalse(session.isLocalTransactionSummaryLoading)
        XCTAssertNil(session.localTransactionSummaryError)
        session.resetLocalTransactionWindow()
        XCTAssertNil(session.localTransactionSummary)
    }

    func testLateSummaryCannotPublishAfterResetPrivacyRangeOrRevisionChange() async throws {
        for operation in 0..<4 {
            let (session, engine, repository) = try await fixture()
            defer { session.chooseLedger() }
            await session.loadLocalTransactionWindow(limits: .init(maxRows: 1))
            let entered = expectation(description: "summary awaiting")
            let gate = Gate(entered)
            await engine.pause(gate: gate)
            let loading = Task { await session.loadLocalTransactionSummary() }
            await fulfillment(of: [entered], timeout: 3)
            XCTAssertTrue(session.isLocalTransactionSummaryLoading)
            switch operation {
            case 0: session.resetLocalTransactionWindow()
            case 1: await session.updateActivity(isActive: false, isBackground: true)
            case 2: await session.applyRange(.month(year: 2026, month: 8))
            default: try await advance(repository)
            }
            await gate.release()
            await loading.value
            XCTAssertNil(session.localTransactionSummary)
            XCTAssertFalse(session.isLocalTransactionSummaryLoading)
            if operation == 3 { XCTAssertNotNil(session.localTransactionSummaryError) }
        }
    }

    func testWindowEOFSummarySupersedesLateIndependentScanFailure() async throws {
        let (session, engine, _) = try await fixture()
        defer { session.chooseLedger() }
        await session.loadLocalTransactionWindow(limits: .init(maxRows: 1))
        let entered = expectation(description: "independent scan awaiting")
        let gate = Gate(entered)
        await engine.pause(gate: gate, fail: true)
        let loading = Task { await session.loadLocalTransactionSummary() }
        await fulfillment(of: [entered], timeout: 3)
        await session.loadNextLocalTransactionWindow()
        await session.loadNextLocalTransactionWindow()
        XCTAssertEqual(session.localTransactionSummary?.fullRangeCount, 3)
        XCTAssertFalse(session.isLocalTransactionSummaryLoading)
        await gate.release()
        await loading.value
        XCTAssertEqual(session.localTransactionSummary?.fullRangeCount, 3)
        XCTAssertNil(session.localTransactionSummaryError)
        XCTAssertFalse(session.isLocalTransactionSummaryLoading)
    }

    func testSummaryFailureLeavesWindowUsableAndCanRetry() async throws {
        let (session, engine, _) = try await fixture()
        defer { session.chooseLedger() }
        await session.loadLocalTransactionWindow(limits: .init(maxRows: 1))
        let visible = session.localTransactionWindow?.transactions
        let entered = expectation(description: "failed summary")
        let gate = Gate(entered)
        await engine.pause(gate: gate, fail: true)
        let loading = Task { await session.loadLocalTransactionSummary() }
        await fulfillment(of: [entered], timeout: 3)
        await session.loadLocalTransactionSummary() // Concurrent duplicate is a no-op.
        await gate.release()
        await loading.value
        XCTAssertNil(session.localTransactionSummary)
        XCTAssertNotNil(session.localTransactionSummaryError)
        XCTAssertEqual(session.localTransactionWindow?.transactions, visible)
        await session.loadLocalTransactionSummary()
        XCTAssertEqual(session.localTransactionSummary?.fullRangeCount, 3)
        XCTAssertNil(session.localTransactionSummaryError)
        await session.loadNextLocalTransactionWindow()
        XCTAssertEqual(session.localTransactionWindow?.transactions.first?.source.line, 2)
        XCTAssertEqual(session.localTransactionSummary?.fullRangeCount, 3)
    }

    func testOptInFirstNextSingleWindowEOFAndExplicitResetLeaveLegacyArraysUntouched() async throws {
        let (session, engine, repository) = try await fixture()
        defer { session.chooseLedger() }
        assertCleared(session)
        let original = session.ledger?.transactions
        let global = session.globalTransactions
        let presented = await repository.presentedRevisionID
        await session.loadNextLocalTransactionWindow() // Never implicitly selects a first window.
        let before = await engine.pageRequests
        XCTAssertTrue(before.isEmpty)
        await session.loadLocalTransactionWindow(limits: .init(maxRows: 1))
        XCTAssertEqual(session.localTransactionWindow?.transactions.map(\.source.line), [1])
        XCTAssertNil(session.localTransactionWindow?.summary)
        await session.loadNextLocalTransactionWindow()
        XCTAssertEqual(session.localTransactionWindow?.transactions.map(\.source.line), [2])
        XCTAssertNil(session.localTransactionWindow?.summary)
        await session.loadNextLocalTransactionWindow()
        XCTAssertEqual(session.localTransactionWindow?.transactions.map(\.source.line), [3])
        XCTAssertEqual(session.localTransactionWindow?.summary?.fullRangeCount, 3)
        XCTAssertEqual(session.localTransactionWindow?.summary?.matchedCount, 3)
        XCTAssertEqual(session.localTransactionWindow?.summary?.visibleTransactions.count, 0)
        XCTAssertEqual(session.localTransactionWindow?.isComplete, true)
        await session.loadNextLocalTransactionWindow()
        XCTAssertEqual(session.localTransactionWindow?.transactions.map(\.source.line), [3])
        let requests = await engine.pageRequests
        XCTAssertEqual(requests.count, 1, "Later windows consume the cached candidate page")
        XCTAssertEqual(requests.first?.query, ["dialect": "native-candidates-v1", "start": session.selectedRange.start,
            "end": session.selectedRange.queryEndExclusive, "limit": "500"])
        let after = await repository.presentedRevisionID
        XCTAssertEqual(after, presented)
        XCTAssertEqual(session.ledger?.transactions, original)
        XCTAssertEqual(session.globalTransactions, global)
        session.resetLocalTransactionWindow()
        assertCleared(session)
    }

    func testLockSwitchResetAndBackgroundWhileAwaitingCannotPublish() async throws {
        for action in 0..<4 {
            let (session, engine, _) = try await fixture()
            let entered = expectation(description: "page awaiting")
            let gate = Gate(entered)
            await engine.pause(gate: gate)
            let loading = Task { await session.loadLocalTransactionWindow() }
            await fulfillment(of: [entered], timeout: 3)
            XCTAssertTrue(session.isLocalTransactionWindowLoading)
            switch action {
            case 0: await session.lock()
            case 1: session.chooseLedger()
            case 2: session.resetLocalTransactionWindow()
            default: await session.updateActivity(isActive: false, isBackground: true)
            }
            assertCleared(session)
            await gate.release()
            await loading.value
            assertCleared(session)
            session.chooseLedger()
        }
    }

    func testBackgroundClearsCachedPageBeforeLockIntervalAndPreventsReads() async throws {
        let (session, engine, _) = try await fixture()
        defer { session.chooseLedger() }
        XCTAssertEqual(session.lockInterval, .fiveMinutes)
        await session.loadLocalTransactionWindow(limits: .init(maxRows: 1))
        XCTAssertNotNil(session.localTransactionWindow?.continuation)
        await session.updateActivity(isActive: false, isBackground: true)
        XCTAssertEqual(session.phase, .ready, "Privacy revocation must not wait for the lock interval")
        XCTAssertTrue(session.privacyShielded)
        assertCleared(session)
        await session.loadNextLocalTransactionWindow()
        await session.loadLocalTransactionWindow()
        assertCleared(session)
        let requests = await engine.pageRequests
        XCTAssertEqual(requests.count, 1)
    }

    func testFilterSupersedesLateSuccessAndFailureWithoutOverwritingNewState() async throws {
        for failure in [false, true] {
            let (session, engine, _) = try await fixture()
            let entered = expectation(description: "old filter awaiting")
            let gate = Gate(entered)
            await engine.pause(gate: gate, fail: failure)
            let old = Task { await session.loadLocalTransactionWindow(limits: .init(maxRows: 1)) }
            await fulfillment(of: [entered], timeout: 3)
            await session.loadLocalTransactionWindow(filter: .init(query: "Needle"))
            XCTAssertEqual(session.localTransactionWindow?.transactions.map(\.source.line), [2])
            XCTAssertEqual(session.localTransactionWindow?.summary?.matchedCount, 1)
            await gate.release()
            await old.value
            XCTAssertEqual(session.localTransactionWindow?.transactions.map(\.source.line), [2])
            XCTAssertNil(session.localTransactionWindowError)
            XCTAssertFalse(session.isLocalTransactionWindowLoading)
            let requests = await engine.pageRequests
            XCTAssertTrue(requests.allSatisfy { $0.query["q"] == nil && $0.query["account"] == nil })
            session.chooseLedger()
        }
    }

    func testRangeAndRequestInvalidationSupersedeAwaitingWindow() async throws {
        for rangeChange in [false, true] {
            let (session, engine, _) = try await fixture()
            let entered = expectation(description: "old request awaiting")
            let gate = Gate(entered)
            await engine.pause(gate: gate)
            let old = Task { await session.loadLocalTransactionWindow() }
            await fulfillment(of: [entered], timeout: 3)
            if rangeChange { await session.applyRange(session.selectedRange.shifted(by: -1)) }
            else { await session.refresh() }
            assertCleared(session)
            await session.loadLocalTransactionWindow(filter: .init(query: "Needle"))
            await gate.release()
            await old.value
            XCTAssertEqual(session.localTransactionWindow?.transactions.map(\.source.line), [2])
            let requests = await engine.pageRequests
            XCTAssertEqual(requests.last?.query["start"], session.selectedRange.start)
            XCTAssertNil(session.localTransactionWindowError)
            session.chooseLedger()
        }
    }

    func testConcurrentNextDoesNotOverwriteActiveLoadingOrError() async throws {
        let (session, engine, _) = try await fixture()
        defer { session.chooseLedger() }
        let entered = expectation(description: "first window awaiting")
        let gate = Gate(entered)
        await engine.pause(gate: gate)
        let first = Task { await session.loadLocalTransactionWindow(limits: .init(maxRows: 1)) }
        await fulfillment(of: [entered], timeout: 3)
        await session.loadNextLocalTransactionWindow()
        XCTAssertTrue(session.isLocalTransactionWindowLoading)
        XCTAssertNil(session.localTransactionWindowError)
        await gate.release()
        await first.value
        async let a: Void = session.loadNextLocalTransactionWindow()
        async let b: Void = session.loadNextLocalTransactionWindow()
        _ = await (a, b)
        XCTAssertEqual(session.localTransactionWindow?.transactions.map(\.source.line), [2])
        XCTAssertFalse(session.isLocalTransactionWindowLoading)
        XCTAssertNil(session.localTransactionWindowError)
    }

    func testCommitDuringFinalPageAwaitAndBetweenCachedWindowsRejectsPublication() async throws {
        for cached in [false, true] {
            let (session, engine, repository) = try await fixture()
            if cached {
                await session.loadLocalTransactionWindow(limits: .init(maxRows: 2))
                XCTAssertNotNil(session.localTransactionWindow)
                try await advance(repository) // No save notification: owner must query current revision.
                await session.loadNextLocalTransactionWindow()
            } else {
                let entered = expectation(description: "final page awaiting")
                let gate = Gate(entered)
                await engine.pause(gate: gate)
                let loading = Task { await session.loadLocalTransactionWindow() }
                await fulfillment(of: [entered], timeout: 3)
                try await advance(repository)
                await gate.release()
                await loading.value
            }
            XCTAssertNil(session.localTransactionWindow)
            XCTAssertNotNil(session.localTransactionWindowError)
            XCTAssertFalse(session.isLocalTransactionWindowLoading)
            session.chooseLedger()
        }
    }

    func testCommitDuringCachedFinalWorkspaceAwaitCannotPublishEOF() async throws {
        let (session, engine, repository) = try await fixture()
        defer { session.chooseLedger() }
        await session.loadLocalTransactionWindow(limits: .init(maxRows: 2))
        XCTAssertEqual(session.localTransactionWindow?.transactions.count, 2)
        XCTAssertNil(session.localTransactionWindow?.summary)
        let original = try await repository.workspace.currentRevision()
        let entered = expectation(description: "workspace actor held before final freshness lookup")
        let release = DispatchSemaphore(value: 0)
        let holding = Task.detached {
            await repository.workspace.holdForWindowPublicationTest(entered: entered, release: release)
        }
        await fulfillment(of: [entered], timeout: 3)
        let loading = expectation(description: "cached next window started")
        let observation = session.$isLocalTransactionWindowLoading.filter { $0 }.prefix(1).sink { _ in loading.fulfill() }
        let next = Task { await session.loadNextLocalTransactionWindow() }
        await fulfillment(of: [loading], timeout: 3)
        observation.cancel()
        // The remaining row is cached. There is no candidate/factory workspace
        // read on this path; publication must wait for its final currentRevision.
        XCTAssertTrue(session.isLocalTransactionWindowLoading)
        XCTAssertEqual(session.localTransactionWindow?.transactions.count, 2)
        do {
            // A second workspace handle models an external writer while the
            // session's workspace actor is held. No production suspension hooks.
            let writer = LocalLedgerWorkspace(rootDirectory: repository.workspace.rootDirectory)
            _ = try await writer.commit(expectedRevisionID: try XCTUnwrap(original).id,
                changes: [.write(Data("; synthetic external commit".utf8), to: "external.bean")]) { _ in }
        } catch {
            release.signal()
            await holding.value
            await next.value
            throw error
        }
        release.signal()
        await holding.value
        await next.value
        XCTAssertNil(session.localTransactionWindow, "Never publish the stale EOF summary")
        XCTAssertNotNil(session.localTransactionWindowError)
        XCTAssertFalse(session.isLocalTransactionWindowLoading)
        let requests = await engine.pageRequests
        XCTAssertEqual(requests.count, 1)
    }

    func testEmptyFilterResultHasCompleteSummaryAndNoImplicitSelection() async throws {
        let (session, _, _) = try await fixture()
        defer { session.chooseLedger() }
        await session.loadLocalTransactionWindow(filter: .init(query: "No synthetic match"))
        XCTAssertEqual(session.localTransactionWindow?.transactions.count, 0)
        XCTAssertEqual(session.localTransactionWindow?.summary?.matchedCount, 0)
        XCTAssertEqual(session.localTransactionWindow?.summary?.fullRangeCount, 3)
        XCTAssertEqual(session.localTransactionWindow?.isComplete, true)
        session.resetLocalTransactionWindow()
        await session.loadNextLocalTransactionWindow()
        assertCleared(session)
    }

    func testSaveObserverClearsCachedAndAwaitingWindowsOnChangedRevision() async throws {
        for awaiting in [false, true] {
            let (session, engine, repository) = try await fixture()
            await session.loadLocalTransactionWindow(limits: .init(maxRows: 1))
            var loading: Task<Void, Never>?
            var gate: Gate?
            if awaiting {
                let entered = expectation(description: "save during page await")
                let paused = Gate(entered)
                gate = paused
                await engine.pause(gate: paused)
                loading = Task { await session.loadLocalTransactionWindow() }
                await fulfillment(of: [entered], timeout: 3)
            }
            try await advance(repository)
            let cleared = expectation(description: "save observed")
            let observation = session.$localOverviewCategoriesError.compactMap { $0 }.prefix(1).sink { _ in cleared.fulfill() }
            NotificationCenter.default.post(name: LocalLedgerRepository.didSaveNotification, object: repository.descriptor.id)
            await fulfillment(of: [cleared], timeout: 3)
            observation.cancel()
            assertCleared(session)
            await gate?.release()
            await loading?.value
            assertCleared(session)
            session.chooseLedger()
        }
    }

    func testMutationBeginClearsWindowBeforeRepositoryAwait() async throws {
        let (session, engine, _) = try await fixture()
        defer { session.chooseLedger() }
        await session.loadLocalTransactionWindow(limits: .init(maxRows: 1))
        let original = try XCTUnwrap(session.ledger?.transactions.first)
        let entered = expectation(description: "delete awaiting")
        let gate = Gate(entered)
        await engine.pause("/api/ledger/transactions", gate: gate)
        let mutation = Task { try await session.deleteTransaction(source: original.source, reason: "Synthetic test") }
        await fulfillment(of: [entered], timeout: 3)
        assertCleared(session)
        await session.loadLocalTransactionWindow()
        assertCleared(session)
        await gate.release()
        _ = await mutation.result // Mock write deliberately fails; no mutation semantics changed.
    }

    func testSuccessfulEditsResumePinnedReadsAfterMonthlyRefreshIncludingRetainedCrossRangeOverlay() async throws {
        for date in ["2026-09-24", "2026-10-02"] {
            let (session, engine, repository) = try await fixture()
            defer { session.chooseLedger() }
            await engine.enableSuccessfulEdits()
            try await advance(repository) // Invalidate the initial bootstrap presentation cache.
            await session.applyRange(.month(year: 2026, month: 9))
            let original = try XCTUnwrap(session.ledger?.transactions.first)
            let unrelated = try XCTUnwrap(session.ledger?.transactions.last)
            let before = try await repository.workspace.currentRevision()
            let entry = LedgerTransactionEntry(date: date, payee: "Committed", narration: "Edited",
                postings: [.init(account: "Expenses:Food", amount: "1.25", currency: "CNY")])
            let entered = expectation(description: "update pending")
            let gate = Gate(entered)
            await engine.pause("/api/ledger/transactions", gate: gate)
            let mutation = Task { try await session.updateTransaction(source: original.source, entry: entry) }
            await fulfillment(of: [entered], timeout: 3)
            XCTAssertEqual(session.transactionMutationPhase(for: original), .pending)
            await session.loadLocalTransactionWindow()
            assertCleared(session)
            do {
                _ = try await session.localTransactionDetail(source: unrelated.source)
                XCTFail("Pending writes must block detail too")
            } catch is CancellationError { }
            let refreshing = expectation(description: "committed bootstrap awaiting")
            let bootstrapGate = Gate(refreshing)
            await engine.pause("/api/ledger/bootstrap", gate: bootstrapGate)
            await gate.release()
            try await mutation.value
            await fulfillment(of: [refreshing], timeout: 3)
            XCTAssertEqual(session.transactionMutationPhase(for: original), .confirmed)
            do {
                try await session.updateTransaction(source: original.source, entry: entry)
                XCTFail("Confirmed overlays must still block repeat writes")
            } catch LedgerTransactionMutationError.alreadyInProgress { }
            let refreshed = expectation(description: "monthly bootstrap published")
            let observation = session.$ledger.dropFirst().prefix(1).sink { _ in refreshed.fulfill() }
            await bootstrapGate.release()
            await fulfillment(of: [refreshed], timeout: 3)
            observation.cancel()
            await session.refresh()
            XCTAssertNil(session.errorMessage)
            XCTAssertEqual(session.selectedRange, .month(year: 2026, month: 9))
            let committed = try await repository.workspace.currentRevision()
            XCTAssertNotEqual(committed?.id, before?.id)
            let crossRange = date.hasPrefix("2026-10")
            XCTAssertEqual(session.transactionMutationPhase(for: original), crossRange ? .confirmed : nil)
            await session.loadLocalTransactionWindow(limits: .init(maxRows: 1))
            XCTAssertNotNil(session.localTransactionWindow)
            await session.loadNextLocalTransactionWindow()
            XCTAssertNotNil(session.localTransactionWindow)
            XCTAssertNil(session.localTransactionWindowError)
            let detail = try await session.localTransactionDetail(source: unrelated.source)
            XCTAssertEqual(detail, unrelated)
            await session.applyRange(.month(year: 2026, month: crossRange ? 10 : 9))
            await session.loadLocalTransactionWindow()
            let native = try XCTUnwrap(session.localTransactionWindow?.transactions.first)
            XCTAssertEqual(native.source.hash, "committed-row-1")
            XCTAssertEqual(native.date, date)
            let editedDetail = try await session.localTransactionDetail(source: native.source)
            XCTAssertEqual(editedDetail, native)
        }
    }

    func testCallerCancellationDoesNotPublishOrPoisonReplacement() async throws {
        let (session, engine, _) = try await fixture()
        defer { session.chooseLedger() }
        let entered = expectation(description: "cancel awaiting page")
        let gate = Gate(entered)
        await engine.pause(gate: gate)
        let old = Task { await session.loadLocalTransactionWindow() }
        await fulfillment(of: [entered], timeout: 3)
        old.cancel()
        await session.loadLocalTransactionWindow(filter: .init(query: "Needle"))
        await gate.release()
        await old.value
        XCTAssertEqual(session.localTransactionWindow?.transactions.map(\.source.line), [2])
        XCTAssertNil(session.localTransactionWindowError)
    }

    func testDetailIsCallerOwnedVerifiedOriginalAndNeverSeedsLegacyResolution() async throws {
        let (session, _, repository) = try await fixture()
        defer { session.chooseLedger() }
        let source = TransactionSource(file: "synthetic.bean", line: 1, hash: "row-1")
        let transactions = session.ledger?.transactions
        let global = session.globalTransactions
        let presented = await repository.presentedRevisionID
        let detail = try await session.localTransactionDetail(source: source)
        XCTAssertEqual(detail.source, source)
        XCTAssertEqual(detail.narration, "window only")
        XCTAssertEqual(session.transactionResolution(for: source), .unloaded)
        XCTAssertNil(session.visibleTransaction(matching: source))
        XCTAssertEqual(session.ledger?.transactions, transactions)
        XCTAssertEqual(session.globalTransactions, global)
        XCTAssertTrue(session.transactionMutationStates.isEmpty)
        let after = await repository.presentedRevisionID
        XCTAssertEqual(after, presented)
        assertCleared(session)
    }

    func testDetailLockBackgroundRangeCommitCancellationAndResetRejectLateReturn() async throws {
        for action in 0..<6 {
            let (session, engine, repository) = try await fixture()
            let source = TransactionSource(file: "synthetic.bean", line: 1, hash: "row-1")
            let entered = expectation(description: "detail awaiting")
            let gate = Gate(entered)
            await engine.pause("/api/ledger/transactions/detail", gate: gate)
            let reading = Task { try await session.localTransactionDetail(source: source) }
            await fulfillment(of: [entered], timeout: 3)
            switch action {
            case 0: await session.lock()
            case 1: await session.updateActivity(isActive: false, isBackground: true)
            case 2: await session.applyRange(session.selectedRange.shifted(by: -1))
            case 3: try await advance(repository)
            case 4: reading.cancel()
            default: session.resetLocalTransactionWindow()
            }
            await gate.release()
            do { _ = try await reading.value; XCTFail("Stale detail returned for action \(action)") }
            catch { }
            XCTAssertEqual(session.transactionResolution(for: source), .unloaded)
            assertCleared(session)
            session.chooseLedger()
        }
    }
}

private extension LocalLedgerWorkspace {
    // Match the existing session bootstrap tests' bounded synchronous actor gate.
    func holdForWindowPublicationTest(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        _ = release.wait(timeout: .now() + 5)
    }
}
