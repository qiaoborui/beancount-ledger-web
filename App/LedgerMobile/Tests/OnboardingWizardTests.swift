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

    func testCreateCustomLedgerGeneratesImportTemplates() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: MockEngine(), validator: { _, _ in })
        let accounts = [
            OnboardingAccountSelection(name: "支付宝余额", account: "Assets:Wallet:Alipay:Balance", currency: "CNY"),
            OnboardingAccountSelection(name: "微信零钱", account: "Assets:Wallet:WeChat:LingQian", currency: "CNY"),
            OnboardingAccountSelection(name: "工行储蓄卡", account: "Assets:Bank:ICBC", currency: "CNY"),
            OnboardingAccountSelection(name: "招行信用卡", account: "Liabilities:CreditCard:CMB", currency: "CNY", isLiability: true)
        ]
        let categories = [
            OnboardingCategorySelection(name: "餐饮美食", account: "Expenses:Food", currency: "CNY"),
            OnboardingCategorySelection(name: "日用百货", account: "Expenses:Shopping", currency: "CNY")
        ]

        let descriptor = try await catalog.createCustom(
            name: "导入测试账本",
            currency: "CNY",
            accounts: accounts,
            categories: categories
        )

        let workspace = await catalog.workspace(for: descriptor)

        // Verify Alipay config generated
        let alipayData = try await workspace.readFile(at: "imports/alipay-config.yaml")
        let alipayText = String(decoding: alipayData, as: UTF8.self)
        XCTAssertTrue(alipayText.contains("title: 支付宝账单导入配置"))
        XCTAssertTrue(alipayText.contains("Assets:Wallet:Alipay:Balance"))
        XCTAssertTrue(alipayText.contains("Assets:Bank:ICBC"))
        XCTAssertTrue(alipayText.contains("Liabilities:CreditCard:CMB"))
        XCTAssertTrue(alipayText.contains("Expenses:Food"))

        // Verify WeChat config generated
        let wechatData = try await workspace.readFile(at: "imports/wechat-config.yaml")
        let wechatText = String(decoding: wechatData, as: UTF8.self)
        XCTAssertTrue(wechatText.contains("title: 微信支付账单导入配置"))
        XCTAssertTrue(wechatText.contains("Assets:Wallet:WeChat:LingQian"))
        XCTAssertTrue(wechatText.contains("Assets:Bank:ICBC"))
        XCTAssertTrue(wechatText.contains("Liabilities:CreditCard:CMB"))
        XCTAssertTrue(wechatText.contains("Expenses:Food"))
    }

    func testCategoryPresetsTaxonomyAndSearch() {
        let expenseSections = CategoryPresets.sections(for: .expense)
        let incomeSections = CategoryPresets.sections(for: .income)

        // Comprehensive categories taxonomy
        XCTAssertGreaterThanOrEqual(expenseSections.count, 14)
        XCTAssertGreaterThanOrEqual(incomeSections.count, 7)

        // Verify key categories exist
        XCTAssertTrue(expenseSections.contains { $0.code == "Food" })
        XCTAssertTrue(expenseSections.contains { $0.code == "Shopping" })
        XCTAssertTrue(expenseSections.contains { $0.code == "Transport" })
        XCTAssertTrue(expenseSections.contains { $0.code == "Health" })
        XCTAssertTrue(expenseSections.contains { $0.code == "Education" })
        XCTAssertTrue(expenseSections.contains { $0.code == "Pets" })
        XCTAssertTrue(expenseSections.contains { $0.code == "Vehicle" })

        XCTAssertTrue(incomeSections.contains { $0.code == "Career" })
        XCTAssertTrue(incomeSections.contains { $0.code == "Freelance" })
        XCTAssertTrue(incomeSections.contains { $0.code == "Investment" })
        XCTAssertTrue(incomeSections.contains { $0.code == "Refund" })

        // Test search
        let cmbSearch = AccountPresets.search(query: "CMB")
        XCTAssertFalse(cmbSearch.isEmpty)
        XCTAssertTrue(cmbSearch.contains { $0.code == "CMB" })

        let wechatSearch = AccountPresets.search(query: "微信")
        XCTAssertFalse(wechatSearch.isEmpty)
        XCTAssertTrue(wechatSearch.contains { $0.name.contains("微信") })
    }

    func testCatalogUpdateLedgerNameAndEntrypoint() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: MockEngine(), validator: { _, _ in })
        let original = try await catalog.create(name: "原始账本", currency: "CNY")

        let updated = try await catalog.update(ledgerID: original.id, name: "修改后的账本")
        XCTAssertEqual(updated.name, "修改后的账本")
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.entrypoint, "main.bean")

        let list = try await catalog.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.name, "修改后的账本")
    }

    func testCatalogDeleteLedger() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: MockEngine(), validator: { _, _ in })
        let l1 = try await catalog.create(name: "账本 1", currency: "CNY")
        let l2 = try await catalog.create(name: "账本 2", currency: "CNY")

        var list = try await catalog.list()
        XCTAssertEqual(list.count, 2)

        try await catalog.delete(ledgerID: l1.id)

        list = try await catalog.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, l2.id)

        let deletedDir = root.appendingPathComponent(l1.id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedDir.path))
    }

    func testCatalogUpdateValidation() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: MockEngine(), validator: { _, _ in })
        let original = try await catalog.create(name: "测试账本", currency: "CNY")

        // Empty name throws
        do {
            _ = try await catalog.update(ledgerID: original.id, name: "   ")
            XCTFail("Should throw on empty name")
        } catch LocalLedgerError.invalidConfiguration {
            // expected
        }

        // Non-existent entrypoint file throws
        do {
            _ = try await catalog.update(ledgerID: original.id, name: "新名字", entrypoint: "missing.bean")
            XCTFail("Should throw on missing entrypoint file")
        } catch LocalLedgerError.invalidConfiguration {
            // expected
        }
    }
}

