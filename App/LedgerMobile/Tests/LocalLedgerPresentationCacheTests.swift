import Foundation
import XCTest
@testable import LedgerMobile

final class LocalLedgerPresentationCacheTests: XCTestCase {
    private final class ScanCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var scans = 0
        var value: Int { lock.withLock { scans } }
        func increment() { lock.withLock { scans += 1 } }
    }

    private final class CountingFileManager: FileManager, @unchecked Sendable {
        let counter: ScanCounter
        init(counter: ScanCounter) { self.counter = counter; super.init() }
        override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                          options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
            if url.lastPathComponent == "workspace" { counter.increment() }
            return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        }
    }

    func testCachedBootstrapValidatesTheSnapshotTreeOnce() async throws {
        let (descriptor, original, engine) = try await fixture()
        let changes = (0..<1_000).map { LocalLedgerWorkspace.Change.write(Data("; safe performance fixture".utf8), to: "entries/\($0).bean") }
        let previous = try await original.currentRevision()
        try await original.commit(expectedRevisionID: previous?.id, changes: changes) { _ in }
        let seed = LocalLedgerRepository(descriptor: descriptor, workspace: original, engine: engine, validator: { _, _ in })
        _ = try await load(seed)
        let scans = ScanCounter()
        let workspace = LocalLedgerWorkspace(rootDirectory: original.rootDirectory,
            fileManager: CountingFileManager(counter: scans))
        let coldEngine = Engine()
        let reopened = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: coldEngine, validator: { _, _ in })
        let started = ContinuousClock.now
        _ = try await load(reopened)
        print("Cached bootstrap: \(started.duration(to: .now)), snapshot scans: \(scans.value)")
        XCTAssertEqual(scans.value, 1, "Validate the immutable tree once per snapshot read")
        let calls = await coldEngine.calls
        XCTAssertEqual(calls, 0)
    }

    private actor Gate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testBootstrapReturnsItsPinnedRevisionWhenPublicationOverlapsTheRead() async throws {
        let (descriptor, workspace, engine) = try await fixture()
        let current = try await workspace.currentRevision()
        let oldRevision = try XCTUnwrap(current)
        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace,
            engine: engine, validator: { _, _ in })
        let entered = expectation(description: "bootstrap engine reading old generation")
        let gate = Gate(entered)
        await engine.pauseNextRead(gate)
        let reading = Task {
            try await repository.bootstrapSnapshot(start: "2026-09-01", end: "2026-10-01",
                today: "2026-09-16", valuationCurrency: "CNY")
        }
        await fulfillment(of: [entered], timeout: 3)
        let next = try await workspace.commit(expectedRevisionID: oldRevision.id,
            changes: [.write(Data("; concurrently published".utf8), to: "main.bean")]) { _ in }
        await gate.release()
        let snapshot = try await reading.value
        XCTAssertEqual(snapshot.revisionID, oldRevision.id)
        XCTAssertNotEqual(snapshot.revisionID, next.id)
        await engine.configure(expense: 777)
        let refreshed = try await repository.bootstrapSnapshot(start: "2026-09-01", end: "2026-10-01",
            today: "2026-09-16", valuationCurrency: "CNY")
        XCTAssertEqual(refreshed.revisionID, next.id)
        XCTAssertEqual(refreshed.payload.summary.expense, 777)
    }

    func testOptionalCacheCannotFailUsableTypedBootstrap() async throws {
        struct EnvelopeEngine: LocalLedgerEngine {
            func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data { Data("{}".utf8) }
            func response(_ request: LocalLedgerEngineRequest) async throws -> LocalLedgerResponse {
                LocalLedgerResponse(envelope: Data(#"{"ok":true,"status":200,"result":{"start":"2026-09-01","end":"2026-10-01","summary":{"currency":"CNY","income":0,"expense":100,"net":-100},"accountBalances":[],"transactions":[],"accounts":[],"valuationCurrency":"CNY","sensitiveUnlocked":true,"ignored":1e1000}}"#.utf8))
            }
        }
        let (descriptor, workspace, _) = try await fixture()
        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace,
            engine: EnvelopeEngine(), validator: { _, _ in })
        let payload = try await load(repository)
        XCTAssertEqual(payload.summary.expense, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.rootDirectory.appendingPathComponent(".bootstrap-presentation.json").path))
    }

    private actor Engine: LocalLedgerEngine {
        private(set) var calls = 0
        var unlocked = true
        var expense = 100
        private var gate: Gate?
        func pauseNextRead(_ gate: Gate) { self.gate = gate }
        func configure(unlocked: Bool = true, expense: Int = 100) {
            self.unlocked = unlocked
            self.expense = expense
        }
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            guard request.path == "/api/ledger/bootstrap" else { return Data("{}".utf8) }
            calls += 1
            if let gate { self.gate = nil; await gate.wait() }
            return try JSONSerialization.data(withJSONObject: [
                "start": request.query["start"] ?? "", "end": request.query["end"] ?? "",
                "summary": ["currency": "CNY", "income": 0, "expense": expense, "net": -expense],
                "accountBalances": [], "transactions": [], "accounts": [],
                "valuationCurrency": request.query["valuationCurrency"] ?? "CNY", "sensitiveUnlocked": unlocked,
            ])
        }
    }

    private func fixture() async throws -> (LocalLedgerDescriptor, LocalLedgerWorkspace, Engine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PresentationCache-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = LocalLedgerWorkspace(rootDirectory: root)
        try await workspace.commit(changes: [.write(Data("; fixture".utf8), to: "main.bean")]) { _ in }
        return (LocalLedgerDescriptor(id: UUID(), name: "Fixture", entrypoint: "main.bean", createdAt: Date()), workspace, Engine())
    }

    private func load(_ repository: LocalLedgerRepository, start: String = "2026-09-01", end: String = "2026-10-01",
                      today: String = "2026-09-16", currency: String = "CNY") async throws -> LedgerBootstrap {
        try await repository.bootstrap(start: start, end: end, today: today, valuationCurrency: currency)
    }

    func testPresentationSurvivesRepositoryRecreationAndRevisionChangeInvalidatesIt() async throws {
        let (descriptor, workspace, engine) = try await fixture()
        let first = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine, validator: { _, _ in })
        let initial = try await load(first)
        let reopenedEngine = Engine()
        await reopenedEngine.configure(expense: 777)
        let reopened = LocalLedgerRepository(descriptor: descriptor,
            workspace: LocalLedgerWorkspace(rootDirectory: workspace.rootDirectory), engine: reopenedEngine, validator: { _, _ in })
        let restored = try await load(reopened)
        XCTAssertEqual(restored.summary, initial.summary)
        let coldCalls = await reopenedEngine.calls
        XCTAssertEqual(coldCalls, 0)
        let current = try await workspace.currentRevision()
        try await workspace.commit(expectedRevisionID: current?.id, changes: [.write(Data("; changed".utf8), to: "main.bean")]) { _ in }
        let updated = try await load(reopened)
        XCTAssertEqual(updated.summary.expense, 777)
        let changedCalls = await reopenedEngine.calls
        XCTAssertEqual(changedCalls, 1)
    }

    func testDateRangeTodayAndCurrencyEachInvalidatePresentation() async throws {
        let (descriptor, workspace, engine) = try await fixture()
        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine, validator: { _, _ in })
        _ = try await load(repository)
        _ = try await load(repository)
        let initialCalls = await engine.calls
        XCTAssertEqual(initialCalls, 1)
        _ = try await load(repository, start: "2026-08-01")
        _ = try await load(repository, start: "2026-08-01", end: "2026-09-01")
        _ = try await load(repository, start: "2026-08-01", end: "2026-09-01", today: "2026-09-17")
        _ = try await load(repository, start: "2026-08-01", end: "2026-09-01", today: "2026-09-17", currency: "USD")
        let changedCalls = await engine.calls
        XCTAssertEqual(changedCalls, 5)
    }

    func testCorruptMismatchedAndUnsupportedRecordsFallBackToTheLedger() async throws {
        let (descriptor, workspace, engine) = try await fixture()
        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine, validator: { _, _ in })
        let path = workspace.rootDirectory.appendingPathComponent(".bootstrap-presentation.json")
        _ = try await load(repository)
        let valid = try Data(contentsOf: path)
        try Data("truncated".utf8).write(to: path)
        _ = try await load(repository)
        for (key, value) in [("formatVersion", 999 as Any), ("applicationVersion", "old build"),
                             ("ledgerID", UUID().uuidString), ("revisionID", UUID().uuidString),
                             ("entrypoint", "other.bean"), ("payload", Data("{}".utf8).base64EncodedString())] {
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            record[key] = value
            try JSONSerialization.data(withJSONObject: record).write(to: path)
            _ = try await load(repository)
        }
        let calls = await engine.calls
        XCTAssertEqual(calls, 8)
    }

    func testLockedPayloadIsNeverPersistedAndCacheStaysOutsideExport() async throws {
        let (descriptor, workspace, engine) = try await fixture()
        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine, validator: { _, _ in })
        let path = workspace.rootDirectory.appendingPathComponent(".bootstrap-presentation.json")
        await engine.configure(unlocked: false)
        _ = try await load(repository)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        await engine.configure()
        _ = try await load(repository)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let exported = try await repository.exportLedger()
        defer { try? FileManager.default.removeItem(at: exported) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent(path.lastPathComponent).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exported.path), ["main.bean"])
    }

    func testCacheSymlinkIsIgnoredAndItsTargetIsPreserved() async throws {
        let (descriptor, workspace, engine) = try await fixture()
        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine, validator: { _, _ in })
        let target = workspace.rootDirectory.appendingPathComponent("sentinel")
        let bytes = Data("preserve this file".utf8)
        try bytes.write(to: target)
        let path = workspace.rootDirectory.appendingPathComponent(".bootstrap-presentation.json")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        _ = try await load(repository)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path.path), target.path)
    }
}
