import SwiftUI

/// Tokens for the Balanced design language (docs/design/ios-balanced).
/// Chroma is reserved for direction: `income` and `expense`; everything else is ink.
enum BalancedPalette {
    static let page = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x121110) : UIColor(hex: 0xFBFAF8) })
    static let sunken = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1B1918) : UIColor(hex: 0xF1EFE9) })
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xF6F3EE) : UIColor(hex: 0x14100C) })
    static let secondary = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xC4BCB0) : UIColor(hex: 0x453E36) })
    static let meta = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x9A9086) : UIColor(hex: 0x6F675A) })
    static let rule = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x2B2825) : UIColor(hex: 0xE2DED4) })
    static let income = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x4FBFAB) : UIColor(hex: 0x0D5346) })
    static let expense = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xCF7A52) : UIColor(hex: 0x96401F) })
}

struct BalancedAmount: View {
    @EnvironmentObject private var session: LedgerSession
    let minorUnits: Int
    let currency: String
    var size: CGFloat = 15
    var color: Color = BalancedPalette.ink
    var prefix = ""
    var showsCurrency = false
    var body: some View {
        Text(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency, showsCurrency: showsCurrency) : "••••••")
            .font(.system(size: size, weight: .medium)).monospacedDigit().foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.45)
            .accessibilityLabel(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency) : "金额已隐藏")
    }
}

/// System text at a design size that still follows Dynamic Type.
struct BalancedFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight))
    }
}

extension View {
    func balancedFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(BalancedFont(size: size, weight: weight))
    }
}
