import Foundation
import XCTest
@testable import LedgerMobile

/// Exercises the production Go + CPython bridges in the signed app host.
/// Every file belongs to a unique temporary fixture; no configured ledger is read.
final class LocalLedgerIntegrationTests: XCTestCase {
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
                metadata: [:], tags: ["offline"], postings: [
                    .init(account: "Expenses:Food", amount: amount, currency: "CNY"),
                    .init(account: "Assets:Cash", amount: credit, currency: "CNY")
                ])
        }
        try await repository.addTransaction(entry: entry("12.34", credit: "-12.34", narration: "created offline"))
        let initial = try await repository.globalTransactions()
        XCTAssertEqual(initial.transactions.count, 1)
        let transaction = try XCTUnwrap(initial.transactions.first)
        XCTAssertEqual(transaction.narration, "created offline")
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
        try await EmbeddedBeancountValidator.shared.validate(workspace: exported, entryFile: descriptor.entrypoint)
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }
}
