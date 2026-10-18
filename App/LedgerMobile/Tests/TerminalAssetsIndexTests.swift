import XCTest
@testable import LedgerMobile

/// The assets report previously recomputed its totals from a filter+grouping on
/// every accessor and scanned every balance per account row. `TerminalAssetsIndex`
/// must produce exactly the values those expressions produced.
final class TerminalAssetsIndexTests: XCTestCase {
    private func balance(_ account: String, _ valuation: Int, missing: Bool = false) -> AccountBalance {
        AccountBalance(account: account, currency: "CNY", amount: valuation,
            valuationCurrency: "CNY", valuation: valuation, valuationMissing: missing ? true : nil)
    }

    private func analysis(_ balances: [AccountBalance]) -> LedgerAssetsAnalysis {
        LedgerAssetsAnalysis(accountBalances: balances, accounts: [], netWorthHistory: [],
            monthEndNetWorth: [], netWorthWindows: nil, comparisons: nil, valuationCurrency: "CNY")
    }

    func testIndexMatchesTheReferenceComputation() {
        let balances = [
            balance("Assets:Bank:Daily", 1_000_00),
            balance("Assets:Broker:Index", 250_000_00),
            balance("Assets:Cash", 12_00),
            balance("Assets:Cash", 8_00),          // same account, two currencies
            balance("Assets:Receivable", 0),
            balance("Liabilities:CreditCard", -30_000_00),
            balance("Liabilities:Loan", 5_000_00),  // positive liability
            balance("Expenses:Food", 999_00),       // filtered out
            balance("Income:Salary", 999_00),       // filtered out
            balance("Assets:Unpriced", 7_000_00, missing: true),
        ]
        let index = TerminalAssetsIndex.index(for: analysis(balances))

        // Reference: the expressions the view used before the index existed.
        let referenceBalances = balances.filter {
            $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")
        }
        let referenceValuations = Dictionary(grouping: referenceBalances.filter { $0.valuationMissing != true },
            by: \.account).mapValues { $0.reduce(0) { $0 + $1.valuation } }
        let referenceAssets = referenceValuations.filter { $0.key.hasPrefix("Assets:") }.values.reduce(0, +)
        let referenceDebt = referenceValuations.filter { $0.key.hasPrefix("Liabilities:") }.values.reduce(0) { $0 + abs($1) }

        XCTAssertEqual(index.balances.map(\.account), referenceBalances.map(\.account))
        XCTAssertEqual(index.valuations, referenceValuations)
        XCTAssertEqual(index.assets, referenceAssets)
        XCTAssertEqual(index.debt, referenceDebt)
        XCTAssertEqual(index.missing, referenceBalances.contains { $0.valuationMissing == true })
        XCTAssertEqual(index.accountNames, Array(Set(referenceBalances.map(\.account))).sorted())
        for name in index.accountNames {
            XCTAssertEqual(index.balancesByAccount[name], referenceBalances.filter { $0.account == name })
        }
    }

    func testRepeatedAccessReusesTheSameIndex() {
        let data = analysis([balance("Assets:Bank", 100)])
        XCTAssertEqual(TerminalAssetsIndex.index(for: data), TerminalAssetsIndex.index(for: data))
    }
}
