import SwiftUI
import UIKit

enum LedgerPalette {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let panel = Color(uiColor: .secondarySystemGroupedBackground)
    static let raised = Color(uiColor: .tertiarySystemGroupedBackground)
    static let tag = Color.dynamic(light: 0xEEF2F6, dark: 0x1E2530)
    static let ink = Color.primary
    static let warm = Color.dynamic(light: 0x1F242B, dark: 0xD1D7E0)
    static let olive = Color.dynamic(light: 0x475569, dark: 0x94A3B8)
    static let secondary = Color.secondary
    static let line = Color(uiColor: .separator)
    static let lineStrong = Color.dynamic(light: 0xC5CED6, dark: 0x3E4754)
    static let cobalt = Color.dynamic(light: 0x0055D4, dark: 0x2E82F2)
    static let cobaltLight = Color.dynamic(light: 0x3B82F6, dark: 0x60A5FA)
    static let income = Color.dynamic(light: 0x107C41, dark: 0x30D158)
    static let expense = Color.dynamic(light: 0xD93829, dark: 0xFF6961)
    static let gold = Color.dynamic(light: 0xB45309, dark: 0xFBBF24)
    static let risk = Color.dynamic(light: 0xDC2626, dark: 0xFF453A)
    static let success = Color.dynamic(light: 0x16A34A, dark: 0x34D399)
    static let onBrand = Color(red: 0.985, green: 0.99, blue: 1)
    static let cardBorder = Color.dynamic(light: 0xE2E8F0, dark: 0x2A3240)
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
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let pill: CGFloat = 999
}

enum LedgerLayout {
    static let pageTopInset: CGFloat = 8
    static let rowVerticalInset: CGFloat = 6
    static let transactionVerticalInset: CGFloat = 10
    static let sidebarWidth: CGFloat = 208
    static let regularContentWidth: CGFloat = 1120
    static let regularPagePadding: CGFloat = 24
    static let compactTabBarClearance: CGFloat = 24
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

/// Shared page chrome; the application shell owns the navigation stack.
private struct LedgerNavigation: ViewModifier {
    let title: String
    let isRoot: Bool
    let showsTimeRange: Bool

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsTimeRange {
                    ToolbarItem(placement: .topBarLeading) {
                        LedgerTimeRangeButton()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    LedgerSyncToolbarButton()
                }
            }
    }
}

extension View {
    func ledgerNavigation(_ title: String, isRoot: Bool = true, showsTimeRange: Bool = false) -> some View {
        modifier(LedgerNavigation(title: title, isRoot: isRoot, showsTimeRange: showsTimeRange))
    }

    /// Reading surfaces share modern Apple grouped card layout with native feel.
    func ledgerReadingList() -> some View {
        listStyle(.insetGrouped)
            .listSectionSpacing(12)
            .contentMargins(.top, LedgerLayout.pageTopInset, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(LedgerPalette.canvas)
    }
}

/// Scoped search for pickers; the app shell owns the global search tab.
private struct LedgerSearch: ViewModifier {
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(prompt))
    }
}

private struct LedgerFloatingActionSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
                .padding(.horizontal, LedgerSpacing.md)
                .padding(.vertical, LedgerSpacing.sm)
        } else {
            content
                .background(LedgerPalette.raised, in: RoundedRectangle(cornerRadius: 24))
                .padding(.horizontal, LedgerSpacing.md)
                .padding(.vertical, LedgerSpacing.sm)
        }
    }
}

extension View {
    func ledgerSearch(text: Binding<String>, prompt: String) -> some View {
        modifier(LedgerSearch(text: text, prompt: prompt))
    }

    func ledgerFloatingActionSurface() -> some View {
        modifier(LedgerFloatingActionSurface())
    }

    @ViewBuilder
    func ledgerAdaptiveTabBar() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
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
                .accessibilityHidden(session.presentsPrivacyCover(sceneIsActive: scenePhase == .active))
                .allowsHitTesting(!session.presentsPrivacyCover(sceneIsActive: scenePhase == .active))
            if session.presentsPrivacyCover(sceneIsActive: scenePhase == .active) {
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
                .font(.body.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

struct LedgerPageContext: View {
    let detail: String
    var meta: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(detail)
                .font(.system(.footnote, design: .default))
                .foregroundStyle(LedgerPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let meta {
                Text(meta)
                    .font(.system(.caption2, design: .default, weight: .medium).monospacedDigit())
                    .foregroundStyle(LedgerPalette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, LedgerSpacing.md)
    }
}

struct LedgerPanel<Content: View>: View {
    var cornerRadius: CGFloat = LedgerRadius.md
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(LedgerPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(LedgerPalette.cardBorder.opacity(0.6), lineWidth: 0.5)
            }
    }
}

struct LedgerCardModifier: ViewModifier {
    var cornerRadius: CGFloat = LedgerRadius.md
    var padding: CGFloat = LedgerSpacing.lg

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(LedgerPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(LedgerPalette.cardBorder.opacity(0.6), lineWidth: 0.5)
            }
    }
}

struct LedgerTactileCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = LedgerRadius.lg
    var padding: CGFloat = LedgerSpacing.lg

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LedgerPalette.panel)
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.045),
                        radius: 8,
                        x: 0,
                        y: 3
                    )
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.015),
                        radius: 1.5,
                        x: 0,
                        y: 1
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.16 : 0.65),
                                LedgerPalette.cardBorder.opacity(colorScheme == .dark ? 0.4 : 0.6),
                                Color.black.opacity(colorScheme == .dark ? 0.2 : 0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
    }
}

extension View {
    func ledgerCard(cornerRadius: CGFloat = LedgerRadius.md, padding: CGFloat = LedgerSpacing.lg) -> some View {
        modifier(LedgerCardModifier(cornerRadius: cornerRadius, padding: padding))
    }

    func ledgerTactileCard(cornerRadius: CGFloat = LedgerRadius.lg, padding: CGFloat = LedgerSpacing.lg) -> some View {
        modifier(LedgerTactileCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(.subheadline, design: .default, weight: .semibold))
                .tracking(-0.15)
                .foregroundStyle(LedgerPalette.ink)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(.caption2, design: .default, weight: .medium).monospacedDigit())
                    .foregroundStyle(LedgerPalette.secondary)
            }
        }
    }
}

struct AmountLabel: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let minorUnits: Int
    let currency: String
    var prefix = ""
    var font: Font = .system(.subheadline, design: .rounded, weight: .semibold)
    var color: Color = LedgerPalette.ink
    var displayMode: MoneyText.DisplayMode = .adaptive
    var showSign = false

    var body: some View {
        amountText
            .font(font.monospacedDigit())
            .foregroundStyle(color)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.amountsVisible)
            .accessibilityLabel(
                session.amountsVisible
                    ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency, showSign: showSign)
                    : prefix.isEmpty ? "金额已隐藏" : prefix + "金额已隐藏"
            )
    }

    @ViewBuilder
    private var amountText: some View {
        if session.amountsVisible {
            switch displayMode {
            case .full:
                Text(prefix + MoneyText.format(minorUnits: minorUnits, currency: currency, showSign: showSign))
                    .fixedSize(horizontal: true, vertical: false)
            case .compact:
                Text(prefix + MoneyText.formatCompact(minorUnits: minorUnits, currency: currency, showSign: showSign))
                    .fixedSize(horizontal: true, vertical: false)
            case .adaptive:
                ViewThatFits(in: .horizontal) {
                    Text(prefix + MoneyText.format(minorUnits: minorUnits, currency: currency, showSign: showSign))
                        .fixedSize(horizontal: true, vertical: false)
                    Text(prefix + MoneyText.formatCompact(minorUnits: minorUnits, currency: currency, showSign: showSign))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
        } else {
            Text(prefix + "••••••")
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

enum LedgerStatusStyle {
    case pending
    case confirmed
    case failure

    var color: Color {
        switch self {
        case .pending: LedgerPalette.cobalt
        case .confirmed: LedgerPalette.success
        case .failure: LedgerPalette.risk
        }
    }

    var systemImage: String {
        switch self {
        case .pending: "clock.arrow.circlepath"
        case .confirmed: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }
}

struct StatusBanner: View {
    let message: String
    var style: LedgerStatusStyle = .failure
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: LedgerSpacing.sm) {
            Image(systemName: style.systemImage)
                .font(.system(.subheadline, design: .default))
                .foregroundStyle(style.color)
            Text(message)
                .font(.system(.caption, design: .default))
                .foregroundStyle(LedgerPalette.warm)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(.caption2, design: .default, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(LedgerPalette.secondary)
            .accessibilityLabel("关闭提示")
        }
        .padding(LedgerSpacing.md)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(style.color.opacity(0.42), lineWidth: 1)
        }
        .onChange(of: message, initial: true) { _, newMessage in
            UIAccessibility.post(notification: .announcement, argument: newMessage)
        }
    }
}

enum LedgerFeedback {
    @MainActor static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    @MainActor static func medium() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    @MainActor static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    @MainActor static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }

    @MainActor static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    @MainActor static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }
}

struct LedgerFrostedCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LedgerPalette.panel)
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.035),
                        radius: 10,
                        x: 0,
                        y: 3
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LedgerPalette.cardBorder.opacity(colorScheme == .dark ? 0.35 : 0.5),
                        lineWidth: 0.5
                    )
            }
    }
}

extension View {
    func ledgerFrostedCard(cornerRadius: CGFloat = 16, padding: CGFloat = 14) -> some View {
        modifier(LedgerFrostedCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var pressedScale: CGFloat = 0.95
    var enablesHaptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.65),
                value: configuration.isPressed
            )
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed && enablesHaptic && !reduceMotion {
                    LedgerFeedback.light()
                }
            }
    }
}

struct TactilePillButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var backgroundColor: Color = LedgerPalette.cobalt
    var foregroundColor: Color = LedgerPalette.onBrand

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, LedgerSpacing.lg)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: LedgerRadius.pill, style: .continuous)
                    .fill(backgroundColor)
                    .shadow(
                        color: backgroundColor.opacity(configuration.isPressed ? 0.15 : 0.28),
                        radius: configuration.isPressed ? 2 : 5,
                        x: 0,
                        y: configuration.isPressed ? 1 : 2.5
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: LedgerRadius.pill, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.2 : 0.4),
                        lineWidth: 0.5
                    )
            }
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.96 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.68),
                value: configuration.isPressed
            )
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed && !reduceMotion {
                    LedgerFeedback.light()
                }
            }
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
                .font(.body.weight(.semibold))
        }
        .foregroundStyle(LedgerPalette.onBrand)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(LedgerPalette.cobalt)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
    }
}

struct LedgerSyncToolbarButton: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var settingsPresented = false
    @State private var failureMessage: String?
    @State private var requested = false
    @State private var initialStatus: LocalStorageSyncStatus?

    private var presentation: LocalSyncPresentation {
        LocalSyncPresentation(status: session.localSyncStatus ?? initialStatus,
            hasGit: session.localGitConfiguration != nil,
            busy: session.isStorageSyncBusy || requested,
            automaticEnabled: session.localAutomaticSyncEnabled)
    }

    var body: some View {
        LedgerToolbarButton(action: activate,
            accessibilityLabel: session.isLocal ? presentation.title : "刷新账本") {
            HStack(spacing: 5) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                if presentation.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(indicatorColor)
                }
            }
        }
        .disabled(presentation.isBusy || session.phase != .ready)
        .accessibilityIdentifier("ledger-sync-status")
        .accessibilityHint(session.isLocal && presentation.action == .storageSettings
            ? "打开存储与同步设置" : "立即同步账本")
        .sheet(isPresented: $settingsPresented) {
            NavigationStack {
                LocalLedgerStorageView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { settingsPresented = false }
                        }
                    }
            }
            .ledgerPrivacyProtectedSheet()
        }
        .alert("同步未完成", isPresented: Binding(
            get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } }
        )) {
            Button("存储与同步") { failureMessage = nil; settingsPresented = true }
            Button("关闭", role: .cancel) { failureMessage = nil }
        } message: { Text(failureMessage ?? "") }
        .task(id: session.location) {
            initialStatus = nil
            failureMessage = nil
            let location = session.location
            let status = try? await session.localRepository?.storageStatus()
            if !Task.isCancelled, location == session.location { initialStatus = status }
        }
    }

    private var indicatorColor: Color {
        guard session.isLocal else { return LedgerPalette.cobalt }
        switch presentation.indicator {
        case .local: return .secondary
        case .syncing: return LedgerPalette.cobalt
        case .synced: return LedgerPalette.success
        case .pending: return LedgerPalette.gold
        case .attention: return LedgerPalette.risk
        }
    }

    private func activate() {
        guard !presentation.isBusy, session.phase == .ready else { return }
        if session.isLocal, presentation.action == .storageSettings {
            settingsPresented = true
            return
        }
        requested = true
        let location = session.location
        Task { @MainActor in
            defer { requested = false }
            do {
                if session.isLocal { _ = try await session.synchronizeLocalStorage() }
                else { await session.refresh() }
            } catch is CancellationError {
                return
            } catch {
                if session.location == location { failureMessage = error.localizedDescription }
            }
        }
    }
}

struct PrivacyToolbarButton: View {
    @EnvironmentObject private var session: LedgerSession

    var body: some View {
        LedgerToolbarButton(
            action: {
                LedgerFeedback.selection()
                session.toggleAmounts()
            },
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
        ContentUnavailableView(title, systemImage: icon, description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LedgerPalette.canvas)
    }
}

struct LedgerAccountChoice: Identifiable, Equatable {
    let account: String
    let label: String
    let group: String
    let active: Bool

    var id: String { account }
}

struct LedgerAccountPicker: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let accounts: [LedgerAccountChoice]
    @Binding var selection: String

    @State private var query = ""
    @State private var showingAddAccount = false
    @State private var showingAddCategory = false

    private var filteredAccounts: [LedgerAccountChoice] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return accounts }
        return accounts.filter {
            $0.label.localizedCaseInsensitiveContains(trimmed)
                || $0.account.localizedCaseInsensitiveContains(trimmed)
                || $0.group.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        List(filteredAccounts) { choice in
            Button {
                selection = choice.account
                dismiss()
            } label: {
                HStack(spacing: LedgerSpacing.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: LedgerSpacing.sm) {
                            Text(choice.label)
                                .font(.system(.subheadline, design: .default, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                            if !choice.active {
                                Text("已停用")
                                    .font(.system(.caption2, design: .default, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.gold)
                            }
                        }
                        Text(choice.account)
                            .font(.system(.caption2, design: .default, weight: .medium).monospaced())
                            .foregroundStyle(LedgerPalette.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if choice.account == selection {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(.body, design: .default, weight: .semibold))
                            .foregroundStyle(LedgerPalette.cobalt)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .listRowBackground(LedgerPalette.panel)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(LedgerPalette.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .ledgerSearch(text: $query, prompt: "搜索账户名称或路径")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingAddAccount = true
                    } label: {
                        Label("新建账户", systemImage: "building.columns")
                    }
                    Button {
                        showingAddCategory = true
                    } label: {
                        Label("新建分类", systemImage: "tag")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建账户或分类")
            }
        }
        .sheet(isPresented: $showingAddAccount) {
            AddAccountView()
                .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $showingAddCategory) {
            AddCategoryView()
                .ledgerPrivacyProtectedSheet()
        }
        .overlay {
            if filteredAccounts.isEmpty {
                EmptyLedgerState(
                    icon: "magnifyingglass",
                    title: "没有匹配的账户",
                    detail: "尝试搜索账户中文名称或完整路径。"
                )
            }
        }
    }
}
