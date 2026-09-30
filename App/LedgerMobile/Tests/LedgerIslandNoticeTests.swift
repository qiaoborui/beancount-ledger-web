import Testing
import Foundation
@testable import LedgerMobile

@Suite("LedgerIslandNoticeTests")
struct LedgerIslandNoticeTests {
    @Test("Test creating notice from expense transaction entry")
    func testNoticeFromExpense() {
        let entry = LedgerTransactionEntry(
            date: "2026-09-30",
            flag: "*",
            payee: "Blue Bottle Coffee",
            narration: "蓝瓶咖啡",
            tags: [],
            links: [],
            postings: [
                LedgerTransactionEntryPosting(account: "Expenses:Food:Coffee", amount: "38.00", currency: "CNY"),
                LedgerTransactionEntryPosting(account: "Assets:Bank:CMB:Credit", amount: "-38.00", currency: "CNY")
            ]
        )

        let notice = LedgerIslandNotice.from(entry: entry)
        #expect(notice.type == .expense)
        #expect(notice.title == "Blue Bottle Coffee")
        #expect(notice.amountText.contains("38.00"))
        #expect(notice.amountText.hasPrefix("-"))
    }

    @Test("Test creating notice from transfer entry")
    func testNoticeFromTransfer() {
        let entry = LedgerTransactionEntry(
            date: "2026-09-30",
            flag: "*",
            payee: "",
            narration: "零钱划转",
            tags: [],
            links: [],
            postings: [
                LedgerTransactionEntryPosting(account: "Assets:Bank:CMB", amount: "-1000.00", currency: "CNY"),
                LedgerTransactionEntryPosting(account: "Assets:WeChat:ZeroPurse", amount: "1000.00", currency: "CNY")
            ]
        )

        let notice = LedgerIslandNotice.from(entry: entry, accountLabels: [
            "Assets:Bank:CMB": "招行",
            "Assets:WeChat:ZeroPurse": "零钱通"
        ])
        #expect(notice.type == .transfer)
        #expect(notice.title == "招行 ➔ 零钱通")
        #expect(notice.iconName == "arrow.left.arrow.right")
        #expect(notice.amountText.contains("1,000.00"))
    }

    @Test("Test creating notice from batch import")
    func testNoticeFromBatchImport() {
        let notice = LedgerIslandNotice.fromImport(count: 8, provider: "微信支付")
        #expect(notice.type == .batchImport(count: 8))
        #expect(notice.title == "微信支付导入")
        #expect(notice.amountText == "8 笔已归档")
    }
}
