#if os(iOS)
import SwiftUI

/// The bottom bar of a local ledger, the way the Claude app draws its own: a
/// 44pt row of icons under the content, no capsule, no glass and no names.
/// 账本助手 is the first icon, then the chosen tabs and 更多. The selected
/// icon is drawn in ink with a slightly heavier weight on a soft rounded
/// ground; the others are a light grey.
///
/// As in Claude's bar, a finger sliding along the row carries the ground
/// with it and names the icon under it in a dark tip above the bar; letting
/// go there changes tab. Holding an icon opens a card of shortcuts over the
/// bar (`LedgerIconTabMenu`, drawn by the shell so it can lie over the
/// page). The bar never minimizes. VoiceOver reads each icon's name.
/// Design: `docs/design/ios-balanced/agent-home.html`.
struct LedgerIconTabBar: View {
    let model: LedgerIconTabBarModel
    @Environment(LedgerIconTabMenu.self) private var menu: LedgerIconTabMenu?
    /// The row's width, for finding the icon under a finger.
    @State private var width: CGFloat = 0
    /// The icon a sliding finger is over; the ground follows it.
    @State private var target: LedgerDestination?
    @State private var press: Press?

    static let height: CGFloat = 44
    private static let inset: CGFloat = 12
    private static let holdDelay: Duration = .milliseconds(260)

    private struct Press {
        var sliding = false
        var held = false
        var timer: Task<Void, Never>?
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.destinations) { destination in
                item(destination)
            }
        }
        .padding(.horizontal, Self.inset)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .gesture(touch)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("标签栏")
        .accessibilityIdentifier("ledger-icon-tab-bar")
    }

    /// One touch drives all three: a tap selects, a hold opens the menu, a
    /// slide names the icon under the finger and selects it on release.
    private var touch: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if press == nil { began(at: drag.startLocation.x) }
                guard var current = press, !current.held else { return }
                if !current.sliding, abs(drag.translation.width) > 6 || abs(drag.translation.height) > 10 {
                    current.sliding = true
                    current.timer?.cancel()
                    press = current
                }
                guard current.sliding, let over = destination(at: drag.location.x) else { return }
                if over != target {
                    LedgerFeedback.selection()
                    withAnimation(.easeOut(duration: 0.18)) { target = over }
                }
                // The tip rides under the finger itself, not from icon to
                // icon; only its name changes as it crosses one.
                let x = min(max(drag.location.x, Self.inset + 24), width - Self.inset - 24)
                menu?.moveTip(title: over.barTitle, x: x)
            }
            .onEnded { drag in
                defer { ended() }
                guard let current = press, !current.held else { return }
                let over = current.sliding ? target : destination(at: drag.location.x)
                if let over { select(over) }
            }
    }

    private func began(at x: CGFloat) {
        let pressed = destination(at: x)
        let timer = Task { @MainActor in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, let pressed, var current = press, !current.sliding else { return }
            current.held = true
            press = current
            LedgerFeedback.light()
            menu?.show(model.shortcuts(pressed), from: center(of: pressed), open: model.open)
        }
        press = Press(timer: timer)
    }

    private func ended() {
        press?.timer?.cancel()
        press = nil
        menu?.hideTip()
        withAnimation(.easeOut(duration: 0.2)) { target = nil }
    }

    private func destination(at x: CGFloat) -> LedgerDestination? {
        let count = model.destinations.count
        let span = width - Self.inset * 2
        guard count > 0, span > 0 else { return nil }
        let index = Int(((x - Self.inset) / (span / CGFloat(count))).rounded(.down))
        return model.destinations[min(max(index, 0), count - 1)]
    }

    /// An icon's centre along the row; the row spans the screen, so this is
    /// also where it is on screen.
    private func center(of destination: LedgerDestination) -> CGFloat {
        let count = CGFloat(max(model.destinations.count, 1))
        let index = CGFloat(model.destinations.firstIndex(of: destination) ?? 0)
        return Self.inset + (width - Self.inset * 2) / count * (index + 0.5)
    }

    private func select(_ destination: LedgerDestination) {
        guard destination != model.selection else { return }
        LedgerFeedback.selection()
        model.select(destination)
    }

    private func item(_ destination: LedgerDestination) -> some View {
        let selected = destination == model.selection
        let grounded = destination == (target ?? model.selection)
        return glyph(destination, selected: grounded)
            .foregroundStyle(grounded ? BalancedPalette.ink : BalancedPalette.meta.opacity(0.7))
            .frame(width: 64, height: 36)
            // Claude's ground: a wide capsule, barely darker than the page,
            // that fades from one icon to the next.
            .background {
                Capsule(style: .continuous)
                    .fill(BalancedPalette.ink.opacity(0.055))
                    .opacity(grounded ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.2), value: grounded)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(destination.barTitle)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { select(destination) }
            .accessibilityIdentifier("ledger-tab-\(destination.barTitle)")
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

/// What floats over the page from the icon bar: the tip naming the icon
/// under a sliding finger, and the card of shortcuts a held icon opens. The
/// shell owns it and draws both over every tab, so they are not clipped by
/// the bar (on 账本助手 it folds away under the keyboard) and a tap
/// anywhere else can close the card.
@MainActor @Observable
final class LedgerIconTabMenu {
    struct Tip: Equatable {
        var title: String
        var x: CGFloat
    }

    struct Card {
        var items: [LedgerQuickLink]
        var x: CGFloat
        var open: @MainActor (URL) -> Void
    }

    var tip: Tip?
    var card: Card?

    /// Follows the finger in a quick spring, so the tip glides with it
    /// rather than jumping frame to frame; it fades and grows in the first
    /// time.
    func moveTip(title: String, x: CGFloat) {
        if tip == nil {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) { tip = Tip(title: title, x: x) }
            return
        }
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.86)) { tip = Tip(title: title, x: x) }
    }

    func hideTip() {
        guard tip != nil else { return }
        withAnimation(.easeOut(duration: 0.16)) { tip = nil }
    }

    func show(_ items: [LedgerQuickLink], from x: CGFloat, open: @escaping @MainActor (URL) -> Void) {
        guard !items.isEmpty else { return }
        tip = nil
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) { card = Card(items: items, x: x, open: open) }
    }

    func close() {
        withAnimation(.easeOut(duration: 0.18)) { card = nil }
    }
}

/// The tip and the card, over the shell, above the bar's row.
private struct LedgerIconTabMenuLayer: View {
    let menu: LedgerIconTabMenu
    private static let cardWidth: CGFloat = 248

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                if menu.card != nil {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { menu.close() }
                        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in menu.close() })
                        .accessibilityHidden(true)
                }
                if let card = menu.card {
                    cardView(card)
                        .padding(.leading, min(max(card.x - 44, 16), proxy.size.width - Self.cardWidth - 16))
                        .padding(.bottom, LedgerIconTabBar.height + 6)
                        .transition(.scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity))
                }
                if let tip = menu.tip {
                    Text(tip.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BalancedPalette.page)
                        .contentTransition(.opacity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(BalancedPalette.ink))
                        .fixedSize()
                        .position(x: tip.x, y: proxy.size.height - LedgerIconTabBar.height - 4)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .ignoresSafeArea(.keyboard)
    }

    private func cardView(_ card: LedgerIconTabMenu.Card) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(card.items, id: \.self) { link in
                Button {
                    menu.close()
                    card.open(link.url)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: link.systemImage)
                            .font(.system(size: 17, weight: .regular))
                            .frame(width: 24)
                        Text(link.title).balancedFont(size: 16)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(BalancedPalette.ink)
                    .padding(.horizontal, 18)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ledger-tab-menu-\(link.rawValue)")
            }
        }
        .padding(.vertical, 8)
        .frame(width: Self.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(BalancedPalette.card)
                .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(BalancedPalette.edge.opacity(0.6), lineWidth: 0.5)
        )
    }
}

extension View {
    /// The icon bar's tip and shortcut card, drawn over this view.
    func ledgerIconTabMenuLayer(_ menu: LedgerIconTabMenu) -> some View {
        overlay { LedgerIconTabMenuLayer(menu: menu) }
            .environment(menu)
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

private struct LedgerIconTabBarHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The icon bar of the shell this page is a tab of; nil on iPad, on a
    /// remote ledger and on pages that are not a tab.
    var ledgerIconTabBar: LedgerIconTabBarModel? {
        get { self[LedgerIconTabBarKey.self] }
        set { self[LedgerIconTabBarKey.self] = newValue }
    }

    /// True while the shell slides from one tab to the next and draws the
    /// bar itself, still, over both: the pages hide their own.
    var ledgerIconTabBarHidden: Bool {
        get { self[LedgerIconTabBarHiddenKey.self] }
        set { self[LedgerIconTabBarHiddenKey.self] = newValue }
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
            LedgerIconTabBarInset(model: model)
        }
    }
}

/// A ledger page's bar on its fading ground, hidden while the shell slides.
private struct LedgerIconTabBarInset: View {
    let model: LedgerIconTabBarModel
    @Environment(\.ledgerIconTabBarHidden) private var hidden

    var body: some View {
        LedgerIconTabBar(model: model)
            .ledgerIconTabBarGround()
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
    }
}

extension View {
    /// The page's ground fading in behind the bar, so content scrolled under
    /// it does not show through.
    func ledgerIconTabBarGround() -> some View {
        background(alignment: .bottom) {
            LinearGradient(stops: [.init(color: BalancedPalette.page.opacity(0), location: 0),
                                   .init(color: BalancedPalette.page, location: 0.4)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -20)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }
}

/// The tabs of a local ledger on a phone. Each tab keeps its navigation
/// stack once it has been opened, as a `TabView` would, but the system tab
/// bar is not used: every tab draws `LedgerIconTabBar` itself, so on
/// 账本助手 the bar is part of the page the history drawer pushes aside.
///
/// Changing tab slides the pages sideways, as Claude's do: side by side, as
/// one strip, the new one in from the side of its icon and the old one out
/// the other way at the same pace, neither covering the other. The bar stays
/// still: while the pages move they hide their own and the shell draws one
/// over both.
struct LedgerIconTabShell<Content: View>: View {
    let model: LedgerIconTabBarModel
    @ViewBuilder var content: (LedgerDestination) -> Content
    /// The tabs opened so far; they stay mounted behind the selected one.
    @State private var opened: Set<LedgerDestination> = []
    @State private var menu = LedgerIconTabMenu()
    @State private var width: CGFloat = 0
    /// Where each page is drawn from, sideways, while they slide.
    @State private var offsets: [LedgerDestination: CGFloat] = [:]
    /// The page sliding out; drawn until the slide is over.
    @State private var leaving: LedgerDestination?
    @State private var slideCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var motion: Animation { .spring(response: 0.42, dampingFraction: 0.92) }

    var body: some View {
        ZStack {
            ForEach(model.destinations) { destination in
                if destination == model.selection || opened.contains(destination) {
                    let selected = destination == model.selection
                    let shown = selected || destination == leaving
                    content(destination)
                        .environment(\.ledgerIconTabBar, model)
                        .environment(\.ledgerTabSelected, selected)
                        .environment(\.ledgerIconTabBarHidden, leaving != nil)
                        .offset(x: offsets[destination] ?? 0)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(selected)
                        .accessibilityHidden(!selected)
                        .zIndex(shown ? 1 : 0)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if leaving != nil {
                LedgerIconTabBar(model: model)
                    .ledgerIconTabBarGround()
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: model.selection, initial: true) { old, new in
            opened.insert(new)
            if old != new { slide(from: old, to: new) }
        }
        .ledgerIconTabMenuLayer(menu)
    }

    private func slide(from old: LedgerDestination, to new: LedgerDestination) {
        guard !reduceMotion, width > 0,
              let from = model.destinations.firstIndex(of: old),
              let to = model.destinations.firstIndex(of: new) else { return }
        let direction: CGFloat = to > from ? 1 : -1
        slideCount += 1
        let current = slideCount
        // Placed first, without animation, so the next frame starts from
        // the side; then both move together.
        var place = Transaction()
        place.disablesAnimations = true
        withTransaction(place) {
            leaving = old
            offsets = [new: direction * width, old: 0]
        }
        DispatchQueue.main.async {
            guard current == slideCount else { return }
            withAnimation(Self.motion) {
                offsets[new] = 0
                offsets[old] = -direction * width
            } completion: {
                guard current == slideCount else { return }
                leaving = nil
                offsets = [:]
            }
        }
    }
}
#endif
