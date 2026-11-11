import Foundation
import XCTest
@testable import LedgerMobile

final class OverviewSectionsTests: XCTestCase {
    func testSectionsKeepOrderDropRepeatsAndNeverGoBlank() {
        XCTAssertEqual(OverviewSection.normalized([.creditCards, .retention, .creditCards]), [.creditCards, .retention])
        XCTAssertEqual(OverviewSection.normalized([]), OverviewSection.defaultSections)
        XCTAssertEqual(OverviewSection.defaultSections, OverviewSection.allCases)
    }

    func testBootstrapDecodesCreditCardsAndIncomeStatementAndToleratesOlderServers() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(LedgerModelsTests.bootstrapJSON.utf8)) as? [String: Any])
        let legacy = try JSONDecoder().decode(LedgerBootstrap.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(legacy.creditCards.isEmpty)
        XCTAssertNil(legacy.incomeStatement)

        object["creditCards"] = [[
            "account": "Liabilities:CMB", "alias": "招行", "label": "CMB", "balance": -120000, "outstanding": 120000,
            "periodSpend": 50000, "periodRepayments": 0, "billCycleSpend": 30000, "billCycleStart": "2026-08-17",
            "billCycleEnd": "2026-09-17", "statementDate": "2026-09-18", "dueDate": "2026-10-05",
            "txCount": 3, "repaymentCount": 0, "lastActivityDate": NSNull(),
        ]]
        // The bootstrap's statement has no range and carries fields the overview ignores.
        object["incomeStatement"] = [
            "income": [["account": "Income:Salary", "label": "Salary", "amount": 900000, "children": [], "depth": 0, "txCount": 1]],
            "expense": [], "totalIncome": 900000, "totalExpense": 0, "expenseAnalytics": NSNull(),
            "topPayees": [["payee": "超市", "amount": 4000, "txCount": 2]],
            "topPaymentAccounts": [], "netIncome": 900000, "valuationCurrency": "CNY",
        ]
        let full = try JSONDecoder().decode(LedgerBootstrap.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(full.creditCards.map(\.outstanding), [120000])
        XCTAssertEqual(full.creditCards.first?.alias, "招行")
        XCTAssertEqual(full.incomeStatement?.income.map(\.account), ["Income:Salary"])
        XCTAssertEqual(full.incomeStatement?.topPayees.first?.txCount, 2)

        let replaced = full.replacingTransactions(with: [])
        XCTAssertEqual(replaced.creditCards, full.creditCards)
        XCTAssertEqual(replaced.incomeStatement, full.incomeStatement)
    }

    func testCreditCardSummaryKeepsCardsWithDebtOrBillSpendAndCountsDaysToDue() throws {
        let cards = [
            card("A", outstanding: 50000, billCycleSpend: 0, due: "2026-09-05"),
            card("B", outstanding: 0, billCycleSpend: 1200, due: "2026-09-10"),
            card("C", outstanding: 0, billCycleSpend: 0, due: "2026-09-10"),
            card("D", outstanding: 900, billCycleSpend: 0, due: "2026-08-30"),
        ]
        let summary = try XCTUnwrap(OverviewCreditCardSummary(cards: cards, today: "2026-08-31"))
        XCTAssertEqual(summary.rows.map(\.id), ["A", "B", "D"])
        XCTAssertEqual(summary.rows.map(\.daysUntilDue), [5, 10, -1])
        XCTAssertEqual(summary.totalOutstanding, 50900)
        XCTAssertNil(OverviewCreditCardSummary(cards: [cards[2]], today: "2026-08-31"))
    }

    func testIncomeSharesFoldTheTailIntoOtherAndAddUpToTheWhole() throws {
        let statement = LedgerPeriodIncomeStatement(income: (1...7).map { index in
            LedgerIncomeNode(account: "Income:I\(index)", alias: index == 1 ? "工资" : nil, label: "I\(index)",
                             amount: index * 100, children: [], depth: 0, txCount: 1)
        } + [LedgerIncomeNode(account: "Income:Zero", alias: nil, label: "Zero", amount: 0, children: [], depth: 0, txCount: 0)])
        let shares = try XCTUnwrap(OverviewRankedShares.income(statement, limit: 3))
        XCTAssertEqual(shares.total, 2800)
        XCTAssertEqual(shares.rows.map(\.label), ["I7", "I6", "I5", "其他"])
        XCTAssertEqual(shares.rows.last?.amount, 1000)
        XCTAssertEqual(shares.rows.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-9)
        XCTAssertNil(OverviewRankedShares.income(LedgerPeriodIncomeStatement()))
        XCTAssertNil(OverviewRankedShares.income(nil))
    }

    func testPayeesDoNotFoldAndNameTheServerPlaceholder() throws {
        let statement = LedgerPeriodIncomeStatement(topPayees: [
            LedgerPayeeAnalytics(payee: "（无商户）", amount: 300, txCount: 4),
            LedgerPayeeAnalytics(payee: "超市", amount: 500, txCount: 2),
            LedgerPayeeAnalytics(payee: "咖啡", amount: 100, txCount: 1),
        ])
        let shares = try XCTUnwrap(OverviewRankedShares.payees(statement, limit: 2))
        XCTAssertEqual(shares.rows.map(\.label), ["超市", "未填商户"])
        XCTAssertEqual(shares.rows.map(\.count), [2, 4])
    }

    func testCurrencyExposureGroupsAssetsByOwnCurrencyAndNamesUnvaluedOnes() throws {
        let balances = [
            balance("Assets:Bank", "CNY", amount: 600000, valuation: 600000),
            balance("Assets:Wallet", "CNY", amount: 100000, valuation: 100000),
            balance("Assets:Broker", "USD", amount: 10000, valuation: 300000),
            balance("Assets:Coins", "BTC", amount: 1, valuation: 0, missing: true),
            balance("Liabilities:Card", "CNY", amount: -50000, valuation: -50000),
        ]
        let exposure = try XCTUnwrap(OverviewCurrencyExposure(balances: balances))
        XCTAssertEqual(exposure.slices.map(\.currency), ["CNY", "USD"])
        XCTAssertEqual(exposure.total, 1_000_000)
        XCTAssertEqual(exposure.slices.first?.share ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertEqual(exposure.unvaluedCurrencies, ["BTC"])
        XCTAssertNil(OverviewCurrencyExposure(balances: Array(balances.prefix(2))))
    }

    private func card(_ account: String, outstanding: Int, billCycleSpend: Int, due: String) -> LedgerCreditCard {
        LedgerCreditCard(account: account, alias: nil, label: account, outstanding: outstanding, periodSpend: 0,
                         billCycleSpend: billCycleSpend, statementDate: "2026-08-18", dueDate: due)
    }

    private func balance(_ account: String, _ currency: String, amount: Int, valuation: Int, missing: Bool = false) -> AccountBalance {
        AccountBalance(account: account, currency: currency, amount: amount, valuationCurrency: "CNY",
                       valuation: valuation, valuationMissing: missing)
    }
}
