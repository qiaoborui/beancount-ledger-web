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

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        Text(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency) : "••••••")
            .font(.system(size: size * scale, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.35)
            .accessibilityLabel(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency) : "金额已隐藏")
    }
}

struct TerminalRule: View {
    var body: some View { Rectangle().fill(TerminalPalette.line).frame(height: 1 / UIScreen.main.scale) }
}

struct TerminalDateRangeButton: View {
    @EnvironmentObject private var session: LedgerSession

    var body: some View {
        Button { session.presentRangePicker() } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar").font(.system(size: 12, weight: .semibold))
                Text(session.selectedRange.toolbarTitle()).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(TerminalPalette.ink)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(TerminalPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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
    @EnvironmentObject private var session: LedgerSession
    let title: String
    let compactTitle: String?

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(TerminalPalette.page)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                    .terminalPlainBackground()
                ToolbarItem(placement: .topBarLeading) {
                    Text(compactTitle ?? title)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(TerminalPalette.accent)
                }
                .terminalPlainBackground()
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        TerminalDateRangeButton().fixedSize(horizontal: true, vertical: false)
                        if !session.isLocal || session.localGitConfiguration != nil {
                            TerminalSyncButton()
                        }
                    }
                }
                .terminalPlainBackground()
            }

    }
}

extension View {
    func terminalPageChrome(_ title: String, compactTitle: String? = nil) -> some View {
        modifier(TerminalPageChrome(title: title, compactTitle: compactTitle))
    }
}


/// The icon reports real repository state; opening details never initiates a sync.
private struct TerminalSyncButton: View {
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
        case .local, .synced: "checkmark.circle"
        case .syncing: "arrow.triangle.2.circlepath"
        case .pending: "arrow.up.circle"
        case .attention: "exclamationmark.circle"
        }
    }

    var body: some View {
        if session.isLocal {
            Button { detailsPresented = true } label: {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(presentation.indicator == .attention ? TerminalPalette.negative : TerminalPalette.accent)
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
                    .foregroundStyle(TerminalPalette.accent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(session.phase != .ready)
            .accessibilityIdentifier("ledger-sync-status")
            .accessibilityLabel("刷新账本")
        }
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder
    func terminalPlainBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
