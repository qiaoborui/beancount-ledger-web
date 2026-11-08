import Foundation
import XCTest
@testable import LedgerMobile

/// The engine's writer lane keeps a publication's canonical export off the read
/// path: committed reads run while the export is in flight, writers still take
/// turns, and a failed export leaves the published state untouched.
final class LocalLedgerEngineConcurrencyTests: XCTestCase {
    /// Wraps the real exporter so a test can pause it, fail it or count overlap.
    private actor ExportProbe {
        private var armed = false
        private var failing = false
        private var delay: UInt64 = 0
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var started = 0
        private(set) var paused = false
        private(set) var concurrent = 0
        private(set) var peak = 0

        /// Pause the next exports until `release()`.
        func arm() { armed = true }
        func failExports() { failing = true }
        func succeedExports() { failing = false }
        func delayExports(nanoseconds: UInt64) { delay = nanoseconds }

        func release() {
            armed = false
            paused = false
            for waiter in releaseWaiters { waiter.resume() }
            releaseWaiters.removeAll()
        }

        func waitUntilPaused() async {
            if paused { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        fileprivate func enter() async throws {
            started += 1
            concurrent += 1
            peak = max(peak, concurrent)
            if armed {
                paused = true
                for waiter in startWaiters { waiter.resume() }
                startWaiters.removeAll()
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if failing {
                concurrent -= 1
                throw LocalLedgerError.operationFailed("synthetic export failure")
            }
        }

        fileprivate func leave() { concurrent -= 1 }

        nonisolated var exporter: EmbeddedLocalLedgerEngine.CanonicalExporter {
            { workspace, entrypoint, output in
                try await self.enter()
                do {
                    let descriptor = try await EmbeddedBeancountValidator.shared.exportCanonical(
                        workspace: workspace, entryFile: entrypoint, to: output)
                    await self.leave()
                    return descriptor
                } catch {
                    await self.leave()
                    throw error
                }
            }
        }
    }

    private actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    private func entry(_ n: Int) -> LedgerTransactionEntry {
        LedgerTransactionEntry(date: "2026-09-01", payee: "Synthetic", narration: "Row \(n)", postings: [
            .init(account: "Expenses:Food", amount: "1", currency: "CNY"),
            .init(account: "Assets:Cash", amount: "-1", currency: "CNY")])
    }

    func testReadDuringExportReturnsOldRevisionWithoutWaiting() async throws {
        #if os(iOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EngineLane-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ExportProbe()
        let engine = EmbeddedLocalLedgerEngine(gate: LocalModelRequestGate(), lane: LocalModelWriterLane(),
            exporter: probe.exporter)
        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: engine)
        let descriptor = try await catalog.create(name: "Lane")
        let repository = catalog.repository(for: descriptor)
        _ = try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-01", valuationCurrency: "CNY")
        try await repository.addTransaction(entry: entry(0))
        let before = try await repository.transactionPage(limit: 50)
        XCTAssertEqual(before.transactions.count, 1)

        await probe.arm()
        let next = entry(1)
        let write = Task { try await repository.addTransaction(entry: next) }
        await probe.waitUntilPaused()
        let done = Flag()
        let read = Task {
            let page = try await repository.transactionPage(limit: 50)
            await done.set()
            return page
        }
        let deadline = Date().addingTimeInterval(15)
        while await !done.isSet, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let finishedDuringExport = await done.isSet
        let exportStillPaused = await probe.paused
        await probe.release()
        let during = try await read.value
        try await write.value

        XCTAssertTrue(finishedDuringExport, "a committed read must not wait for the publication's export")
        XCTAssertTrue(exportStillPaused)
        XCTAssertEqual(during.revision, before.revision, "the read must see the generation before the write")
        XCTAssertEqual(during.transactions.count, 1)

        // The published generation serves through the promoted, pre-warmed model.
        let after = try await repository.transactionPage(limit: 50)
        XCTAssertNotEqual(after.revision, before.revision)
        XCTAssertEqual(Set(after.transactions.map(\.narration)), ["Row 0", "Row 1"])
        XCTAssertTrue(after.transactions.allSatisfy { !$0.source.file.hasPrefix("/") })
        let detail = try await repository.globalTransactions()
        XCTAssertEqual(detail.transactions.count, 2)
        XCTAssertTrue(detail.transactions.allSatisfy { $0.editableEntry != nil })
        #else
        throw XCTSkip("Requires app-linked Go and Beancount runtimes")
        #endif
    }

    func testFailedExportLeavesPublishedStateAndLocksAsBefore() async throws {
        #if os(iOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EngineLaneFailure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ExportProbe()
        let engine = EmbeddedLocalLedgerEngine(gate: LocalModelRequestGate(), lane: LocalModelWriterLane(),
            exporter: probe.exporter)
        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: engine)
        let descriptor = try await catalog.create(name: "Lane failure")
        let repository = catalog.repository(for: descriptor)
        _ = try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-01", valuationCurrency: "CNY")
        try await repository.addTransaction(entry: entry(0))
        let before = try await repository.transactionPage(limit: 50)
        let beforeRevision = try await repository.workspace.currentRevision()

        await probe.failExports()
        do {
            try await repository.addTransaction(entry: entry(1))
            XCTFail("a failed export published the write")
        } catch {}
        let afterRevision = try await repository.workspace.currentRevision()
        XCTAssertEqual(afterRevision?.id, beforeRevision?.id)
        let retained = await engine.hasRetainedStage(ledgerRoot: repository.workspace.rootDirectory,
            entrypoint: descriptor.entrypoint)
        XCTAssertFalse(retained, "a failed validation must not leave a stage to promote")
        let unchanged = try await repository.transactionPage(limit: 50)
        XCTAssertEqual(unchanged.revision, before.revision)
        XCTAssertEqual(unchanged.transactions.count, 1)

        // The lane and the gate were released: the next write goes through.
        await probe.succeedExports()
        try await repository.addTransaction(entry: entry(2))
        let recovered = try await repository.transactionPage(limit: 50)
        XCTAssertEqual(Set(recovered.transactions.map(\.narration)), ["Row 0", "Row 2"])
        #else
        throw XCTSkip("Requires app-linked Go and Beancount runtimes")
        #endif
    }

    func testConcurrentValidationsExportOneAtATime() async throws {
        #if os(iOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EngineLaneSerial-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ExportProbe()
        await probe.delayExports(nanoseconds: 150_000_000)
        let engine = EmbeddedLocalLedgerEngine(gate: LocalModelRequestGate(), lane: LocalModelWriterLane(),
            exporter: probe.exporter)
        // Managed layout: <ledger>/generations/<id>/workspace beside <ledger>/runtime.
        var workspaces: [URL] = []
        for index in 0..<2 {
            let workspace = root.appendingPathComponent("ledger-\(index)/generations/initial/workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try Data("""
            option "operating_currency" "CNY"
            2026-01-01 open Assets:Cash CNY
            2026-01-01 open Expenses:Food CNY
            2026-09-0\(index + 1) * "Synthetic" "Distinct \(index)"
              Expenses:Food  \(index + 1) CNY
              Assets:Cash

            """.utf8).write(to: workspace.appendingPathComponent("main.bean"))
            workspaces.append(workspace)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for workspace in workspaces {
                group.addTask {
                    let runtime = workspace.deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().appendingPathComponent("runtime")
                    try await engine.validateCanonical(workspaceRoot: workspace.path,
                        runtimeRoot: runtime.path, entrypoint: "main.bean")
                }
            }
            try await group.waitForAll()
        }
        let started = await probe.started
        let peak = await probe.peak
        XCTAssertEqual(started, 2, "both distinct trees must be exported")
        XCTAssertEqual(peak, 1, "writers must still take turns on the scratch directory")
        #else
        throw XCTSkip("Requires app-linked Go and Beancount runtimes")
        #endif
    }
}
