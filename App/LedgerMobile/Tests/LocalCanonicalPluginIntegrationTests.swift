import Foundation
import XCTest
@testable import LedgerMobile

final class LocalCanonicalPluginIntegrationTests: XCTestCase {
    func testPluginAccountsPricesAndEditingUseCanonicalSnapshot() async throws {
        #if os(iOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CanonicalPlugins-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("""
        option "operating_currency" "USD"
        plugin "beancount.plugins.auto_accounts"
        plugin "beancount.plugins.implicit_prices"
        2026-09-01 custom "budget" Expenses:Food "monthly" 100.00 USD
        2026-09-01 * "Plugin fixture" "Buy stock"
          file: "receipt.pdf"
          paid: 20.00 USD
          Assets:Stock  2 HOOL {10 USD}
          Assets:Cash  -20 USD

        """.utf8).write(to: source.appendingPathComponent("main.bean"))
        let catalog = LocalLedgerCatalog(rootDirectory: root.appendingPathComponent("managed"))
        let descriptor = try await catalog.importLedger(from: source, name: "Plugin fixture")
        let repository = catalog.repository(for: descriptor)
        let initial = try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-15", valuationCurrency: "USD")
        XCTAssertEqual(Set(initial.accounts.map(\.account)), ["Assets:Stock", "Assets:Cash"])
        XCTAssertFalse(initial.prices.isEmpty, "implicit_prices must reach the valuation model")
        XCTAssertEqual(initial.valuationCurrency, "USD")
        let stock = try XCTUnwrap(initial.accountBalances.first { $0.account == "Assets:Stock" && $0.currency == "HOOL" })
        XCTAssertEqual(stock.amount, 200, "Synthetic canonical stock: \(stock); prices: \(initial.prices); transaction: \(initial.transactions)")
        XCTAssertEqual(stock.valuation, 2000, "Synthetic canonical stock: \(stock); prices: \(initial.prices)")
        XCTAssertFalse(stock.valuationMissing ?? false)
        XCTAssertEqual(initial.balanceSheetTotals.netWorth, 0)
        let transaction = try XCTUnwrap(initial.transactions.first)
        XCTAssertEqual(transaction.source.file, "main.bean")
        XCTAssertEqual(transaction.metadata?["file"], .string("receipt.pdf"))
        XCTAssertEqual(transaction.metadata?["paid"], .string("20.00 USD"))
        let reportData = try await repository.workspace.withCurrentSnapshot { _, snapshot in
            try await EmbeddedLocalLedgerEngine.shared.dispatch(.init(
                workspaceRoot: snapshot.path,
                runtimeRoot: repository.workspace.rootDirectory.appendingPathComponent("runtime").path,
                entrypoint: descriptor.entrypoint, method: "GET", path: "/api/ledger/home-report",
                query: ["start": "2026-09-01", "end": "2026-10-01", "valuationCurrency": "USD"]))
        }
        struct BudgetResult: Decodable {
            struct Budget: Decodable { let configured: Bool; let amount: Int; let currency: String }
            let budget: Budget
        }
        let budget = try JSONDecoder().decode(BudgetResult.self, from: reportData).budget
        XCTAssertTrue(budget.configured)
        XCTAssertEqual(budget.amount, 10000)
        XCTAssertEqual(budget.currency, "USD")
        try await repository.addTransactionTags(sources: [transaction.source], tags: ["verified"])
        let updated = try await repository.globalTransactions()
        XCTAssertEqual(updated.transactions.count, 1)
        let edited = try XCTUnwrap(updated.transactions.first)
        XCTAssertTrue(edited.tags?.contains("verified") ?? false)
        XCTAssertEqual(edited.metadata?["file"], .string("receipt.pdf"))
        XCTAssertEqual(edited.metadata?["paid"], .string("20.00 USD"))
        try await repository.deleteTransaction(source: edited.source, reason: "Synthetic regression cleanup")
        let deleted = try await repository.globalTransactions()
        XCTAssertTrue(deleted.transactions.isEmpty)
        #else
        throw XCTSkip("Requires app-linked Go and Beancount runtimes")
        #endif
    }
}
