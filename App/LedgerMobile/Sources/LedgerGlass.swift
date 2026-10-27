import SwiftUI

/// Liquid Glass for the app's own chrome, so the custom top bar, docked action
/// bars and native editor bars read as one material with the system tab bar on
/// iOS 26. Earlier systems keep the flat Balanced surfaces (page fill + rule).
enum LedgerGlass {
    static let controlHeight: CGFloat = 44
    static let dockRadius: CGFloat = 26

    static let isAvailable: Bool = {
        if #available(iOS 26.0, *) { return true }
        return false
    }()
}

extension View {
    /// Top-bar chrome: on iOS 26 a `safeAreaBar`, so scrolled content blurs
    /// under it through the system scroll edge effect instead of a page fill.
    @ViewBuilder
    func ledgerGlassTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        let content = bar()
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0) { content }
        } else {
            safeAreaInset(edge: .top, spacing: 0) { content.background(BalancedPalette.page) }
        }
    }

    /// One interactive glass capsule behind a top-bar control or control group.
    @ViewBuilder
    func ledgerGlassControl() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self
        }
    }

    /// A bottom action bar docked through `safeAreaInset`: a floating glass
    /// panel on iOS 26, the page fill under a top rule before it.
    /// `margin` insets the floating panel from the screen edges; pass 0 when
    /// the caller already pads around the dock.
    @ViewBuilder
    func ledgerGlassDock(margin: CGFloat = 12) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: LedgerGlass.dockRadius, style: .continuous))
                .padding(.horizontal, margin)
                .padding(.bottom, margin / 3)
        } else {
            background(BalancedPalette.page)
                .overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
        }
    }

    /// System navigation bars: iOS 26 draws them as glass with a scroll edge
    /// effect, which an opaque `toolbarBackground` would cover.
    @ViewBuilder
    func ledgerGlassNavigationBar() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            toolbarBackground(TerminalPalette.page, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

/// Groups adjacent glass controls so they blend and morph together on iOS 26.
struct LedgerGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
