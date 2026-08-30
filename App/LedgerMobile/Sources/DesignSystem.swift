import SwiftUI

enum LedgerPalette {
    static let canvas = Color.dynamic(light: 0xF0F4F9, dark: 0x020407)
    static let panel = Color.dynamic(light: 0xFCFEFF, dark: 0x070A10)
    static let raised = Color.dynamic(light: 0xE4EBF4, dark: 0x0E141C)
    static let tag = Color.dynamic(light: 0xDDE7F5, dark: 0x0C1827)
    static let ink = Color.dynamic(light: 0x0C1219, dark: 0xE8EBF1)
    static let warm = Color.dynamic(light: 0x21272F, dark: 0xC4CBD4)
    static let olive = Color.dynamic(light: 0x38404B, dark: 0x9CA6B3)
    static let secondary = Color.dynamic(light: 0x515962, dark: 0x808A97)
    static let line = Color.dynamic(light: 0xD1D6DE, dark: 0x232932)
    static let lineStrong = Color.dynamic(light: 0xB6BFC9, dark: 0x353E49)
    static let cobalt = Color.dynamic(light: 0x004CA4, dark: 0x2B7AD6)
    static let cobaltLight = Color.dynamic(light: 0x3A7BCB, dark: 0x6AA7F4)
    static let income = Color.dynamic(light: 0x006C7B, dark: 0x2CC3D2)
    static let expense = Color.dynamic(light: 0xA14E2B, dark: 0xF19E6A)
    static let gold = Color.dynamic(light: 0x916600, dark: 0xE4B65C)
    static let risk = Color.dynamic(light: 0xC44134, dark: 0xF87868)
    static let success = Color.dynamic(light: 0x006D3A, dark: 0x60C385)
    static let onBrand = Color(red: 0.985, green: 0.99, blue: 1)
}

enum LedgerSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
}

enum LedgerRadius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 12
    static let pill: CGFloat = 999
}

enum LedgerLayout {
    static let sidebarWidth: CGFloat = 208
    static let regularContentWidth: CGFloat = 1120
    static let regularPagePadding: CGFloat = 24
    static let compactTabBarClearance: CGFloat = 104
}

extension Color {
    fileprivate static func dynamic(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    fileprivate convenience init(hex: UInt) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct LedgerBrandMark: View {
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: "waveform.path.ecg")
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(LedgerPalette.onBrand)
            .frame(width: size, height: size)
            .background(LedgerPalette.cobalt)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct LedgerAppBar<Trailing: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.ledgerSidebarVisibility) private var sidebarVisibility
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: LedgerSpacing.md) {
            if horizontalSizeClass != .regular {
                LedgerBrandMark()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ledger")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("个人财务工作台")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            } else if let sidebarVisibility {
                LedgerToolbarButton(
                    action: {
                        sidebarVisibility.wrappedValue = isSidebarHidden ? .all : .detailOnly
                    },
                    accessibilityLabel: isSidebarHidden ? "展开侧边栏" : "收起侧边栏"
                ) {
                    Image(systemName: "sidebar.left")
                }
            }
            Spacer(minLength: LedgerSpacing.sm)
            trailing
        }
        .padding(.horizontal, horizontalSizeClass == .regular ? LedgerSpacing.xxl : LedgerSpacing.lg)
        .frame(minHeight: horizontalSizeClass == .regular ? 56 : 60)
        .background(LedgerPalette.panel)
        .background(LedgerPalette.panel.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle().fill(LedgerPalette.line).frame(height: 1)
        }
    }

    private var isSidebarHidden: Bool {
        sidebarVisibility?.wrappedValue == .detailOnly
    }
}

private struct LedgerSidebarVisibilityKey: EnvironmentKey {
    static let defaultValue: Binding<NavigationSplitViewVisibility>? = nil
}

extension EnvironmentValues {
    var ledgerSidebarVisibility: Binding<NavigationSplitViewVisibility>? {
        get { self[LedgerSidebarVisibilityKey.self] }
        set { self[LedgerSidebarVisibilityKey.self] = newValue }
    }
}

private struct LedgerAdaptivePageWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content
            .frame(
                maxWidth: horizontalSizeClass == .regular ? LedgerLayout.regularContentWidth : .infinity,
                alignment: .top
            )
            .padding(.horizontal, horizontalSizeClass == .regular ? LedgerLayout.regularPagePadding : 0)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension View {
    func ledgerAdaptivePageWidth() -> some View {
        modifier(LedgerAdaptivePageWidth())
    }

    func ledgerPrivacyProtectedSheet() -> some View {
        modifier(LedgerPrivacyProtectedSheet())
    }
}

private struct LedgerPrivacyProtectedSheet: ViewModifier {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        ZStack {
            content
            if scenePhase != .active || session.privacyShielded {
                PrivacyCover()
                    .zIndex(1)
            }
        }
    }
}

struct LedgerToolbarButton<Label: View>: View {
    let action: () -> Void
    let accessibilityLabel: String
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 40, height: 40)
                .background(LedgerPalette.canvas)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                        .stroke(LedgerPalette.line, lineWidth: 1)
                }
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

struct LedgerPageIntro<Action: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let title: String
    var detail: String?
    var meta: String?
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .top, spacing: LedgerSpacing.lg) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: LedgerSpacing.md) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.35)
                        .foregroundStyle(LedgerPalette.ink)
                    if let meta {
                        Text(meta)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(LedgerPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.horizontal, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)
        .padding(.vertical, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)
        .background(horizontalSizeClass == .regular ? Color.clear : LedgerPalette.panel)
    }
}

struct LedgerPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(LedgerPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                    .stroke(LedgerPalette.line, lineWidth: 1)
            }
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.15)
                .foregroundStyle(LedgerPalette.ink)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(LedgerPalette.secondary)
            }
        }
    }
}

struct LedgerMetric: View {
    let label: String
    let minorUnits: Int
    let currency: String
    var detail: String
    var color = LedgerPalette.ink
    var primary = false

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
            AmountLabel(
                minorUnits: minorUnits,
                currency: currency,
                font: .system(size: primary ? 24 : 18, weight: .semibold),
                color: color
            )
            .tracking(primary ? -0.65 : -0.35)
            .lineLimit(1)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(LedgerPalette.secondary)
                .lineLimit(2)
        }
        .padding(LedgerSpacing.lg)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(LedgerPalette.panel)
    }
}

struct AmountLabel: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let minorUnits: Int
    let currency: String
    var prefix = ""
    var font: Font = .system(size: 15, weight: .semibold)
    var color: Color = LedgerPalette.ink
    var displayMode: MoneyText.DisplayMode = .adaptive

    var body: some View {
        amountText
            .font(font.monospacedDigit())
            .foregroundStyle(color)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.amountsVisible)
            .accessibilityLabel(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency) : "金额已隐藏")
    }

    @ViewBuilder
    private var amountText: some View {
        if session.amountsVisible {
            switch displayMode {
            case .full:
                Text(prefix + MoneyText.format(minorUnits: minorUnits, currency: currency))
                    .fixedSize(horizontal: true, vertical: false)
            case .adaptive:
                ViewThatFits(in: .horizontal) {
                    Text(prefix + MoneyText.format(minorUnits: minorUnits, currency: currency))
                        .fixedSize(horizontal: true, vertical: false)
                    Text(prefix + MoneyText.formatCompact(minorUnits: minorUnits, currency: currency))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        } else {
            Text("••••••")
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct StatusBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: LedgerSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(LedgerPalette.risk)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(LedgerPalette.warm)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .foregroundStyle(LedgerPalette.secondary)
            .accessibilityLabel("关闭提示")
        }
        .padding(LedgerSpacing.md)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.risk.opacity(0.42), lineWidth: 1)
        }
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct PrimaryButtonLabel: View {
    let title: String
    let loading: Bool

    var body: some View {
        HStack(spacing: LedgerSpacing.sm) {
            if loading {
                ProgressView().tint(LedgerPalette.onBrand)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(LedgerPalette.onBrand)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(LedgerPalette.cobalt)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
    }
}

struct PrivacyToolbarButton: View {
    @EnvironmentObject private var session: LedgerSession

    var body: some View {
        LedgerToolbarButton(
            action: session.toggleAmounts,
            accessibilityLabel: session.amountsVisible ? "隐藏金额" : "显示金额"
        ) {
            Image(systemName: session.amountsVisible ? "eye.slash" : "eye")
        }
    }
}

struct EmptyLedgerState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: LedgerSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 44, height: 44)
                .background(LedgerPalette.tag)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LedgerPalette.ink)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(LedgerPalette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LedgerSpacing.xxl)
        .background(LedgerPalette.canvas)
    }
}
