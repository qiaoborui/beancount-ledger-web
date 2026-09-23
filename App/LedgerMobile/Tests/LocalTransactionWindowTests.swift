import XCTest
@testable import LedgerMobile

final class LocalTransactionWindowTests: XCTestCase, @unchecked Sendable {
    private static func row(_ index: Int, payee: String = "Shop", narration: String = "Lunch",
                            amount: Int = 125) -> LedgerTransaction {
        LedgerTransaction(date: "2026-09-23", payee: payee, narration: narration, tags: ["food"],
                          postings: [LedgerPosting(account: "Expenses:Food", amount: amount, currency: "CNY")],
                          source: TransactionSource(file: "synthetic.bean", line: index + 1, hash: "row-\(index)"))
    }

    private static func page(_ rows: [LedgerTransaction], next: String? = nil,
                             revision: String = "native", unlocked: Bool = true) -> LedgerTransactionPage {
        LedgerTransactionPage(revision: revision, transactions: rows, nextCursor: next, sensitiveUnlocked: unlocked)
    }

    private func reader(_ pages: [LedgerTransactionPage], filter: LedgerTransactionFilter = .init(),
                        limits: LocalTransactionWindow.Limits = .init()) throws -> LocalTransactionWindow {
        try LocalTransactionWindow(workspaceID: UUID(), filter: filter, limits: limits) { request in
            pages[request.cursor.flatMap(Int.init) ?? 0]
        }
    }

    private func expectError(_ expected: LocalTransactionWindow.WindowError,
                             reader: LocalTransactionWindow, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await reader.nextWindow(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? LocalTransactionWindow.WindowError, expected, file: file, line: line) }
        do { _ = try await reader.nextWindow(); XCTFail("Expected poisoned reader", file: file, line: line) }
        catch { XCTAssertEqual(error as? LocalTransactionWindow.WindowError, .failed, file: file, line: line) }
    }

    func testScopeBoundCheckpointsAndBoundedLRUAnchors() async throws {
        let id = UUID()
        let limits = LocalTransactionWindow.Limits(maxRows: 1)
        let reader = try LocalTransactionWindow(workspaceID: id, scope: "revision-and-range", limits: limits) { _ in
            Self.page([Self.row(0), Self.row(1)])
        }
        let first = try await reader.nextWindow()
        let checkpoint = try XCTUnwrap(first.continuation)
        XCTAssertThrowsError(try LocalTransactionWindow(workspaceID: id, scope: "different-range", limits: limits,
                                                       checkpoint: checkpoint) { _ in Self.page([]) })
        var anchors = LocalTransactionWindow.Anchors()
        for id in 0..<100 { anchors.insert(checkpoint, for: id) }
        XCTAssertEqual(anchors.count, 32)
        XCTAssertLessThanOrEqual(anchors.accountedBytes, 64 * 1_024)
        XCTAssertNil(anchors.checkpoint(for: 0))
        XCTAssertNotNil(anchors.checkpoint(for: 68))
        anchors.insert(checkpoint, for: 100)
        XCTAssertNil(anchors.checkpoint(for: 69))
        XCTAssertNotNil(anchors.checkpoint(for: 68))
        anchors.removeAll()
        XCTAssertEqual(anchors.count, 0)
        XCTAssertEqual(anchors.accountedBytes, 0)
    }

    func testNormalFiveHundredTwoPostingCandidatesFitAccountingBudget() async throws {
        let rows = (0..<500).map { index in
            LedgerTransaction(date: "2026-09-23", payee: "Synthetic", narration: "Lunch", tags: ["food"],
                postings: [LedgerPosting(account: "Expenses:Food", amount: 125, currency: "CNY"),
                           LedgerPosting(account: "Assets:Cash", amount: -125, currency: "CNY")],
                source: TransactionSource(file: "main.bean", line: index + 1, hash: "hash-\(index)"))
        }
        let reader = try reader([Self.page(rows)])
        let result = try await reader.nextWindow()
        XCTAssertEqual(result.transactions.count, 500)
        XCTAssertEqual(result.summary?.matchedCount, 500)
    }

    func testMidPageAndExactFinalEOFWithIndependentWindows() async throws {
        var limits = LocalTransactionWindow.Limits()
        limits.maxRows = 2
        let window = try reader([Self.page((0..<5).map { Self.row($0) })], limits: limits)
        let a = try await window.nextWindow()
        let b = try await window.nextWindow()
        let c = try await window.nextWindow()
        XCTAssertEqual(a.transactions.map(\.source.line), [1, 2])
        XCTAssertEqual(b.transactions.map(\.source.line), [3, 4])
        XCTAssertEqual(c.transactions.map(\.source.line), [5])
        XCTAssertFalse(a.isComplete)
        XCTAssertTrue(c.isComplete)
        XCTAssertEqual(c.summary?.fullRangeCount, 5)
        XCTAssertEqual(c.summary?.matchedCount, 5)
        XCTAssertEqual(c.summary?.visibleTransactions.count, 0)
        let after = try await window.nextWindow()
        XCTAssertTrue(after.transactions.isEmpty)
        XCTAssertTrue(after.isComplete)

        let exact = try reader([Self.page([Self.row(0), Self.row(1)])], limits: limits)
        let last = try await exact.nextWindow()
        XCTAssertTrue(last.isComplete)
    }

    func testEmptyAndUnmatchedPagesAreNotEOFAndTrailingNonmatchesAreEOF() async throws {
        var limits = LocalTransactionWindow.Limits()
        limits.maxRows = 1
        let filter = LedgerTransactionFilter(query: "needle")
        let window = try reader([
            Self.page([], next: "1"),
            Self.page([Self.row(0)], next: "2"),
            Self.page([Self.row(1, payee: "needle")], next: "3"),
            Self.page([Self.row(2)], next: "4"), Self.page([])
        ], filter: filter, limits: limits)
        let result = try await window.nextWindow()
        XCTAssertEqual(result.transactions.map(\.source.line), [2])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.summary?.fullRangeCount, 3)
        XCTAssertEqual(result.summary?.matchedCount, 1)
        let zero = try reader([Self.page([], next: "1"), Self.page([Self.row(0)])], filter: filter)
        let empty = try await zero.nextWindow()
        XCTAssertTrue(empty.transactions.isEmpty)
        XCTAssertTrue(empty.isComplete)
        XCTAssertEqual(empty.summary?.matchedCount, 0)
    }

    func testUnicodeUsesCanonicalSwiftFilter() async throws {
        let rows = [Self.row(0, payee: "✁‍✁"), Self.row(1, payee: "Café"),
                    Self.row(2, payee: "Cafe\u{301}"), Self.row(3, payee: "မြန်မာ"),
                    Self.row(4, payee: "İstanbul")]
        for query in ["✁", "CAFÉ", "မြ", "i", "#food Expenses"] {
            let filter = LedgerTransactionFilter(query: query, account: "Expenses", tags: ["food"])
            let window = try reader([Self.page(rows)], filter: filter)
            let result = try await window.nextWindow()
            XCTAssertEqual(result.transactions, rows.filter(filter.matches), query)
        }
    }

    func testByteWindowsAndOversizedSingleRow() async throws {
        var scanLimits = LocalTransactionScan.Limits()
        scanLimits.maxVisibleCount = 1
        var scan = try LocalTransactionScan(expectedRevision: "native", limits: scanLimits)
        let size = try XCTUnwrap(scan.consume(Self.page([Self.row(0)]), requestedCursor: nil)).visibleAccountedBytes
        var limits = LocalTransactionWindow.Limits()
        limits.maxBytes = size
        let window = try reader([Self.page([Self.row(0), Self.row(1)])], limits: limits)
        let first = try await window.nextWindow()
        XCTAssertEqual(first.accountedBytes, size)
        XCTAssertEqual(first.transactions.count, 1)
        XCTAssertFalse(first.isComplete)
        let last = try await window.nextWindow()
        XCTAssertEqual(last.transactions.count, 1)
        XCTAssertTrue(last.isComplete)
        limits.maxBytes = size - 1
        await expectError(.rowBytes, reader: try reader([Self.page([Self.row(0)])], limits: limits))
        await expectError(.candidateBytes, reader: try reader([
            Self.page([Self.row(0, narration: String(repeating: "x", count: 8 * 1_024 * 1_024))])
        ]))
        await expectError(.pageRows, reader: try reader([Self.page((0...500).map { Self.row($0) })]))
    }

    func testRevisionLockCyclesAndLimits() async throws {
        await expectError(.revisionMismatch, reader: try reader([Self.page([], next: "1"), Self.page([], revision: "changed")]))
        await expectError(.revisionMismatch, reader: try reader([Self.page([], revision: "")]))
        await expectError(.locked, reader: try reader([Self.page([], unlocked: false)]))
        await expectError(.locked, reader: try reader([Self.page([], next: "1"), Self.page([], unlocked: false)]))
        await expectError(.emptyCursor, reader: try reader([Self.page([], next: "")]))
        await expectError(.repeatedCursor, reader: try reader([Self.page([], next: "1"), Self.page([], next: "2"), Self.page([], next: "1")]))
        var limits = LocalTransactionWindow.Limits()
        limits.maxPages = 1
        await expectError(.pages, reader: try reader([Self.page([], next: "1"), Self.page([])], limits: limits))
        limits = .init()
        limits.maxCursorBytes = 128
        await expectError(.cursorBytes, reader: try reader([Self.page([], next: "1")], limits: limits))
        for invalid in [0, 1_001] {
            limits = .init()
            limits.maxRows = invalid
            XCTAssertThrowsError(try reader([], limits: limits))
        }
    }

    func testArithmeticValidationBeforeMatchingEvenForUnmatchedRow() async throws {
        let window = try reader([Self.page([Self.row(0, amount: Int.min)])], filter: .init(query: "absent"))
        do { _ = try await window.nextWindow(); XCTFail("Expected overflow") }
        catch { XCTAssertEqual(error as? LocalTransactionScan.ScanError, .arithmeticOverflow) }
    }

    func test100kStreamRevisionPinningSummaryAndNoOmissionsOrDuplicates() async throws {
        let workspace = UUID()
        let window = try LocalTransactionWindow(workspaceID: workspace) { request in
            XCTAssertEqual(request.workspaceID, workspace)
            XCTAssertEqual(request.limit, 500)
            let batch = request.cursor.flatMap(Int.init) ?? 0
            XCTAssertEqual(request.expectedRevision, batch == 0 ? nil : "native")
            return Self.page((batch * 500..<(batch + 1) * 500).map { Self.row($0) },
                             next: batch == 199 ? nil : String(batch + 1))
        }
        var expected = 1
        var windows = 0
        while true {
            let result = try await window.nextWindow()
            XCTAssertLessThanOrEqual(result.transactions.count, 1_000)
            XCTAssertLessThanOrEqual(result.accountedBytes, 4 * 1_024 * 1_024)
            for row in result.transactions {
                XCTAssertEqual(row.source.line, expected)
                expected += 1
            }
            windows += 1
            if result.isComplete {
                XCTAssertEqual(result.summary?.fullRangeCount, 100_000)
                XCTAssertEqual(result.summary?.matchedCount, 100_000)
                XCTAssertEqual(result.summary?.days.first?.signedExpense, 12_500_000)
                break
            }
            XCTAssertNil(result.summary)
        }
        XCTAssertEqual(expected, 100_001)
        XCTAssertEqual(windows, 100)
    }

    func testSparse100kStreamPreservesOrderAcrossMidPageWindows() async throws {
        var limits = LocalTransactionWindow.Limits()
        limits.maxRows = 137
        let window = try LocalTransactionWindow(workspaceID: UUID(), filter: .init(query: "needle"), limits: limits) { request in
            let batch = request.cursor.flatMap(Int.init) ?? 0
            return Self.page((batch * 500..<(batch + 1) * 500).map {
                Self.row($0, payee: $0 % 7 == 0 ? "needle" : "other")
            }, next: batch == 199 ? nil : String(batch + 1))
        }
        var nextIndex = 0
        var count = 0
        while true {
            let result = try await window.nextWindow()
            XCTAssertLessThanOrEqual(result.transactions.count, 137)
            for row in result.transactions {
                XCTAssertEqual(row.source.line, nextIndex + 1)
                nextIndex += 7
                count += 1
            }
            if result.isComplete {
                XCTAssertEqual(count, 14_286)
                XCTAssertEqual(result.summary?.matchedCount, count)
                XCTAssertEqual(result.summary?.fullRangeCount, 100_000)
                break
            }
        }
    }

    func testTenThousandPageBoundFailsExplicitlyInsteadOfDroppingCursorHistory() async throws {
        let window = try LocalTransactionWindow(workspaceID: UUID()) { request in
            let batch = request.cursor.flatMap(Int.init) ?? 0
            return Self.page([], next: String(batch + 1))
        }
        await expectError(.pages, reader: window)
    }

    func testCheckpointReplayFromMidPageAndAfterEmptyPagesDoesNotDuplicateSummary() async throws {
        var limits = LocalTransactionWindow.Limits()
        limits.maxRows = 2
        let workspace = UUID()
        let provider: LocalTransactionWindow.Provider = { request in
            let pages = [Self.page([], next: "1"), Self.page([], next: "2"),
                         Self.page((0..<5).map { Self.row($0) }, next: "3"), Self.page([Self.row(5)])]
            return pages[request.cursor.flatMap(Int.init) ?? 0]
        }
        let original = try LocalTransactionWindow(workspaceID: workspace, limits: limits, provider: provider)
        let first = try await original.nextWindow()
        let anchor = try XCTUnwrap(first.continuation)
        XCTAssertLessThanOrEqual(anchor.accountedBytes, 64 * 1_024)
        let second = try await original.nextWindow()
        let final = try await original.nextWindow()
        XCTAssertEqual(final.summary?.matchedCount, 6)
        let replay = try LocalTransactionWindow(workspaceID: workspace, limits: limits, checkpoint: anchor, provider: provider)
        let replaySecond = try await replay.nextWindow()
        let replayFinal = try await replay.nextWindow()
        XCTAssertEqual(replaySecond.transactions, second.transactions)
        XCTAssertEqual(replayFinal.transactions, final.transactions)
        XCTAssertNil(replayFinal.summary)
        XCTAssertTrue(replayFinal.isComplete)
        XCTAssertThrowsError(try LocalTransactionWindow(workspaceID: UUID(), limits: limits, checkpoint: anchor, provider: provider))
        let changed = try LocalTransactionWindow(workspaceID: workspace, limits: limits, checkpoint: anchor) { _ in
            Self.page([], revision: "changed")
        }
        await expectError(.revisionMismatch, reader: changed)
    }

    func testCheckpointAtPageBoundarySkipsEmptyPagesAndReplaysPinnedRevision() async throws {
        let workspace = UUID()
        var limits = LocalTransactionWindow.Limits()
        limits.maxRows = 1
        let provider: LocalTransactionWindow.Provider = { request in
            let pages = [Self.page([Self.row(0)], next: "1"), Self.page([], next: "2"),
                         Self.page([Self.row(1)], next: "3"), Self.page([Self.row(2)])]
            return pages[request.cursor.flatMap(Int.init) ?? 0]
        }
        let original = try LocalTransactionWindow(workspaceID: workspace, limits: limits, provider: provider)
        let first = try await original.nextWindow()
        let anchor = try XCTUnwrap(first.continuation)
        let replay = try LocalTransactionWindow(workspaceID: workspace, limits: limits, checkpoint: anchor) { request in
            XCTAssertEqual(request.expectedRevision, "native")
            return try await provider(request)
        }
        let second = try await replay.nextWindow()
        XCTAssertEqual(second.transactions.map(\.source.line), [2])
        let third = try await replay.nextWindow()
        XCTAssertEqual(third.transactions.map(\.source.line), [3])
        XCTAssertTrue(third.isComplete)
        XCTAssertNil(third.summary)
    }

    func testCheckpointSizeLimitIsExplicit() async throws {
        var limits = LocalTransactionWindow.Limits()
        limits.maxRows = 1
        // Retained filter is valid for scan state, but too large for a navigation anchor.
        let filter = LedgerTransactionFilter(query: String(repeating: " ", count: 65_536))
        let window = try reader([Self.page([Self.row(0), Self.row(1)])], filter: filter, limits: limits)
        await expectError(.checkpointBytes, reader: window)
    }

    func testInvalidationRevokesCachedRowsAndInFlightResponse() async throws {
        var limits = LocalTransactionWindow.Limits()
        limits.maxRows = 1
        let cached = try reader([Self.page([Self.row(0), Self.row(1)])], limits: limits)
        _ = try await cached.nextWindow()
        await cached.invalidate()
        await expectError(.failed, reader: cached)

        let gate = Gate()
        let pending = try LocalTransactionWindow(workspaceID: UUID()) { _ in
            await gate.wait()
            return Self.page([Self.row(0)])
        }
        let task = Task { try await pending.nextWindow() }
        while !(await gate.started) { await Task.yield() }
        await pending.invalidate()
        await gate.release()
        do { _ = try await task.value; XCTFail("Expected invalidated response") }
        catch { XCTAssertEqual(error as? LocalTransactionWindow.WindowError, .failed) }
    }

    actor Gate {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testCancellationAndReentrantCall() async throws {
        let gate = Gate()
        let window = try LocalTransactionWindow(workspaceID: UUID()) { _ in
            await gate.wait()
            return Self.page([Self.row(0)])
        }
        let task = Task { try await window.nextWindow() }
        while !(await gate.started) { await Task.yield() }
        do { _ = try await window.nextWindow(); XCTFail("Expected busy") }
        catch { XCTAssertEqual(error as? LocalTransactionWindow.WindowError, .busy) }
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await window.nextWindow(); XCTFail("Expected failed") }
        catch { XCTAssertEqual(error as? LocalTransactionWindow.WindowError, .failed) }
    }
}
