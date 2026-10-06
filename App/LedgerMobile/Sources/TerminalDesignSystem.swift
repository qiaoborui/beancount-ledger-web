import SwiftUI

enum TerminalPalette {
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x181D21) : .white
    })
    static let page = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x181D21) : UIColor(hex: 0xF5F6F4)
    })
    static let panel = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x222A30) : UIColor(hex: 0xE9EDE8)
    })
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0xE1E7E6) : UIColor(hex: 0x202B2E)
    })
    static let secondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0xA2AFAF) : UIColor(hex: 0x536266)
    })
    static let line = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x354047) : UIColor(hex: 0xCBD3CF)
    })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0xE5B55F) : UIColor(hex: 0x855300)
    })
    static let positive = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x86C89A) : UIColor(hex: 0x286B42)
    })
    static let negative = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0xF0A18C) : UIColor(hex: 0x9D3422)
    })
}

struct TerminalAmount: View {
    @EnvironmentObject private var session: LedgerSession
    let minorUnits: Int
    let currency: String
    var color: Color = TerminalPalette.ink
    var size: CGFloat = 16
    var prefix: String = ""
    var showsCurrency = false

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        Text(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency, showsCurrency: showsCurrency) : "••••••")
            .font(.system(size: size * scale, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.35)
            .accessibilityLabel(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency) : "金额已隐藏")
    }
}

struct TerminalRule: View {
    var body: some View { Rectangle().fill(TerminalPalette.line).frame(height: 1) }
}

struct TerminalDateRangeButton: View {
    var balanced = false
    @EnvironmentObject private var session: LedgerSession

    var body: some View {
        Button { session.presentRangePicker() } label: {
            HStack(spacing: 5) {
                Text(session.selectedRange.preset == .custom ? "自定义" : session.selectedRange.displayTitle).font(.system(size: 13, weight: .regular, design: balanced ? .default : .monospaced))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(balanced ? BalancedPalette.ink : TerminalPalette.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.isRangeLoading || session.isValuationCurrencyLoading)
        .accessibilityIdentifier("navigation-time-range")
        .accessibilityLabel("选择时间范围，当前为" + session.selectedRange.displayTitle)
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
    var balanced = false

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(balanced ? BalancedPalette.page : TerminalPalette.page)
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
                            if showsTimeRange { TerminalDateRangeButton(balanced: balanced) }
                            if showsSync && (!session.isLocal || session.localGitConfiguration != nil) { TerminalSyncButton(balanced: balanced) }
                            actions
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if horizontalSizeClass != .regular {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            if !isRoot {
                                Button { dismiss() } label: {
                                    Image(systemName: "chevron.left").font(.system(size: 18))
                                        .frame(width: 44, height: 44)
                                }.buttonStyle(.plain).foregroundStyle(balanced ? BalancedPalette.ink : TerminalPalette.accent)
                                    .accessibilityLabel("返回上一页")
                            }
                            Text(compactTitle ?? title)
                                .accessibilityLabel(title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(balanced ? BalancedPalette.ink : TerminalPalette.accent)
                            Spacer(minLength: 4)
                            if showsTimeRange { TerminalDateRangeButton(balanced: balanced).fixedSize(horizontal: true, vertical: false) }
                            if showsSync && (!session.isLocal || session.localGitConfiguration != nil) {
                                TerminalSyncButton(balanced: balanced)
                            }
                            actions
                        }
                        .padding(.horizontal, 12)
                        .frame(height: balanced ? 52 : 55)
                        Rectangle().fill(balanced ? BalancedPalette.rule : TerminalPalette.line).frame(height: 1)
                    }.background(balanced ? BalancedPalette.page : TerminalPalette.page)
                }
            }
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


/// The icon reports real repository state; opening details never initiates a sync.
private struct TerminalSyncButton: View {
    var balanced = false
    @EnvironmentObject private var session: LedgerSession
    @State private var detailsPresented = false

    private var presentation: LocalSyncPresentation {
        LocalSyncPresentation(status: session.localSyncStatus,
            hasGit: session.localGitConfiguration != nil,
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

    var body: some View {
        if session.isLocal {
            Button { detailsPresented = true } label: {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(balanced ? BalancedPalette.ink : (presentation.indicator == .attention ? TerminalPalette.negative : TerminalPalette.accent))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ledger-sync-status")
            .accessibilityLabel(presentation.title)
            .accessibilityHint("查看存储与同步详情")
            .sheet(isPresented: $detailsPresented) {
                LedgerStorageSheet().ledgerPrivacyProtectedSheet()
            }
        } else {
            // Server mode has no local Git status. Keep its refresh semantics explicit.
            Button { Task { await session.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(balanced ? BalancedPalette.ink : TerminalPalette.accent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
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
                            Text(destination == .transactions ? "流水" : destination.compactTitle)
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

struct TerminalSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).terminalFont(size: 11, weight: .semibold, design: .monospaced)
            .tracking(0.7).foregroundStyle(TerminalPalette.secondary).textCase(nil)
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
