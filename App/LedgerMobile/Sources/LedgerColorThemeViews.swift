import SwiftUI
import UIKit

/// Holds the chosen 配色方案 and makes a switch show at once.
///
/// Palette colours are dynamic `UIColor`s that read `LedgerColorTheme.active`
/// whenever they resolve. SwiftUI caches a resolved `UIColor` per appearance
/// and does not resolve it again for an environment change it does not track,
/// so `RootView` rebuilds its shell with `.id(theme)` on a switch. UIKit chrome
/// re-resolves when a colour-affecting trait changes, so the scheme is also
/// set as a custom trait on every window scene.
@MainActor
final class LedgerColorThemeStore: ObservableObject {
    static let shared = LedgerColorThemeStore()

    @Published private(set) var theme: LedgerColorTheme

    private init() {
        theme = LedgerColorTheme.active
    }

    func select(_ newTheme: LedgerColorTheme) {
        guard newTheme != theme else { return }
        newTheme.store()
        LedgerColorTheme.active = newTheme
        theme = newTheme
        applyToWindows()
    }

    /// Sets the scheme trait on every connected window scene. Called on launch
    /// too, so a scene's traits always name the scheme in use.
    func applyToWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.traitOverrides[LedgerColorThemeTrait.self] = theme
        }
    }
}

/// The scheme as a UIKit trait. `affectsColorAppearance` makes UIKit redraw
/// and re-resolve dynamic colours when it changes.
struct LedgerColorThemeTrait: UITraitDefinition {
    static let defaultValue: LedgerColorTheme = LedgerColorTheme.defaultTheme
    static let identifier = "com.qiaoborui.ledger.colorTheme"
    static let name = "LedgerColorTheme"
    static let affectsColorAppearance = true
}

private extension Color {
    init(ledgerHex hex: UInt32) {
        self.init(uiColor: UIColor(hex: UInt(hex)))
    }
}

/// 设置 › 外观 › 配色方案: one card per scheme, each showing its light and
/// dark ground with a balance, an income and an expense on it.
struct LedgerColorThemePicker: View {
    @ObservedObject private var store = LedgerColorThemeStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(LedgerColorTheme.allCases) { theme in
                    option(theme)
                }
                Text("配色方案只改变背景与文字的色调，收入、支出的颜色保持不变。浅色与深色跟随系统外观。")
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
        .background(BalancedPalette.page)
        .ledgerNavigation(String(localized: "配色方案"), isRoot: false)
    }

    private func option(_ theme: LedgerColorTheme) -> some View {
        let isSelected = store.theme == theme
        return Button {
            withLedgerAnimation(LedgerMotion.selection) { store.select(theme) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(theme.title).balancedFont(size: 15, weight: .medium).foregroundStyle(BalancedPalette.ink)
                        Text(theme.detail).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(isSelected ? BalancedPalette.ink : BalancedPalette.edge)
                }
                HStack(spacing: 8) {
                    swatch(theme.tokens(dark: false))
                    swatch(theme.tokens(dark: true))
                }
            }
            .padding(14)
            .background(BalancedPalette.sunken, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? BalancedPalette.ink : Color.clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.title)，\(theme.detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("color-theme-\(theme.rawValue)")
    }

    /// A miniature page: the ground, a sunken band with a balance, and an
    /// income and expense row, in the scheme's own tones for one appearance.
    private func swatch(_ tokens: LedgerThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("净资产").balancedFont(size: 9.5).foregroundStyle(Color(ledgerHex: tokens.meta))
                Text(verbatim: "128,460.00").balancedFont(size: 14, weight: .medium).monospacedDigit()
                    .foregroundStyle(Color(ledgerHex: tokens.ink))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(ledgerHex: tokens.card), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            row(String(localized: "工资"), amount: "+18,000", color: tokens.income, tokens: tokens)
            Rectangle().fill(Color(ledgerHex: tokens.rule)).frame(height: 1)
            row(String(localized: "午餐"), amount: "-36.50", color: tokens.expense, tokens: tokens)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color(ledgerHex: tokens.page), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(ledgerHex: tokens.rule), lineWidth: 1)
        }
    }

    private func row(_ title: String, amount: String, color: UInt32, tokens: LedgerThemeTokens) -> some View {
        HStack {
            Text(title).balancedFont(size: 11).foregroundStyle(Color(ledgerHex: tokens.secondary))
            Spacer(minLength: 4)
            Text(verbatim: amount).balancedFont(size: 11).monospacedDigit().foregroundStyle(Color(ledgerHex: color))
        }
        .padding(.horizontal, 2)
    }
}
