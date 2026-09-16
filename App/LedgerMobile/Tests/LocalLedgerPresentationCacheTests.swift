import Foundation
import XCTest
@testable import LedgerMobile

final class LocalLedgerPresentationCacheTests: XCTestCase {
    private actor Engine: LocalLedgerEngine {
        private(set) var calls = 0
        var unlocked = true
        var expense = 100
        func configure(unlocked: Bool = true, expense: Int = 100) {
            self.unlocked = unlocked
            self.expense = expense
        }
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            guard request.path == "/api/ledger/bootstrap" else { return Data("{}".utf8) }
            calls += 1
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
