import Foundation
@testable import LedgerMobile

/// The keyword matcher the natural-language editor used before the scored
/// matcher, kept verbatim (minus the candidate lists) as the benchmark baseline.
enum LegacyBookkeepingAccountMatcher {
    static func match(role: String, text: String, accounts: [LedgerAccount]) -> String? {
        let lower = text.lowercased()
        switch role {
        case "expense":
            return matchExpense(text: lower, accounts: accounts)
        case "funding", "receivable":
            return matchFunding(text: lower, accounts: accounts)
        case "income":
            return matchIncome(text: lower, accounts: accounts)
        default:
            return matchExpense(text: lower, accounts: accounts) ?? matchFunding(text: lower, accounts: accounts)
        }
    }

    private static func matchExpense(text: String, accounts: [LedgerAccount]) -> String? {
        if text.contains("外卖") || text.contains("美团") || text.contains("饿了么") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["takeout", "外卖"]) { return acc }
        }
        if text.contains("咖啡") || text.contains("奶茶") || text.contains("饮品") || text.contains("星巴克") || text.contains("瑞幸") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["drink", "coffee", "beverage", "饮品", "咖啡"]) { return acc }
        }
        if text.contains("餐") || text.contains("饭") || text.contains("吃") || text.contains("麦当劳")
            || text.contains("肯德基") || text.contains("汉堡") || text.contains("火锅") || text.contains("美食")
            || text.contains("早饭") || text.contains("午餐") || text.contains("晚餐") || text.contains("夜宵") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["food", "dining", "meal", "餐饮", "正餐"]) { return acc }
        }
        if text.contains("打车") || text.contains("滴滴") || text.contains("出租") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["taxi", "打车", "出租"]) { return acc }
        }
        if text.contains("地铁") || text.contains("公交") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["subway", "bus", "transit", "地铁", "公交"]) { return acc }
        }
        if text.contains("交通") || text.contains("加油") || text.contains("停车") || text.contains("高铁") || text.contains("火车") || text.contains("机票") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["transport", "traffic", "travel", "交通"]) { return acc }
        }
        if text.contains("买菜") || text.contains("超市") || text.contains("便利店") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["groceries", "supermarket", "超市", "买菜"]) { return acc }
        }
        if text.contains("购物") || text.contains("淘宝") || text.contains("京东") || text.contains("拼多多") || text.contains("日用") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["shopping", "daily", "购物", "日用"]) { return acc }
        }
        if text.contains("书") || text.contains("学习") || text.contains("课程") || text.contains("培训") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["book", "education", "study", "书", "学习"]) { return acc }
        }
        if text.contains("电影") || text.contains("游戏") || text.contains("门票") || text.contains("旅游") || text.contains("玩") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["entertainment", "game", "movie", "娱乐", "游戏", "电影"]) { return acc }
        }
        if text.contains("房租") || text.contains("物业") || text.contains("水费") || text.contains("电费") || text.contains("燃气") || text.contains("话费") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["housing", "utilities", "rent", "居住", "房租", "水电", "话费"]) { return acc }
        }
        if text.contains("医院") || text.contains("药") || text.contains("门诊") || text.contains("体检") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["health", "medical", "医疗", "药品"]) { return acc }
        }
        return accounts.first(where: { $0.account.hasPrefix("Expenses:") && $0.active })?.account
    }

    private static func matchFunding(text: String, accounts: [LedgerAccount]) -> String? {
        if text.contains("微信") || text.contains("wx") || text.contains("零钱") {
            if let acc = find(accounts, prefix: "Assets:", keywords: ["wechat", "weixin", "wx", "微信", "零钱"]) { return acc }
        }
        if text.contains("花呗") {
            if let acc = find(accounts, prefix: "Liabilities:", keywords: ["huabei", "花呗"]) { return acc }
        }
        if text.contains("支付宝") || text.contains("alipay") || text.contains("余额宝") {
            if let acc = find(accounts, prefix: "Assets:", keywords: ["alipay", "支付宝", "余额宝"]) { return acc }
        }
        if text.contains("招行") || text.contains("招商") || text.contains("cmb") {
            if text.contains("信用卡") {
                if let acc = find(accounts, prefix: "Liabilities:", keywords: ["cmb", "招行", "招商"]) { return acc }
            }
            if let acc = find(accounts, prefix: "Assets:", keywords: ["cmb", "招行", "招商"]) { return acc }
        }
        if text.contains("工行") || text.contains("工商") || text.contains("icbc") {
            if text.contains("信用卡") {
                if let acc = find(accounts, prefix: "Liabilities:", keywords: ["icbc", "工行", "工商"]) { return acc }
            }
            if let acc = find(accounts, prefix: "Assets:", keywords: ["icbc", "工行", "工商"]) { return acc }
        }
        if text.contains("信用卡") {
            if let acc = find(accounts, prefix: "Liabilities:", keywords: ["creditcard", "信用卡", "card"]) { return acc }
        }
        if text.contains("现金") || text.contains("cash") {
            if let acc = find(accounts, prefix: "Assets:", keywords: ["cash", "现金"]) { return acc }
        }
        for kw in ["wechat", "weixin", "alipay", "cmb", "cash", "bank"] {
            if let acc = find(accounts, prefix: "Assets:", keywords: [kw]) { return acc }
        }
        return accounts.first(where: { $0.account.hasPrefix("Assets:") && $0.active })?.account
    }

    private static func matchIncome(text: String, accounts: [LedgerAccount]) -> String? {
        if text.contains("工资") || text.contains("薪水") || text.contains("奖金") {
            if let acc = find(accounts, prefix: "Income:", keywords: ["salary", "wage", "bonus", "工资", "薪水"]) { return acc }
        }
        return accounts.first(where: { $0.account.hasPrefix("Income:") && $0.active })?.account
    }

    private static func find(_ accounts: [LedgerAccount], prefix: String, keywords: [String]) -> String? {
        let matchingPrefix = accounts.filter { $0.account.hasPrefix(prefix) && $0.active }
        for kw in keywords {
            if let match = matchingPrefix.first(where: {
                $0.account.lowercased().contains(kw) || $0.label.lowercased().contains(kw) || $0.displayLabel.lowercased().contains(kw)
            }) {
                return match.account
            }
        }
        return nil
    }
}
