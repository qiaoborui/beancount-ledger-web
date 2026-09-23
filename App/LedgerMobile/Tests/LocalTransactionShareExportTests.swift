import Foundation
import XCTest
@testable import LedgerMobile

@MainActor
final class LocalTransactionShareExportTests: XCTestCase {
    private actor Engine: LocalLedgerEngine {
        var requests = 0
        var rows: [LedgerTransaction] = (1...3).map(Engine.row)
        var mismatchOnSecondPass = false
        func setRows(_ rows: [LedgerTransaction]) { self.rows = rows }
        func mismatch() { mismatchOnSecondPass = true }
        var failAt: Int?
        var entered: XCTestExpectation?
        var continuation: CheckedContinuation<Void, Never>?
        var pauseAt: Int?
        func fail(_ request: Int) { failAt = request }
        func pause(_ request: Int, entered: XCTestExpectation) { pauseAt = request; self.entered = entered }
        func resume() { continuation?.resume(); continuation = nil }
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            requests += 1
            if requests == pauseAt {
                await withCheckedContinuation { continuation = $0; entered?.fulfill() }
            }
            if requests == failAt { throw LocalLedgerError.operationFailed("Synthetic failed second pass") }
            let offset = Int(request.query["cursor"] ?? "0") ?? 0
            let end = min(offset + 150, rows.count)
            let page = Array(rows[offset..<end])
            return try JSONSerialization.data(withJSONObject: ["revision": mismatchOnSecondPass && requests > 1 ? "changed-native" : "synthetic-native",
                "transactions": JSONSerialization.jsonObject(with: JSONEncoder().encode(page)),
                "nextCursor": end < rows.count ? String(end) as Any : NSNull(), "sensitiveUnlocked": true])
        }
        nonisolated static func row(_ id: Int) -> LedgerTransaction {
            LedgerTransaction(date: "2026-09-23", payee: id == 2 ? "Needle" : "Synthetic", narration: "row-\(id)",
                postings: [.init(account: "Expenses:Food", amount: 125, currency: "CNY")],
                source: .init(file: "main.bean", line: id, hash: "row-\(id)"))
        }
    }
    private func fixture() async throws -> (LocalLedgerRepository, Engine, UUID, URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = LocalLedgerWorkspace(rootDirectory: root.appendingPathComponent("workspace"))
        let revision = try await workspace.commit(changes: [.write(Data("; synthetic".utf8), to: "main.bean")]) { _ in }
        let exports = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
        let engine = Engine()
        let descriptor = LocalLedgerDescriptor(id: UUID(), name: "Synthetic", entrypoint: "main.bean", createdAt: Date())
        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine, validator: { _, _ in })
        return (repository, engine, revision.id, exports)
    }
    private func prepare(_ repository: LocalLedgerRepository, _ revision: UUID, _ parent: URL,
                         ids: Set<String>? = nil, filter: LedgerTransactionFilter = .init(),
                         validate: @MainActor () throws -> Void = {}) async throws -> LocalTransactionShareExport {
        try await LocalTransactionShareExport.prepare(repository: repository, start: "2026-09-01", end: "2026-10-01",
            filter: filter, selectedIDs: ids, expectedRevisionID: revision, currency: "CNY", accountLabels: [:],
            parentDirectory: parent, validate: validate)
    }
    func testExactSubsetIntersectionAndEmptyExportsNeverAdvanceWriteAuthority() async throws {
        for ids: Set<String>? in [nil, [], [Engine.row(1).id, Engine.row(2).id]] {
            let (repository, _, revision, parent) = try await fixture()
            let export = try await prepare(repository, revision, parent, ids: ids, filter: .init(query: "Needle"))
            let rows = (1...3).map(Engine.row).filter { $0.payee == "Needle" && (ids?.contains($0.id) ?? true) }
            XCTAssertEqual(export.count, rows.count)
            XCTAssertEqual(try String(contentsOf: export.url, encoding: .utf8),
                TransactionShareTextFormatter.format(transactions: rows, currency: "CNY"))
            let presented = await repository.presentedRevisionID
            XCTAssertNil(presented)
            export.discard()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        }
    }
    func testSingleReceiptRejectsExtremePostingWithoutTrappingOrLeavingFile() async throws {
        let (repository, engine, revision, parent) = try await fixture()
        let transaction = LedgerTransaction(date: "2026-09-23", payee: "Synthetic", narration: "Extreme",
            postings: [.init(account: "Expenses:Food", amount: 1, currency: "CNY"),
                       .init(account: "Assets:Cash", amount: Int.min, currency: "CNY"),
                       .init(account: "Equity:Opening", amount: Int.max, currency: "CNY")],
            source: .init(file: "main.bean", line: 1, hash: "extreme"))
        await engine.setRows([transaction])
        do { _ = try await prepare(repository, revision, parent); XCTFail("Unrepresentable abs accepted") }
        catch { XCTAssertEqual(error as? TransactionShareTextStream.StreamError, .arithmeticOverflow) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testMultiplePagesWindowsAndDatesExactlyMatchLegacyAndPartialFailureCleansUp() async throws {
        for fail in [false, true] {
            let (repository, engine, revision, parent) = try await fixture()
            let rows = (1...350).map { id in
                LedgerTransaction(date: id <= 175 ? "2026-09-23" : "2026-09-22", payee: "Synthetic", narration: "row-\(id)",
                    postings: [.init(account: "Expenses:Food", amount: 125, currency: "CNY")],
                    source: .init(file: "main.bean", line: id, hash: "row-\(id)"))
            }
            await engine.setRows(rows)
            if fail { await engine.fail(5) } // Three first-pass pages; fail after second-pass output exists.
            do {
                let export = try await prepare(repository, revision, parent)
                XCTAssertFalse(fail)
                XCTAssertEqual(export.count, 350)
                XCTAssertEqual(try String(contentsOf: export.url, encoding: .utf8),
                    TransactionShareTextFormatter.format(transactions: rows, currency: "CNY"))
                export.discard()
            } catch { XCTAssertTrue(fail, "\(error)") }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        }
    }

    func testNativeRevisionMismatchBetweenPassesRejectsExport() async throws {
        let (repository, engine, revision, parent) = try await fixture()
        await engine.mismatch()
        do { _ = try await prepare(repository, revision, parent); XCTFail("Changed native model accepted") }
        catch { XCTAssertEqual(error as? LocalLedgerError, .staleTransactionCursor) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testSynchronousAdoptionOwnsCompletedFileBeforeAsyncReturn() async throws {
        let (repository, _, revision, parent) = try await fixture()
        var adopted: LocalTransactionShareExport?
        let export = try await LocalTransactionShareExport.prepare(repository: repository,
            start: "2026-09-01", end: "2026-10-01", filter: .init(), selectedIDs: nil,
            expectedRevisionID: revision, currency: "CNY", accountLabels: [:], parentDirectory: parent,
            adopt: { value in
                adopted = value
                XCTAssertTrue(FileManager.default.fileExists(atPath: value.url.path))
                // Model synchronous owner revocation before the awaiting task
                // can resume; completed result must not postpone file deletion.
                value.discard()
                XCTAssertFalse(FileManager.default.fileExists(atPath: value.url.path))
            }, validate: {})
        XCTAssertTrue(adopted === export)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testSecondPassFailureDeletesPartialExport() async throws {
        let (repository, engine, revision, parent) = try await fixture()
        await engine.fail(2)
        do { _ = try await prepare(repository, revision, parent); XCTFail("Failed pass published") } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }
    func testOwnerRevocationCancellationAndRevisionChangeDuringSecondPassDiscardEverything() async throws {
        for operation in 0..<3 {
            let (repository, engine, revision, parent) = try await fixture()
            let entered = expectation(description: "second pass paused")
            await engine.pause(2, entered: entered)
            var allowed = true
            let task = Task { try await prepare(repository, revision, parent, validate: {
                if !allowed { throw CancellationError() }
            }) }
            await fulfillment(of: [entered], timeout: 3)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 1)
            if operation == 0 { allowed = false }
            else if operation == 1 { task.cancel() }
            else {
                _ = try await repository.workspace.commit(expectedRevisionID: revision,
                    changes: [.write(Data("; changed".utf8), to: "main.bean")]) { _ in }
            }
            await engine.resume()
            do { _ = try await task.value; XCTFail("Revoked export published") } catch { }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        }
    }
}
