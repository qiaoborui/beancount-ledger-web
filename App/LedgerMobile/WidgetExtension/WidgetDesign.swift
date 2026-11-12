import SwiftUI
import UIKit
import WidgetKit

/// Balanced tokens (Sources/BalancedDesignSystem.swift), restated here because
/// the extension does not compile the app's design system. There is no accent:
/// ink carries emphasis, and `expense` marks only the chart line, today and heat.
enum LedgerWidgetColors {
    static let page = Color.dynamic(light: 0xFBFAF8, dark: 0x121110)
    static let sunken = Color.dynamic(light: 0xF1EFE9, dark: 0x1B1918)
    static let ink = Color.dynamic(light: 0x14100C, dark: 0xF6F3EE)
    static let secondary = Color.dynamic(light: 0x453E36, dark: 0xC4BCB0)
    static let meta = Color.dynamic(light: 0x6F675A, dark: 0x9A9086)
    static let rule = Color.dynamic(light: 0xE2DED4, dark: 0x2B2825)
    static let ruleStrong = Color.dynamic(light: 0xC8C2B4, dark: 0x423C36)
    static let expense = Color.dynamic(light: 0x96401F, dark: 0xCF7A52)
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

/// The palette as the current rendering mode can show it. Tinted and clear
/// Home Screens (`.accented`, `.vibrant`) keep only each view's opacity, so
/// hierarchy has to come from `.primary`/`.secondary` and alpha, never hue.
struct LedgerWidgetTone {
    let mode: WidgetRenderingMode
    init(_ mode: WidgetRenderingMode) { self.mode = mode }

    var isFullColor: Bool { mode == .fullColor }
    var ink: Color { isFullColor ? LedgerWidgetColors.ink : .primary }
    var secondary: Color { isFullColor ? LedgerWidgetColors.secondary : .secondary }
    var meta: Color { isFullColor ? LedgerWidgetColors.meta : .secondary }
    var rule: Color { isFullColor ? LedgerWidgetColors.rule : Color.primary.opacity(0.2) }
    var ruleStrong: Color { isFullColor ? LedgerWidgetColors.ruleStrong : Color.primary.opacity(0.3) }
    var expense: Color { isFullColor ? LedgerWidgetColors.expense : .primary }
}

/// IBM Plex Sans, bundled through the extension's UIAppFonts. `Font.custom`
/// falls back to the system face if registration fails. Sizes stay fixed, as
/// widgets do not follow Dynamic Type.
enum LedgerWidgetFont {
    /// Weight 450, the workhorse for labels and secondary figures.
    static func text(_ size: CGFloat) -> Font { .custom("IBMPlexSans-Text", fixedSize: size) }
    static func medium(_ size: CGFloat) -> Font { .custom("IBMPlexSans-Medm", fixedSize: size) }
}

struct LedgerWidgetHeader: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let title: String
    let detail: String

    var body: some View {
        let tone = LedgerWidgetTone(renderingMode)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(LedgerWidgetFont.medium(12))
                .foregroundStyle(tone.ink).lineLimit(1)
            Spacer(minLength: 0)
            Text(detail).font(LedgerWidgetFont.text(10))
                .foregroundStyle(tone.meta).lineLimit(1)
        }
    }
}

/// Shared by the "no data" and stale-period states. The parent widget owns the
/// container background.
struct LedgerWidgetUnavailableView: View {
    enum Reason {
        case refresh
        case message(String, detail: String)
    }

    @Environment(\.widgetRenderingMode) private var renderingMode
    /// The widget's name, shown beside the brand so a blank tile stays identifiable.
    let title: String
    var reason: Reason = .refresh

    var body: some View {
        let tone = LedgerWidgetTone(renderingMode)
        VStack(alignment: .leading, spacing: 4) {
            LedgerWidgetHeader(title: "Ledger", detail: title)
            Spacer(minLength: 0)
            Text(line).font(LedgerWidgetFont.text(12)).foregroundStyle(tone.ink)
                .lineLimit(2)
            if let detail {
                Text(detail).font(LedgerWidgetFont.text(10)).foregroundStyle(tone.meta)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .unredacted()
    }

    private var line: String {
        switch reason {
        case .refresh: String(localized: "打开 Ledger 刷新")
        case let .message(text, _): text
        }
    }

    private var detail: String? {
        if case let .message(_, detail) = reason { return detail }
        return nil
    }
}

enum LedgerWidgetText {
    /// "+12%" or "-8%": the sign carries direction, so no arrow is needed.
    static func signedPercentage(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = LedgerLocale.current
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.positivePrefix = "+" + (formatter.positivePrefix ?? "")
        return formatter.string(from: NSNumber(value: value)) ?? "--"
    }

    static func updated(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = LedgerLocale.current
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "MM/dd HH:mm"
        return String(localized: "更新于 \(formatter.string(from: date))")
    }
}

extension LedgerWidgetSnapshot {
    static let placeholder: LedgerWidgetSnapshot = {
        var snapshot = LedgerWidgetSnapshot(
        updatedAt: Date(),
        expense: LedgerWidgetExpenseSnapshot(
            periodTitle: String(localized: "2026年8月"),
            start: "2026-08-01",
            end: "2026-09-01",
            currency: "CNY",
            amount: 555_180,
            transactionCount: 9,
            yearOverYearPercentage: -0.126,
            categories: [
                LedgerWidgetExpenseCategory(account: "Expenses:Housing", label: String(localized: "居住"), amount: 380_000),
                LedgerWidgetExpenseCategory(account: "Expenses:Food", label: String(localized: "餐饮"), amount: 84_780),
                LedgerWidgetExpenseCategory(account: "Expenses:Travel", label: String(localized: "出行"), amount: 57_600),
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
                label: String(localized: "日常账户"),
                group: "cash",
                currency: "CNY",
                balance: 826_420,
                valuationCurrency: "CNY",
                valuation: 826_420
            ),
            LedgerWidgetAccountSnapshot(
                account: "Liabilities:CreditCard",
                label: String(localized: "信用卡"),
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
                label: String(localized: "支付宝"),
                coverageStart: "2026-08-01",
                coverageEnd: "2026-08-28"
            ),
            LedgerWidgetImportSnapshot(
                provider: "wechat",
                label: String(localized: "微信支付"),
                coverageStart: "2026-08-01",
                coverageEnd: "2026-08-25"
            ),
            LedgerWidgetImportSnapshot(
                provider: "cmb",
                label: String(localized: "招行信用卡"),
                coverageStart: "2026-07-01",
                coverageEnd: "2026-07-31"
            ),
            LedgerWidgetImportSnapshot(
                provider: "hsbchk-credit",
                label: String(localized: "汇丰香港信用卡"),
                coverageStart: "2026-07-01",
                coverageEnd: "2026-07-31"
            ),
        ],
        importsUpdatedAt: Date()
        )
        // The local day, so the preview covers the period the widgets gate on.
        let today = LedgerWidgetDates.localDay(Date())
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
            return LedgerWidgetExpenseSnapshot(periodTitle: String(localized: "示例"), start: start, end: end, currency: "CNY",
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

/// A figure: the currency symbol at 0.6x in meta, then the number in ink with
/// tabular digits. Two Texts in one baseline-aligned stack (Text + Text is
/// deprecated), redacted together. Callers always state the size: 27 for the
/// hero figure, 15 or 23 for secondary ones.
struct LedgerWidgetAmount: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let amount: Int
    let currency: String
    let size: CGFloat

    var body: some View {
        let tone = LedgerWidgetTone(renderingMode)
        let code = currency.isEmpty ? "CNY" : currency
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            if amount < 0 {
                Text(verbatim: "-").font(LedgerWidgetFont.medium(size)).foregroundStyle(tone.ink)
            }
            Text(verbatim: MoneyText.currencySymbol(for: code).trimmingCharacters(in: .whitespaces))
                .font(LedgerWidgetFont.text(size * 0.6)).foregroundStyle(tone.meta)
                .fixedSize()
            Text(verbatim: MoneyText.format(minorUnits: MoneyText.magnitude(amount), currency: code, showsCurrency: false))
                .font(LedgerWidgetFont.medium(size)).monospacedDigit().tracking(-0.01 * size)
                .foregroundStyle(tone.ink)
                .minimumScaleFactor(0.4).allowsTightening(true)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MoneyText.format(minorUnits: amount, currency: code))
        .privacySensitive()
    }
}

/// Bottom line in meta: an optional label, then when the data was published.
struct LedgerWidgetFooter: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    var label: String? = nil
    let date: Date?
    let now: Date

    var body: some View {
        HStack(spacing: 4) {
            if let label { Text(label).lineLimit(1) }
            Spacer(minLength: 0)
            Text(date.map { LedgerWidgetText.updated($0, now: now) } ?? String(localized: "尚未更新")).lineLimit(1)
        }
        .font(LedgerWidgetFont.text(10)).monospacedDigit()
        .foregroundStyle(LedgerWidgetTone(renderingMode).meta)
    }
}

/// The filled call to action. In full colour it is ink with page-coloured
/// content; a tinted or clear Home Screen would flatten fill and label into
/// one tint, so there it becomes a 1pt outline and the content stays primary.
struct LedgerWidgetPrimaryButtonStyle: ViewModifier {
    @Environment(\.widgetRenderingMode) private var renderingMode
    var shape: AnyShape = AnyShape(Capsule(style: .continuous))

    func body(content: Content) -> some View {
        if renderingMode == .fullColor {
            content
                .foregroundStyle(LedgerWidgetColors.page)
                .background(shape.fill(LedgerWidgetColors.ink))
                .contentShape(shape)
        } else {
            content
                .foregroundStyle(Color.primary)
                .widgetAccentable()
                .overlay(shape.stroke(Color.primary, lineWidth: 1).widgetAccentable())
                .contentShape(shape)
        }
    }
}

/// A secondary button: page on the sunken widget background in full colour;
/// in the other modes a faint wash and a hairline, so the shape survives tinting.
struct LedgerWidgetTileStyle: ViewModifier {
    @Environment(\.widgetRenderingMode) private var renderingMode
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

    func body(content: Content) -> some View {
        let tone = LedgerWidgetTone(renderingMode)
        content
            .foregroundStyle(tone.ink)
            .background {
                if tone.isFullColor {
                    shape.fill(LedgerWidgetColors.page)
                } else {
                    shape.fill(Color.primary.opacity(0.08))
                        .overlay(shape.stroke(tone.ruleStrong, lineWidth: 0.5))
                }
            }
            .contentShape(shape)
    }
}

extension View {
    func ledgerWidgetPrimaryButton(_ shape: some Shape = Capsule(style: .continuous)) -> some View {
        modifier(LedgerWidgetPrimaryButtonStyle(shape: AnyShape(shape)))
    }

    func ledgerWidgetTile(_ shape: some Shape = RoundedRectangle(cornerRadius: 14, style: .continuous)) -> some View {
        modifier(LedgerWidgetTileStyle(shape: AnyShape(shape)))
    }
}

enum LedgerWidgetHeat {
    // Fixed minor-unit thresholds retain comparable intensity across dates.
    static func level(_ amount: Int) -> Int {
        if amount <= 0 { return 0 }
        if amount <= 5_000 { return 1 }
        if amount <= 10_000 { return 2 }
        if amount <= 20_000 { return 3 }
        return 4
    }

    /// Full colour ramps the expense hue over a `rule` floor; the tinted modes
    /// ramp primary opacity, the only channel they keep.
    static func color(level: Int, mode: WidgetRenderingMode = .fullColor) -> Color {
        let level = min(max(level, 0), 4)
        if mode == .fullColor {
            return level == 0 ? LedgerWidgetColors.rule
                : LedgerWidgetColors.expense.opacity([0.25, 0.45, 0.7, 1.0][level - 1])
        }
        return Color.primary.opacity([0.12, 0.3, 0.5, 0.75, 1.0][level])
    }

    static func color(_ amount: Int, mode: WidgetRenderingMode = .fullColor) -> Color {
        color(level: level(amount), mode: mode)
    }

    static func shortDate(_ raw: String) -> String {
        String(raw.suffix(5)).replacingOccurrences(of: "-", with: "/")
    }
}

// MARK: - Glass Live Activity styling

#if !targetEnvironment(macCatalyst)
enum LedgerGlass {
    static let text = Color.white
    static let secondary = Color.white.opacity(0.72)
    static let gold = Color(red: 0xE5 / 255, green: 0xB5 / 255, blue: 0x5F / 255)
    static let success = Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
    static let warning = Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
    static let failure = Color(red: 0xF8 / 255, green: 0x71 / 255, blue: 0x71 / 255)
    static let opaqueFill = Color(red: 0x1E / 255, green: 0x24 / 255, blue: 0x29 / 255)
    /// The mark's ink in dark appearance (ledger-mark.svg).
    static let markInk = Color(red: 0xE1 / 255, green: 0xE7 / 255, blue: 0xE6 / 255)
}

/// Lock-screen card: clear glass on iOS 26, ultra-thin material before it, an
/// opaque fill when Reduce Transparency is on. A faint dark base keeps white
/// text legible over bright wallpapers.
struct LedgerGlassCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let content: Content
    /// Follows the system's own card corner so the glass and stroke meet the
    /// edge exactly; a fixed radius left dark slivers in the corners.
    private let shape = ContainerRelativeShape()

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(minHeight: 104)
            .background { surface }
            .overlay {
                // iOS 26 glass draws its own edge highlight; only the
                // fallback materials need a stroke.
                if !hasNativeGlass {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.28)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.75)
                }
            }
            .clipShape(shape)
            .environment(\.colorScheme, .dark)
    }

    private var hasNativeGlass: Bool {
        if #available(iOS 26.0, *) { return !reduceTransparency }
        return false
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            shape.fill(LedgerGlass.opaqueFill)
        } else {
            ZStack {
                shape.fill(Color.black.opacity(0.12))
                glass
                GeometryReader { proxy in
                    LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: proxy.size.height * 0.4)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var glass: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.clear, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

/// Two-layer lock-screen body: a small header (state word + brand glyph), then
/// a 56pt glass tile, title, detail and a trailing capsule; optional footer.
struct LedgerLockBody<Trailing: View, Footer: View>: View {
    let header: String
    let glyph: LedgerGlyph
    let color: Color
    let title: String
    let detail: String
    let detailLines: Int
    let trailing: Trailing
    let footer: Footer

    init(
        header: String, symbol: String, color: Color, title: String, detail: String, detailLines: Int = 1,
        @ViewBuilder trailing: () -> Trailing, @ViewBuilder footer: () -> Footer
    ) {
        self.init(header: header, glyph: .symbol(symbol), color: color, title: title, detail: detail,
                  detailLines: detailLines, trailing: trailing, footer: footer)
    }

    init(
        header: String, glyph: LedgerGlyph, color: Color, title: String, detail: String, detailLines: Int = 1,
        @ViewBuilder trailing: () -> Trailing, @ViewBuilder footer: () -> Footer
    ) {
        self.header = header
        self.glyph = glyph
        self.color = color
        self.title = title
        self.detail = detail
        self.detailLines = detailLines
        self.trailing = trailing()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(header)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .ledgerGlassTextShadow()
                Spacer()
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
            }
            HStack(spacing: 14) {
                LedgerGlyphImage(glyph: glyph, color: color, size: 22, weight: .medium)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.30), lineWidth: 0.75))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LedgerGlass.text)
                        .ledgerGlassTextShadow()
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .ledgerGlassTextShadow()
                        .lineLimit(detailLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                trailing
            }
            footer
        }
        .accessibilityElement(children: .combine)
    }
}

struct LedgerGlassBadge: View {
    let glyph: LedgerGlyph
    let color: Color
    let size: CGFloat
    let symbolSize: CGFloat

    init(symbol: String, color: Color, size: CGFloat = 38, symbolSize: CGFloat = 17) {
        self.init(glyph: .symbol(symbol), color: color, size: size, symbolSize: symbolSize)
    }

    init(glyph: LedgerGlyph, color: Color, size: CGFloat = 38, symbolSize: CGFloat = 17) {
        self.glyph = glyph
        self.color = color
        self.size = size
        self.symbolSize = symbolSize
    }

    var body: some View {
        LedgerGlyphImage(glyph: glyph, color: color, size: symbolSize)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(0.16)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.30), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// What a glass tile or badge shows: an SF Symbol, or the app's mark.
enum LedgerGlyph: Equatable {
    case symbol(String)
    case mark
}

/// A glyph at a symbol's point size. The mark is drawn that many points
/// square, about the footprint of a symbol at that size.
struct LedgerGlyphImage: View {
    let glyph: LedgerGlyph
    let color: Color
    let size: CGFloat
    var weight: Font.Weight = .semibold

    var body: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
        case .mark:
            LedgerMark(accent: color)
                .frame(width: size, height: size)
        }
    }
}

/// The app's mark, Supporting/AppIcon/ledger-mark.svg: a page with an L cut
/// out of it and an accent corner fold. Drawn as shapes, so it stays crisp at
/// Dynamic Island sizes without an asset catalog in the extension. The ink is
/// the mark's dark-appearance colour, as Live Activities sit on black or glass.
struct LedgerMark: View {
    var ink: Color = LedgerGlass.markInk
    var accent: Color = LedgerGlass.gold

    var body: some View {
        ZStack {
            LedgerMarkShape(part: .page).fill(ink, style: FillStyle(eoFill: true))
            LedgerMarkShape(part: .fold).fill(accent)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// One path of the mark. The svg's 64-unit view box has the mark in its
/// 40-unit middle (12...52); that square is fitted to the rect, centred.
struct LedgerMarkShape: Shape {
    enum Part { case page, fold }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 40
        let originX = rect.midX - 20 * scale
        let originY = rect.midY - 20 * scale
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + (x - 12) * scale, y: originY + (y - 12) * scale)
        }
        var path = Path()
        switch part {
        case .page:
            // M12 12H36V28H52V52H12Z, less the L: M22 22H28V40H42V46H22Z.
            path.addLines([point(12, 12), point(36, 12), point(36, 28), point(52, 28), point(52, 52), point(12, 52)])
            path.closeSubpath()
            path.addLines([point(22, 22), point(28, 22), point(28, 40), point(42, 40), point(42, 46), point(22, 46)])
            path.closeSubpath()
        case .fold:
            // M40 12L52 24H40Z
            path.addLines([point(40, 12), point(52, 24), point(40, 24)])
            path.closeSubpath()
        }
        return path
    }
}

/// The in-app island's language for Live Activities: a solid hue disc with a
/// dark glyph, not a glass ring. Hues match `LedgerIslandNoticeType.hueHex`
/// in the app (the extension does not compile LedgerModels).
enum LedgerIslandHue {
    static let expense = Color(red: 0xCF / 255, green: 0x7A / 255, blue: 0x52 / 255)
    static let income = Color(red: 0x4F / 255, green: 0xBF / 255, blue: 0xAB / 255)
    static let neutral = Color.white
}

struct LedgerIslandDiscBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28
    var symbolSize: CGFloat = 13

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: symbolSize, weight: .bold))
            .foregroundStyle(Color.black)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .accessibilityHidden(true)
    }
}

/// One clean track: a white hairline groove and a hue fill. No segments, no
/// glow; the fraction is whatever stage the caller can actually vouch for.
struct LedgerIslandProgressBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule().fill(color)
                    .frame(width: max(height, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct LedgerGlassPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.30), lineWidth: 0.5))
    }
}

extension View {
    func ledgerGlassTextShadow() -> some View {
        shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
#endif
