import SwiftUI
import WidgetKit

enum LedgerWidgetColors {
    static let canvas = Color.dynamic(light: 0xF6F7F9, dark: 0x020407)
    static let panel = Color.dynamic(light: 0xFFFFFF, dark: 0x070A10)
    static let raised = Color.dynamic(light: 0xE4EBF4, dark: 0x0E141C)
    static let tag = Color.dynamic(light: 0xDDE7F5, dark: 0x0C1827)
    static let ink = Color.dynamic(light: 0x0C1219, dark: 0xE8EBF1)
    static let secondary = Color.dynamic(light: 0x515962, dark: 0x808A97)
    static let line = Color.dynamic(light: 0xD1D6DE, dark: 0x232932)
    static let cobalt = Color.dynamic(light: 0x004CA4, dark: 0x2B7AD6)
    static let expense = Color.dynamic(light: 0xA14E2B, dark: 0xF19E6A)
    static let success = Color.dynamic(light: 0x006D3A, dark: 0x60C385)
    static let gold = Color.dynamic(light: 0x916600, dark: 0xE4B65C)
    static let onBrand = Color(red: 0.985, green: 0.99, blue: 1)
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
    var body: some View {
        Image(systemName: "waveform.path.ecg")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LedgerWidgetColors.onBrand)
            .frame(width: 28, height: 28)
            .background(LedgerWidgetColors.cobalt)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct LedgerWidgetHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            LedgerWidgetBrandMark()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
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
    static let placeholder = LedgerWidgetSnapshot(
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
}
