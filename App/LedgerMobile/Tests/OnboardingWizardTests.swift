import Foundation
import XCTest
@testable import LedgerMobile

final class OnboardingWizardTests: XCTestCase {
    private final class MockEngine: LocalLedgerEngine {
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            Data("{}".utf8)
        }
    }

    private func tempRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OnboardingTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testCreateCustomLedgerWithAccountsAndInitialBalances() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: MockEngine(), validator: { _, _ in })
        let accounts = [
            OnboardingAccountSelection(name: "微信零钱", account: "Assets:Wallet:WeChat:LingQian", currency: "CNY", initialBalance: "250.00", isLiability: false),
            OnboardingAccountSelection(name: "招商银行", account: "Assets:Bank:CMB", currency: "CNY", initialBalance: "8888.50", isLiability: false),
            OnboardingAccountSelection(name: "招行信用卡", account: "Liabilities:CreditCard:CMB", currency: "CNY", initialBalance: "1200.00", isLiability: true),
            OnboardingAccountSelection(name: "现金", account: "Assets:Cash:CNY", currency: "CNY", initialBalance: nil, isLiability: false)
        ]
        let categories = [
            OnboardingCategorySelection(name: "餐饮美食", account: "Expenses:Food", currency: "CNY"),
            OnboardingCategorySelection(name: "工资薪酬", account: "Income:Salary", currency: "CNY")
        ]

        let descriptor = try await catalog.createCustom(
            name: "测试开账账本",
            currency: "CNY",
            accounts: accounts,
            categories: categories
        )

        let repository = catalog.repository(for: descriptor)
        let draft = try await repository.readFile(path: "main.bean")
        let content = draft.text

        // Check options & commodity
        XCTAssertTrue(content.contains("option \"title\" \"测试开账账本\""))
        XCTAssertTrue(content.contains("option \"operating_currency\" \"CNY\""))
        XCTAssertTrue(content.contains("1970-01-01 commodity CNY"))

        // Check accounts & aliases
        XCTAssertTrue(content.contains("open Assets:Wallet:WeChat:LingQian CNY"))
        XCTAssertTrue(content.contains("alias: \"微信零钱\""))
        XCTAssertTrue(content.contains("open Assets:Bank:CMB CNY"))
        XCTAssertTrue(content.contains("alias: \"招商银行\""))
        XCTAssertTrue(content.contains("open Liabilities:CreditCard:CMB CNY"))
        XCTAssertTrue(content.contains("alias: \"招行信用卡\""))
        XCTAssertTrue(content.contains("open Equity:Opening-Balances"))
        XCTAssertTrue(content.contains("alias: \"期初余额\""))

        // Check categories
        XCTAssertTrue(content.contains("open Expenses:Food CNY"))
        XCTAssertTrue(content.contains("alias: \"餐饮美食\""))
        XCTAssertTrue(content.contains("open Income:Salary CNY"))
        XCTAssertTrue(content.contains("alias: \"工资薪酬\""))

        // Check opening balance transactions
        XCTAssertTrue(content.contains("* \"期初余额\" \"初始化账户余额 - 微信零钱\""))
        XCTAssertTrue(content.contains("Assets:Wallet:WeChat:LingQian  250.00 CNY"))
        XCTAssertTrue(content.contains("Equity:Opening-Balances  -250.00 CNY"))

        XCTAssertTrue(content.contains("* \"期初余额\" \"初始化账户余额 - 招商银行\""))
        XCTAssertTrue(content.contains("Assets:Bank:CMB  8888.50 CNY"))
        XCTAssertTrue(content.contains("Equity:Opening-Balances  -8888.50 CNY"))

        // Liability credit card opening balance should be negative on liability account
        XCTAssertTrue(content.contains("* \"期初余额\" \"初始化账户欠款 - 招行信用卡\""))
        XCTAssertTrue(content.contains("Liabilities:CreditCard:CMB  -1200.00 CNY"))
        XCTAssertTrue(content.contains("Equity:Opening-Balances  1200.00 CNY"))

        // Cash has no initial balance, so no opening tx for cash
        XCTAssertFalse(content.contains("初始化账户余额 - 现金"))
    }

    func testCreateCustomLedgerWithMultipleCurrencies() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: MockEngine(), validator: { _, _ in })
        let accounts = [
            OnboardingAccountSelection(name: "招行储蓄卡", account: "Assets:Bank:CMB", currency: "CNY", initialBalance: "1000.00"),
            OnboardingAccountSelection(name: "汇丰港币", account: "Assets:Bank:HSBC", currency: "HKD", initialBalance: "5000.00"),
            OnboardingAccountSelection(name: "美元备用金", account: "Assets:Cash:USD", currency: "USD", initialBalance: "200.00")
        ]

        let descriptor = try await catalog.createCustom(
            name: "多币种账本",
            currency: "CNY",
            accounts: accounts,
            categories: []
        )

        let repository = catalog.repository(for: descriptor)
        let draft = try await repository.readFile(path: "main.bean")
        let content = draft.text

        // Commodities for all 3 currencies registered
        XCTAssertTrue(content.contains("commodity CNY"))
        XCTAssertTrue(content.contains("commodity HKD"))
        XCTAssertTrue(content.contains("commodity USD"))

        // Multi-currency opening balances balance independently
        XCTAssertTrue(content.contains("Assets:Bank:HSBC  5000.00 HKD"))
        XCTAssertTrue(content.contains("Equity:Opening-Balances  -5000.00 HKD"))
        XCTAssertTrue(content.contains("Assets:Cash:USD  200.00 USD"))
        XCTAssertTrue(content.contains("Equity:Opening-Balances  -200.00 USD"))
    }
}
