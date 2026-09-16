import SwiftUI

struct TransactionVisualCategory: Equatable {
    let iconName: String
    let color: Color
    let categoryLabel: String

    static func resolve(
        transaction: LedgerTransaction,
        presentation: TransactionPresentation,
        accountLabels: [String: String] = [:]
    ) -> TransactionVisualCategory {
        let label = TransactionCategoryPresentation(transaction: transaction, accountLabels: accountLabels).label

        // 1. Check expense & income accounts directly for precise categorization
        let categoryAccounts = transaction.postings
            .map(\.account)
            .filter { $0.hasPrefix("Expenses:") || $0.hasPrefix("Income:") || $0.hasPrefix("Assets:") }

        for account in categoryAccounts {
            let lower = account.lowercased()
            if lower.hasPrefix("expenses:food") || lower.hasPrefix("expenses:dining") || lower.hasPrefix("expenses:groceries") || lower.hasPrefix("expenses:meal") {
                return TransactionVisualCategory(iconName: "fork.knife", color: Color(red: 0.96, green: 0.55, blue: 0.18), categoryLabel: label)
            }
            if lower.hasPrefix("expenses:transport") || lower.hasPrefix("expenses:travel") || lower.hasPrefix("expenses:taxi") {
                return TransactionVisualCategory(iconName: "car.fill", color: Color(red: 0.16, green: 0.54, blue: 0.95), categoryLabel: label)
            }
            if lower.hasPrefix("expenses:book") || lower.hasPrefix("expenses:education") || lower.hasPrefix("expenses:study") {
                return TransactionVisualCategory(iconName: "book.fill", color: Color(red: 0.72, green: 0.48, blue: 0.28), categoryLabel: label)
            }
            if lower.hasPrefix("expenses:digital") || lower.hasPrefix("expenses:communication") || lower.hasPrefix("expenses:telecom") {
                return TransactionVisualCategory(iconName: "antenna.radiowaves.left.and.right", color: Color(red: 0.35, green: 0.45, blue: 0.88), categoryLabel: label)
            }
            if lower.hasPrefix("expenses:shopping") || lower.hasPrefix("expenses:clothing") || lower.hasPrefix("expenses:daily") {
                return TransactionVisualCategory(iconName: "bag.fill", color: Color(red: 0.92, green: 0.32, blue: 0.55), categoryLabel: label)
            }
            if lower.hasPrefix("expenses:entertainment") || lower.hasPrefix("expenses:game") || lower.hasPrefix("expenses:movie") {
                return TransactionVisualCategory(iconName: "popcorn.fill", color: Color(red: 0.65, green: 0.36, blue: 0.88), categoryLabel: label)
            }
            if lower.hasPrefix("expenses:housing") || lower.hasPrefix("expenses:rent") || lower.hasPrefix("expenses:utilities") {
                return TransactionVisualCategory(iconName: "house.fill", color: Color(red: 0.12, green: 0.66, blue: 0.72), categoryLabel: label)
            }
            if lower.hasPrefix("expenses:health") || lower.hasPrefix("expenses:medical") {
                return TransactionVisualCategory(iconName: "heart.fill", color: Color(red: 0.92, green: 0.28, blue: 0.28), categoryLabel: label)
            }
            if lower.hasPrefix("income:salary") || lower.hasPrefix("income:wage") || lower.hasPrefix("income:bonus") {
                return TransactionVisualCategory(iconName: "banknote.fill", color: Color(red: 0.12, green: 0.68, blue: 0.36), categoryLabel: label)
            }
            if lower.contains("fund") || lower.contains("invest") || lower.contains("stock") {
                return TransactionVisualCategory(iconName: "chart.line.uptrend.xyaxis", color: Color(red: 0.08, green: 0.68, blue: 0.55), categoryLabel: label)
            }
        }

        // 2. Keyword matching on label, payee, and narration
        let textToMatch = "\(label) \(transaction.payee) \(transaction.narration)".lowercased()

        // Dining & Food
        if textToMatch.contains("餐饮") || textToMatch.contains("美食") || textToMatch.contains("早餐")
            || textToMatch.contains("午餐") || textToMatch.contains("晚餐") || textToMatch.contains("外卖")
            || textToMatch.contains("美团") || textToMatch.contains("饿了么") || textToMatch.contains("超市")
            || textToMatch.contains("买菜") || textToMatch.contains("食材") || textToMatch.contains("咖啡")
            || textToMatch.contains("水果") || textToMatch.contains("零食") || textToMatch.contains("青禾")
            || textToMatch.contains("星巴克") || textToMatch.contains("肯德基") || textToMatch.contains("麦当劳")
            || textToMatch.contains("海底捞") || textToMatch.contains("dining") || textToMatch.contains("food")
            || textToMatch.contains("coffee") || textToMatch.contains("groceries") {
            return TransactionVisualCategory(iconName: "fork.knife", color: Color(red: 0.96, green: 0.55, blue: 0.18), categoryLabel: label)
        }

        // Books & Education
        if textToMatch.contains("图书") || textToMatch.contains("书房") || textToMatch.contains("书籍")
            || textToMatch.contains("阅读") || textToMatch.contains("学习") || textToMatch.contains("课程")
            || textToMatch.contains("培训") || textToMatch.contains("教育") || textToMatch.contains("学费")
            || textToMatch.contains("book") || textToMatch.contains("education") {
            return TransactionVisualCategory(iconName: "book.fill", color: Color(red: 0.72, green: 0.48, blue: 0.28), categoryLabel: label)
        }

        // Transport & Travel
        if textToMatch.contains("交通") || textToMatch.contains("出行") || textToMatch.contains("打车")
            || textToMatch.contains("滴滴") || textToMatch.contains("地铁") || textToMatch.contains("公交")
            || textToMatch.contains("高铁") || textToMatch.contains("机票") || textToMatch.contains("火车")
            || textToMatch.contains("加油") || textToMatch.contains("停车") || textToMatch.contains("高速")
            || textToMatch.contains("租车") || textToMatch.contains("航班") || textToMatch.contains("云端出行")
            || textToMatch.contains("transport") || textToMatch.contains("travel") || textToMatch.contains("taxi")
            || textToMatch.contains("flight") {
            return TransactionVisualCategory(iconName: "car.fill", color: Color(red: 0.16, green: 0.54, blue: 0.95), categoryLabel: label)
        }

        // Shopping
        if textToMatch.contains("购物") || textToMatch.contains("数码") || textToMatch.contains("淘宝")
            || textToMatch.contains("天猫") || textToMatch.contains("京东") || textToMatch.contains("拼多多")
            || textToMatch.contains("服饰") || textToMatch.contains("衣服") || textToMatch.contains("商场")
            || textToMatch.contains("电器") || textToMatch.contains("杂货") || textToMatch.contains("shopping") {
            return TransactionVisualCategory(iconName: "bag.fill", color: Color(red: 0.92, green: 0.32, blue: 0.55), categoryLabel: label)
        }

        // Entertainment & Leisure
        if textToMatch.contains("娱乐") || textToMatch.contains("游戏") || textToMatch.contains("电影")
            || textToMatch.contains("演出") || textToMatch.contains("门票") || textToMatch.contains("音乐")
            || textToMatch.contains("会员") || textToMatch.contains("网易云") || textToMatch.contains("bilibili")
            || textToMatch.contains("steam") || textToMatch.contains("switch") || textToMatch.contains("entertainment") {
            return TransactionVisualCategory(iconName: "popcorn.fill", color: Color(red: 0.65, green: 0.36, blue: 0.88), categoryLabel: label)
        }

        // Housing & Utilities
        if textToMatch.contains("房租") || textToMatch.contains("房贷") || textToMatch.contains("水电")
            || textToMatch.contains("水费") || textToMatch.contains("电费") || textToMatch.contains("燃气")
            || textToMatch.contains("物业") || textToMatch.contains("宽带") || textToMatch.contains("维修")
            || textToMatch.contains("家政") || textToMatch.contains("housing") || textToMatch.contains("rent") {
            return TransactionVisualCategory(iconName: "house.fill", color: Color(red: 0.12, green: 0.66, blue: 0.72), categoryLabel: label)
        }

        // Health & Medical
        if textToMatch.contains("医疗") || textToMatch.contains("健康") || textToMatch.contains("医院")
            || textToMatch.contains("诊所") || textToMatch.contains("体检") || textToMatch.contains("药品")
            || textToMatch.contains("药房") || textToMatch.contains("健身") || textToMatch.contains("运动")
            || textToMatch.contains("health") || textToMatch.contains("medical") {
            return TransactionVisualCategory(iconName: "heart.fill", color: Color(red: 0.92, green: 0.28, blue: 0.28), categoryLabel: label)
        }

        // Digital & Telecom
        if textToMatch.contains("话费") || textToMatch.contains("流量") || textToMatch.contains("移动")
            || textToMatch.contains("联通") || textToMatch.contains("电信") || textToMatch.contains("云服务")
            || textToMatch.contains("icloud") || textToMatch.contains("apple") || textToMatch.contains("软件")
            || textToMatch.contains("digital") || textToMatch.contains("telecom") {
            return TransactionVisualCategory(iconName: "antenna.radiowaves.left.and.right", color: Color(red: 0.35, green: 0.45, blue: 0.88), categoryLabel: label)
        }

        // Investment & Wealth
        if textToMatch.contains("理财") || textToMatch.contains("基金") || textToMatch.contains("股票")
            || textToMatch.contains("投资") || textToMatch.contains("证券") || textToMatch.contains("分红")
            || textToMatch.contains("指数") || textToMatch.contains("invest") || textToMatch.contains("wealth") {
            return TransactionVisualCategory(iconName: "chart.line.uptrend.xyaxis", color: Color(red: 0.08, green: 0.68, blue: 0.55), categoryLabel: label)
        }

        // Transfers & Repayments
        if presentation.kind == .transfer || textToMatch.contains("转账") || textToMatch.contains("还款")
            || textToMatch.contains("充值") || textToMatch.contains("提现") || textToMatch.contains("信用卡")
            || textToMatch.contains("借还") || textToMatch.contains("transfer") || textToMatch.contains("repay") {
            return TransactionVisualCategory(iconName: "arrow.left.arrow.right", color: Color(red: 0.0, green: 0.48, blue: 0.88), categoryLabel: label)
        }

        // Income & Salary
        if presentation.kind == .income || textToMatch.contains("工资") || textToMatch.contains("薪水")
            || textToMatch.contains("奖金") || textToMatch.contains("报销") || textToMatch.contains("兼职")
            || textToMatch.contains("收入") || textToMatch.contains("salary") || textToMatch.contains("income") {
            return TransactionVisualCategory(iconName: "banknote.fill", color: Color(red: 0.12, green: 0.68, blue: 0.36), categoryLabel: label)
        }

        // 3. Kind-based fallbacks
        switch presentation.kind {
        case .expense:
            return TransactionVisualCategory(iconName: "cart.fill", color: Color(red: 0.95, green: 0.45, blue: 0.22), categoryLabel: label)
        case .income:
            return TransactionVisualCategory(iconName: "arrow.down.left", color: Color(red: 0.12, green: 0.68, blue: 0.36), categoryLabel: label)
        case .transfer:
            return TransactionVisualCategory(iconName: "arrow.left.arrow.right", color: Color(red: 0.0, green: 0.48, blue: 0.88), categoryLabel: label)
        }
    }

    static func resolve(account: String, label: String = "") -> TransactionVisualCategory {
        let displayLabel = label.isEmpty ? (account.components(separatedBy: ":").last ?? account) : label
        let lower = account.lowercased()

        if lower.hasPrefix("expenses:food") || lower.hasPrefix("expenses:dining") || lower.hasPrefix("expenses:groceries") || lower.hasPrefix("expenses:meal") {
            return TransactionVisualCategory(iconName: "fork.knife", color: Color(red: 0.96, green: 0.55, blue: 0.18), categoryLabel: displayLabel)
        }
        if lower.hasPrefix("expenses:transport") || lower.hasPrefix("expenses:travel") || lower.hasPrefix("expenses:taxi") {
            return TransactionVisualCategory(iconName: "car.fill", color: Color(red: 0.16, green: 0.54, blue: 0.95), categoryLabel: displayLabel)
        }
        if lower.hasPrefix("expenses:book") || lower.hasPrefix("expenses:education") || lower.hasPrefix("expenses:study") {
            return TransactionVisualCategory(iconName: "book.fill", color: Color(red: 0.72, green: 0.48, blue: 0.28), categoryLabel: displayLabel)
        }
        if lower.hasPrefix("expenses:digital") || lower.hasPrefix("expenses:communication") || lower.hasPrefix("expenses:telecom") {
            return TransactionVisualCategory(iconName: "antenna.radiowaves.left.and.right", color: Color(red: 0.35, green: 0.45, blue: 0.88), categoryLabel: displayLabel)
        }
        if lower.hasPrefix("expenses:shopping") || lower.hasPrefix("expenses:clothing") || lower.hasPrefix("expenses:daily") {
            return TransactionVisualCategory(iconName: "bag.fill", color: Color(red: 0.92, green: 0.32, blue: 0.55), categoryLabel: displayLabel)
        }
        if lower.hasPrefix("expenses:entertainment") || lower.hasPrefix("expenses:game") || lower.hasPrefix("expenses:movie") {
            return TransactionVisualCategory(iconName: "popcorn.fill", color: Color(red: 0.65, green: 0.36, blue: 0.88), categoryLabel: displayLabel)
        }
        if lower.hasPrefix("expenses:housing") || lower.hasPrefix("expenses:rent") || lower.hasPrefix("expenses:utilities") {
            return TransactionVisualCategory(iconName: "house.fill", color: Color(red: 0.12, green: 0.66, blue: 0.72), categoryLabel: displayLabel)
        }
        if lower.hasPrefix("expenses:health") || lower.hasPrefix("expenses:medical") {
            return TransactionVisualCategory(iconName: "heart.fill", color: Color(red: 0.92, green: 0.28, blue: 0.28), categoryLabel: displayLabel)
        }
        if lower.hasPrefix("income:salary") || lower.hasPrefix("income:wage") || lower.hasPrefix("income:bonus") {
            return TransactionVisualCategory(iconName: "banknote.fill", color: Color(red: 0.12, green: 0.68, blue: 0.36), categoryLabel: displayLabel)
        }
        if lower.contains("fund") || lower.contains("invest") || lower.contains("stock") {
            return TransactionVisualCategory(iconName: "chart.line.uptrend.xyaxis", color: Color(red: 0.08, green: 0.68, blue: 0.55), categoryLabel: displayLabel)
        }

        // Keyword matching on displayLabel & account
        let textToMatch = "\(displayLabel) \(account)".lowercased()
        if textToMatch.contains("餐饮") || textToMatch.contains("美食") || textToMatch.contains("早餐") || textToMatch.contains("午餐") || textToMatch.contains("晚餐") || textToMatch.contains("外卖") || textToMatch.contains("美团") || textToMatch.contains("咖啡") || textToMatch.contains("超市") || textToMatch.contains("买菜") {
            return TransactionVisualCategory(iconName: "fork.knife", color: Color(red: 0.96, green: 0.55, blue: 0.18), categoryLabel: displayLabel)
        }
        if textToMatch.contains("交通") || textToMatch.contains("出行") || textToMatch.contains("打车") || textToMatch.contains("滴滴") || textToMatch.contains("地铁") || textToMatch.contains("公交") || textToMatch.contains("加油") || textToMatch.contains("停车") {
            return TransactionVisualCategory(iconName: "car.fill", color: Color(red: 0.16, green: 0.54, blue: 0.95), categoryLabel: displayLabel)
        }
        if textToMatch.contains("购物") || textToMatch.contains("数码") || textToMatch.contains("淘宝") || textToMatch.contains("京东") || textToMatch.contains("拼多多") || textToMatch.contains("服饰") || textToMatch.contains("衣服") || textToMatch.contains("日用") {
            return TransactionVisualCategory(iconName: "bag.fill", color: Color(red: 0.92, green: 0.32, blue: 0.55), categoryLabel: displayLabel)
        }
        if textToMatch.contains("娱乐") || textToMatch.contains("游戏") || textToMatch.contains("电影") || textToMatch.contains("音乐") || textToMatch.contains("会员") {
            return TransactionVisualCategory(iconName: "popcorn.fill", color: Color(red: 0.65, green: 0.36, blue: 0.88), categoryLabel: displayLabel)
        }
        if textToMatch.contains("房租") || textToMatch.contains("房贷") || textToMatch.contains("水电") || textToMatch.contains("燃气") || textToMatch.contains("物业") || textToMatch.contains("家居") {
            return TransactionVisualCategory(iconName: "house.fill", color: Color(red: 0.12, green: 0.66, blue: 0.72), categoryLabel: displayLabel)
        }
        if textToMatch.contains("医疗") || textToMatch.contains("健康") || textToMatch.contains("医院") || textToMatch.contains("药品") {
            return TransactionVisualCategory(iconName: "heart.fill", color: Color(red: 0.92, green: 0.28, blue: 0.28), categoryLabel: displayLabel)
        }
        if textToMatch.contains("话费") || textToMatch.contains("流量") || textToMatch.contains("宽带") || textToMatch.contains("云服务") {
            return TransactionVisualCategory(iconName: "antenna.radiowaves.left.and.right", color: Color(red: 0.35, green: 0.45, blue: 0.88), categoryLabel: displayLabel)
        }
        if textToMatch.contains("学习") || textToMatch.contains("图书") || textToMatch.contains("书籍") || textToMatch.contains("课程") || textToMatch.contains("培训") {
            return TransactionVisualCategory(iconName: "book.fill", color: Color(red: 0.72, green: 0.48, blue: 0.28), categoryLabel: displayLabel)
        }
        if textToMatch.contains("工资") || textToMatch.contains("薪水") || textToMatch.contains("奖金") || textToMatch.contains("收入") {
            return TransactionVisualCategory(iconName: "banknote.fill", color: Color(red: 0.12, green: 0.68, blue: 0.36), categoryLabel: displayLabel)
        }

        if account.hasPrefix("Income:") {
            return TransactionVisualCategory(iconName: "arrow.down.left", color: Color(red: 0.12, green: 0.68, blue: 0.36), categoryLabel: displayLabel)
        }
        return TransactionVisualCategory(iconName: "cart.fill", color: Color(red: 0.95, green: 0.45, blue: 0.22), categoryLabel: displayLabel)
    }
}
