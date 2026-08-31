import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerWidgetSnapshotTests: XCTestCase {
    func testBuilderKeepsExpenseAndSelectableBalancesWithoutIncomeData() throws {
        let ledger = try JSONDecoder().decode(
            LedgerBootstrap.self,
            from: Data(LedgerModelsTests.bootstrapJSON.utf8)
        )
        let snapshot = LedgerWidgetSnapshotBuilder.make(
            report: Self.report,
            ledger: ledger,
            importDocuments: Self.importDocuments,
            fallbackDate: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.expense.amount, 555_180)
        XCTAssertEqual(snapshot.expense.transactionCount, 9)
        XCTAssertEqual(snapshot.expense.yearOverYearPercentage ?? 0, -0.125_976, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.expense.categories.map(\.label), ["居住", "餐饮", "出行"])
        XCTAssertTrue(snapshot.accounts.allSatisfy {
            $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")
        })
        XCTAssertFalse(snapshot.accounts.contains { $0.account.hasPrefix("Income:") })
        XCTAssertEqual(snapshot.imports.map(\.provider), ["alipay", "wechat"])
        XCTAssertEqual(snapshot.imports.first?.latestCoverageDate, "2026-08-28")

        let encoded = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.lowercased().contains("income"))
        XCTAssertFalse(json.contains("工资"))
        XCTAssertFalse(json.contains("private-alipay.csv"))
        XCTAssertFalse(json.contains("transactions/2026/documents"))
        XCTAssertFalse(json.contains("2026-08-29T08:00:00Z"))
    }

    func testStoreRoundTripsCurrentSchemaAndRejectsUnsupportedSchemas() throws {
        let suiteName = "ledger-widget-snapshot-tests-\(UUID().uuidString)"
        let store = LedgerWidgetSnapshotStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let current = LedgerWidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 123),
            expense: LedgerWidgetExpenseSnapshot(
                periodTitle: "2026年8月",
                start: "2026-08-01",
                end: "2026-09-01",
                currency: "CNY",
                amount: 555_180,
                transactionCount: 9,
                yearOverYearPercentage: -0.12,
                categories: [],
                dailySeries: []
            ),
            accounts: []
        )
        try store.save(current)
        XCTAssertEqual(store.load(), current)

        for unsupportedVersion in [-1, 0, 99] {
            try store.save(
                LedgerWidgetSnapshot(
                    schemaVersion: unsupportedVersion,
                    updatedAt: current.updatedAt,
                    expense: current.expense,
                    accounts: current.accounts,
                    imports: current.imports
                )
            )
            XCTAssertNil(store.load())
        }

        store.clear()
        XCTAssertNil(store.load())
    }

    func testStoreMigratesSchemaOneWithoutDiscardingCachedExpenseAndAccounts() throws {
        let suiteName = "ledger-widget-snapshot-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = LedgerWidgetSnapshotStore(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let updatedAt = Date(timeIntervalSince1970: 123)
        let expense = LedgerWidgetExpenseSnapshot(
            periodTitle: "2026年8月",
            start: "2026-08-01",
            end: "2026-09-01",
            currency: "CNY",
            amount: 555_180,
            transactionCount: 9,
            yearOverYearPercentage: -0.12,
            categories: [],
            dailySeries: []
        )
        let account = LedgerWidgetAccountSnapshot(
            account: "Assets:Bank:CMB",
            label: "招商银行",
            group: "资产",
            currency: "CNY",
            balance: 1_234_500,
            valuationCurrency: "CNY",
            valuation: 1_234_500
        )
        let legacySnapshot = SchemaOneSnapshot(
            schemaVersion: 1,
            updatedAt: updatedAt,
            expense: expense,
            accounts: [account]
        )
        defaults.set(try JSONEncoder().encode(legacySnapshot), forKey: LedgerWidgetSnapshotStore.snapshotKey)

        let migrated = try XCTUnwrap(store.load())

        XCTAssertEqual(migrated.schemaVersion, LedgerWidgetSnapshot.currentSchemaVersion)
        XCTAssertEqual(migrated.updatedAt, updatedAt)
        XCTAssertEqual(migrated.expense, expense)
        XCTAssertEqual(migrated.accounts, [account])
        XCTAssertEqual(migrated.imports, [])
        XCTAssertNil(migrated.importsUpdatedAt)

        let rewrittenData = try XCTUnwrap(defaults.data(forKey: LedgerWidgetSnapshotStore.snapshotKey))
        let rewritten = try JSONDecoder().decode(LedgerWidgetSnapshot.self, from: rewrittenData)
        XCTAssertEqual(rewritten, migrated)
        XCTAssertEqual(rewritten.schemaVersion, LedgerWidgetSnapshot.currentSchemaVersion)
    }

    private static let report = LedgerHomeReport(
        start: "2026-08-01",
        end: "2026-09-01",
        currency: "CNY",
        current: LedgerHomeReportPeriod(
            kpis: LedgerHomeReportExpenseKPI(expense: 555_180, transactionCount: 9),
            categorySeries: [
                LedgerCategorySeries(account: "Expenses:Food", alias: "餐饮", label: "餐饮", total: 84_780, values: []),
                LedgerCategorySeries(account: "Expenses:Travel", alias: "出行", label: "出行", total: 57_600, values: []),
                LedgerCategorySeries(account: "Expenses:Housing", alias: "居住", label: "居住", total: 380_000, values: []),
                LedgerCategorySeries(account: "Expenses:Education", alias: "教育", label: "教育", total: 32_800, values: []),
            ]
        ),
        previous: LedgerHomeReportPeriod(
            kpis: LedgerHomeReportExpenseKPI(expense: 635_200, transactionCount: 12),
            categorySeries: []
        ),
        dailyExpenseSeries: [
            LedgerDailyExpense(date: "2026-08-28", weekday: "周五", amount: 32_800, txCount: 1),
            LedgerDailyExpense(date: "2026-08-09", weekday: "周日", amount: 380_000, txCount: 1),
        ],
        generatedAt: "2026-08-31T05:30:00Z"
    )

    private static let importDocuments = [
        LedgerImportDocument(
            provider: "alipay",
            dateStart: "2026-08-01",
            dateEnd: "2026-08-20",
            modTime: "2026-08-30T08:00:00Z"
        ),
        LedgerImportDocument(
            provider: "alipay",
            dateStart: "2026-08-01",
            dateEnd: "2026-08-28",
            modTime: "2026-08-29T08:00:00Z"
        ),
        LedgerImportDocument(
            provider: "wechat",
            dateStart: "2026-08-01",
            dateEnd: "2026-08-25",
            modTime: "2026-08-26T08:00:00Z"
        ),
        LedgerImportDocument(
            provider: nil,
            dateStart: nil,
            dateEnd: nil,
            modTime: "2026-08-31T08:00:00Z"
        ),
    ]

    private struct SchemaOneSnapshot: Encodable {
        let schemaVersion: Int
        let updatedAt: Date
        let expense: LedgerWidgetExpenseSnapshot
        let accounts: [LedgerWidgetAccountSnapshot]
    }
}
