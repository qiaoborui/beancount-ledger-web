#if os(iOS)
import SwiftUI

/// The bottom bar of a local ledger, the way the Claude app draws its own: a
/// 44pt row of icons under the content, no capsule, no glass and no names.
/// 账本助手 is the first icon, then the chosen tabs and 更多. The selected
/// icon is drawn in ink with a slightly heavier weight; the others are a
/// light grey. Nothing sits behind the selected one.
///
/// The bar never minimizes. Long-pressing an icon with a large accessibility
/// text size shows its name (the large content viewer), and VoiceOver reads
/// the name. Design: `docs/design/ios-balanced/agent-home.html`.
struct LedgerIconTabBar: View {
    let model: LedgerIconTabBarModel
    /// The row's width, for finding the icon under a dragging finger.
    @State private var width: CGFloat = 0

    static let height: CGFloat = 44
    private static let inset: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.destinations) { destination in
                item(destination)
            }
        }
        .padding(.horizontal, Self.inset)
        .frame(height: Self.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // A finger sliding along the row changes tab as it passes each icon,
        // as Claude's bar does. Alongside the buttons, so a tap and a long
        // press still reach them.
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { drag in
                    guard let destination = destination(at: drag.location.x) else { return }
                    select(destination)
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("标签栏")
        .accessibilityIdentifier("ledger-icon-tab-bar")
    }

    private func destination(at x: CGFloat) -> LedgerDestination? {
        let count = model.destinations.count
        let span = width - Self.inset * 2
        guard count > 0, span > 0 else { return nil }
        let index = Int(((x - Self.inset) / (span / CGFloat(count))).rounded(.down))
        return model.destinations[min(max(index, 0), count - 1)]
    }

    private func select(_ destination: LedgerDestination) {
        guard destination != model.selection else { return }
        LedgerFeedback.selection()
        model.select(destination)
    }

    private func item(_ destination: LedgerDestination) -> some View {
        let selected = destination == model.selection
        return Button {
            select(destination)
        } label: {
            glyph(destination, selected: selected)
                .foregroundStyle(selected ? BalancedPalette.ink : BalancedPalette.meta.opacity(0.55))
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A long press offers the shortcuts that tab leads to: on 更多, the
        // pages that are not in the bar.
        .contextMenu {
            ForEach(model.shortcuts(destination), id: \.self) { link in
                Button(link.title, systemImage: link.systemImage) { model.open(link.url) }
            }
        }
        .accessibilityLabel(destination.barTitle)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("ledger-tab-\(destination.barTitle)")
        .accessibilityShowsLargeContentViewer {
            glyph(destination, selected: selected)
            Text(destination.barTitle)
        }
    }

    @ViewBuilder private func glyph(_ destination: LedgerDestination, selected: Bool) -> some View {
        switch destination {
        case .agent:
            // The app's own mark, the same one over the greeting.
            LedgerTabMark.image
                .resizable()
                .frame(width: 25, height: 25)
        case .settings:
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: selected ? .semibold : .regular))
                .frame(width: 25, height: 25)
        default:
            Image(systemName: destination.systemImage)
                .font(.system(size: 19, weight: selected ? .semibold : .regular))
                .frame(width: 25, height: 25)
        }
    }
}

/// What the bar shows and how it changes tabs. The shell hands it to every
/// tab: the ledger pages draw the bar under themselves, and 账本助手 draws it
/// under its composer, inside the card the history drawer pushes aside.
struct LedgerIconTabBarModel: Equatable {
    var destinations: [LedgerDestination]
    var selection: LedgerDestination
    var select: @MainActor (LedgerDestination) -> Void
    /// Opens a shortcut's `ledger://` link, as the widget and the icon menu do.
    var open: @MainActor (URL) -> Void = { _ in }

    /// What a long press on a tab offers. 更多 lists the pages that are not
    /// in the bar; every other tab offers 记一笔 and 搜索, the two things
    /// worth reaching from anywhere.
    func shortcuts(_ destination: LedgerDestination) -> [LedgerQuickLink] {
        if destination == .settings {
            return LedgerDestination.allCases
                .filter { !destinations.contains($0) && $0 != .search }
                .compactMap { LedgerQuickLink(rawValue: $0.rawValue) }
        }
        return [.record, .search]
    }

    /// What the bar shows. The shell builds a new model, with a new closure,
    /// each time it draws; compared by what it shows, the model left in the
    /// environment changes only with the tabs or the selection, and a page
    /// that reads it (账本助手, mid-reply) is not drawn again for nothing.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.destinations == rhs.destinations && lhs.selection == rhs.selection
    }
}

private struct LedgerIconTabBarKey: EnvironmentKey {
    // Computed: the model holds a closure, so it is not Sendable.
    static var defaultValue: LedgerIconTabBarModel? { nil }
}

private struct LedgerTabSelectedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// The icon bar of the shell this page is a tab of; nil on iPad, on a
    /// remote ledger and on pages that are not a tab.
    var ledgerIconTabBar: LedgerIconTabBarModel? {
        get { self[LedgerIconTabBarKey.self] }
        set { self[LedgerIconTabBarKey.self] = newValue }
    }

    /// False while this tab is kept alive behind another one.
    var ledgerTabSelected: Bool {
        get { self[LedgerTabSelectedKey.self] }
        set { self[LedgerTabSelectedKey.self] = newValue }
    }
}

extension View {
    /// The icon bar under a ledger page, with the page's ground fading in
    /// behind it so content scrolled under it does not show through.
    func ledgerIconTabBar(_ model: LedgerIconTabBarModel) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            LedgerIconTabBar(model: model)
                .background(alignment: .bottom) {
                    LinearGradient(stops: [.init(color: BalancedPalette.page.opacity(0), location: 0),
                                           .init(color: BalancedPalette.page, location: 0.4)],
                                   startPoint: .top, endPoint: .bottom)
                        .padding(.top, -20)
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                }
        }
    }
}

/// The tabs of a local ledger on a phone. Each tab keeps its navigation
/// stack once it has been opened, as a `TabView` would, but the system tab
/// bar is not used: every tab draws `LedgerIconTabBar` itself, so on
/// 账本助手 the bar is part of the page the history drawer pushes aside.
struct LedgerIconTabShell<Content: View>: View {
    let model: LedgerIconTabBarModel
    @ViewBuilder var content: (LedgerDestination) -> Content
    /// The tabs opened so far; they stay mounted behind the selected one.
    @State private var opened: Set<LedgerDestination> = []

    var body: some View {
        ZStack {
            ForEach(model.destinations) { destination in
                if destination == model.selection || opened.contains(destination) {
                    let selected = destination == model.selection
                    content(destination)
                        .environment(\.ledgerIconTabBar, model)
                        .environment(\.ledgerTabSelected, selected)
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .accessibilityHidden(!selected)
                        .zIndex(selected ? 1 : 0)
                }
            }
        }
        .onChange(of: model.selection, initial: true) { _, selection in
            opened.insert(selection)
        }
    }
}
#endif
