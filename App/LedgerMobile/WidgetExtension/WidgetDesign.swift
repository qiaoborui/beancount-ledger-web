import SwiftUI
import UIKit
import WidgetKit

enum LedgerWidgetColors {
    static let canvas = Color.dynamic(light: 0xF2F4F7, dark: 0x0C0E14)
    static let panel = Color.dynamic(light: 0xFFFFFF, dark: 0x161A22)
    static let raised = Color.dynamic(light: 0xF0F3F7, dark: 0x202632)
    static let tag = Color.dynamic(light: 0xEAEEF4, dark: 0x1E2430)
    static let ink = Color.dynamic(light: 0x0F172A, dark: 0xF1F5F9)
    static let secondary = Color.dynamic(light: 0x64748B, dark: 0x94A3B8)
    static let line = Color.dynamic(light: 0xE2E8F0, dark: 0x2A3241)
    static let cobalt = Color.dynamic(light: 0x0F172A, dark: 0xF1F5F9)
    static let chartLine = Color.dynamic(light: 0x334155, dark: 0x94A3B8)
    static let expense = Color.dynamic(light: 0xC0392B, dark: 0xF87171)
    static let expenseSoft = Color.dynamic(light: 0xFEE2E2, dark: 0x381E1E)
    static let success = Color.dynamic(light: 0x15803D, dark: 0x4ADE80)
    static let successSoft = Color.dynamic(light: 0xDCFCE7, dark: 0x142B1A)
    static let gold = Color.dynamic(light: 0xB45309, dark: 0xFBBF24)
    static let goldSoft = Color.dynamic(light: 0xFEF3C7, dark: 0x332508)
    static let purple = Color.dynamic(light: 0x6D28D9, dark: 0xA78BFA)
    static let onBrand = Color.white
}

private extension Color {
    static func dynamic(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct LedgerWidgetBrandMark: View {
    var systemName: String = "waveform.path.ecg"
    var tint: Color = LedgerWidgetColors.cobalt

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .fill(LedgerWidgetColors.raised)
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LedgerWidgetColors.ink)
        }
        .frame(width: 24, height: 24)
        .overlay {
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .strokeBorder(LedgerWidgetColors.line.opacity(0.8), lineWidth: 0.5)
        }
    }
}

struct LedgerWidgetHeader: View {
    let title: String
    let detail: String
    var systemName: String = "waveform.path.ecg"
    var tint: Color = LedgerWidgetColors.cobalt
    var badgeText: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            LedgerWidgetBrandMark(systemName: systemName, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let badgeText {
                Text(badgeText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(LedgerWidgetColors.raised)
                    .clipShape(Capsule())
            }
        }
    }
}

extension View {
    func widgetSubcard(cornerRadius: CGFloat = 10, padding: CGFloat = 8) -> some View {
        self
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LedgerWidgetColors.raised.opacity(0.65))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(LedgerWidgetColors.line.opacity(0.6), lineWidth: 0.5)
                    }
            }
    }
}

enum LedgerWidgetVisualHelper {
    struct CategoryStyle {
        let icon: String
        let color: Color
    }

    static func category(for accountOrLabel: String) -> CategoryStyle {
        let lower = accountOrLabel.lowercased()
        if lower.contains("food") || lower.contains("dining") || lower.contains("meal")
            || lower.contains("餐饮") || lower.contains("美食") || lower.contains("外卖")
            || lower.contains("买菜") || lower.contains("咖啡") {
            return CategoryStyle(icon: "fork.knife", color: LedgerWidgetColors.ink)
        }
        if lower.contains("transport") || lower.contains("travel") || lower.contains("taxi")
            || lower.contains("交通") || lower.contains("出行") || lower.contains("打车")
            || lower.contains("加油") || lower.contains("停车") {
            return CategoryStyle(icon: "car.fill", color: LedgerWidgetColors.ink)
        }
        if lower.contains("housing") || lower.contains("rent") || lower.contains("utilities")
            || lower.contains("居住") || lower.contains("房租") || lower.contains("物业")
            || lower.contains("水电气") {
            return CategoryStyle(icon: "house.fill", color: LedgerWidgetColors.ink)
        }
        if lower.contains("shopping") || lower.contains("clothing") || lower.contains("daily")
            || lower.contains("购物") || lower.contains("服饰") || lower.contains("日用")
            || lower.contains("超市") || lower.contains("杂货") {
            return CategoryStyle(icon: "bag.fill", color: LedgerWidgetColors.ink)
        }
        if lower.contains("entertainment") || lower.contains("game") || lower.contains("movie")
            || lower.contains("娱乐") || lower.contains("游戏") || lower.contains("电影")
            || lower.contains("演出") || lower.contains("会员") {
            return CategoryStyle(icon: "popcorn.fill", color: LedgerWidgetColors.ink)
        }
        if lower.contains("book") || lower.contains("education") || lower.contains("study")
            || lower.contains("图书") || lower.contains("学习") || lower.contains("教育")
            || lower.contains("学费") {
            return CategoryStyle(icon: "book.fill", color: LedgerWidgetColors.ink)
        }
        if lower.contains("digital") || lower.contains("communication") || lower.contains("telecom")
            || lower.contains("数码") || lower.contains("通信") || lower.contains("话费") {
            return CategoryStyle(icon: "antenna.radiowaves.left.and.right", color: LedgerWidgetColors.ink)
        }
        if lower.contains("health") || lower.contains("medical")
            || lower.contains("医疗") || lower.contains("健康") || lower.contains("药品") {
            return CategoryStyle(icon: "heart.fill", color: LedgerWidgetColors.ink)
        }
        if lower.contains("salary") || lower.contains("wage") || lower.contains("bonus")
            || lower.contains("工资") || lower.contains("收入") {
            return CategoryStyle(icon: "banknote.fill", color: LedgerWidgetColors.ink)
        }
        return CategoryStyle(icon: "tag.fill", color: LedgerWidgetColors.ink)
    }

    struct AccountStyle {
        let icon: String
        let tint: Color
        let groupLabel: String
    }

    static func account(for account: LedgerWidgetAccountSnapshot) -> AccountStyle {
        let name = "\(account.account) \(account.label) \(account.group)".lowercased()
        if account.isLiability || name.contains("credit") || name.contains("信用卡") {
            return AccountStyle(icon: "creditcard.fill", tint: LedgerWidgetColors.ink, groupLabel: "信用卡")
        }
        if name.contains("cash") || name.contains("现金") {
            return AccountStyle(icon: "banknote.fill", tint: LedgerWidgetColors.ink, groupLabel: "现金资产")
        }
        if name.contains("invest") || name.contains("fund") || name.contains("stock") || name.contains("理财") || name.contains("基金") || name.contains("证券") {
            return AccountStyle(icon: "chart.line.uptrend.xyaxis", tint: LedgerWidgetColors.ink, groupLabel: "投资理财")
        }
        if name.contains("loan") || name.contains("mortgage") || name.contains("借款") || name.contains("房贷") {
            return AccountStyle(icon: "arrow.up.right.circle.fill", tint: LedgerWidgetColors.ink, groupLabel: "负债借贷")
        }
        return AccountStyle(icon: "building.columns.fill", tint: LedgerWidgetColors.ink, groupLabel: "日常银行")
    }

    struct ImportStyle {
        let icon: String
        let tint: Color
        let displayName: String
    }

    static func importChannel(for item: LedgerWidgetImportSnapshot) -> ImportStyle {
        let lower = "\(item.provider) \(item.label)".lowercased()
        if lower.contains("alipay") || lower.contains("支付宝") {
            return ImportStyle(icon: "qrcode", tint: LedgerWidgetColors.ink, displayName: "支付宝")
        }
        if lower.contains("wechat") || lower.contains("微信") {
            return ImportStyle(icon: "bubble.left.and.bubble.right.fill", tint: LedgerWidgetColors.ink, displayName: "微信支付")
        }
        if lower.contains("cmb") || lower.contains("招行") || lower.contains("招商") {
            return ImportStyle(icon: "creditcard.fill", tint: LedgerWidgetColors.ink, displayName: "招商银行")
        }
        if lower.contains("hsbc") || lower.contains("汇丰") {
            return ImportStyle(icon: "hexagon.fill", tint: LedgerWidgetColors.ink, displayName: "汇丰银行")
        }
        if lower.contains("icbc") || lower.contains("工行") || lower.contains("boc") || lower.contains("中行") || lower.contains("ccb") || lower.contains("建行") || lower.contains("bank") || lower.contains("银行") {
            return ImportStyle(icon: "building.columns.fill", tint: LedgerWidgetColors.ink, displayName: item.label)
        }
        return ImportStyle(icon: "doc.text.fill", tint: LedgerWidgetColors.ink, displayName: item.label)
    }
}

struct LedgerWidgetUnavailableView: View {
    let title: String
    let detail: String
    var symbol = "arrow.clockwise"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerWidgetHeader(title: "Ledger", detail: "只读财务小组件")
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(LedgerWidgetColors.cobalt)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.ink)
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
                    .lineLimit(2)
            }
        }
        .containerBackground(for: .widget) { LedgerWidgetColors.panel }
    }
}

enum LedgerWidgetText {
    static func percentage(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? "--"
    }

    static func updated(_ date: Date, now: Date = Date()) -> String {
        guard date < now.addingTimeInterval(-60) else { return "刚刚更新" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now) + "更新"
    }

    static func checked(_ date: Date, now: Date = Date()) -> String {
        guard date < now.addingTimeInterval(-60) else { return "刚刚检查" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now) + "检查"
    }
}

extension LedgerWidgetSnapshot {
    static let placeholder: LedgerWidgetSnapshot = {
        var snapshot = LedgerWidgetSnapshot(
        updatedAt: Date(),
        expense: LedgerWidgetExpenseSnapshot(
            periodTitle: "2026年8月",
            start: "2026-08-01",
            end: "2026-09-01",
            currency: "CNY",
            amount: 555_180,
            transactionCount: 9,
            yearOverYearPercentage: -0.126,
            categories: [
                LedgerWidgetExpenseCategory(account: "Expenses:Housing", label: "居住", amount: 380_000),
                LedgerWidgetExpenseCategory(account: "Expenses:Food", label: "餐饮", amount: 84_780),
                LedgerWidgetExpenseCategory(account: "Expenses:Travel", label: "出行", amount: 57_600),
            ],
            dailySeries: [
                LedgerWidgetDailyExpense(date: "2026-08-03", amount: 42_500),
                LedgerWidgetDailyExpense(date: "2026-08-09", amount: 380_000),
                LedgerWidgetDailyExpense(date: "2026-08-12", amount: 23_600),
                LedgerWidgetDailyExpense(date: "2026-08-21", amount: 57_600),
                LedgerWidgetDailyExpense(date: "2026-08-28", amount: 32_800),
            ]
        ),
        accounts: [
            LedgerWidgetAccountSnapshot(
                account: "Assets:Bank:Daily",
                label: "日常账户",
                group: "cash",
                currency: "CNY",
                balance: 826_420,
                valuationCurrency: "CNY",
                valuation: 826_420
            ),
            LedgerWidgetAccountSnapshot(
                account: "Liabilities:CreditCard",
                label: "信用卡",
                group: "credit",
                currency: "CNY",
                balance: -289_900,
                valuationCurrency: "CNY",
                valuation: -289_900
            ),
        ],
        imports: [
            LedgerWidgetImportSnapshot(
                provider: "alipay",
                label: "支付宝",
                coverageStart: "2026-08-01",
                coverageEnd: "2026-08-28"
            ),
            LedgerWidgetImportSnapshot(
                provider: "wechat",
                label: "微信支付",
                coverageStart: "2026-08-01",
                coverageEnd: "2026-08-25"
            ),
            LedgerWidgetImportSnapshot(
                provider: "cmb",
                label: "招行信用卡",
                coverageStart: "2026-07-01",
                coverageEnd: "2026-07-31"
            ),
            LedgerWidgetImportSnapshot(
                provider: "hsbchk-credit",
                label: "汇丰香港信用卡",
                coverageStart: "2026-07-01",
                coverageEnd: "2026-07-31"
            ),
        ],
        importsUpdatedAt: Date()
        )
        let today = LedgerWidgetDates.day(Date())
        let week = LedgerWidgetDates.weekStart(today)
        let start = LedgerWidgetDates.adding(-77, to: week)
        let end = LedgerWidgetDates.adding(1, to: today)
        let daily = (0..<84).compactMap { index -> LedgerWidgetDailyExpense? in
            let day = LedgerWidgetDates.adding(index, to: start)
            guard day < end else { return nil }
            let amount = index % 6 == 0 ? 0 : (index * 37 % 149 + 18) * 100 + index * 13 % 100
            return LedgerWidgetDailyExpense(date: day, amount: amount)
        }
        func expense(start: String, end: String) -> LedgerWidgetExpenseSnapshot {
            let points = daily.filter { $0.date >= start && $0.date < end }
            let total = points.reduce(0) { $0 + $1.amount }
            let categories = snapshot.expense.categories.enumerated().map { index, category in
                LedgerWidgetExpenseCategory(account: category.account, label: category.label,
                    amount: total * [55, 30, 15][index] / 100)
            }
            return LedgerWidgetExpenseSnapshot(periodTitle: "示例", start: start, end: end, currency: "CNY",
                amount: total, transactionCount: points.filter { $0.amount > 0 }.count,
                yearOverYearPercentage: -0.126, categories: categories, dailySeries: points)
        }
        snapshot.insights = LedgerWidgetExpenseInsights(updatedAt: ISO8601DateFormatter().string(from: snapshot.updatedAt),
            week: expense(start: week, end: LedgerWidgetDates.adding(7, to: week)),
            year: expense(start: String(today.prefix(4)) + "-01-01", end: String(Int(today.prefix(4))! + 1) + "-01-01"),
            history: expense(start: start, end: end))
        let month = String(today.prefix(7)) + "-01"
        let monthEnd = LedgerWidgetDates.day(LedgerWidgetDates.calendar.date(byAdding: .month, value: 1,
            to: LedgerWidgetDates.date(month)!)!)
        var result = LedgerWidgetSnapshot(updatedAt: snapshot.updatedAt, expense: expense(start: month, end: monthEnd),
            accounts: snapshot.accounts, imports: snapshot.imports, importsUpdatedAt: snapshot.importsUpdatedAt)
        result.insights = snapshot.insights
        return result
    }()
}
