import XCTest
@testable import LedgerMobile

final class AccountPresetTests: XCTestCase {
    func testToPinyinCamelCaseKnownKeywords() {
        let cmb = BeancountNaming.toPinyinCamelCase("招商银行")
        XCTAssertEqual(cmb, "CMB")

        let wechat = BeancountNaming.toPinyinCamelCase("微信零钱")
        XCTAssertEqual(wechat, "WeChat:LingQian")

        let alipay = BeancountNaming.toPinyinCamelCase("支付宝余额宝")
        XCTAssertEqual(alipay, "Alipay:YuEBao")
    }

    func testToPinyinCamelCaseArbitraryChinese() {
        let result = BeancountNaming.toPinyinCamelCase("小明的私房钱")
        XCTAssertEqual(result, "XiaoMingDeSiFangQian")

        let rent = BeancountNaming.toPinyinCamelCase("自如房租")
        XCTAssertEqual(rent, "ZiRu:Rent")
    }

    func testBuildAccountPath() {
        let cmbPreset = AccountPresets.presets.first(where: { $0.id == "bank_cmb" })
        XCTAssertNotNil(cmbPreset)

        let path1 = BeancountNaming.buildAccountPath(
            category: .bank,
            preset: cmbPreset,
            customName: "招商银行",
            detail: nil
        )
        XCTAssertEqual(path1, "Assets:Bank:CMB")

        let path2 = BeancountNaming.buildAccountPath(
            category: .bank,
            preset: cmbPreset,
            customName: "招商银行",
            detail: "尾号8888"
        )
        XCTAssertEqual(path2, "Assets:Bank:CMB:WeiHao8888")

        let path3 = BeancountNaming.buildAccountPath(
            category: .cash,
            preset: nil,
            customName: "小金库",
            detail: nil
        )
        XCTAssertEqual(path3, "Assets:Cash:XiaoJinKu")
    }

    func testIsValidAccountPath() {
        XCTAssertTrue(BeancountNaming.isValidAccountPath("Assets:Bank:CMB"))
        XCTAssertTrue(BeancountNaming.isValidAccountPath("Liabilities:CreditCard:CMB:C8888"))
        XCTAssertTrue(BeancountNaming.isValidAccountPath("Expenses:Food:Coffee"))
        XCTAssertTrue(BeancountNaming.isValidAccountPath("Income:Career:Salary"))
        XCTAssertTrue(BeancountNaming.isValidAccountPath("Equity:Opening-Balances"))

        XCTAssertFalse(BeancountNaming.isValidAccountPath("Invalid:Root:Name"))
        XCTAssertFalse(BeancountNaming.isValidAccountPath("Assets:银行:招商"))
        XCTAssertFalse(BeancountNaming.isValidAccountPath("Assets:"))
        XCTAssertFalse(BeancountNaming.isValidAccountPath("Expenses"))
    }
}
