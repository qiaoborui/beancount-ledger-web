import Foundation
import XCTest
@testable import LedgerMobile

@MainActor
final class LocalEventReportExportTests: XCTestCase {
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
                tags: id == 2 ? ["other"] : ["trip"], postings: [.init(account: "Expenses:Food", amount: 125, currency: "CNY")],
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
                         tag: String = "trip", validate: @MainActor () throws -> Void = {}) async throws -> LocalEventReportExport {
        try await LocalEventReportExport.prepare(repository: repository, tag: tag, start: "2026-09-01", end: "2026-10-01",
            expectedRevisionID: revision, accountLabels: [:], parentDirectory: parent, validate: validate)
    }
    private func expected(_ rows: [LedgerTransaction], tag: String) throws -> String {
        let report = EventTagCalculator.generateReport(tag: tag, from: rows)
        var formatter = try EventReportMarkdownStream(summary: .init(tag: tag, transactionCount: report.transactions.count,
            totalExpense: report.totalExpense, totalIncome: report.totalIncome, netSpend: report.netSpend,
            currency: report.currency, startDate: report.startDate, endDate: report.endDate, daysCount: report.daysCount,
            dailyAverage: report.dailyAverage), categories: report.categoryBreakdown)
        var bytes = Data()
        for row in report.transactions { try formatter.append(row) { bytes.append($0) } }
        try formatter.finish { bytes.append($0) }
        return String(decoding: bytes, as: UTF8.self)
    }
    func testCompleteTagAndEmptyExportsMatchFormatterAndDoNotAuthorizeWrites() async throws {
        for tag in ["trip", "missing", ""] {
            let (repository, _, revision, parent) = try await fixture()
            let export = try await prepare(repository, revision, parent, tag: tag)
            XCTAssertEqual(export.count, tag == "trip" ? 2 : 0)
            XCTAssertEqual(try String(contentsOf: export.url, encoding: .utf8), try expected((1...3).map(Engine.row), tag: tag))
            let authority = await repository.presentedRevisionID
            XCTAssertNil(authority)
            export.discard()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        }
    }
    func testMultipageExportAndPartialOutputFailureCleanup() async throws {
        for fail in [false, true] {
            let (repository, engine, revision, parent) = try await fixture()
            let rows = (1...350).map(Engine.row)
            await engine.setRows(rows)
            if fail { await engine.fail(5) }
            do {
                let export = try await prepare(repository, revision, parent)
                XCTAssertFalse(fail)
                XCTAssertEqual(export.count, 349)
                XCTAssertEqual(try String(contentsOf: export.url, encoding: .utf8), try expected(rows, tag: "trip"))
                export.discard()
            } catch { XCTAssertTrue(fail, "\(error)") }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        }
    }
    func testNativeRevisionChangeAndOwnerRevocationRejectCompleteOrPartialFile() async throws {
        for operation in 0..<4 {
            let (repository, engine, revision, parent) = try await fixture()
            if operation == 0 {
                await engine.mismatch()
                do { _ = try await prepare(repository, revision, parent); XCTFail("model changed") }
                catch { XCTAssertEqual(error as? LocalLedgerError, .staleTransactionCursor) }
            } else {
                let entered = expectation(description: "event export second pass")
                await engine.pause(2, entered: entered)
                var allowed = true
                let task = Task { try await prepare(repository, revision, parent, validate: {
                    if !allowed { throw CancellationError() }
                }) }
                await fulfillment(of: [entered], timeout: 3)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 1)
                if operation == 1 { allowed = false }
                else if operation == 2 { task.cancel() }
                else {
                    _ = try await repository.workspace.commit(expectedRevisionID: revision,
                        changes: [.write(Data("; changed".utf8), to: "main.bean")]) { _ in }
                }
                await engine.resume()
                do { _ = try await task.value; XCTFail("revoked export returned") } catch {}
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        }
    }
    func testSynchronousAdoptionCanRevokeBeforeAsyncReturn() async throws {
        let (repository, _, revision, parent) = try await fixture()
        var adopted: LocalEventReportExport?
        let export = try await LocalEventReportExport.prepare(repository: repository, tag: "trip",
            start: "2026-09-01", end: "2026-10-01", expectedRevisionID: revision, accountLabels: [:], parentDirectory: parent,
            adopt: { value in adopted = value; value.discard() }, validate: {})
        XCTAssertTrue(adopted === export)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }
}
