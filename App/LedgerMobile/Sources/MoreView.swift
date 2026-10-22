import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var session: LedgerSession
    @Binding var overflowDestination: LedgerDestination?

    var body: some View {
        List {
            Section {
                NavigationLink { SettingsView(isRoot: false) } label: {
                    MoreNavigationRow(index: "00", icon: "gearshape", title: String(localized: "设置"), detail: String(localized: "\(session.localLedgerName) · 本地"))
                }.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)).listRowBackground(Color.clear).listRowSeparator(.hidden).navigationLinkIndicatorVisibility(.hidden).accessibilityIdentifier("more-settings")
            } header: { TerminalSectionLabel(text: String(localized: "系统")) }

            let remaining = [LedgerDestination.overview, .transactions, .accounts]
                .filter { !session.compactTabDestinations.contains($0) }
            if !remaining.isEmpty {
                Section { ForEach(remaining) { destination in
                    MoreDestinationButton(destination: destination, detail: destination.title)
                }} header: { TerminalSectionLabel(text: String(localized: "账本")) }
            }
            Section { ForEach(LedgerAnalysisKind.allCases, id: \.self) { kind in
                MoreDestinationButton(destination: destination(for: kind), detail: kind.detail,
                    accessibilityIdentifier: "more-analysis-\(kind.rawValue)")
            }} header: { TerminalSectionLabel(text: String(localized: "财务分析")) }
            Section {
                MoreDestinationButton(destination: .search, detail: String(localized: "搜索整个账本"), accessibilityIdentifier: "more-search")
                NavigationLink { CategoriesManagementView() } label: {
                    MoreNavigationRow(index: "02", icon: "tag", title: String(localized: "分类管理"), detail: String(localized: "查看与新增收支分类"))
                }.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)).listRowBackground(Color.clear).listRowSeparator(.hidden).navigationLinkIndicatorVisibility(.hidden).accessibilityIdentifier("more-categories")
                MoreDestinationButton(destination: .imports, detail: String(localized: "账单导入与归档"), accessibilityIdentifier: "more-imports")
                MoreDestinationButton(destination: .currencies, detail: String(localized: "估值货币与汇率"), accessibilityIdentifier: "more-currencies")
                MoreDestinationButton(destination: .query, detail: String(localized: "查询与历史"), accessibilityIdentifier: "more-query")
            } header: { TerminalSectionLabel(text: String(localized: "账本工具")) }
        }
        .scrollContentBackground(.hidden)
        .background(BalancedPalette.page)
        .listStyle(.plain)
        .listSectionSpacing(8)
        .tint(TerminalPalette.accent)
        .font(.subheadline)
        .accessibilityIdentifier("more-list")
        .terminalPageChrome(String(localized: "更多"), isRoot: true,
            actions: AnyView(Button { session.primaryDestinationID = LedgerDestination.search.rawValue } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(TerminalPalette.accent).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("搜索账本").accessibilityIdentifier("more-header-search")), balanced: true)
        .navigationDestination(item: $overflowDestination) { destination in
            LedgerDestinationView(destination: destination)
        }
        .onChange(of: session.primaryDestinationID, initial: true) { _, _ in restoreOverflowRoute() }
        .onChange(of: overflowDestination) { _, destination in
            guard destination == nil else { return }
            let current = LedgerDestination.stored(session.primaryDestinationID)
            if current.isCompactOverflow(in: session.compactTabDestinations) { session.primaryDestinationID = LedgerDestination.settings.rawValue }
        }
    }

    private func restoreOverflowRoute() {
        let destination = LedgerDestination.stored(session.primaryDestinationID)
        guard destination.isCompactOverflow(in: session.compactTabDestinations) else { return }
        overflowDestination = destination
    }

    private func destination(for kind: LedgerAnalysisKind) -> LedgerDestination {
        switch kind { case .assets: .assets; case .incomeExpense: .incomeExpense; case .investments: .investments }
    }
}

private struct MoreDestinationButton: View {
    @EnvironmentObject private var session: LedgerSession
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
                Button { session.primaryDestinationID = destination.rawValue } label: {
                    MoreNavigationRow(index: index, icon: destination.systemImage, title: destination.title, detail: detail)
                }
            }
        }.buttonStyle(.plain).listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)).listRowBackground(Color.clear).listRowSeparator(.hidden).accessibilityIdentifier(accessibilityIdentifier ?? "more-\(destination.rawValue)")
    }
    private var index: String {
        switch destination { case .overview: "01"; case .transactions: "02"; case .accounts: "03"; case .assets: "01"; case .incomeExpense: "02"; case .investments: "03"; case .search: "01"; case .imports: "03"; case .currencies: "04"; case .query: "05"; case .settings: "00" }
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
