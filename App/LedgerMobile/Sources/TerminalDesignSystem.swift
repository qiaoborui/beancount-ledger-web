import SwiftUI

/// Retargeted to the Balanced tokens (docs/design/ios-balanced) so every legacy
/// page that still reaches for `TerminalPalette` inherits Balanced colour
/// without a per-call-site rewrite. There is no accent colour in Balanced —
/// `accent` maps to `ink`, the same tone as every other label.
enum TerminalPalette {
    static let onAccent = BalancedPalette.page
    static let page = BalancedPalette.page
    static let panel = BalancedPalette.sunken
    static let ink = BalancedPalette.ink
    static let secondary = BalancedPalette.secondary
    static let line = BalancedPalette.rule
    static let accent = BalancedPalette.ink
    static let positive = BalancedPalette.income
    static let negative = BalancedPalette.expense
}

/// Proportional Plex Sans with tabular figures — Balanced reserves mono for
/// account paths and beancount source only, never amounts.
struct TerminalAmount: View {
    @EnvironmentObject private var session: LedgerSession
    let minorUnits: Int
    let currency: String
    var color: Color = TerminalPalette.ink
    var size: CGFloat = 16
    var prefix: String = ""
    var showsCurrency = false

    var body: some View {
        Text(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency, showsCurrency: showsCurrency) : "••••••")
            .font(.custom(BalancedWeight.text.sansPostscriptName, size: size, relativeTo: .body))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.35)
            .accessibilityLabel(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency) : String(localized: "金额已隐藏"))
    }
}

struct TerminalRule: View {
    var body: some View { Rectangle().fill(TerminalPalette.line).frame(height: 1) }
}

struct TerminalDateRangeButton: View {
    /// Retained for call-site compatibility; Balanced is the only appearance now.
    var balanced = false
    @EnvironmentObject private var session: LedgerSession

    var body: some View {
        Button { session.presentRangePicker() } label: {
            HStack(spacing: 5) {
                Text(session.selectedRange.preset == .custom ? String(localized: "自定义") : session.selectedRange.displayTitle)
                    .balancedFont(size: 13)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(BalancedPalette.ink)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.isRangeLoading || session.isValuationCurrencyLoading)
        .accessibilityIdentifier("navigation-time-range")
        .accessibilityLabel("选择时间范围，当前为\(session.selectedRange.displayTitle)")
    }
}

struct TerminalPageChrome: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var isRoot = true
    @EnvironmentObject private var session: LedgerSession
    let title: String
    let compactTitle: String?
    var actions: AnyView? = nil
    var showsTimeRange = false
    var showsSync = true
    /// Retained for call-site compatibility; Balanced is the only appearance now.
    var balanced = false

    private var titleText: some View {
        Text(compactTitle ?? title)
            .accessibilityLabel(title)
            .balancedFont(size: 17, weight: .medium)
            .tracking(-0.085)
            .foregroundStyle(BalancedPalette.ink)
            .lineLimit(1)
    }

    @ViewBuilder private var trailingControls: some View {
        if showsTimeRange { TerminalDateRangeButton().fixedSize(horizontal: true, vertical: false) }
        if showsSync && (!session.isLocal || session.hasLocalRemoteSync) {
            TerminalSyncButton()
        }
        actions
    }

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .background {
                if !isRoot && horizontalSizeClass != .regular {
                    TerminalBackGestureBridge().frame(width: 0, height: 0)
                }
            }
            .toolbar(horizontalSizeClass == .regular ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if horizontalSizeClass == .regular {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 8) {
                            if showsTimeRange { TerminalDateRangeButton() }
                            if showsSync && (!session.isLocal || session.hasLocalRemoteSync) { TerminalSyncButton() }
                            actions
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if horizontalSizeClass != .regular {
                    // `.appbar` (styles.css): `padding: 4px var(--pad) 10px`
                    // with `--pad: 20px`, so a root title sits at x=20. `.back`
                    // is a 44×44 hit target with `margin-left: -8px`, pulling
                    // its box left so the chevron glyph still lands near
                    // x=20. A pushed page (d11/d12/d15) centers its title
                    // between the chevron and the trailing actions instead of
                    // setting it left-aligned next to the chevron.
                    Group {
                        if isRoot {
                            HStack(spacing: 8) {
                                titleText
                                Spacer(minLength: 4)
                                trailingControls
                            }
                        } else {
                            BalancedPushedBarLayout(spacing: 8) {
                                Button { dismiss() } label: {
                                    Image(systemName: "chevron.left").font(.system(size: 18))
                                        .frame(width: 44, height: 44, alignment: .leading)
                                        .padding(.leading, 8)
                                }.buttonStyle(.plain).foregroundStyle(BalancedPalette.ink)
                                    .accessibilityLabel("返回上一页")
                                    .padding(.leading, -8)
                                titleText
                                HStack(spacing: 8) { trailingControls }.fixedSize()
                            }
                        }
                    }
                    .padding(.leading, 20)
                    .padding(.trailing, 20)
                    .frame(height: 52)
                    .background(BalancedPalette.page)
                }
            }
    }
}

/// Pushed-page bar: back button, title, trailing controls. The title is
/// centred across the whole bar (d11/d12/d15) but never drawn under either
/// side — when the trailing cluster is wider than the back button, it moves
/// toward the gap between them, and truncates once that gap is too small.
private struct BalancedPushedBarLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(leading))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(trailing))
        let minX = bounds.minX + leading.width + spacing
        let maxX = bounds.maxX - trailing.width - spacing
        let available = max(0, maxX - minX)
        let width = min(subviews[1].sizeThatFits(ProposedViewSize(width: available, height: bounds.height)).width, available)
        let x = min(max(bounds.midX - width / 2, minX), maxX - width)
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

/// A custom compact header must not disable UINavigationController's edge-swipe pop.
/// Scope the delegate to the visible destination and restore UIKit's delegate on exit.
private struct TerminalBackGestureBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.installIfVisible() }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.restore() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private struct OriginalGesture {
            weak var recognizer: UIGestureRecognizer?
            weak var delegate: UIGestureRecognizerDelegate?
            var enabled: Bool
        }
        private var originals: [OriginalGesture] = []
        private var isVisible = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            installIfVisible()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            installIfVisible()
        }

        func installIfVisible() {
            guard isVisible, let navigationController else { return }
            var recognizers = [navigationController.interactivePopGestureRecognizer].compactMap { $0 }
            // iOS 26+ also routes back swipes through the content-area recognizer.
            if #available(iOS 26.0, *), let content = navigationController.interactiveContentPopGestureRecognizer {
                recognizers.append(content)
            }
            for recognizer in recognizers where recognizer.delegate !== self {
                originals.append(OriginalGesture(recognizer: recognizer, delegate: recognizer.delegate, enabled: recognizer.isEnabled))
                recognizer.delegate = self
                recognizer.isEnabled = true
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isVisible = false
            restore()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController,
                  navigationController.viewControllers.count > 1,
                  navigationController.transitionCoordinator == nil else { return false }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: pan.view)
                let direction: CGFloat = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
                return velocity.x * direction > abs(velocity.y)
            }
            return true
        }

        func restore() {
            for original in originals.reversed() {
                guard let recognizer = original.recognizer, recognizer.delegate === self else { continue }
                recognizer.delegate = original.delegate
                recognizer.isEnabled = original.enabled
            }
            originals.removeAll()
        }
    }

}

extension View {
    func terminalPageChrome(_ title: String, compactTitle: String? = nil, isRoot: Bool = true, showsTimeRange: Bool = false, showsSync: Bool = true, actions: AnyView? = nil, balanced: Bool = false) -> some View {
        modifier(TerminalPageChrome(isRoot: isRoot, title: title, compactTitle: compactTitle, actions: actions, showsTimeRange: showsTimeRange, showsSync: showsSync, balanced: balanced))
    }
}


/// The icon reports real repository state; opening details never initiates a
/// sync. Balanced carries that state as a small dot (`.iconbtn .dot`), not a
/// colour change on the glyph itself.
private struct TerminalSyncButton: View {
    /// Retained for call-site compatibility; Balanced is the only appearance now.
    var balanced = false
    @EnvironmentObject private var session: LedgerSession
    @State private var detailsPresented = false

    private var presentation: LocalSyncPresentation {
        LocalSyncPresentation(status: session.localSyncStatus,
            hasGit: session.hasLocalRemoteSync,
            busy: session.isStorageSyncBusy,
            automaticEnabled: session.localAutomaticSyncEnabled)
    }

    private var symbol: String {
        switch presentation.indicator {
        case .local, .synced: "checkmark"
        case .syncing: "arrow.triangle.2.circlepath"
        case .pending: "square.and.arrow.up"
        case .attention: "exclamationmark.triangle"
        }
    }

    private var dotColor: Color {
        switch presentation.indicator {
        case .local: BalancedPalette.meta
        case .synced: BalancedPalette.income
        case .syncing: BalancedPalette.secondary
        case .pending, .attention: BalancedPalette.expense
        }
    }

    private func iconButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(BalancedPalette.secondary)
                    .frame(width: 44, height: 44)
                Circle().fill(dotColor).frame(width: 8, height: 8)
                    .offset(x: -9, y: 9)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        if session.isLocal {
            iconButton(symbol: symbol) { detailsPresented = true }
                .accessibilityIdentifier("ledger-sync-status")
                .accessibilityLabel(presentation.title)
                .accessibilityHint("查看存储与同步详情")
                .sheet(isPresented: $detailsPresented) {
                    LedgerStorageSheet().ledgerPrivacyProtectedSheet()
                }
        } else {
            // Server mode has no local Git status. Keep its refresh semantics explicit.
            iconButton(symbol: "arrow.clockwise") { Task { await session.refresh() } }
                .disabled(session.phase != .ready)
                .accessibilityIdentifier("ledger-sync-status")
                .accessibilityLabel("刷新账本")
        }
    }
}

/// The native TabView retains each navigation stack; only its visual tab strip is replaced.
struct TerminalTabBar: View {
    let destinations: [LedgerDestination]
    @Binding var selection: LedgerDestination

    var body: some View {
        VStack(spacing: 0) {
            TerminalRule()
            HStack(spacing: 8) {
                ForEach(destinations) { destination in
                    let selected = selection == destination || (selection == .search && destination == .settings)
                    Button { selection = destination } label: {
                        VStack(spacing: 3) {
                            Image(systemName: destination == .settings ? "ellipsis" : destination.systemImage)
                                .font(.system(size: 18, weight: .regular)).frame(height: 20)
                            Text(destination == .transactions ? String(localized: "流水") : destination.compactTitle)
                                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            Rectangle().fill(selected ? TerminalPalette.accent : .clear).frame(width: 16, height: 2)
                        }
                        .foregroundStyle(selected ? TerminalPalette.ink : TerminalPalette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("terminal-tab-" + destination.rawValue)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(.horizontal, 12).padding(.vertical, 7.5)
        }.background(TerminalPalette.page)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminal-tab-bar")
    }
}

private struct TerminalFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design
    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.weight = weight
        self.design = design
    }
    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    func terminalFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(TerminalFont(size: size, weight: weight, design: design))
    }
}

/// `.sechead` — 12.5pt / 500 / `--ink-3` / +0.03em. No numbered prefix, no
/// mono, no uppercase: the label is the heading, not a terminal readout.
struct TerminalSectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .balancedFont(size: 12.5, weight: .medium)
            .tracking(0.375)
            .foregroundStyle(BalancedPalette.meta)
    }
}

/// Native editor and sheet chrome retains system navigation and all existing
/// confirmation/cancellation toolbar actions. Reading pages use PageChrome.
struct TerminalNativeChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(TerminalPalette.page)
            .tint(TerminalPalette.accent)
            .toolbarBackground(TerminalPalette.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(nil, for: .navigationBar)
            .listStyle(.plain)
            .listSectionSpacing(8)
            .font(.subheadline)
    }
}

extension View {
    func terminalNativeChrome() -> some View { modifier(TerminalNativeChrome()) }
}
