import Testing
import Foundation
@testable import LedgerMobile

@Suite("LedgerIslandNoticeTests")
struct LedgerIslandNoticeTests {
    private func expense(payee: String = "Blue Bottle Coffee", account: String = "Expenses:Food:Coffee",
                         amount: String = "38.00") -> LedgerTransactionEntry {
        LedgerTransactionEntry(
            date: "2026-09-30",
            flag: "*",
            payee: payee,
            narration: "蓝瓶咖啡",
            tags: [],
            links: [],
            postings: [
                LedgerTransactionEntryPosting(account: account, amount: amount, currency: "CNY"),
                LedgerTransactionEntryPosting(account: "Assets:Bank:CMB:Credit", amount: "-\(amount)", currency: "CNY")
            ]
        )
    }

    @Test("A manual expense shows its payee, category and signed amount")
    func noticeFromExpense() {
        let notice = LedgerIslandNotice.from(entry: expense(), accountLabels: ["Expenses:Food:Coffee": "咖啡"])
        #expect(notice.type == .expense)
        #expect(notice.title == "Blue Bottle Coffee")
        #expect(notice.subtitle == "咖啡")
        // The cached MoneyText formatter, so the island reads like the list.
        #expect(notice.amountText == MoneyText.format(minorUnits: -3800, currency: "CNY"))
        #expect(notice.amountText.contains("38.00"))
        #expect(notice.amountText.hasPrefix("-"))
        #expect(notice.type.hueHex == 0xCF7A52)
        #expect(notice.announcement.contains("Blue Bottle Coffee"))
        // The compact pill drops the cents and shows the category symbol.
        #expect(notice.compactText == "-¥38")
        #expect(notice.compactSymbol == "fork.knife")
    }

    @Test("The compact pill's icon comes from the category, as the transaction list draws it")
    func iconFollowsCategory() {
        #expect(LedgerIslandNotice.from(entry: expense()).iconName == "fork.knife")
        #expect(LedgerIslandNotice.from(entry: expense(account: "Expenses:Transport:Taxi")).iconName == "car.fill")
        #expect(LedgerIslandNotice.from(entry: expense(account: "Expenses:Housing:Rent")).iconName == "house.fill")
        // A label the user gave the account counts too.
        #expect(LedgerIslandNotice.from(entry: expense(account: "Expenses:Misc"),
                                        accountLabels: ["Expenses:Misc": "话费"]).iconName == "antenna.radiowaves.left.and.right")
        // Unknown expenses fall back to the list's cart, never a fixed fork.
        #expect(LedgerIslandNotice.from(entry: expense(account: "Expenses:Misc")).iconName == "cart.fill")
        #expect(LedgerCategoryIcon.name(account: "Income:Salary") == "banknote.fill")
        #expect(LedgerCategoryIcon.name(account: "Income:Other") == "arrow.down.left")
    }

    @Test("Income is signed and uses the income hue")
    func noticeFromIncome() {
        let entry = LedgerTransactionEntry(
            date: "2026-09-30", flag: "*", payee: "", narration: "九月工资", tags: [], links: [],
            postings: [
                LedgerTransactionEntryPosting(account: "Assets:Bank:CMB", amount: "12800.00", currency: "CNY"),
                LedgerTransactionEntryPosting(account: "Income:Salary", amount: "-12800.00", currency: "CNY")
            ]
        )
        let notice = LedgerIslandNotice.from(entry: entry)
        #expect(notice.type == .income)
        #expect(notice.title == "九月工资")
        #expect(notice.amountText == MoneyText.format(minorUnits: 1_280_000, currency: "CNY", showSign: true))
        #expect(notice.amountText.hasPrefix("+"))
        #expect(notice.compactText == "+¥1.28万")
        #expect(notice.iconName == "banknote.fill")
        #expect(notice.type.hueHex == 0x4FBFAB)
    }

    @Test("A transfer names both accounts and stays white")
    func noticeFromTransfer() {
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
        #expect(notice.title == "招行 → 零钱通")
        #expect(notice.iconName == "arrow.left.arrow.right")
        #expect(notice.amountText.contains("1,000.00"))
        #expect(!notice.amountText.hasPrefix("-") && !notice.amountText.hasPrefix("+"))
        #expect(notice.type.hueHex == 0xFFFFFF)
    }

    @Test("One prepared entry gets its own notice; several get a count")
    func noticeFromEntries() {
        #expect(LedgerIslandNotice.from(entries: [expense()]).type == .expense)
        let several = LedgerIslandNotice.from(entries: [expense(), expense(payee: "Bakery")])
        #expect(several.type == .entries(count: 2))
        #expect(several.amountText == "2 笔")
        #expect(several.compactText == "2 笔")
        // Several entries have no single category, so the pill keeps the check.
        #expect(several.compactSymbol == nil)
        #expect(several.type.hueHex == 0xFFFFFF)
        #expect(!several.type.isImport)
        #expect(LedgerIslandNotice.written(count: 3).amountText == "3 笔")
    }

    @Test("A bill import names its provider and shows a static count")
    func noticeFromBatchImport() {
        let wechat = LedgerIslandNotice.fromImport(count: 8, provider: "wechat")
        #expect(wechat.type == .batchImport(count: 8))
        #expect(wechat.type.isImport)
        #expect(wechat.title == "微信支付账单")
        #expect(wechat.subtitle == "已导入")
        #expect(wechat.amountText == "8 笔")
        #expect(wechat.compactText == "8 笔")
        #expect(wechat.compactSymbol == "tray.and.arrow.down.fill")
        #expect(wechat.type.hueHex == 0xFFFFFF)
        // Provider ids use the short label; display names pass through.
        #expect(LedgerIslandNotice.fromImport(count: 1, provider: "cmb").title == "招行信用卡账单")
        #expect(LedgerIslandNotice.fromImport(count: 1, provider: "支付宝").title == "支付宝账单")
        #expect(LedgerIslandNotice.fromImport(count: 1, provider: nil).title == "账单")
        #expect(wechat.announcement.hasPrefix("已导入"))
    }
}
