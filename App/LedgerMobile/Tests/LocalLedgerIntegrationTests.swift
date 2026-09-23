import Foundation
import XCTest
#if canImport(BeancountRuntime)
import BeancountRuntime
#endif
@testable import LedgerMobile

/// Exercises the production Go + CPython bridges in the signed app host.
/// Every file belongs to a unique temporary fixture; no configured ledger is read.
final class LocalLedgerIntegrationTests: XCTestCase {
    func testValidationOnlyBridgeKeepsCanonicalDiagnosticsAndReadModel() async throws {
        #if os(iOS) && canImport(BeancountRuntime)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ValidationOnly-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main.bean")
        let valid = """
        plugin "beancount.plugins.auto_accounts"
        2026-01-01 * "Synthetic precision fixture"
          Assets:Cash -1.234567 CNY
          Expenses:Food 1.234567 CNY

        """
        try valid.write(to: main, atomically: true, encoding: .utf8)
        try await EmbeddedBeancountValidator.shared.validate(workspace: root)
        let model = try await EmbeddedBeancountValidator.shared.canonicalModel(workspace: root)
        XCTAssertTrue(String(decoding: model, as: UTF8.self).contains("1.234567"))
        // Call the native symbol too: its success payload must contain no model.
        let pointer = root.path.withCString { workspace in
            "main.bean".withCString { BRValidateOnly(workspace, $0) }
        }
        let raw = try XCTUnwrap(pointer)
        defer { BRFree(raw) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["errors"])
        XCTAssertEqual((object["errors"] as? [Any])?.count, 0)
        try valid.replacingOccurrences(of: "Food 1.234567", with: "Food 1.000000")
            .write(to: main, atomically: true, encoding: .utf8)
        var messages: [String] = []
        do {
            try await EmbeddedBeancountValidator.shared.validate(workspace: root)
            XCTFail("Validation-only accepted an unbalanced transaction")
        } catch let error as EmbeddedBeancountValidator.ValidationError { messages.append(error.message) }
        do {
            _ = try await EmbeddedBeancountValidator.shared.canonicalModel(workspace: root)
            XCTFail("Canonical load accepted an unbalanced transaction")
        } catch let error as EmbeddedBeancountValidator.ValidationError { messages.append(error.message) }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first, messages.last)
        #else
        throw XCTSkip("Requires the app-linked canonical Beancount runtime")
        #endif
    }

    func testCanonicalStreamExportIsSmallExclusiveAndKeepsSourceUntouched() async throws {
        #if os(iOS) && canImport(BeancountRuntime)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("StreamIntegration-" + UUID().uuidString)
        let source = base.appendingPathComponent("workspace")
        let output = base.appendingPathComponent("canonical.records")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let text = "2000-01-01 open Assets:Cash CNY\n"
        try text.write(to: source.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        let result = try await EmbeddedBeancountValidator.shared.exportCanonical(workspace: source, to: output)
        XCTAssertEqual(result.entries, 1)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertEqual(result.sha256.count, 64)
        let exported = try Data(contentsOf: output)
        XCTAssertEqual(result.bytes, exported.count)
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("end_entry"))
        do {
            _ = try await EmbeddedBeancountValidator.shared.exportCanonical(workspace: source, to: output)
            XCTFail("Existing export overwritten")
        } catch is EmbeddedBeancountValidator.ValidationError { }
        XCTAssertEqual(try Data(contentsOf: output), exported)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("main.bean"), encoding: .utf8), text)
        #else
        throw XCTSkip("Requires embedded canonical runtime")
        #endif
    }

    func testCanonicalOfflineCreateReadAddEditDeleteAndReopen() async throws {
        #if os(iOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalIntegration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = LocalLedgerCatalog(rootDirectory: root)
        let descriptor = try await catalog.create(name: "Offline integration")
        let repository = catalog.repository(for: descriptor)
        let empty = try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-15", valuationCurrency: "CNY")
        XCTAssertTrue(empty.transactions.isEmpty)
        XCTAssertTrue(empty.sensitiveUnlocked)
        XCTAssertFalse(empty.accounts.isEmpty)

        func entry(_ amount: String, credit: String, narration: String) -> LedgerTransactionEntry {
            LedgerTransactionEntry(date: "2026-09-15", payee: "Offline fixture", narration: narration,
                metadata: ["file": .string("receipt.pdf")], tags: ["offline"], postings: [
                    .init(account: "Expenses:Food", amount: amount, currency: "CNY"),
                    .init(account: "Assets:Cash", amount: credit, currency: "CNY")
                ])
        }
        try await repository.addTransaction(entry: entry("12.34", credit: "-12.34", narration: "created offline"))
        let initial = try await repository.globalTransactions()
        XCTAssertEqual(initial.transactions.count, 1)
        let transaction = try XCTUnwrap(initial.transactions.first)
        XCTAssertEqual(transaction.narration, "created offline")
        XCTAssertEqual(transaction.metadata?["file"], .string("receipt.pdf"))
        XCTAssertFalse(transaction.source.file.hasPrefix("/"))

        let beforeInvalid = try await repository.workspace.currentRevision()
        do {
            try await repository.addTransaction(entry: entry("12.34", credit: "-11.00", narration: "must reject"))
            XCTFail("Canonical validation accepted an unbalanced transaction")
        } catch { }
        let afterInvalid = try await repository.workspace.currentRevision()
        XCTAssertEqual(beforeInvalid?.id, afterInvalid?.id)

        try await repository.updateTransaction(source: transaction.source,
            entry: entry("15.67", credit: "-15.67", narration: "edited offline"))
        let updated = try await repository.globalTransactions()
        XCTAssertEqual(updated.transactions.count, 1)
        XCTAssertEqual(updated.transactions.first?.narration, "edited offline")
        XCTAssertEqual(updated.transactions.first?.editableEntry?.metadata["file"], .string("receipt.pdf"))
        _ = try await repository.homeReport(start: "2026-09-01", end: "2026-10-01", valuationCurrency: "CNY")
        _ = try await repository.dashboard(start: "2026-09-01", end: "2026-10-01", valuationCurrency: "CNY")
        _ = try await repository.incomeStatement(start: "2026-09-01", end: "2026-10-01", valuationCurrency: "CNY")
        _ = try await repository.accountDetail(account: "Assets:Cash", currency: "CNY", start: "2026-09-01", end: "2026-10-01")
        _ = try await repository.investments()
        _ = try await repository.runBQL(query: "SELECT account, sum(value) AS total FROM postings GROUP BY account", valuationCurrency: "CNY")

        let reopened = LocalLedgerCatalog(rootDirectory: root)
        let descriptors = try await reopened.list()
        XCTAssertEqual(descriptors, [descriptor])
        let restored = reopened.repository(for: descriptor)
        let restoredTransactions = try await restored.globalTransactions()
        XCTAssertEqual(restoredTransactions.transactions.first?.narration, "edited offline")
        try await restored.deleteTransaction(source: XCTUnwrap(restoredTransactions.transactions.first).source, reason: "Integration fixture cleanup")
        let deleted = try await restored.globalTransactions()
        XCTAssertTrue(deleted.transactions.isEmpty)
        let exported = try await restored.exportLedger()
        defer { try? FileManager.default.removeItem(at: exported) }
        let saved = try String(contentsOf: exported.appendingPathComponent("transactions/2026/09.bean"), encoding: .utf8)
        XCTAssertTrue(saved.contains("file: \"receipt.pdf\""), "Stored metadata must retain the exact user value, including in recoverable deletion comments")
        try await EmbeddedBeancountValidator.shared.validate(workspace: exported, entryFile: descriptor.entrypoint)
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }
}
