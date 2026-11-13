import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var session: LedgerSession
    @Binding var overflowDestination: LedgerDestination?

    /// `localLedgerName` keeps the last opened local ledger, so a remote
    /// session names its server instead (as the login screen does).
    private var settingsDetail: String {
        if session.isLocal {
            return String(localized: "\(session.localLedgerName) · 本地")
        }
        return String(localized: "\(session.serverURL?.host ?? "Ledger") · 远程")
    }

    var body: some View {
        List {
            Section {
                NavigationLink { SettingsView(isRoot: false) } label: {
                    MoreNavigationRow(index: "00", icon: "gearshape", title: String(localized: "设置"), detail: settingsDetail)
                }.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)).listRowBackground(Color.clear).listRowSeparator(.hidden).navigationLinkIndicatorVisibility(.hidden).accessibilityIdentifier("more-settings")
            } header: { TerminalSectionLabel(text: String(localized: "系统")) }

            let remaining = [LedgerDestination.overview, .transactions, .accounts]
                .filter { !session.compactTabDestinations.contains($0) }
            if !remaining.isEmpty {
                Section { ForEach(remaining) { destination in
                    MoreDestinationButton(overflowDestination: $overflowDestination, destination: destination, detail: destination.title)
                }} header: { TerminalSectionLabel(text: String(localized: "账本")) }
            }
            Section {
                ForEach(LedgerAnalysisKind.allCases, id: \.self) { kind in
                    MoreDestinationButton(overflowDestination: $overflowDestination, destination: destination(for: kind), detail: kind.detail,
                        accessibilityIdentifier: "more-analysis-\(kind.rawValue)")
                }
                // Reports read the on-device ledger only.
                if session.isLocal {
                    NavigationLink { LedgerReportView() } label: {
                        MoreNavigationRow(index: "04", icon: "doc.text", title: String(localized: "周报 / 月报"), detail: String(localized: "按周、按月的收支小结与小票"))
                    }.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)).listRowBackground(Color.clear).listRowSeparator(.hidden).navigationLinkIndicatorVisibility(.hidden).accessibilityIdentifier("more-reports")
                }
            } header: { TerminalSectionLabel(text: String(localized: "财务分析")) }
            Section {
                // Search floats beside the tab bar where 账本助手 can't take that
                // button, and is a tab when chosen; otherwise it opens from here.
                if !directDestinations.contains(.search) {
                    MoreDestinationButton(overflowDestination: $overflowDestination, destination: .search, detail: String(localized: "交易、账户、标签与文件"), accessibilityIdentifier: "more-search")
                }
                NavigationLink { CategoriesManagementView() } label: {
                    MoreNavigationRow(index: "01", icon: "tag", title: String(localized: "分类管理"), detail: String(localized: "查看与新增收支分类"))
                }.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)).listRowBackground(Color.clear).listRowSeparator(.hidden).navigationLinkIndicatorVisibility(.hidden).accessibilityIdentifier("more-categories")
                MoreDestinationButton(overflowDestination: $overflowDestination, destination: .imports, detail: String(localized: "账单导入与归档"), accessibilityIdentifier: "more-imports")
                MoreDestinationButton(overflowDestination: $overflowDestination, destination: .currencies, detail: String(localized: "估值货币与汇率"), accessibilityIdentifier: "more-currencies")
                MoreDestinationButton(overflowDestination: $overflowDestination, destination: .query, detail: String(localized: "查询与历史"), accessibilityIdentifier: "more-query")
            } header: { TerminalSectionLabel(text: String(localized: "账本工具")) }
        }
        .scrollContentBackground(.hidden)
        .background(BalancedPalette.page)
        .listStyle(.plain)
        .listSectionSpacing(8)
        .tint(TerminalPalette.accent)
        .font(.subheadline)
        .accessibilityIdentifier("more-list")
        .terminalPageChrome(String(localized: "更多"), isRoot: true, balanced: true)
        .navigationDestination(item: overflowRoute) { destination in
            LedgerDestinationView(destination: destination)
        }
        .onChange(of: session.primaryDestinationID, initial: true) { _, _ in restoreOverflowRoute() }
    }

    /// The single item the page pushes for its overflow rows. Pops write nil
    /// here, which also clears the route the compact bar mirrors in
    /// `primaryDestinationID`: leaving it set made the next appearance restore
    /// the old page, and a navigation item that never became nil swallowed the
    /// next row's push until the tab was rebuilt.
    private var overflowRoute: Binding<LedgerDestination?> {
        Binding(
            get: { overflowDestination },
            set: { destination in
                overflowDestination = destination
                guard destination == nil else { return }
                let current = LedgerDestination.stored(session.primaryDestinationID)
                if current.isCompactOverflow(in: directDestinations) {
                    session.primaryDestinationID = LedgerDestination.settings.rawValue
                }
            }
        )
    }

    private var directDestinations: [LedgerDestination] {
        LedgerDestination.compactDirectDestinations(session.compactTabDestinations, agentFloats: session.agentFloatsInTabBar)
    }

    private func restoreOverflowRoute() {
        let destination = LedgerDestination.stored(session.primaryDestinationID)
        guard destination.isCompactOverflow(in: directDestinations) else { return }
        // Where the assistant floats, MainTabView opens it as a sheet instead.
        if destination == .agent, session.agentFloatsInTabBar { return }
        overflowDestination = destination
    }

    private func destination(for kind: LedgerAnalysisKind) -> LedgerDestination {
        switch kind { case .assets: .assets; case .incomeExpense: .incomeExpense; case .investments: .investments }
    }
}

private struct MoreDestinationButton: View {
    @EnvironmentObject private var session: LedgerSession
    @Binding var overflowDestination: LedgerDestination?
    let destination: LedgerDestination
    let detail: String
    var accessibilityIdentifier: String? = nil
    var body: some View {
        Group {
            if destination == .assets || destination == .incomeExpense || destination == .investments {
                NavigationLink { LedgerDestinationView(destination: destination, isRoot: false) } label: {
                    MoreNavigationRow(index: index, icon: destination.systemImage, title: destination.title, detail: detail)
                }.navigationLinkIndicatorVisibility(.hidden)
            } else {
                Button {
                    // Push the row directly. The session value only mirrors the
                    // current page for the compact bar, so a pop can clear it
                    // without this tap depending on a value change there.
                    overflowDestination = destination
                    session.primaryDestinationID = destination.rawValue
                } label: {
                    MoreNavigationRow(index: index, icon: destination.systemImage, title: destination.title, detail: detail)
                }
            }
        }.buttonStyle(.plain).listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)).listRowBackground(Color.clear).listRowSeparator(.hidden).accessibilityIdentifier(accessibilityIdentifier ?? "more-\(destination.rawValue)")
    }
    private var index: String {
        switch destination { case .overview: "01"; case .transactions: "02"; case .accounts: "03"; case .assets: "01"; case .incomeExpense: "02"; case .investments: "03"; case .search: "01"; case .imports: "02"; case .currencies: "03"; case .query: "04"; case .agent: "00"; case .settings: "00" }
    }
}

/// `.row` — exactly one `--rule` hairline, full column width; `.row .chev` in
/// `--edge`. The native disclosure indicator is hidden at the call site
/// (`.navigationLinkIndicatorVisibility(.hidden)`) so this is the only chevron.
private struct MoreNavigationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let index: String
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize { EmptyView() }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                Text(detail).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BalancedPalette.edge)
        }
        .frame(minHeight: 44)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
        .contentShape(Rectangle())
    }
}
